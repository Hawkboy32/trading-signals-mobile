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

from backtester import current_signals
from backtester.conviction import compute_conviction, compute_levels
from backtester.data import PolygonClient
from backtester.strategies import build_strategy
from backtester.strategy import Bar, Signal

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
    levels: dict[str, float] | None = None  # strategy's own reference levels, see Strategy.levels()


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
        levels=entry.get("levels"),
    )


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
        bars = client.get_aggregates(
            ticker=ticker,
            from_date=from_date.isoformat(),
            to_date=to_date.isoformat(),
            multiplier=1,
            timespan="minute",
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

        return SignalResult(
            ticker=ticker, strategy_name=strategy_name, signal=signal.value,
            conviction=conviction, price=float(current.close),
            computed_at=current.timestamp.isoformat(),
            source="Polygon (direct)",  # no fresh auto_trader.py snapshot to reuse - see _signal_from_snapshot
            recent_closes=[float(c) for c in bars["close"].tail(RECENT_CLOSES_COUNT)],
            levels=levels,
        )
    except Exception as e:  # noqa: BLE001
        # A single combo failing (bad ticker, transient Polygon error) must
        # never take down the whole refresh cycle - report it, don't raise.
        return SignalResult(
            ticker=ticker, strategy_name=strategy_name, signal=Signal.HOLD.value,
            conviction=None, price=0.0, computed_at="", error=str(e),
        )
