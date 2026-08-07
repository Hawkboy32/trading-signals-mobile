"""Read-only signal API for the mobile app - serves the CURRENT buy/sell/hold
+ conviction for whatever the live auto_trader is actually configured to
trade (the roster's active/paused entries, plus any extra_targets like the
IG forex combo). Never writes to roster.json/control.json, never places an
order - purely mirrors "what the bot is thinking" for manual decision-making.

Run: uvicorn signal_api:app --host 0.0.0.0 --port 8600
"""

from __future__ import annotations

import threading
import time
from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path

from dotenv import load_dotenv
from fastapi import FastAPI

from backtester.auto_trader_state import load_control
from backtester.data import PolygonClient
from backtester.roster import load_roster
from signal_service import compute_current_signal

ROSTER_STATUSES = ("active", "paused")

# Load by absolute path, cwd-independent, same as auto_trader.py/scan_runner.py.
# Must happen before PolygonClient() is ever instantiated (in _refresh_loop).
load_dotenv(Path(__file__).resolve().parent.parent.parent / "backtester" / ".env")

REFRESH_SECONDS = 120  # matches the live bot's own poll_interval_seconds

app = FastAPI(title="Trading Signal API", description="Read-only buy/sell/hold + conviction feed")

_cache: dict[str, object] = {"signals": [], "last_refreshed": None, "last_error": None}
_cache_lock = threading.Lock()


def _current_combos() -> list[tuple[str, str, dict]]:
    """(ticker, strategy_name, params) for everything the live bot is
    configured to trade right now - the roster's active/paused entries plus
    every extra_targets group's tickers. Re-read fresh each refresh cycle so
    a roster re-evaluation or a new extra_targets config is picked up
    automatically, no separate watchlist to maintain."""
    combos: list[tuple[str, str, dict]] = []

    roster = load_roster()
    for entry in roster.entries:
        if entry.status in ROSTER_STATUSES:
            combos.append((entry.ticker, entry.strategy_name, entry.params))

    control = load_control()
    for group in control.extra_targets:
        strategy_name = group.get("strategy_name", "")
        params = group.get("strategy_params", {})
        for ticker in group.get("tickers", []):
            combos.append((ticker, strategy_name, params))

    return combos


def _refresh_loop() -> None:
    client = PolygonClient(use_cache=False)  # must see fresh bars, not a stale same-day cache hit
    while True:
        try:
            combos = _current_combos()
            results = [compute_current_signal(t, s, p, client) for t, s, p in combos]
            with _cache_lock:
                _cache["signals"] = [asdict(r) for r in results]
                _cache["last_refreshed"] = datetime.now(timezone.utc).isoformat()
                _cache["last_error"] = None
        except Exception as e:  # noqa: BLE001
            # A whole-cycle failure (e.g. roster.json unreadable) must never
            # kill the refresh loop - log it and keep serving the last good
            # cache rather than going permanently stale/silent.
            with _cache_lock:
                _cache["last_error"] = str(e)
        time.sleep(REFRESH_SECONDS)


@app.on_event("startup")
def _start_refresh_loop() -> None:
    threading.Thread(target=_refresh_loop, daemon=True).start()


@app.get("/health")
def health() -> dict:
    with _cache_lock:
        return {
            "status": "ok",
            "last_refreshed": _cache["last_refreshed"],
            "last_error": _cache["last_error"],
        }


@app.get("/signals")
def signals() -> dict:
    with _cache_lock:
        return {
            "signals": _cache["signals"],
            "last_refreshed": _cache["last_refreshed"],
        }


@app.get("/roster")
def roster() -> dict:
    """Roster health: each active/paused combo's live win rate, trade count,
    and pause reason, plus the demotion thresholds they're judged against
    (roster.py's RosterConfig - min_live_trades, losing_streak_threshold,
    etc.) so the app can show "why is this paused / how close to being
    judged" instead of a bare status label. Read-only, reads fresh on every
    request - a local file read, not a Polygon call, so this doesn't need
    the cached refresh loop /signals has."""
    state = load_roster()
    entries = [
        {
            "ticker": e.ticker,
            "strategy_name": e.strategy_name,
            "status": e.status,
            "pause_reason": e.pause_reason,
            "live_stats": e.live_stats,
        }
        for e in state.entries
        if e.status in ROSTER_STATUSES
    ]
    return {"entries": entries, "config": asdict(state.config)}
