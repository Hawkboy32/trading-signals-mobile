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
from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel

import _auth
from backtester import notifications
from backtester.auto_trader_state import load_control, save_control, trigger_kill_switch
from backtester.data import PolygonClient
from backtester.live_trades import list_recent_trades
from backtester.roster import load_roster
from positions_service import fetch_all_positions
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
    # enabled/killed are exposed unauthenticated - same read-only trust level as
    # the rest of this file's GET endpoints, and the app needs them just to
    # decide whether to show a Stop or a Start button. Actually CHANGING either
    # value still requires the full /kill or /rearm login flow below.
    control = load_control()
    with _cache_lock:
        return {
            "status": "ok",
            "last_refreshed": _cache["last_refreshed"],
            "last_error": _cache["last_error"],
            "enabled": control.enabled,
            "killed": control.killed,
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


@app.get("/trades")
def trades() -> dict:
    """Most recent closed round trips (real trading activity only - see
    list_recent_trades' own docstring for why the old 'mock-1' test rows are
    excluded). Read-only, reads fresh on every request - a local sqlite read,
    not a Polygon call."""
    return {"trades": list_recent_trades(limit=50)}


# --------------------------------------------------------------------------
# Auth + write-capable endpoints. Everything above this line is read-only and
# always was; /kill and /rearm are the first endpoints that can change
# anything, so they're gated behind a real login (see _auth.py) - a bearer
# token proves "I logged in with password+TOTP earlier", and the password
# sent fresh on EACH of /kill and /rearm proves "I mean this specific action
# right now", not just a standing session left open on an unlocked phone.
# --------------------------------------------------------------------------


class LoginRequest(BaseModel):
    username: str
    password: str
    totp_code: str


class ActionRequest(BaseModel):
    password: str


def _require_session(authorization: str | None = Header(default=None)) -> str:
    token = None
    if authorization and authorization.lower().startswith("bearer "):
        token = authorization[7:].strip()
    username = _auth.resolve_session(token)
    if username is None:
        raise HTTPException(status_code=401, detail="Not logged in, or session expired - log in again.")
    return username


@app.post("/login")
def login(req: LoginRequest) -> dict:
    ok, error = _auth.verify_login(req.username, req.password, req.totp_code)
    if not ok:
        raise HTTPException(status_code=401, detail=error)
    token, expires_at = _auth.create_session(req.username)
    return {"token": token, "expires_at": expires_at}


@app.post("/kill")
def kill(req: ActionRequest, username: str = Depends(_require_session)) -> dict:
    """Immediate remote stop. Requires a valid session (proves "logged in
    earlier") AND the password fresh in this request (proves "I mean this
    specific tap right now") - protects against both a fat-fingered press and
    a standing session on an unlocked phone."""
    if not _auth.verify_password(username, req.password):
        raise HTTPException(status_code=401, detail="Incorrect password.")
    trigger_kill_switch()
    notifications.notify_kill_switch_engaged("the mobile app")
    return {"ok": True, "control": {"enabled": False, "killed": True}}


@app.post("/rearm")
def rearm(req: ActionRequest, username: str = Depends(_require_session)) -> dict:
    """Re-enables trading (enabled=True, killed=False) on the ALREADY-RUNNING
    auto_trader.py process - deliberately does not launch a new process the
    way the dashboard's Start button can, since the process is expected to
    already be alive via the startup-folder shortcut + singleton guard. If
    the process itself is down, that's a separate concern for the desktop
    side, not something this remote endpoint tries to fix. Re-arming resumes
    money-moving activity, meaningfully riskier than stopping, so it gets the
    same password-confirmation friction as /kill, not a lighter check."""
    if not _auth.verify_password(username, req.password):
        raise HTTPException(status_code=401, detail="Incorrect password.")
    control = load_control()
    control.enabled = True
    control.killed = False
    save_control(control)
    return {"ok": True, "control": {"enabled": True, "killed": False}}


@app.get("/positions")
def positions(username: str = Depends(_require_session)) -> dict:
    """Live open positions + unrealized P&L, per linked account - the first
    endpoint that touches real broker credentials (see positions_service.py's
    own docstring for the full reasoning). Login-gated like /kill and /rearm,
    but no password re-confirmation needed each request - it's a read, not an
    action, so the friction only needs to match "are you logged in", not
    "do you specifically mean this one tap"."""
    return {"accounts": fetch_all_positions()}
