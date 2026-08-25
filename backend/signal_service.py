"""Computes the CURRENT buy/sell/hold signal + conviction for a (ticker,
strategy) combo, reusing backtester's own validated strategy code exactly -
this module contains zero trading logic of its own, only the same sequence
auto_trader.py's _trade_target already runs each poll cycle, minus order
execution/position checks.

Read-only: never touches roster.json/control.json, never places an order.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone

import pandas as pd

from backtester import current_signals
from backtester.accounts import account_asset_class, build_broker_accounts, infer_asset_class, list_accounts
from backtester.conviction import compute_conviction, compute_levels
from backtester.data import PolygonClient
from backtester.oanda_data import OandaDataClient, OandaError
from backtester.strategies import build_strategy
from backtester.strategy import Bar, Signal

# Preference order for the crypto direct-fetch fallback below - matches
# auto_trader.py's _pick_live_data_source reasoning exactly: Coinbase's
# get_live_bars can page back several days, Kraken's OHLC endpoint can't
# page backward at all (confirmed live 2026-08-20, ~12h ceiling regardless
# of how far back you ask) - so Coinbase is tried first, Kraken only if
# Coinbase isn't linked/reachable.
_CRYPTO_BROKER_PREFERENCE = ("coinbase", "kraken")

_live_crypto_account = False  # False = not yet resolved, None = resolved-to-unavailable


def _get_live_crypto_account():
    """Lazily built, cached for the process lifetime - same pattern as
    auto_trader.py's _get_oanda_client. Finds the first linked, live
    (non-paper) crypto account matching _CRYPTO_BROKER_PREFERENCE and
    exposing get_live_bars; returns None (falls back to Polygon) if no such
    account is linked, mirroring exactly what auto_trader.py's own fallback
    chain does when nothing better is available."""
    global _live_crypto_account
    if _live_crypto_account is not False:
        return _live_crypto_account
    candidates = {
        broker_name: acct for acct in list_accounts()
        if not acct["is_paper"] and account_asset_class(acct) == "crypto"
        for broker_name in [acct["broker"]]
    }
    for broker_name in _CRYPTO_BROKER_PREFERENCE:
        acct = candidates.get(broker_name)
        if acct is None:
            continue
        try:
            built = build_broker_accounts([acct["id"]])
        except Exception:  # noqa: BLE001 - a broken/unreachable link just falls through to Polygon
            continue
        if built and hasattr(built[0], "get_live_bars"):
            _live_crypto_account = built[0]
            return _live_crypto_account
    _live_crypto_account = None
    return None


_live_equity_account = False  # False = not yet resolved, None = resolved-to-unavailable


def _get_live_equity_account():
    """Same pattern as _get_live_crypto_account, for equities. Added
    2026-08-20 alongside it, after a real gap was caught live: the shared
    snapshot goes stale (>SNAPSHOT_STALE_SECONDS) whenever auto_trader.py
    stops rewriting a ticker's entry every cycle - which happens legitimately
    whenever that ticker's market is closed, not just when auto_trader.py is
    down - and this fallback had branches for forex/crypto but NONE for
    equities, so it fell straight to Polygon every time that happened
    (confirmed on a real device: PSKY/ZBRA/WTW/BIIB all showing "Polygon
    (direct)" at 20-25min staleness with the market closed, auto_trader.py
    itself perfectly healthy). AlpacaBroker is currently the only broker
    class exposing get_live_bars for equities (see auto_trader.py's
    _pick_live_data_source) - prefers a live (non-paper) account, same
    "prefer real, not simulated" reasoning as the crypto helper, but the data
    itself is identical either way (Alpaca's IEX feed doesn't differ by
    paper/live status) - a paper-only-linked setup still gets real live bars,
    just isn't preferred over a live one if both exist."""
    global _live_equity_account
    if _live_equity_account is not False:
        return _live_equity_account
    linked = list_accounts()
    equity_accounts = [a for a in linked if account_asset_class(a) == "equity"]
    for acct in sorted(equity_accounts, key=lambda a: a["is_paper"]):  # live (False) sorts before paper (True)
        try:
            built = build_broker_accounts([acct["id"]])
        except Exception:  # noqa: BLE001 - a broken/unreachable link just falls through to Polygon
            continue
        if built and hasattr(built[0], "get_live_bars"):
            _live_equity_account = built[0]
            return _live_equity_account
    _live_equity_account = None
    return None

# Same flat window auto_trader.py's LOOKBACK_DAYS uses - enough history for
# any strategy's default window, even on daily bars. Not required_lookback()
# -driven, matching the live bot exactly (see auto_trader.py).
LOOKBACK_DAYS = 90

# Trailing closes returned for the app's sparkline - matches auto_trader.py's
# own RECENT_CLOSES_COUNT so a snapshot hit and a direct fetch look identical.
RECENT_CLOSES_COUNT = 30

# 3x the shared 120s poll interval - same staleness margin auto_trader.py's
# own singleton guard uses for its heartbeat. Beyond this, auto_trader.py is
# either not running or stuck, and a direct fetch is the honest fallback.
SNAPSHOT_STALE_SECONDS = 360


@dataclass
class SignalResult:
    ticker: str
    strategy_name: str
    signal: str  # Signal.value: "buy" / "sell" / "hold"
    conviction: float | None
    price: float
    computed_at: str  # ISO timestamp of the bar this was computed from
    error: str | None = None
    source: str | None = None  # which feed the bars came from, e.g. "MyAlpaca (live)" or "Polygon"
    recent_closes: list[float] | None = None  # trailing closes for the app's sparkline
    recent_opens: list[float] | None = None  # matching trailing OHLC for the app's candlestick chart
    recent_highs: list[float] | None = None
    recent_lows: list[float] | None = None
    levels: dict[str, float] | None = None  # strategy's own reference levels, see Strategy.levels()
    # market_open/trading_accounts: only ever known via the snapshot (auto_trader.py
    # has real broker connections; this backend deliberately doesn't) - stay None
    # on the direct-fetch fallback path below, same as an older snapshot missing
    # these keys. None means "unknown", not "closed" - see current_signals.py.
    market_open: bool | None = None
    trading_accounts: list[str] | None = None


def _signal_from_snapshot(ticker: str, strategy_name: str) -> SignalResult | None:
    """Reuse auto_trader.py's already-computed signal for this ticker this
    cycle instead of hitting Polygon a second time for identical data - see
    backtester.current_signals. Both this backend and auto_trader.py share
    one Polygon account and its real ~5 req/min free-tier ceiling; each
    self-throttling independently doesn't stop their combined, uncoordinated
    calls from tripping a real 429 when their cycles land close together.

    Returns None (falls back to a direct fetch below) if auto_trader.py
    isn't running, hasn't evaluated this ticker yet, is currently trading a
    different strategy for it (e.g. mid roster change), or the entry has
    gone stale.
    """
    entry = current_signals.load_signals().get(ticker)
    if entry is None or entry.get("strategy_name") != strategy_name:
        return None
    try:
        written_at = datetime.fromisoformat(entry["written_at"])
    except (KeyError, ValueError):
        return None
    age = (datetime.now(timezone.utc) - written_at).total_seconds()
    if age > SNAPSHOT_STALE_SECONDS:
        return None
    return SignalResult(
        ticker=ticker, strategy_name=strategy_name, signal=entry["signal"],
        conviction=entry.get("conviction"), price=entry.get("price", 0.0),
        computed_at=entry.get("bar_timestamp", ""),
        source=entry.get("source"),  # entry.get(...) so older snapshots without these keys still parse
        recent_closes=entry.get("recent_closes"),
        recent_opens=entry.get("recent_opens"),
        recent_highs=entry.get("recent_highs"),
        recent_lows=entry.get("recent_lows"),
        levels=entry.get("levels"),
        market_open=entry.get("market_open"),
        trading_accounts=entry.get("trading_accounts"),
    )


def fetch_live_bars(
    ticker: str,
    from_date: date,
    to_date: date,
    client: PolygonClient,
    multiplier: int = 1,
    timespan: str = "minute",
) -> tuple[pd.DataFrame, str]:
    """Bars for `ticker` from the best LIVE source for its asset class,
    with a human-readable label for where they came from.

    Same preference as auto_trader.py's own fallback chain: OANDA for forex
    (data only - IG stays the only forex execution venue; see
    CLAUDE_NOTES.txt), a live crypto broker (Coinbase preferred, see
    _get_live_crypto_account) for crypto, a live equity broker (Alpaca, see
    _get_live_equity_account) for equities - the equity and crypto branches
    added 2026-08-20, Polygon is backtesting-only from here on, project-wide,
    not just in auto_trader.py. Polygon remains ONLY as the last-resort
    fallback when a live source is unavailable or returns nothing.

    In compute_current_signal's use this is the SECOND line of defense - the
    shared snapshot already carries auto_trader.py's own live-sourced bars
    when it's running AND fresh; this is what matters whenever that snapshot
    goes stale for a reason OTHER than auto_trader.py being down - e.g. a
    closed market, where auto_trader.py legitimately stops rewriting that
    ticker's entry every cycle (real gap found 2026-08-20: equities used to
    always fall through to Polygon the moment the snapshot aged past
    SNAPSHOT_STALE_SECONDS, even with auto_trader.py perfectly healthy).

    Extracted from compute_current_signal 2026-08-25 so the /bars endpoint
    (the app's 1m/5m candle toggle) resolves its source through exactly this
    same chain rather than a second, drifting copy of it - every broker's
    get_live_bars already takes multiplier/timespan, so an arbitrary
    granularity needs no per-broker work here.
    """
    # DELIBERATELY no IG branch here, even though IGBroker gained a
    # get_live_bars() on 2026-08-25 for index tickers (I:NDX). IG's
    # historical-price allowance is only 10,000 points per WEEK, and
    # auto_trader.py already spends part of it inside a tight
    # market-open window (see its _index_bars_window_open). This backend
    # polls on its own independent schedule, so calling IG here too would
    # double-spend the same shared weekly budget for what is only a DISPLAY
    # refresh. Index tickers therefore fall through to Polygon below - which
    # is fine for display, and the app usually shows auto_trader's own
    # IG-sourced bars anyway via the shared snapshot (_signal_from_snapshot).
    bars = None
    source_label = "Polygon (direct)"
    asset_class = infer_asset_class(ticker)
    if asset_class == "forex":
        try:
            bars = OandaDataClient().get_live_bars(
                ticker=ticker, from_date=from_date.isoformat(), to_date=to_date.isoformat(),
                multiplier=multiplier, timespan=timespan,
            )
            if bars.empty:
                bars = None
            else:
                source_label = "OANDA (direct)"
        except OandaError:
            bars = None  # OANDA_API_KEY not set yet - fall through to Polygon
    elif asset_class == "crypto":
        crypto_account = _get_live_crypto_account()
        if crypto_account is not None:
            try:
                bars = crypto_account.get_live_bars(
                    ticker=ticker, from_date=from_date.isoformat(), to_date=to_date.isoformat(),
                    multiplier=multiplier, timespan=timespan,
                )
                if bars.empty:
                    bars = None
                else:
                    source_label = f"{crypto_account.nickname} (direct)"
            except Exception:  # noqa: BLE001 - a transient exchange-API error just falls through to Polygon
                bars = None
    elif asset_class == "equity":
        equity_account = _get_live_equity_account()
        if equity_account is not None:
            try:
                bars = equity_account.get_live_bars(
                    ticker=ticker, from_date=from_date.isoformat(), to_date=to_date.isoformat(),
                    multiplier=multiplier, timespan=timespan,
                )
                if bars.empty:
                    bars = None
                else:
                    source_label = f"{equity_account.nickname} (direct)"
            except Exception:  # noqa: BLE001 - a transient broker-API error just falls through to Polygon
                bars = None
    if bars is None:
        bars = client.get_aggregates(
            ticker=ticker,
            from_date=from_date.isoformat(),
            to_date=to_date.isoformat(),
            multiplier=multiplier,
            timespan=timespan,
        )
    return bars, source_label


def compute_current_signal(
    ticker: str, strategy_name: str, params: dict, client: PolygonClient
) -> SignalResult:
    """Mirrors auto_trader.py's _trade_target signal-computation steps
    exactly: fetch recent bars, build the strategy, run on_bar, and (unlike
    the live bot, which only scores conviction on a BUY for sizing purposes)
    compute conviction whenever the signal isn't HOLD - this app is purely
    informational, so a SELL's conviction is just as useful to show.

    Tries the shared snapshot first (see _signal_from_snapshot) - a direct
    Polygon fetch only happens when there's no fresh snapshot to reuse.
    """
    snapshot = _signal_from_snapshot(ticker, strategy_name)
    if snapshot is not None:
        return snapshot

    try:
        to_date = date.today()
        from_date = to_date - timedelta(days=LOOKBACK_DAYS)
        bars, source_label = fetch_live_bars(
            ticker, from_date, to_date, client, multiplier=1, timespan="minute",
        )
        if bars.empty or len(bars) < 2:
            return SignalResult(
                ticker=ticker, strategy_name=strategy_name, signal=Signal.HOLD.value,
                conviction=None, price=0.0, computed_at="", error="not enough bar history",
            )

        strategy = build_strategy(strategy_name, params=params)
        row = bars.iloc[-1]
        current = Bar(
            timestamp=bars.index[-1], open=row["open"], high=row["high"],
            low=row["low"], close=row["close"], volume=row["volume"],
        )
        signal = strategy.on_bar(bars, current)
        conviction = compute_conviction(strategy, bars, current) if signal != Signal.HOLD else None
        levels = compute_levels(strategy, bars, current)
        recent_bars = bars.tail(RECENT_CLOSES_COUNT)

        return SignalResult(
            ticker=ticker, strategy_name=strategy_name, signal=signal.value,
            conviction=conviction, price=float(current.close),
            computed_at=current.timestamp.isoformat(),
            source=source_label,  # no fresh auto_trader.py snapshot to reuse - see _signal_from_snapshot
            recent_closes=[float(c) for c in recent_bars["close"]],
            recent_opens=[float(o) for o in recent_bars["open"]],
            recent_highs=[float(h) for h in recent_bars["high"]],
            recent_lows=[float(l) for l in recent_bars["low"]],
            levels=levels,
        )
    except Exception as e:  # noqa: BLE001
        # A single combo failing (bad ticker, transient Polygon error) must
        # never take down the whole refresh cycle - report it, don't raise.
        return SignalResult(
            ticker=ticker, strategy_name=strategy_name, signal=Signal.HOLD.value,
            conviction=None, price=0.0, computed_at="", error=str(e),
        )
