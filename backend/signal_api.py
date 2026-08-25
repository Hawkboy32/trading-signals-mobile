"""Read-only signal API for the mobile app - serves the CURRENT buy/sell/hold
+ conviction for whatever the live auto_trader is actually configured to
trade (the roster's active/paused entries, plus any extra_targets like the
IG forex combo). Never places an order directly, never touches backtests or
account/broker credentials - the only writes are the explicit, login-gated,
password-confirmed live-bot actions below (/kill, /rearm, /risk-preset).

Run: uvicorn signal_api:app --host 0.0.0.0 --port 8600
"""

from __future__ import annotations

import ipaddress
import threading
import time
from dataclasses import asdict
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

from dotenv import load_dotenv
from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel

import _auth
from backtester import account_risk, execution_log, notifications, position_attribution, source_stamp, version
from backtester.accounts import build_broker_accounts, list_accounts
from backtester.auto_trader_state import load_control, save_control, trigger_kill_switch
from backtester.brokers.base import OrderSide, summarize_fees
from backtester.data import PolygonClient
from backtester.deposits import deposits_for, record_deposit, remove_deposit, total_deposited
from backtester.execution import sliding_pct_equity
from backtester.live_trades import (
    UNATTRIBUTED_STRATEGY, list_recent_trades, recent_performance, record_realized_trade,
)
from backtester.risk_presets import RISK_PRESETS, apply_risk_preset
from backtester.roster import (
    RosterConfig, append_event, clear_pending, load_pending, load_roster, save_roster,
)
from backtester.tax import TaxSettings, compute_tax_summary, load_tax_settings, save_tax_settings
from backtester.strategies import STRATEGY_REGISTRY
from positions_service import fetch_all_positions
from signal_service import compute_current_signal, fetch_live_bars

ROSTER_STATUSES = ("active", "paused")

# Load by absolute path, cwd-independent, same as auto_trader.py/scan_runner.py.
# Must happen before PolygonClient() is ever instantiated (in _refresh_loop).
load_dotenv(Path(__file__).resolve().parent.parent.parent / "backtester" / ".env")

REFRESH_SECONDS = 120  # matches the live bot's own poll_interval_seconds

app = FastAPI(title="Trading Signal API", description="Read-only buy/sell/hold + conviction feed")

# Tailscale hands every node an address in the CGNAT range 100.64.0.0/10.
# Matching the RANGE rather than one hardcoded IP means a tailnet address
# change (new device, re-auth, Tailscale reassignment) can't silently lock the
# phone out.
_TAILSCALE_CGNAT = ipaddress.ip_network("100.64.0.0/10")


def _is_allowed_client(host: str | None) -> bool:
    """Loopback (the watchdog's own /health poll, and any local tooling) or
    the tailnet. Everything else is refused — see the middleware below."""
    if not host:
        return False
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        return False
    return ip.is_loopback or ip in _TAILSCALE_CGNAT


@app.middleware("http")
async def restrict_to_tailnet(request, call_next):
    """The server binds 0.0.0.0 (it must: the watchdog health-checks it on
    127.0.0.1 while the phone reaches it over Tailscale), which also exposed
    it to every peer on whatever LAN this machine happened to join — a café
    or hotel network included. The unauthenticated read endpoints
    (/signals, /roster, /trades, /health, the APK download) would hand any
    such peer the full trade history with P&L, the live roster and its
    performance stats, and current positions-derived signals. Writes were
    never at risk (all password-confirmed), but the reads are real financial
    activity data. Rejecting by client IP keeps the bind unchanged — so
    nothing that already worked breaks — while cutting off the LAN.
    """
    if not _is_allowed_client(request.client.host if request.client else None):
        return JSONResponse(status_code=403, content={"detail": "Forbidden."})
    return await call_next(request)


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
    # Same stale-code stamp the trader and dashboard record — this backend
    # imports the shared backtester library too, so it goes stale the same
    # way. See backtester/src/backtester/source_stamp.py.
    source_stamp.record_start("mobile_backend")
    threading.Thread(target=_refresh_loop, daemon=True).start()


# One PolygonClient for /bars, separate from _refresh_loop's own (that one
# lives inside its thread). use_cache=False for the same reason: a chart the
# user just asked to redraw must show fresh bars, not a stale same-day hit.
_bars_client = PolygonClient(use_cache=False)

# Granularities the app's candle toggle may request. An allowlist rather than
# passing multiplier/timespan straight through: these are the two the UI
# actually offers, and every value here is known to work across all four live
# sources (Alpaca/Coinbase/Kraken/OANDA all take multiplier+timespan already).
_ALLOWED_GRANULARITIES = {(1, "minute"), (5, "minute"), (15, "minute")}

# How far back to ask for, per granularity. Coarser bars need a wider window
# to fill the same bar count - 60 x 15min is ~15 hours of MARKET time, i.e.
# ~2.5 equity sessions, which 7 calendar days covers comfortably (and 60 x
# 1min needs a fraction of it, so one value serves all three).
#
# Kraken deliberately gets no special case: its public OHLC endpoint can't
# page backward (only returns the most recent ~12h regardless of what's asked
# for, confirmed 2026-08-20), so a Kraken-sourced crypto chart is simply
# shorter - and at 15min that ceiling bites soonest, giving ~48 bars rather
# than 60. Coinbase is the preferred crypto source anyway (see
# _get_live_crypto_account), so this is a fallback-path cosmetic limit, not a
# correctness one.
_BARS_LOOKBACK_DAYS = {"minute": 7}
_BARS_COUNT = 60  # more than the signal card's 30 - this is the zoomed-in view


@app.get("/bars")
def bars(ticker: str, multiplier: int = 1, timespan: str = "minute") -> dict:
    """OHLC bars at a requested granularity, for the app's expanded candle
    view and its 1m/5m toggle (2026-08-25).

    Unauthenticated, same read-only trust level as /signals - this is market
    data, not account data. Resolves its source through signal_service's
    shared fetch_live_bars(), so it follows exactly the same live-broker
    preference chain as everything else and can't drift from it.
    """
    if (multiplier, timespan) not in _ALLOWED_GRANULARITIES:
        allowed = ", ".join(f"{m}/{t}" for m, t in sorted(_ALLOWED_GRANULARITIES))
        raise HTTPException(
            status_code=400,
            detail=f"Unsupported granularity {multiplier}/{timespan}. Allowed: {allowed}",
        )
    to_date = date.today()
    from_date = to_date - timedelta(days=_BARS_LOOKBACK_DAYS.get(timespan, 7))
    try:
        frame, source = fetch_live_bars(
            ticker, from_date, to_date, _bars_client,
            multiplier=multiplier, timespan=timespan,
        )
    except Exception as e:  # noqa: BLE001 - a data-source failure is a 502, not a crash
        raise HTTPException(status_code=502, detail=f"Could not load bars: {e}") from e
    if frame.empty:
        raise HTTPException(status_code=404, detail=f"No bars available for {ticker}")
    recent = frame.tail(_BARS_COUNT)
    return {
        "ticker": ticker,
        "multiplier": multiplier,
        "timespan": timespan,
        "source": source,
        "computed_at": recent.index[-1].isoformat(),
        "opens": [float(o) for o in recent["open"]],
        "highs": [float(h) for h in recent["high"]],
        "lows": [float(low) for low in recent["low"]],
        "closes": [float(c) for c in recent["close"]],
    }


@app.get("/risk-presets")
def risk_presets() -> dict:
    """The actual RISK_PRESETS values (sizing/vol-target/drawdown/giveback per
    preset) - unauthenticated read, same trust level as /health's enabled/
    killed, so the app can show real current numbers instead of a hardcoded
    copy that could drift from the dashboard's own definition."""
    return {"presets": RISK_PRESETS}


_APK_PATH = (
    Path(__file__).resolve().parent.parent / "flutter_app" / "build" / "app" / "outputs"
    / "flutter-apk" / "app-release.apk"
)


@app.get("/download/app-release.apk")
def download_apk():
    """Serves the latest built release APK over Tailscale so it can be
    installed straight from the phone's browser - unauthenticated by
    necessity (you need the app installed before you can log into it), same
    trust level as /health below. Fixed path, not user-supplied, so this
    isn't a general file server - just this one known build artifact."""
    if not _APK_PATH.exists():
        raise HTTPException(status_code=404, detail="No release APK built yet.")
    return FileResponse(
        _APK_PATH, media_type="application/vnd.android.package-archive", filename="trading-signals.apk"
    )


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
            "sizing_mode": control.sizing_mode,
            "sizing_value": control.sizing_value,
            "backend_version": version.VERSION,
        }


_NY_TZ = ZoneInfo("America/New_York")
_UK_TZ = ZoneInfo("Europe/London")
_DAY_LABELS = ["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"]


def _ny_clock_to_uk_minutes(ny_date: date, hour: int, minute: int) -> int:
    """Converts a US-market clock time on a given (ET-calendar) date into
    minutes-since-midnight UK LOCAL time on that SAME calendar date. Real
    zoneinfo conversion, not a hardcoded offset - the US and UK don't always
    shift DST on the same date (a ~1-2 week mismatch window each spring/
    autumn where the offset is 4h instead of the usual 5h), and this stays
    correct either way. Safe to treat the UK date as unchanged from the ET
    date for both the equities (9:30/16:00 ET) and forex (17:00 ET) session
    boundaries this is used for - UK is always AHEAD of ET, and adding
    4-5 hours to either boundary never crosses into the next UK calendar
    day, confirmed by construction (16:00 + 5h = 21:00, nowhere near
    midnight)."""
    ny_dt = datetime(ny_date.year, ny_date.month, ny_date.day, hour, minute, tzinfo=_NY_TZ)
    uk_dt = ny_dt.astimezone(_UK_TZ)
    return uk_dt.hour * 60 + uk_dt.minute


@app.get("/trading-hours")
def trading_hours() -> dict:
    """Weekly market-open/close schedule in UK local time, for the app's
    trading-hours timeline widget. Pure calendar math (zoneinfo), no broker
    calls - shows the REGULAR recurring weekly schedule, not this specific
    week's real holidays (a genuine simplification, called out in `note`
    below rather than silently implied as exact - a one-off market holiday
    won't show as closed here). Unauthenticated - same trust level as
    /signals, this is just a public schedule, not account data.

    Equities (NYSE regular session, 09:30-16:00 ET, Mon-Fri) and Forex
    (continuous 17:00 ET Sun through 17:00 ET Fri) are the two markets with
    a genuine weekly open/close pattern worth drawing as a timeline. Crypto
    trades 24/7 with no such pattern, so it's returned as a flat note
    instead of an all-green week of bars, which would carry no information.
    """
    today = date.today()
    monday = today - timedelta(days=today.weekday())
    week = [monday + timedelta(days=i) for i in range(7)]

    equities_days = []
    forex_days = []
    for i, d in enumerate(week):
        if i <= 4:  # Mon-Fri
            equities_days.append({
                "day_index": i, "label": _DAY_LABELS[i],
                "open_minutes": _ny_clock_to_uk_minutes(d, 9, 30),
                "close_minutes": _ny_clock_to_uk_minutes(d, 16, 0),
            })
        else:
            equities_days.append({"day_index": i, "label": _DAY_LABELS[i], "open_minutes": None, "close_minutes": None})

        if i == 5:  # Saturday - forex fully closed
            forex_days.append({"day_index": i, "label": _DAY_LABELS[i], "open_minutes": None, "close_minutes": None})
        elif i == 6:  # Sunday - opens at 17:00 ET
            forex_days.append({
                "day_index": i, "label": _DAY_LABELS[i],
                "open_minutes": _ny_clock_to_uk_minutes(d, 17, 0), "close_minutes": 24 * 60,
            })
        elif i == 4:  # Friday - closes at 17:00 ET
            forex_days.append({
                "day_index": i, "label": _DAY_LABELS[i],
                "open_minutes": 0, "close_minutes": _ny_clock_to_uk_minutes(d, 17, 0),
            })
        else:  # Mon-Thu - open the full day
            forex_days.append({"day_index": i, "label": _DAY_LABELS[i], "open_minutes": 0, "close_minutes": 24 * 60})

    now_uk = datetime.now(_UK_TZ)
    return {
        "timezone": "Europe/London",
        "now_day_index": now_uk.weekday(),
        "now_minutes": now_uk.hour * 60 + now_uk.minute,
        "note": "Regular weekly hours shown - one-off market holidays aren't reflected.",
        "markets": [
            {"name": "Equities (NYSE)", "days": equities_days},
            {"name": "Forex", "days": forex_days},
        ],
        "crypto_note": "Crypto: always open, 24/7",
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


class CustomSizingRequest(BaseModel):
    sizing_value: float
    password: str


@app.post("/custom-sizing")
def custom_sizing(req: CustomSizingRequest, username: str = Depends(_require_session)) -> dict:
    """Set per-trade sizing (% of equity) to any value, not just the three
    named presets - the dashboard's own Advanced Settings has always allowed
    this (a plain number_input, no upper bound), this is the same capability
    for the phone. Only touches sizing_mode/sizing_value; leaves vol-target,
    max-drawdown, giveback and the risk_preset LABEL untouched, same as the
    dashboard's own Advanced Settings field - so the preset name shown
    elsewhere can go stale relative to the real value, which is exactly the
    documented risk_presets.py caveat ("a label, not a guarantee"), not a
    behavior unique to this endpoint. Same password-confirmation friction as
    /risk-preset, since it changes real position sizing for the next trade
    onward. Capped to the range risk_dial_sizing_sweep.py actually
    walk-forward tested (1-100%) - a value outside that range would be
    genuinely unvalidated, unlike the dashboard's uncapped field, since a
    fat-fingered phone entry deserves a tighter guard rail than a desktop
    typo would."""
    if not (1.0 <= req.sizing_value <= 100.0):
        raise HTTPException(status_code=400, detail="Sizing must be between 1 and 100 (% of equity).")
    if not _auth.verify_password(username, req.password):
        raise HTTPException(status_code=401, detail="Incorrect password.")
    control = load_control()
    control.sizing_mode = "pct_equity"
    control.sizing_value = req.sizing_value
    save_control(control)
    return {"ok": True, "sizing_mode": control.sizing_mode, "sizing_value": control.sizing_value}


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


@app.get("/roster-recommendation")
def roster_recommendation(username: str = Depends(_require_session)) -> dict:
    """A computed-but-not-yet-applied roster change, if the overnight
    post-close check (auto_trader.py's _maybe_check_roster_gap, see
    roster.compute_recommendation) found one - null otherwise. Login-gated
    like /positions - a read, no password needed. Nothing has changed yet;
    this is purely "is there something to review"."""
    pending = load_pending()
    if pending is None:
        return {"recommendation": None}
    return {
        "recommendation": {
            "computed_at": pending.computed_at,
            "scan_run_id": pending.scan_run_id,
            "num_scan_results": pending.num_scan_results,
            "summary": pending.summary,
        }
    }


class RosterRecommendationRequest(BaseModel):
    action: str  # "apply" | "dismiss"
    password: str


@app.post("/roster-recommendation")
def respond_to_roster_recommendation(
    req: RosterRecommendationRequest, username: str = Depends(_require_session)
) -> dict:
    """Apply or dismiss the pending roster recommendation - same
    password-confirmation friction as /kill and /risk-preset, since applying
    changes what the live bot trades (same effect as the dashboard's own
    "Re-evaluate roster now" button, just pre-computed overnight)."""
    if req.action not in ("apply", "dismiss"):
        raise HTTPException(status_code=400, detail='action must be "apply" or "dismiss"')
    if not _auth.verify_password(username, req.password):
        raise HTTPException(status_code=401, detail="Incorrect password.")

    pending = load_pending()
    if pending is None:
        raise HTTPException(status_code=404, detail="No pending recommendation to respond to.")

    if req.action == "apply":
        save_roster(pending.proposed_state)
    clear_pending()
    return {"ok": True, "action": req.action}


@app.get("/deposits")
def deposits(username: str = Depends(_require_session)) -> dict:
    """Per-account deposit log + True P&L (equity minus total deposited) -
    same real-broker-equity join as /sizing (reuses positions_service's
    cached fetch, no extra broker call). Login-gated like /positions - real
    account financial history, not a hypothetical."""
    equity_by_id = {a["account_id"]: a["equity"] for a in fetch_all_positions() if a.get("account_id")}
    rows = []
    for account in list_accounts():
        account_id = account["id"]
        deposited = total_deposited(account_id)
        equity = equity_by_id.get(account_id)
        rows.append({
            "account_id": account_id,
            "nickname": account["nickname"],
            "broker": account["broker"],
            "is_paper": account["is_paper"],
            "equity": equity,
            "total_deposited": deposited,
            "true_pnl": (equity - deposited) if equity is not None else None,
            "entries": [
                {"amount": d.amount, "date": d.date, "note": d.note, "recorded_at": d.recorded_at}
                for d in deposits_for(account_id)
            ],
        })
    return {"accounts": rows}


class AddDepositRequest(BaseModel):
    account_id: str
    amount: float
    date: str
    note: str = ""
    password: str


@app.post("/deposits")
def add_deposit(req: AddDepositRequest, username: str = Depends(_require_session)) -> dict:
    """Records a deposit - password-confirmed like every other write here,
    even though it doesn't change what the bot trades, since it's a
    financial record the user relies on for True P&L."""
    if not _auth.verify_password(username, req.password):
        raise HTTPException(status_code=401, detail="Incorrect password.")
    try:
        record_deposit(req.account_id, req.amount, req.date, req.note)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    return {"ok": True, "total_deposited": total_deposited(req.account_id)}


class RemoveDepositRequest(BaseModel):
    account_id: str
    index: int  # into deposits_for(account_id)'s own most-recent-first order
    password: str


@app.post("/deposits/remove")
def remove_deposit_endpoint(req: RemoveDepositRequest, username: str = Depends(_require_session)) -> dict:
    if not _auth.verify_password(username, req.password):
        raise HTTPException(status_code=401, detail="Incorrect password.")
    remove_deposit(req.account_id, req.index)
    return {"ok": True, "total_deposited": total_deposited(req.account_id)}


@app.get("/tax-summary")
def tax_summary(username: str = Depends(_require_session)) -> dict:
    """GBP capital-gains ESTIMATE per account for the current UK tax year -
    see backtester.tax's own module docstring for exactly what this is (and
    isn't): the simple realized-P&L-sum method, not HMRC Section 104
    pooling, and allowance/rate/FX are whatever the user has entered via
    /tax-settings, never assumed. Login-gated like /deposits - real
    financial figures, not a hypothetical."""
    summary = compute_tax_summary(list_accounts())
    return {
        "tax_year_start": summary.tax_year_start.isoformat(),
        "tax_year_end": summary.tax_year_end.isoformat(),
        "lines": [
            {
                "account_id": line.account_id, "nickname": line.nickname, "currency": line.currency,
                "realized_gain_native": line.realized_gain_native, "realized_gain_gbp": line.realized_gain_gbp,
            }
            for line in summary.lines
        ],
        "total_gain_gbp": summary.total_gain_gbp,
        "missing_fx_accounts": summary.missing_fx_accounts,
        "allowance_gbp": summary.allowance_gbp,
        "taxable_gain_gbp": summary.taxable_gain_gbp,
        "rate_pct": summary.rate_pct,
        "estimated_tax_gbp": summary.estimated_tax_gbp,
    }


@app.get("/tax-settings")
def tax_settings(username: str = Depends(_require_session)) -> dict:
    settings = load_tax_settings()
    # Live accounts only, matching compute_tax_summary's own filter (paper
    # accounts never appear in /tax-summary, so seeding a currency choice
    # for one here would be dead data the app never actually shows).
    return {
        "cgt_allowance_gbp": settings.cgt_allowance_gbp,
        "cgt_rate_pct": settings.cgt_rate_pct,
        "gbp_usd_rate": settings.gbp_usd_rate,
        "account_currencies": {
            a["id"]: settings.currency_for(a["id"]) for a in list_accounts() if not a["is_paper"]
        },
    }


class UpdateTaxSettingsRequest(BaseModel):
    cgt_allowance_gbp: float
    cgt_rate_pct: float
    gbp_usd_rate: float
    account_currencies: dict[str, str]
    password: str


@app.post("/tax-settings")
def update_tax_settings(req: UpdateTaxSettingsRequest, username: str = Depends(_require_session)) -> dict:
    """Password-confirmed like /deposits, even though this changes a display
    calculation rather than trading behaviour - it's a financial figure the
    user relies on, same reasoning as that endpoint's own docstring."""
    if not _auth.verify_password(username, req.password):
        raise HTTPException(status_code=401, detail="Incorrect password.")
    save_tax_settings(TaxSettings(
        cgt_allowance_gbp=req.cgt_allowance_gbp, cgt_rate_pct=req.cgt_rate_pct,
        gbp_usd_rate=req.gbp_usd_rate, account_currencies=req.account_currencies,
    ))
    return {"ok": True}


@app.get("/account-detail")
def account_detail(account_id: str, username: str = Depends(_require_session)) -> dict:
    """Everything the app's Account Details screen shows, in ONE call:
    balances, the three different P&L numbers, open positions and closed
    round trips. Assembled server-side rather than making the phone fan out
    to /positions + /trades + /deposits and stitch them together.

    The three P&L figures are deliberately separate because they answer
    different questions and get confused otherwise:
      unrealized_pnl  - paper gain/loss on what's still OPEN right now
      realized_pnl    - actually banked from CLOSED round trips, all time
      true_pnl        - equity minus money deposited, i.e. has this account
                        actually made anything net of what was put in
    """
    account = next((a for a in list_accounts() if a["id"] == account_id), None)
    if account is None:
        raise HTTPException(status_code=404, detail="No such account.")

    equity = cash = buying_power = None
    positions: list[dict] = []
    error = None
    try:
        broker = build_broker_accounts([account_id])[0]
        snap = broker.get_account_snapshot()
        equity, cash, buying_power = snap.equity, snap.cash, snap.buying_power
        positions = [
            {
                "ticker": p.ticker, "qty": p.qty, "side": p.side,
                "avg_entry_price": p.avg_entry_price, "current_price": p.current_price,
                "market_value": p.market_value, "unrealized_pl": p.unrealized_pl,
            }
            for p in broker.get_positions() if p.qty
        ]
    except Exception as e:  # noqa: BLE001 — an unreachable broker shouldn't 500 the whole screen
        error = _friendly_broker_error(e)

    # Fees never touch live_trades.db, so realised P&L there is GROSS of
    # costs. Surfaced separately (not silently netted off) because the two
    # kinds behave completely differently: per-trade regulatory fees scale
    # with trade COUNT, while the currency-conversion charge is a one-off per
    # DEPOSIT and was by far the larger of the two on AlpacaLive.
    fees: list[dict] = []
    fee_totals = {"trading": 0.0, "funding": 0.0, "total": 0.0}
    fees_supported = True
    try:
        broker_for_fees = build_broker_accounts([account_id])[0]
        raw_fees = broker_for_fees.get_fees()
        fee_totals = summarize_fees(raw_fees)
        fees = [
            {
                "date": f.date, "kind": f.kind, "amount": f.amount,
                "description": f.description, "is_funding": f.is_funding,
            }
            for f in raw_fees
        ]
    except NotImplementedError:
        fees_supported = False  # this broker has no uniform fee endpoint
    except Exception:  # noqa: BLE001 — a fee-read failure must not break the screen
        fees_supported = False

    closed = list_recent_trades(limit=100, account_id=account_id)
    realized = sum(t["pnl"] for t in closed)
    unrealized = sum(p["unrealized_pl"] for p in positions)
    deposited = total_deposited(account_id)
    # REALIZED-only, today - not a mark-to-market day's-change figure, since
    # most brokers here have no equity-history API to diff against (see
    # positions_service.AccountView.realized_pnl_today's own docstring for
    # why). Reuses `closed` (already fetched above) rather than a second query.
    today_iso = date.today().isoformat()
    realized_today = sum(t["pnl"] for t in closed if (t.get("exit_time") or "").startswith(today_iso))

    return {
        "account_id": account_id,
        "nickname": account["nickname"],
        "broker": account.get("broker", ""),
        "is_paper": account["is_paper"],
        "error": error,
        "equity": equity,
        "cash": cash,
        "buying_power": buying_power,
        "unrealized_pnl": unrealized,
        "realized_pnl": realized,
        "realized_pnl_today": realized_today,
        "total_deposited": deposited,
        # None, not a number, in two cases where "equity minus deposits" would
        # be actively misleading rather than merely unknown:
        #   - broker unreachable: there's no real equity to subtract from
        #   - nothing deposited: it degenerates to "equity", which on a paper
        #     account is just its fictional starting balance (MyAlpaca would
        #     have proudly reported "True P&L +$99,600" — its opening float).
        # The app shows a "log a deposit to see this" hint instead.
        "true_pnl": (equity - deposited) if (equity is not None and deposited > 0) else None,
        "open_positions": positions,
        "closed_trades": closed,
        "fees_supported": fees_supported,
        "fees": fees,
        "total_fees": fee_totals["total"],
        # Split out because they behave differently and the difference drives
        # what's worth doing about them: trading fees are a FIXED ~$0.01-0.03/day
        # toll (every regulatory fee rounds up to a $0.01 minimum, so it doesn't
        # grow with trade size), while funding fees are ~1.5% of every deposit
        # and stay proportional forever. See BrokerFee.is_funding.
        "trading_fees": fee_totals["trading"],
        "funding_fees": fee_totals["funding"],
        # realised P&L after the broker's own charges — the number that
        # actually reconciles against equity, unlike realized_pnl alone.
        "realized_pnl_net": realized + fee_totals["total"],
        # Trading profit against only the cost of TRADING, excluding the cost of
        # funding the account. Answers "is the strategy itself paying for the
        # act of trading" separately from "have deposit charges been earned back".
        "realized_pnl_after_trading_fees": realized + fee_totals["trading"],
    }


def _friendly_broker_error(exc: Exception) -> str:
    """Plain-English reason a broker read failed, so the app shows a note
    instead of a raw traceback (mirrors app.py's own helper)."""
    msg = str(exc)
    if isinstance(exc, NotImplementedError):
        return "not supported by this broker's API"
    if "permission denied" in msg.lower():
        return "the API key lacks a required permission"
    if "refused" in msg.lower():
        return "could not connect (is the broker gateway running?)"
    return msg[:140]


class ClosePositionRequest(BaseModel):
    account_id: str
    ticker: str
    password: str


@app.post("/positions/close")
def close_position(req: ClosePositionRequest, username: str = Depends(_require_session)) -> dict:
    """Market-sell one open position, closing it in full.

    EXITS ONLY, deliberately — there is no mobile endpoint that OPENS a
    position. Closing reduces exposure, so a mis-tap on a phone costs at
    worst an unwanted exit; opening one would put real money into a new
    trade. Sizing is the held quantity, never a fresh calculation (same rule
    auto_trader.py follows: recomputing 'what would today's sizing buy' broke
    a real close on 2026-08-05 when a partial fill had shrunk the position).
    """
    if not _auth.verify_password(username, req.password):
        raise HTTPException(status_code=401, detail="Incorrect password.")
    try:
        broker = build_broker_accounts([req.account_id])[0]
    except Exception as e:  # noqa: BLE001
        raise HTTPException(status_code=502, detail=f"Could not reach that account: {e}")

    position = next((p for p in broker.get_positions() if p.ticker == req.ticker and p.qty), None)
    if position is None:
        raise HTTPException(status_code=404, detail=f"No open {req.ticker} position on that account.")

    # Opposite side closes it, so this works for a short as well as a long.
    side = OrderSide.SELL if position.side == "long" else OrderSide.BUY
    result = broker.submit_market_order(req.ticker, side, position.qty)
    execution_log.log_results(req.ticker, side, [result])
    if not result.success:
        raise HTTPException(status_code=502, detail=result.error or "Broker rejected the order.")

    # Always record the round trip, even with no attribution — an
    # unattributed close is still real money moving, and dropping it (the old
    # behaviour) silently understated realised P&L. Same placeholder and same
    # reasoning as auto_trader.py's close path.
    attribution = position_attribution.pop_open(broker.account_id, req.ticker) or {
        "strategy_name": UNATTRIBUTED_STRATEGY, "opened_at": "", "conviction": None,
    }
    if result.filled_avg_price:
        qty = result.filled_qty or position.qty
        record_realized_trade(
            account_id=broker.account_id, ticker=req.ticker,
            strategy_name=attribution["strategy_name"], is_paper=broker.is_paper,
            entry_time=attribution["opened_at"], entry_price=position.avg_entry_price,
            exit_time=datetime.now(timezone.utc).isoformat(),
            exit_price=result.filled_avg_price,
            qty=qty if position.side == "long" else -qty,
            conviction=attribution.get("conviction"),
        )
    return {
        "ok": True, "ticker": req.ticker, "side": side.value,
        "qty": position.qty, "filled_qty": result.filled_qty,
        "filled_avg_price": result.filled_avg_price,
        "queued": not result.filled_qty,  # market shut -> broker queues it for the open
    }


class ResetBreakerRequest(BaseModel):
    account_id: str
    password: str


@app.get("/account-risk")
def account_risk_status(username: str = Depends(_require_session)) -> dict:
    """Per-account drawdown-breaker state, so the app can show WHICH account
    is halted and why before offering to re-arm it."""
    out = []
    for a in list_accounts():
        status = account_risk.get_status(a["id"]) or {}
        out.append({
            "account_id": a["id"], "nickname": a["nickname"], "is_paper": a["is_paper"],
            "blocked": bool(status.get("blocked")), "reason": status.get("reason"),
            "blocked_at": status.get("blocked_at"), "peak_equity": status.get("peak_equity"),
        })
    return {"accounts": out}


@app.post("/account-risk/reset")
def reset_account_breaker(req: ResetBreakerRequest, username: str = Depends(_require_session)) -> dict:
    """Clear a tripped max-drawdown circuit breaker for one account.

    The breaker is deliberately NOT self-healing (see account_risk.py): once
    an account drops more than max_drawdown_pct from its peak it stays
    blocked even if equity recovers, until a human clears it. This is that
    human step, moved to the phone — previously it was dashboard-only, so an
    account halted while away stayed halted until you got back to a desk.
    Re-arming re-baselines the peak to CURRENT equity, otherwise it would
    re-trip instantly against the old high-water mark.
    """
    if not _auth.verify_password(username, req.password):
        raise HTTPException(status_code=401, detail="Incorrect password.")
    try:
        broker = build_broker_accounts([req.account_id])[0]
        equity = broker.get_account_snapshot().equity
    except Exception as e:  # noqa: BLE001
        raise HTTPException(status_code=502, detail=f"Could not read that account's equity: {e}")
    account_risk.reset_breach(req.account_id, equity)
    return {"ok": True, "account_id": req.account_id, "peak_equity_reset_to": equity}


class RosterSettingsRequest(BaseModel):
    roster_size: int
    losing_streak_threshold: int
    win_rate_floor: float          # percent, e.g. 30.0
    max_per_strategy: int
    max_per_sector: int
    review_cadence_days: int
    pause_release_days: int
    password: str


@app.get("/roster-settings")
def roster_settings(username: str = Depends(_require_session)) -> dict:
    c = load_roster().config
    return {
        "roster_size": c.roster_size,
        "losing_streak_threshold": c.losing_streak_threshold,
        "win_rate_floor": c.win_rate_floor * 100,
        "max_per_strategy": c.max_per_strategy,
        "max_per_sector": c.max_per_sector,
        "review_cadence_days": c.review_cadence_days,
        "pause_release_days": c.pause_release_days,
    }


@app.post("/roster-settings")
def set_roster_settings(req: RosterSettingsRequest, username: str = Depends(_require_session)) -> dict:
    """Edit the roster's own rules. Only the fields the phone exposes are
    taken from the request; everything else is carried forward from the
    stored config so saving from mobile can't silently reset a setting the
    app doesn't show (the exact bug that reset rescan_universes once)."""
    if not _auth.verify_password(username, req.password):
        raise HTTPException(status_code=401, detail="Incorrect password.")
    if req.roster_size < 1:
        raise HTTPException(status_code=400, detail="Roster size must be at least 1.")
    if not 0 <= req.win_rate_floor <= 100:
        raise HTTPException(status_code=400, detail="Win-rate floor must be between 0 and 100.")

    state = load_roster()
    old = state.config
    state.config = RosterConfig(
        roster_size=req.roster_size,
        min_live_trades=old.min_live_trades,
        losing_streak_threshold=req.losing_streak_threshold,
        win_rate_floor=req.win_rate_floor / 100,
        cum_pnl_floor=old.cum_pnl_floor,
        max_pnl_drawdown_floor=old.max_pnl_drawdown_floor,
        weights=old.weights,
        regime_match_only=old.regime_match_only,
        max_per_strategy=req.max_per_strategy,
        max_per_sector=req.max_per_sector,
        rescan_universes=old.rescan_universes,
        rescan_strategy_names=old.rescan_strategy_names,
        rescan_window_days=old.rescan_window_days,
        review_cadence_days=req.review_cadence_days,
        pause_release_days=req.pause_release_days,
    )
    save_roster(state)
    return {"ok": True}


class ProtectiveExitsRequest(BaseModel):
    """Percentages as the USER sees them (1.0 = 1%), converted to the fractions
    the engine uses on the way in. None disables that exit."""
    stop_loss_pct: float | None = None
    take_profit_pct: float | None = None
    flatten_before_close_minutes: int | None = None
    password: str


@app.get("/protective-exits")
def protective_exits(username: str = Depends(_require_session)) -> dict:
    c = load_control()
    return {
        "stop_loss_pct": (c.stop_loss_pct * 100) if c.stop_loss_pct else None,
        "take_profit_pct": (c.take_profit_pct * 100) if c.take_profit_pct else None,
        "flatten_before_close_minutes": c.flatten_before_close_minutes,
    }


@app.post("/protective-exits")
def set_protective_exits(req: ProtectiveExitsRequest, username: str = Depends(_require_session)) -> dict:
    """Stop-loss / take-profit attached to OPENING orders as broker-side
    brackets, so they survive the bot process being down.

    Password-confirmed like every other control that changes what the bot does
    with real money. Read-modify-write on the loaded control so the phone can
    never reset a setting it doesn't display.
    """
    if not _auth.verify_password(username, req.password):
        raise HTTPException(status_code=401, detail="Incorrect password.")
    for label, value in (("Stop-loss", req.stop_loss_pct), ("Take-profit", req.take_profit_pct)):
        if value is not None and not 0.1 <= value <= 20:
            raise HTTPException(status_code=400, detail=f"{label} must be between 0.1% and 20%.")
    if req.flatten_before_close_minutes is not None and not 1 <= req.flatten_before_close_minutes <= 180:
        raise HTTPException(status_code=400, detail="Flatten window must be 1-180 minutes.")

    control = load_control()
    control.stop_loss_pct = (req.stop_loss_pct / 100) if req.stop_loss_pct else None
    control.take_profit_pct = (req.take_profit_pct / 100) if req.take_profit_pct else None
    control.flatten_before_close_minutes = req.flatten_before_close_minutes
    save_control(control)
    return {"ok": True}


class EntryStatusRequest(BaseModel):
    ticker: str
    strategy_name: str
    action: str  # "pause" | "activate"
    password: str


@app.post("/roster/entry-status")
def set_entry_status(req: EntryStatusRequest, username: str = Depends(_require_session)) -> dict:
    """Manually bench or re-activate one roster combo.

    A deliberate human override of the automatic rules. Activating also
    clears the streak grace marker the same way an auto-release does, so the
    frozen losing streak that benched it can't immediately re-pause it on the
    next poll — without that, 'activate' would visibly do nothing (the very
    deadlock that made MPWR un-releasable).
    """
    if not _auth.verify_password(username, req.password):
        raise HTTPException(status_code=401, detail="Incorrect password.")
    if req.action not in ("pause", "activate"):
        raise HTTPException(status_code=400, detail="action must be 'pause' or 'activate'.")

    state = load_roster()
    entry = next(
        (e for e in state.entries if e.ticker == req.ticker and e.strategy_name == req.strategy_name),
        None,
    )
    if entry is None:
        raise HTTPException(status_code=404, detail=f"{req.ticker}/{req.strategy_name} is not in the roster.")

    if req.action == "pause":
        entry.status = "paused"
        entry.paused_at = datetime.now(timezone.utc).isoformat()
        entry.pause_reason = "manually paused from the mobile app"
        entry.demoted_for_cap = False
        entry.grace_after_trades = None
    else:
        active = sum(1 for e in state.entries if e.status == "active")
        if active >= state.config.roster_size:
            raise HTTPException(
                status_code=409,
                detail=f"Roster is full ({active}/{state.config.roster_size} active). "
                       "Pause something first or raise the roster size.",
            )
        stats = recent_performance(req.ticker, req.strategy_name)
        entry.status = "active"
        entry.pause_reason = None
        entry.paused_at = None
        entry.demoted_for_cap = False
        entry.grace_after_trades = stats.num_trades  # same grace an auto-release grants
    save_roster(state)
    append_event(
        req.ticker, req.strategy_name,
        "paused" if req.action == "pause" else "released",
        f"manual {req.action} from the mobile app",
    )
    return {"ok": True, "ticker": req.ticker, "status": entry.status}
