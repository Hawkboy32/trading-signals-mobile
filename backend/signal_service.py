"""Computes the CURRENT buy/sell/hold signal + conviction for a (ticker,
strategy) combo, reusing backtester's own validated strategy code exactly -
this module contains zero trading logic of its own, only the same sequence
auto_trader.py's _trade_target already runs each poll cycle, minus order
execution/position checks.

Read-only: never touches roster.json/control.json, never places an order.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, timedelta

from backtester.conviction import compute_conviction
from backtester.data import PolygonClient
from backtester.strategies import build_strategy
from backtester.strategy import Bar, Signal

# Same flat window auto_trader.py's LOOKBACK_DAYS uses - enough history for
# any strategy's default window, even on daily bars. Not required_lookback()
# -driven, matching the live bot exactly (see auto_trader.py).
LOOKBACK_DAYS = 90


@dataclass
class SignalResult:
    ticker: str
    strategy_name: str
    signal: str  # Signal.value: "buy" / "sell" / "hold"
    conviction: float | None
    price: float
    computed_at: str  # ISO timestamp of the bar this was computed from
    error: str | None = None


def compute_current_signal(
    ticker: str, strategy_name: str, params: dict, client: PolygonClient
) -> SignalResult:
    """Mirrors auto_trader.py's _trade_target signal-computation steps
    exactly: fetch recent bars, build the strategy, run on_bar, and (unlike
    the live bot, which only scores conviction on a BUY for sizing purposes)
    compute conviction whenever the signal isn't HOLD - this app is purely
    informational, so a SELL's conviction is just as useful to show.
    """
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

        return SignalResult(
            ticker=ticker, strategy_name=strategy_name, signal=signal.value,
            conviction=conviction, price=float(current.close),
            computed_at=current.timestamp.isoformat(),
        )
    except Exception as e:  # noqa: BLE001
        # A single combo failing (bad ticker, transient Polygon error) must
        # never take down the whole refresh cycle - report it, don't raise.
        return SignalResult(
            ticker=ticker, strategy_name=strategy_name, signal=Signal.HOLD.value,
            conviction=None, price=0.0, computed_at="", error=str(e),
        )
