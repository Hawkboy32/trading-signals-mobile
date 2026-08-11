"""Read-only signal API for the mobile app - serves the CURRENT buy/sell/hold
+ conviction for whatever the live auto_trader is actually configured to
trade (the roster's active/paused entries, plus any extra_targets like the
IG forex combo). Never places an order directly, never touches backtests or
account/broker credentials - the only writes are the explicit, login-gated,
password-confirmed live-bot actions below (/kill, /rearm, /risk-preset).

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
from backtester.accounts import list_accounts
from backtester.auto_trader_state import load_control, save_control, trigger_kill_switch
from backtester.data import PolygonClient
from backtester.execution import sliding_pct_equity
from backtester.live_trades import list_recent_trades
from backtester.risk_presets import RISK_PRESETS, apply_risk_preset
from backtester.roster import load_roster
from backtester.strategies import STRATEGY_REGISTRY
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


@app.get("/risk-presets")
def risk_presets() -> dict:
    """The actual RISK_PRESETS values (sizing/vol-target/drawdown/giveback per
    preset) - unauthenticated read, same trust level as /health's enabled/
    killed, so the app can show real current numbers instead of a hardcoded
    copy that could drift from the dashboard's own definition."""
    return {"presets": RISK_PRESETS}


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
            "risk_preset": control.risk_preset,
        }


@app.get("/signals")
def signals() -> dict:
    with _cache_lock:
        return {
            "signals": _cache["signals"],
            "last_refreshed": _cache["last_refreshed"],
        }


def _roster_entry_dict(e) -> dict:
    return {
        "ticker": e.ticker,
        "strategy_name": e.strategy_name,
        "status": e.status,
        "pause_reason": e.pause_reason,
        "live_stats": e.live_stats,
        "promoted_at": e.promoted_at,
        "paused_at": e.paused_at,
        "backtest_score": e.backtest_score,
    }


@app.get("/roster")
def roster() -> dict:
    """Roster health: each active/paused combo's live win rate, trade count,
    pause reason, promoted/paused timestamps, and the backtest score it was
    selected on, plus the demotion thresholds they're judged against
    (roster.py's RosterConfig - min_live_trades, losing_streak_threshold,
    etc.) so the app can show "why is this paused / how close to being
    judged" instead of a bare status label.

    Also returns the top candidates (not yet promoted) ranked by
    backtest_score, capped at 10 - the full candidate pool can run to dozens
    of entries, which isn't "what's coming next" so much as noise; the config
    dict's num_candidates carries the true total so the app can show "top 10
    of N" honestly rather than implying the list is exhaustive.

    Read-only, reads fresh on every request - a local file read, not a
    Polygon call, so this doesn't need the cached refresh loop /signals has.
    """
    state = load_roster()
    entries = [_roster_entry_dict(e) for e in state.entries if e.status in ROSTER_STATUSES]
    all_candidates = [e for e in state.entries if e.status == "candidate"]
    top_candidates = sorted(all_candidates, key=lambda e: e.backtest_score, reverse=True)[:10]
    config = asdict(state.config)
    config["num_candidates"] = len(all_candidates)
    return {
        "entries": entries,
        "candidates": [_roster_entry_dict(e) for e in top_candidates],
        "config": config,
    }


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


class RiskPresetRequest(BaseModel):
    preset: str
    password: str


@app.post("/risk-preset")
def risk_preset(req: RiskPresetRequest, username: str = Depends(_require_session)) -> dict:
    """Switches the live bot's risk dial (Conservative/Moderate/Aggressive) -
    same backtester.risk_presets.apply_risk_preset the dashboard's own preset
    buttons call, so the two surfaces can never define the preset differently.
    Changes real position sizing for the next trade onward, so it gets the
    same password-confirmation friction as /kill and /rearm, not a lighter
    check just because it isn't a full stop."""
    if req.preset not in RISK_PRESETS:
        raise HTTPException(status_code=400, detail=f"Unknown preset. Choose one of: {', '.join(RISK_PRESETS)}")
    if not _auth.verify_password(username, req.password):
        raise HTTPException(status_code=401, detail="Incorrect password.")
    control = apply_risk_preset(req.preset)
    return {"ok": True, "risk_preset": control.risk_preset, "sizing_value": control.sizing_value}


@app.get("/positions")
def positions(username: str = Depends(_require_session)) -> dict:
    """Live open positions + unrealized P&L, per linked account - the first
    endpoint that touches real broker credentials (see positions_service.py's
    own docstring for the full reasoning). Login-gated like /kill and /rearm,
    but no password re-confirmation needed each request - it's a read, not an
    action, so the friction only needs to match "are you logged in", not
    "do you specifically mean this one tap"."""
    return {"accounts": fetch_all_positions()}


@app.get("/targets")
def targets(username: str = Depends(_require_session)) -> dict:
    """What the live bot is currently configured to trade - Manual (fixed
    strategy/ticker list) vs Adaptive roster, and the manual-mode fields
    themselves. Login-gated like /positions (a read, no password needed) -
    this is meaningfully more revealing than /health's bare enabled/killed
    booleans, on par with seeing open positions."""
    control = load_control()
    return {
        "mode": "roster" if control.use_roster else "manual",
        "tickers": control.tickers,
        "strategy_name": control.strategy_name,
        "available_strategies": list(STRATEGY_REGISTRY.keys()),
    }


class TargetsRequest(BaseModel):
    mode: str
    tickers: list[str] = []
    strategy_name: str = ""
    password: str


@app.post("/targets")
def set_targets(req: TargetsRequest, username: str = Depends(_require_session)) -> dict:
    """Switches Manual/Adaptive roster mode and, in Manual mode, the
    ticker list + strategy - the same fields app.py's Auto Trading tab
    Save button writes. Changes what the bot trades from the next poll
    cycle onward, so it gets the same password-confirmation friction as
    /kill and /risk-preset."""
    if req.mode not in ("manual", "roster"):
        raise HTTPException(status_code=400, detail='mode must be "manual" or "roster"')
    tickers = [t.strip().upper() for t in req.tickers if t.strip()]
    if req.mode == "manual" and not tickers:
        raise HTTPException(status_code=400, detail="Manual mode needs at least one ticker.")
    if req.mode == "manual" and req.strategy_name not in STRATEGY_REGISTRY:
        raise HTTPException(status_code=400, detail=f"Unknown strategy: {req.strategy_name}")
    if not _auth.verify_password(username, req.password):
        raise HTTPException(status_code=401, detail="Incorrect password.")

    control = load_control()
    control.use_roster = req.mode == "roster"
    if req.mode == "manual":
        control.tickers = tickers
        control.strategy_name = req.strategy_name
    save_control(control)
    return {"ok": True, "mode": req.mode, "tickers": control.tickers, "strategy_name": control.strategy_name}


def _account_sizing_view(account_id: str, override: dict, target_pct: float, equity_by_id: dict) -> dict:
    equity = equity_by_id.get(account_id)
    slide_start_pct = float(override.get("slide_start_pct", 0.0))
    slide_floor_notional = float(override.get("slide_floor_notional", 1.0))
    current_effective_pct = None
    if slide_start_pct > 0 and equity is not None:
        current_effective_pct = sliding_pct_equity(equity, slide_start_pct, target_pct, slide_floor_notional)
    return {
        "equity": equity,
        "slide_start_pct": slide_start_pct,
        "slide_floor_notional": slide_floor_notional,
        "target_pct": target_pct,
        "current_effective_pct": current_effective_pct,
    }


@app.get("/sizing")
def sizing(username: str = Depends(_require_session)) -> dict:
    """Per-account sliding-scale sizing (backtester.execution.sliding_pct_equity)
    for every account currently selected for auto-trading - real live equity
    (reusing positions_service's cached fetch, no extra broker call) joined
    against each account's slide_start_pct/slide_floor_notional override, plus
    the CURRENT effective rate computed live from that equity - the "what's it
    actually trading at right now" figure that isn't a fixed number anywhere
    else, since the slide recomputes fresh at every trade entry. Login-gated
    like /positions - a read, no password needed."""
    control = load_control()
    accounts_by_id = {a["id"]: a for a in list_accounts()}
    equity_by_id = {a["account_id"]: a["equity"] for a in fetch_all_positions() if a.get("account_id")}

    rows = []
    for account_id in control.account_ids:
        account = accounts_by_id.get(account_id)
        if account is None:
            continue
        override = control.account_sizing_overrides.get(account_id, {})
        view = _account_sizing_view(account_id, override, control.sizing_value, equity_by_id)
        rows.append({
            "account_id": account_id,
            "nickname": account["nickname"],
            "broker": account["broker"],
            "is_paper": account["is_paper"],
            **view,
        })
    return {"accounts": rows}


class SizingRequest(BaseModel):
    account_id: str
    slide_start_pct: float
    slide_floor_notional: float = 1.0
    password: str


@app.post("/sizing")
def set_sizing(req: SizingRequest, username: str = Depends(_require_session)) -> dict:
    """Sets or clears (slide_start_pct=0) one account's sliding-scale sizing
    override - the same account_sizing_overrides the dashboard's Auto Trading
    tab writes per-account, under Target accounts. Changes real position
    sizing from the next trade onward, so it gets the same password-
    confirmation friction as /kill and /risk-preset."""
    control = load_control()
    if req.account_id not in control.account_ids:
        raise HTTPException(status_code=400, detail="That account isn't currently selected for auto-trading.")
    if req.slide_start_pct < 0:
        raise HTTPException(status_code=400, detail="slide_start_pct can't be negative.")
    if not _auth.verify_password(username, req.password):
        raise HTTPException(status_code=401, detail="Incorrect password.")

    control = load_control()
    if req.slide_start_pct == 0:
        control.account_sizing_overrides.pop(req.account_id, None)
    else:
        control.account_sizing_overrides[req.account_id] = {
            "slide_start_pct": req.slide_start_pct,
            "slide_floor_notional": req.slide_floor_notional,
        }
    save_control(control)

    accounts_by_id = {a["id"]: a for a in list_accounts()}
    equity_by_id = {a["account_id"]: a["equity"] for a in fetch_all_positions() if a.get("account_id")}
    override = control.account_sizing_overrides.get(req.account_id, {})
    view = _account_sizing_view(req.account_id, override, control.sizing_value, equity_by_id)
    account = accounts_by_id.get(req.account_id, {})
    return {
        "ok": True,
        "account_id": req.account_id,
        "nickname": account.get("nickname"),
        **view,
    }
