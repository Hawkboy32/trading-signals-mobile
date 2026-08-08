"""Login + session handling for the mobile backend's write-capable endpoints
(/kill, /rearm). Everything before this module was strictly read-only with
zero authentication - this is the first time the mobile backend can change
anything, so it borrows the dashboard's own trust boundary rather than
inventing a separate one: same auth_config.yaml (bcrypt password hash) and
the same two_factor.py TOTP module the dashboard now uses (see backtester's
CLAUDE_NOTES.txt "dashboard 2FA wired into app.py's real login flow").

Unlike the dashboard - where 2FA is optional until a user enrols - mobile
login REQUIRES a TOTP code on every login. This is a brand-new remote-write
surface, so it starts at the strictest posture rather than inheriting the
dashboard's backward-compatible "optional until enrolled" default. If the
user hasn't enrolled 2FA yet (via the dashboard's Settings page), mobile
login fails with a clear message telling them to do that first, rather than
silently allowing password-only access to a kill switch.

Sessions are in-memory only (a plain dict), not persisted to disk - a
restart of this backend (e.g. via watchdog.py) logs every mobile session
out, which is an accepted tradeoff: it means a bearer token is never sitting
in a file on disk, only ever in this process's memory.
"""

from __future__ import annotations

import secrets
import threading
from datetime import datetime, timedelta, timezone
from pathlib import Path

import bcrypt
import yaml

from backtester import two_factor

AUTH_CONFIG_PATH = Path(__file__).resolve().parent.parent.parent / "backtester" / "auth_config.yaml"

# How long a mobile login stays valid before requiring password+TOTP again.
# Deliberately shorter than the dashboard's 7-day cookie - a phone is more
# likely to be lost/stolen than this laptop, and re-logging in on mobile is
# a normal, low-friction thing to ask for periodically.
SESSION_LIFETIME = timedelta(hours=24)

_sessions: dict[str, dict] = {}
_sessions_lock = threading.Lock()


def _normalize_username(username: str) -> str:
    """Matches streamlit_authenticator's OWN AuthenticationController.login()
    exactly (confirmed in its source: `username = username.lower().strip()`)
    - the dashboard's session-state username, and therefore whatever identity
    its 2FA enrollment gets stored under (two_factor.py keys purely off the
    string it's given), is ALWAYS this normalized form, regardless of the
    case a user originally registered with in auth_config.yaml. A real bug
    found live 2026-08-08: auth_config.yaml's stored key was '[redacted-dashboard-username]'
    (mixed case), the dashboard's own login normalized it to 'blindbandit'
    for 2FA enrollment, but this module's password check did an exact-case
    dict lookup - a mobile login typed as '[redacted-dashboard-username]' passed the password
    check against the real config key, then failed the 2FA check because it
    was looking for a '[redacted-dashboard-username]' enrollment that was actually stored under
    'blindbandit'. Every identity-bearing operation below now normalizes
    first, so mobile and dashboard always agree on who "the same user" is."""
    return username.lower().strip()


def _load_credentials() -> dict:
    """Keys are normalized to match _normalize_username, so a lookup with a
    normalized username finds the right entry regardless of what case it was
    originally registered under in auth_config.yaml."""
    if not AUTH_CONFIG_PATH.exists():
        return {}
    config = yaml.safe_load(AUTH_CONFIG_PATH.read_text(encoding="utf-8"))
    raw = (config or {}).get("credentials", {}).get("usernames", {})
    return {_normalize_username(k): v for k, v in raw.items()}


def verify_password(username: str, password: str) -> bool:
    """Checks a plain password against the SAME bcrypt hash the dashboard's
    streamlit_authenticator login already uses - one password, one source of
    truth, not a second credential store to keep in sync."""
    users = _load_credentials()
    user = users.get(_normalize_username(username))
    if not user:
        return False
    stored_hash = user.get("password", "")
    if not stored_hash:
        return False
    try:
        return bcrypt.checkpw(password.encode("utf-8"), stored_hash.encode("utf-8"))
    except (ValueError, TypeError):
        return False


def verify_login(username: str, password: str, totp_code: str) -> tuple[bool, str]:
    """Full mobile login check: password AND a TOTP code, always - see this
    module's own docstring for why TOTP isn't optional here the way it is on
    the dashboard. Returns (ok, error_message) so the API can surface which
    part actually failed rather than one generic "invalid" for every case."""
    username = _normalize_username(username)
    if not verify_password(username, password):
        return False, "Incorrect username or password."
    if not two_factor.is_enrolled(username):
        return False, "2FA isn't set up yet - enrol it from the dashboard's Settings page first."
    if not two_factor.verify_code(totp_code, username=username):
        return False, "Incorrect authentication code."
    return True, ""


def create_session(username: str) -> tuple[str, str]:
    """Issues a fresh bearer token. Returns (token, iso_expires_at). Stores
    the NORMALIZED username - see _normalize_username - so a later /kill or
    /rearm re-check of the password (via resolve_session -> verify_password)
    stays consistent regardless of what case the original login was typed in."""
    username = _normalize_username(username)
    token = secrets.token_urlsafe(32)
    expires_at = datetime.now(timezone.utc) + SESSION_LIFETIME
    with _sessions_lock:
        _sessions[token] = {"username": username, "expires_at": expires_at}
    return token, expires_at.isoformat()


def resolve_session(token: str | None) -> str | None:
    """Returns the logged-in username for a valid, unexpired token, or None.
    Expired tokens are dropped here rather than left to accumulate."""
    if not token:
        return None
    with _sessions_lock:
        entry = _sessions.get(token)
        if entry is None:
            return None
        if datetime.now(timezone.utc) >= entry["expires_at"]:
            del _sessions[token]
            return None
        return entry["username"]
