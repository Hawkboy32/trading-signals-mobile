"""On-demand Claude advisory pass over the roster/positions data the app
already shows elsewhere (see /roster, /positions, /roster-recommendation) -
synthesizes it into a plain-language summary plus structured flags, as a
second opinion alongside (never instead of) the system's own deterministic
roster scoring and the human's own approve/dismiss decision.

Deliberately NOT wired into any execution path, and never will be by design
of this module: no function here can place, modify, or block a trade. Same
"the trade is sacred, the ping is a nicety" principle backtester's own
notifications.py already follows for phone alerts, extended to this: advice
is something a human reads, not something the system acts on. The system
prompt below also tells Claude this directly, as a second, independent
layer of the same guarantee - even if a future caller mishandled the
response, the model itself has been told never to phrase output as an
instruction to execute anything.

Design decisions (2026-09-18, discussed before building):
  - On-demand only, no background refresh loop (unlike signal_service.py's
    _refresh_loop) - this costs a real, billed API call, so it only runs
    when a human actually asks for it from the app.
  - Roster + positions + pending recommendation only for v1 - no news feed
    yet (a natural extension, deliberately deferred to keep the first build
    small).
  - claude-sonnet-5 - a cost-conscious default while this is unproven, not
    claude-opus-5.

Uses a forced single tool call (`strict: true`, forced tool_choice) rather
than the newer structured-output helpers, since that pattern's exact
current syntax was directly documented and verified against the Claude API
skill at build time - not guessed.
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from typing import Literal

import anthropic
from pydantic import BaseModel

from backtester import keystore
from backtester.roster import load_pending, load_roster
from positions_service import fetch_all_positions

MODEL = "claude-sonnet-5"
ROSTER_STATUSES = ("active", "paused")  # matches signal_api.py's own constant

SYSTEM_PROMPT = """You are a read-only advisory reviewer for Chopper, an algorithmic \
trading system. You do NOT make trading decisions, place orders, or suggest specific \
trades to buy or sell - you exist purely to give a human a second opinion to read \
before they decide anything, alongside (never instead of) the system's own \
deterministic roster scoring. You are not in the execution path and nothing you say \
is acted on automatically.

Given the current roster state, live positions, and any pending roster-change \
recommendation, write a brief, plain-language summary and flag anything that looks \
statistically odd, risky, or worth the human double-checking - e.g. a combo whose \
live track record looks thin (few trades, a short time since promotion), a \
concentration risk across positions or sectors, or a pending recommendation that \
looks questionable given the data behind it. If nothing stands out, say so plainly \
rather than manufacturing a concern - a false "all clear" is bad, but so is crying \
wolf every time this is asked."""

ADVISOR_TOOL = {
    "name": "submit_advisory_report",
    "description": "Submit the advisory summary and any flags for a human to read.",
    "input_schema": {
        "type": "object",
        "properties": {
            "summary": {
                "type": "string",
                "description": "2-4 sentence plain-language synthesis of current roster/position health.",
            },
            "flags": {
                "type": "array",
                "description": "Specific things worth the human's attention. Empty list if nothing stands out.",
                "items": {
                    "type": "object",
                    "properties": {
                        "severity": {"type": "string", "enum": ["info", "warning"]},
                        "combo": {
                            "type": "string",
                            "description": "e.g. 'RMBS/VWAP Mean Reversion', or 'portfolio' for a general flag.",
                        },
                        "note": {"type": "string"},
                    },
                    "required": ["severity", "combo", "note"],
                    "additionalProperties": False,
                },
            },
        },
        "required": ["summary", "flags"],
        "additionalProperties": False,
    },
    "strict": True,
}


class AdvisorFlag(BaseModel):
    severity: Literal["info", "warning"]
    combo: str
    note: str


class AdvisorReport(BaseModel):
    summary: str
    flags: list[AdvisorFlag]
    generated_at: str


class AdvisorError(RuntimeError):
    pass


def _build_context() -> dict:
    state = load_roster()
    entries = [
        {
            "ticker": e.ticker,
            "strategy_name": e.strategy_name,
            "status": e.status,
            "pause_reason": e.pause_reason,
            "live_stats": e.live_stats,
            "backtest_score": e.backtest_score,
        }
        for e in state.entries
        if e.status in ROSTER_STATUSES
    ]
    pending = load_pending()
    pending_dict = None
    if pending is not None:
        pending_dict = {"computed_at": pending.computed_at, "summary": pending.summary}
    return {
        "roster_entries": entries,
        "pending_recommendation": pending_dict,
        "positions": fetch_all_positions(),
    }


def generate_advice() -> AdvisorReport:
    # keystore.get_key reloads .env fresh on every call (unlike relying on
    # process-startup os.environ), so a key added via the dashboard's
    # Settings -> API keys tab after this backend started is picked up
    # immediately - no restart needed, matching keystore.py's own contract.
    api_key = keystore.get_key("ANTHROPIC_API_KEY")
    if not api_key:
        raise AdvisorError(
            "No Anthropic API key set. Add one in the dashboard's Settings -> API keys tab."
        )

    context = _build_context()
    client = anthropic.Anthropic(api_key=api_key)
    try:
        response = client.messages.create(
            model=MODEL,
            max_tokens=2048,
            system=SYSTEM_PROMPT,
            tools=[ADVISOR_TOOL],
            tool_choice={"type": "tool", "name": "submit_advisory_report"},
            messages=[
                {
                    "role": "user",
                    "content": f"Current state (JSON):\n{json.dumps(context, indent=2, default=str)}",
                }
            ],
        )
    except anthropic.APIError as e:
        raise AdvisorError(f"Claude API call failed: {e}") from e

    tool_use = next((b for b in response.content if b.type == "tool_use"), None)
    if tool_use is None:
        raise AdvisorError("Claude did not return a structured report (no tool_use block).")

    parsed = tool_use.input
    return AdvisorReport(
        summary=parsed["summary"],
        flags=[AdvisorFlag(**f) for f in parsed["flags"]],
        generated_at=datetime.now(timezone.utc).isoformat(),
    )
