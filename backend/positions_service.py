"""Live open positions + unrealized P&L, per linked account.

This is the FIRST place the mobile backend gets real broker-credential
access - everything else in this backend (signal_service.py, roster,
trades) is deliberately zero-credential, reading only shared files. That
boundary is crossed here on purpose (2026-08-08, user's own explicit
go-ahead after it was flagged as a real architectural decision, not a
routine build).

Worth being precise about what actually changed: this backend runs on the
SAME machine as the dashboard, under the SAME OS user account, so it already
had access to the same OS keyring the dashboard's broker credentials live
in - accounts.build_broker_accounts() works here exactly as it does in
app.py, no new credential storage was added. The real change is that this
data becomes reachable over the phone/Tailscale, not that new secrets exist
anywhere. Because of that, /positions in signal_api.py requires a valid
login (same session token as /kill and /rearm) - real account balances and
holdings are meaningfully more sensitive than the hypothetical "what would
the strategy do" signals every other endpoint here serves.
"""

from __future__ import annotations

import threading
import time
from dataclasses import asdict, dataclass

from backtester.accounts import build_broker_accounts, list_accounts

CACHE_TTL_SECONDS = 30  # short - real broker calls, but avoid hammering IG/Alpaca/IBKR on every phone poll

_cache: dict[str, object] = {"data": None, "fetched_at": 0.0}
_cache_lock = threading.Lock()


@dataclass
class PositionView:
    ticker: str
    qty: float
    side: str
    avg_entry_price: float
    current_price: float | None
    market_value: float
    unrealized_pl: float


@dataclass
class AccountView:
    nickname: str
    broker: str
    is_paper: bool
    equity: float | None
    cash: float | None
    positions: list[PositionView]
    error: str | None = None


def _friendly_error(exc: Exception) -> str:
    """Mirrors app.py's own _friendly_account_error - same reasoning: an
    empty/quiet account (nothing wrong, just no data) shouldn't look like a
    scary traceback on the phone either."""
    msg = str(exc)
    if isinstance(exc, NotImplementedError):
        return "not supported by this broker's API"
    if "permission denied" in msg.lower():
        return "the API key lacks the required permission"
    return msg[:140]


def _fetch_fresh() -> list[AccountView]:
    linked = list_accounts()
    if not linked:
        return []
    broker_by_account_id = {a["id"]: a["broker"] for a in linked}
    try:
        broker_accounts = build_broker_accounts([a["id"] for a in linked])
    except Exception as e:  # noqa: BLE001
        # Whole-fetch failure (e.g. a keyring read failed) - one error entry
        # rather than crashing the endpoint.
        return [AccountView(nickname="(all accounts)", broker="", is_paper=True, equity=None, cash=None, positions=[], error=str(e))]

    views: list[AccountView] = []
    for broker_account in broker_accounts:
        broker_type = broker_by_account_id.get(broker_account.account_id, "")
        try:
            snapshot = broker_account.get_account_snapshot()
            equity, cash = snapshot.equity, snapshot.cash
        except Exception as e:  # noqa: BLE001
            views.append(
                AccountView(
                    nickname=broker_account.nickname, broker=broker_type, is_paper=broker_account.is_paper,
                    equity=None, cash=None, positions=[], error=_friendly_error(e),
                )
            )
            continue
        try:
            positions = broker_account.get_positions()
        except Exception as e:  # noqa: BLE001
            views.append(
                AccountView(
                    nickname=broker_account.nickname, broker=broker_type, is_paper=broker_account.is_paper,
                    equity=equity, cash=cash, positions=[], error=_friendly_error(e),
                )
            )
            continue
        views.append(
            AccountView(
                nickname=broker_account.nickname, broker=broker_type, is_paper=broker_account.is_paper,
                equity=equity, cash=cash,
                positions=[
                    PositionView(
                        ticker=p.ticker, qty=p.qty, side=p.side,
                        avg_entry_price=p.avg_entry_price, current_price=p.current_price,
                        market_value=p.market_value, unrealized_pl=p.unrealized_pl,
                    )
                    for p in positions
                ],
                error=None,
            )
        )
    return views


def fetch_all_positions() -> list[dict]:
    """Cached for CACHE_TTL_SECONDS - real broker API calls, not a local file
    read, so this deliberately doesn't refetch on every single phone request
    the way /roster and /trades do."""
    with _cache_lock:
        now = time.monotonic()
        if _cache["data"] is not None and (now - _cache["fetched_at"]) < CACHE_TTL_SECONDS:
            return _cache["data"]
        views = _fetch_fresh()
        data = [asdict(v) for v in views]
        _cache["data"] = data
        _cache["fetched_at"] = now
        return data
