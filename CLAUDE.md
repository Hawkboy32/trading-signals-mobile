# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

This is the mobile companion to "Chopper", the trading bot/backtester that lives in the sibling
repo `../backtester`. It has two halves:

- **`backend/`** — a small FastAPI service (`signal_api.py`) that imports `backtester` as an
  editable dependency and re-exposes a slice of the trading system's own live state (current
  buy/sell/hold signals, roster health, positions, P&L, deposits/tax, and a handful of
  password-confirmed controls like kill-switch/rearm/sizing) over HTTP, reachable from the phone
  via Tailscale. It never re-implements any trading logic — it calls straight into
  `backtester`'s own modules, so what the app shows can't drift from what was actually validated.
  `backend/watchdog.py` is a separate always-on process that launches `signal_api.py`'s uvicorn
  server and relaunches it if it ever dies or stops responding to `/health`.
- **`flutter_app/`** — a Flutter/Android client. It is a thin client: it has no trading logic of
  its own, just HTTP calls to the backend (`lib/services/api_client.dart` for unauthenticated
  reads, `lib/services/auth_client.dart` for everything behind login), screens to display the
  result, and a native Android home-screen widget (Jetpack Glance, under
  `android/app/.../widget/`) fed by `lib/services/widget_service.dart`.

In short: the backend is the trading system's own data, read over a local network; the app is a
window onto that data plus a few tightly-gated remote controls.

## Common commands

**Backend** (from `backend/`, using its own venv — `pip install -e ../../backtester` is already
done inside it):
```
.venv/Scripts/uvicorn signal_api:app --host 0.0.0.0 --port 8600
```
Needs `backtester/.env` (same Polygon API key the dashboard/bot use) — loaded automatically by
absolute path, so cwd doesn't matter. For the always-on supervised version, run
`backend/watchdog.py` instead (it launches/relaunches `signal_api`'s uvicorn itself).
There is no backend test suite (no pytest files under `backend/` outside its own venv's installed
packages) — the one place a dry-run test was done (watchdog's relaunch logic) was a manual
mocked run, not a committed test file.

**Flutter app** (from `flutter_app/`):
```
flutter run                      # debug run against an emulator/device
flutter build apk --debug        # quick compile check, used throughout development as the main "does it build" gate
flutter build apk --release      # the APK actually installed on the real phone (also what backend/signal_api.py's /download/app-release.apk serves)
flutter test                     # runs flutter_app/test/widget_test.dart
flutter analyze                  # static analysis gate used alongside build checks
```
There is exactly one Dart test file, `flutter_app/test/widget_test.dart` — see Gotchas below,
it is currently stale and will fail as written.

**Android widget build**: there's no separate build step — the Glance widget
(`SignalsWidget.kt`/`SignalsWidgetReceiver.kt`) is plain Kotlin source compiled as part of the
normal `flutter build apk`/`flutter run` Android build (Gradle compiles `android/app/src/main/kotlin/**`
alongside the Flutter engine). To see widget changes you need a real build+install+add-to-homescreen
cycle, not `flutter run`'s hot reload.

## Architecture

### Backend API surface (`backend/signal_api.py`, ~1400 lines, FastAPI, all routes in one file)

Split into two trust tiers:

- **Unauthenticated reads** (market/strategy data only, never account data):
  `/signals`, `/roster`, `/trades`, `/bars`, `/risk-presets`, `/trading-hours`, `/health`,
  `/download/app-release.apk`.
- **Login-gated** (bearer token from `/login`, some additionally require the password resent in
  the request body for state-changing actions): `/positions`, `/targets` (+POST),
  `/sizing` (+POST), `/roster-recommendation` (+POST), `/advisor`, `/deposits` (+POST,
  `/deposits/remove`, `/deposits/convert`), `/tax-summary`, `/tax-settings` (+POST),
  `/account-detail`, `/positions/close`, `/account-risk` (+`/account-risk/reset`),
  `/roster-settings` (+POST), `/protective-exits` (+POST), `/roster/entry-status`, `/challenge`
  (+`/challenge/start`), plus the two original write actions `/kill` and `/rearm`.

Auth/pairing (`backend/_auth.py`): login requires **password + TOTP code every time** (unlike the
desktop dashboard, where 2FA is optional until enrolled — mobile starts at the strictest posture
since it's a brand-new remote-write surface). It reuses the dashboard's own `auth_config.yaml`
bcrypt hash and `two_factor.py` TOTP module — one credential store, not a separate one. Sessions
are a plain in-memory dict (bearer tokens via `secrets.token_urlsafe`), 24h lifetime, lost on
backend restart (deliberate — a token never touches disk). State-changing endpoints additionally
require the password fresh in that same request (not just a valid session) — this proves "I mean
this specific tap right now", not just "a session is open on an unlocked phone". There is no
long-lived pairing/device-registration concept here (unlike a QR-pairing pattern some other
projects use) — it's username/password/TOTP login over Tailscale, nothing more.

Network trust: the server binds `0.0.0.0:8600` (required so the watchdog's `127.0.0.1` health
check and the phone's Tailscale connection both work), but a middleware (`restrict_to_tailnet` in
`signal_api.py`) rejects any client whose IP isn't loopback or in the Tailscale CGNAT range
`100.64.0.0/10` — this is what actually keeps it off whatever LAN the machine happens to join.

### Home-screen widget (Jetpack Glance)

- `widget_service.dart`'s `refreshWidget()` fetches signals/roster/positions/control-state/trading
  hours and writes them into `home_widget`'s shared prefs as flat String/int/double/bool keys;
  called both from the app's own poll loop (near-real-time while open) and a ~15-minute
  `workmanager` periodic background task registered in `main.dart` (Android's practical floor for
  background work).
- `SignalsWidget.kt` reads those same keys back out and renders a HUD-style layout (responsive at
  SMALL/MEDIUM/LARGE breakpoints), tapping into the app via `MainActivity`.
- `SignalsData.kt` holds the shared parsing/formatting used by both the widget and
  `BubbleActivity`/`BubbleTrigger.kt` (a notification-bubble surface), so the two never drift.
- **Known historical bug** (documented in `CLAUDE_NOTES.txt` and still visible as a load-bearing
  comment in `SignalsWidget.kt` around its `rows.isEmpty()` branch): Glance hard-caps every
  `Column` at 10 direct children and silently truncates/fails the render past that — confirmed live
  via device logcat 2026-08-18 ("Truncated Column container from 13 to 10 elements"). The fix in
  place is wrapping the per-row list in its own nested `Column` so it only ever counts as *one*
  child of the root Column regardless of row count — don't flatten that back out when touching the
  LARGE-tier layout.

### How the Flutter app reaches the backend

- Backend address is a user-entered Tailscale IP/hostname, stored via `shared_preferences`
  (`ApiClient._prefsKey = 'backend_url'`, no hardcoded default beyond a placeholder
  `http://100.x.x.x:8600`), editable from the Settings screen with a "Test connection" check
  against `/health`.
- Android blocks plaintext `http://` by default since API 28; `network_security_config.xml`
  explicitly allows cleartext everywhere, which is safe here specifically because the address is
  always a private Tailscale one, never public internet.
- The session **token** (not the password) is the only credential stored on-device, in
  `flutter_secure_storage` (Android Keystore-backed) — see `auth_client.dart`'s `_storage`/
  `_tokenKey`. The password itself is never persisted anywhere on the client; it's only ever
  passed straight through in the request body for each password-confirmed call.

## File/directory map

### `backend/` (FastAPI service)
- `signal_api.py` — the entire API surface: every route, the Tailscale-only middleware, the
  120s background refresh loop that computes current signals for every roster/extra_targets
  combo. Touch this for any new endpoint or any change to what data the app can read/write.
- `signal_service.py` — `compute_current_signal()` / `fetch_live_bars()`: mirrors
  `auto_trader.py`'s own signal-computation steps (fetch bars → build strategy → `on_bar` →
  conviction) exactly, with a live-broker-preference fallback chain (OANDA/Coinbase/Kraken/Alpaca
  before Polygon). Touch this if signal computation or the live-bars source chain needs to change.
- `positions_service.py` — the first (and only early) module with real broker-credential access;
  `fetch_all_positions()` is cached 30s. Touch this for anything about how positions/equity/P&L
  are assembled from the linked broker accounts.
- `advisor_service.py` — on-demand Claude (`claude-sonnet-5`) second-opinion synthesis over
  roster/positions/pending-recommendation data, via a forced single tool call. Strictly advisory —
  not wired into any execution path by design. Touch this for the `/advisor` feature only.
- `_auth.py` — login/session handling (bcrypt + TOTP, in-memory bearer tokens). Touch this for
  anything about how mobile login or session expiry works.
- `watchdog.py` — supervises `signal_api.py`'s uvicorn process (health-checks `/health` on
  `127.0.0.1`, relaunches on process death or failed health check). Touch this for anything about
  process supervision/auto-restart, not API behavior.
- `requirements.txt` — fastapi, uvicorn, anthropic, plus `-e ../../backtester` (the editable
  dependency that gives this backend access to the whole trading system's code).
- `backend_restart*.log` — runtime logs, not source; currently has uncommitted content, leave
  alone.

### `flutter_app/lib/` (Flutter client)
- `main.dart` — app entry point: registers the WorkManager periodic widget-refresh task, sets up
  the "Chopper"/hologram-blue Material theme, launches `SignalListScreen`.
- `services/api_client.dart` — unauthenticated backend calls (`/signals`, `/roster`,
  `/trading-hours`, `/trades`, `/risk-presets`, `/bars`, `/health`) plus the stored backend URL.
  Touch this for any new unauthenticated read.
- `services/auth_client.dart` (~840 lines) — login plus every authenticated/password-confirmed
  call (positions, targets, sizing, deposits, tax, account-detail/risk, roster settings,
  protective exits, challenge, kill/rearm). The single place that owns session-token storage and
  401/session-expiry handling. Touch this for any new authenticated endpoint or write action.
- `services/widget_service.dart` — `refreshWidget()`: the bridge from the app's own data fetches
  to the home-screen widget's saved prefs; also drives the two on-device notification checks
  below. Touch this for anything about what the widget shows or when it refreshes.
- `services/position_notifier.dart` / `services/roster_notifier.dart` — on-device-only local
  notifications (no push server) for "a new position opened" / "a new roster recommendation is
  pending", diffed against the last-seen state in `shared_preferences`. Touch these for alerting
  behavior, not display behavior.
- `screens/signal_list_screen.dart` (~811 lines) — the main screen: grouped signal cards + any
  held positions with no live signal, pull-to-refresh plus a 60s poll timer.
- `screens/bot_control_screen.dart` (~983 lines, the largest screen) — kill/rearm, risk
  preset/custom sizing, manual/roster target mode, protective exits, per-account sizing overrides.
- `screens/positions_screen.dart` / `screens/account_detail_screen.dart` — open positions list and
  the single-account drill-down (balances, three P&L figures, closed trades, fees).
- `screens/roster_health_screen.dart` — roster entries/candidates, pending recommendation
  apply/dismiss, roster settings editor.
- `screens/signal_detail_screen.dart` — per-ticker detail with the candlestick chart
  (1m/5m/15m toggle via `/bars`).
- `screens/challenge_screen.dart` — Kraken Funded challenge tier/state UI.
- `screens/tax_screen.dart` / `screens/trade_history_screen.dart` / `screens/trading_hours_screen.dart`
  / `screens/login_screen.dart` / `screens/settings_screen.dart` — one screen each for GBP tax
  summary, closed-trade history, the weekly market-hours timeline, login, and backend-URL/connection
  settings.
- `models/*.dart` — one typed `fromJson` model per backend response shape (e.g. `signal.dart`,
  `roster.dart`, `position.dart`, `account_detail.dart`, `tax.dart`, `challenge.dart`). Touch the
  matching model whenever a backend endpoint's JSON shape changes.
- `widgets/collapsible_card.dart`, `widgets/password_confirm_dialog.dart`,
  `widgets/trading_hours_timeline.dart` — small shared UI pieces reused across screens (the
  password-confirm dialog in particular backs every password-gated action button).

### `flutter_app/android/app/src/main/kotlin/.../`
- `MainActivity.kt` — standard Flutter Android entry point.
- `widget/SignalsWidget.kt` — the Glance widget's entire composable UI (see Architecture above).
- `widget/SignalsWidgetReceiver.kt` — thin registration shim pointing at `SignalsWidget`.
- `widget/SignalsData.kt` — shared parsing/formatting (`parseSignals`, `colorFor`, `relativeTime`)
  used by both the widget and the notification bubble.
- `bubble/BubbleActivity.kt` / `bubble/BubbleTrigger.kt` — a notification-bubble surface showing
  the same signal data outside the widget.
- `res/xml/signals_widget_info.xml` / `res/xml/samsung_signals_widget_info.xml` — widget
  provider metadata (sizes, resize behavior); the Samsung variant exists for that launcher's own
  widget-registration quirks.
- `res/xml/network_security_config.xml` — allows cleartext HTTP everywhere (see "How the Flutter
  app reaches the backend" above for why that's scoped-safe here).

## Gotchas

- **`flutter_app/test/widget_test.dart` is stale.** It pumps `TradingSignalsApp` and asserts
  `find.text('Trading Signals')`, but `main.dart`'s `MaterialApp.title` is now `'Chopper'` and the
  home screen is `SignalListScreen` — as written, `flutter test` will fail. Fix or rewrite this
  test before relying on `flutter test` as a gate.
- **Glance `Column` 10-child cap** — see Architecture above. Any change to `SignalsWidget.kt`'s
  root-level layout that adds new direct children (not nested inside the rows' own wrapper
  `Column`) risks silently truncating/failing the render on-device; this doesn't show up in a
  normal build, only on a real device/logcat.
- **`backend_restart*.log`, `CLAUDE_NOTES.txt`, and `backend/watchdog.py` currently have
  uncommitted changes** (per `git status` at the time this file was written) — this CLAUDE.md is
  independent of that in-progress work; don't assume those files are in the state described above
  if they've since been edited further.
- Mobile login's 2FA is mandatory (no "optional until enrolled" grace period the dashboard has) —
  a user who hasn't enrolled 2FA via the dashboard's Settings page yet will get a clear "set it up
  first" error from `/login`, not a silent password-only login.
- There is deliberately **no mobile endpoint that opens a position** — `/positions/close` only
  ever reduces exposure (closes the held quantity, never recomputes a fresh size), so a mis-tap on
  the phone can't put new money into a trade.
- The backend's `/advisor` endpoint makes a real, billed Anthropic API call on every single
  request (no caching) — don't add a poll loop or auto-refresh to any UI that calls it.

## Pointers

- `../CLAUDE_NOTES.txt` — the workspace master index: every sibling project, cross-repo
  dependencies, and what runs at login (including this backend's `watchdog.py`).
- `README.md` (repo root) — short public-facing project description and links to the real
  write-up (screenshots, bugs found/fixed) hosted outside this repo.
- `CLAUDE_NOTES.txt` (repo root, ~950 lines) — the long-form running session log for this project
  (toolchain setup, every feature session, real bugs hit and how they were diagnosed/fixed). Not
  duplicated here; consult it directly for history/detail beyond what's summarized above.
- `flutter_app/README.md` — the default, unedited `flutter create` boilerplate README; no
  project-specific content.
