# trading-signals-mobile

A cross-platform Flutter companion app for a live trading system, reusing
its backend's own validated strategy logic through a live API rather than
re-implementing it, so what the app shows never drifts from what was
actually tested.

Built and maintained solo via an AI-pair-programming workflow (Claude Code).

**Full write-up, real screenshots, and specific bugs found and fixed:**
[hawkboy32.github.io/mobile-app.html](https://hawkboy32.github.io/mobile-app.html)
and [hawkboy32.github.io/widget.html](https://hawkboy32.github.io/widget.html)

## What's in here

- `flutter_app/` — the Flutter/Dart client, including the **Datapad**
  native Android home-screen widget (Jetpack Glance)
- `backend/` — a FastAPI service (`signal_api.py`) that reuses the trading
  system's own logic over a live API, plus an on-demand Claude-powered
  advisory feature

## License

All rights reserved — see [LICENSE](LICENSE). This repository is public for
portfolio and evaluation purposes; it is not licensed for reuse.
