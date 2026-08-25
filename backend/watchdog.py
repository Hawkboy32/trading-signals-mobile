"""Keeps signal_api.py's uvicorn server running: launches it, then relaunches
it if it ever dies while this watchdog stays alive.

WHY THIS EXISTS. Found live 2026-08-06: the uvicorn process had simply
stopped — no crash log, no visible error — leaving the mobile app unreachable
until someone noticed and restarted it manually. Once actually running again
it worked immediately (including a real request from the phone over
Tailscale), so this was never a code or connectivity bug — purely "nothing
notices or restarts it if it ever stops."

WHY A LOOP, NOT TASK SCHEDULER. auto_trader.py's own auto-start (a Startup-
folder shortcut, see backtester/CLAUDE_NOTES.txt) only relaunches on login —
fine for "the PC rebooted," not for "the process died at 3pm while still
logged in." Windows Task Scheduler could poll on an interval, but was
already found to need admin rights in this environment when auto_trader.py's
own auto-start was set up — the Startup-folder shortcut needs none. So this
watchdog IS the periodic check: launched once at login (its own Startup
shortcut, same no-admin mechanism), then stays running and checks health on
an interval for as long as the session lasts.

WHY POLL is_healthy() AND check the process handle, not just one or the
other. A dead OS process is the clearest possible signal a process is down —
same lesson learned fixing auto_trader.py's own singleton guard, which used
to trust a soft signal (heartbeat age) alone and got fooled by it. But a
process can also be alive and hung (unresponsive, never actually serving
requests) — checking only the process handle would miss that. Checking both
catches either failure mode.
"""

from __future__ import annotations

import subprocess
import time
from pathlib import Path

import requests

from backtester import logging_setup  # noqa: E402 - this venv has backtester installed too

BACKEND_DIR = Path(__file__).resolve().parent
PYTHON = BACKEND_DIR / ".venv" / "Scripts" / "python.exe"
HEALTH_URL = "http://127.0.0.1:8600/health"
CHECK_INTERVAL_SECONDS = 30
STARTUP_GRACE_SECONDS = 10  # a freshly launched server needs a moment before its first health check


def _is_healthy() -> bool:
    try:
        resp = requests.get(HEALTH_URL, timeout=5)
        return resp.status_code == 200
    except Exception:  # noqa: BLE001
        return False


def _launch() -> subprocess.Popen:
    print("[watchdog] launching signal_api...", flush=True)
    return subprocess.Popen(
        [str(PYTHON), "-m", "uvicorn", "signal_api:app", "--host", "0.0.0.0", "--port", "8600"],
        cwd=str(BACKEND_DIR),
        creationflags=subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.DETACHED_PROCESS,
    )


def main() -> None:
    # 2026-08-24: this watchdog's own print() calls were going nowhere too -
    # launched via pythonw.exe (no console), same blind spot that let
    # auto_trader.py die with zero trace the same day. See logging_setup.py.
    logging_setup.configure("mobile_backend_watchdog")
    proc = _launch()
    time.sleep(STARTUP_GRACE_SECONDS)
    while True:
        proc_dead = proc.poll() is not None
        if proc_dead or not _is_healthy():
            reason = "process exited" if proc_dead else "health check failed"
            print(f"[watchdog] backend down ({reason}) - relaunching", flush=True)
            if not proc_dead:
                try:
                    proc.kill()
                except Exception:  # noqa: BLE001
                    pass
            proc = _launch()
            time.sleep(STARTUP_GRACE_SECONDS)
        time.sleep(CHECK_INTERVAL_SECONDS)


if __name__ == "__main__":
    main()
