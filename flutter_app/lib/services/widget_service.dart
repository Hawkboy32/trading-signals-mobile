import 'dart:convert';
import 'package:home_widget/home_widget.dart';

import 'api_client.dart';
import 'auth_client.dart';
import 'position_notifier.dart';
import '../models/signal.dart';

/// Bridges the app's own signal data to the Android home-screen widget.
/// Reuses ApiClient.fetchSignals() exactly - no separate fetch logic, no
/// duplicated parsing. The native (Kotlin/Glance) side reads this back out
/// as one JSON string rather than juggling dynamic per-ticker keys, since
/// home_widget's data model is flat String/int/double/bool per key.
///
/// Called from two places, deliberately: SignalListScreen's own _refresh()
/// (so the widget stays near-real-time whenever the app is actually open -
/// reuses the SAME fetch that screen needs anyway, no duplicate network
/// call) and a WorkManager periodic background task (~15 minutes, the
/// practical floor for Android background work - the widget cannot refresh
/// every 60s like the in-app screen while the app itself is closed).
// Full package path required: HomeWidget.updateWidget's `androidName` param
// resolves as `context.packageName + "." + androidName` (confirmed against
// the plugin's own source), which doesn't account for the .widget
// subpackage the native classes actually live in below - qualifiedAndroidName
// sidesteps that ambiguity by taking the exact class name as-is.
const String widgetProviderQualifiedName =
    'com.blindbandit.tradingsignals.trading_signals.widget.SignalsWidgetReceiver';

/// Fetches fresh signals, pushes them to the widget, and returns the data
/// so callers that ALSO need it (SignalListScreen) don't fetch twice.
/// Returns null on failure - the widget just keeps showing whatever it last
/// successfully saved, and the caller falls back to its own error handling.
Future<SignalsResponse?> refreshWidget() async {
  SignalsResponse? data;
  try {
    data = await ApiClient.fetchSignals();
    final compact = data.signals
        .map((s) => {
              'ticker': s.ticker,
              'signal': s.signal,
            })
        .toList();
    await HomeWidget.saveWidgetData<String>('signals_json', jsonEncode(compact));
    await HomeWidget.saveWidgetData<String>('last_refreshed', data.lastRefreshed ?? '');
  } catch (_) {
    // Swallow - see doc comment above.
  }

  // Positions and kill-switch state are each optional extras layered on top
  // of the core signals list - failures (not logged in, network hiccup) must
  // never block the signals refresh above, so each gets its own try/catch and
  // just leaves the widget's last saved value in place.
  try {
    final loggedIn = await AuthClient.isLoggedIn();
    await HomeWidget.saveWidgetData<bool>('positions_available', loggedIn);
    if (loggedIn) {
      final accounts = await AuthClient.fetchPositions();
      var openCount = 0;
      var totalPnl = 0.0;
      for (final account in accounts) {
        openCount += account.positions.length;
        for (final position in account.positions) {
          totalPnl += position.unrealizedPl;
        }
      }
      await HomeWidget.saveWidgetData<int>('open_positions_count', openCount);
      await HomeWidget.saveWidgetData<double>('open_positions_pnl', totalPnl);
    }
  } catch (_) {
    // Swallow - widget keeps showing the last known positions summary.
  }

  try {
    final control = await AuthClient.fetchControlState();
    if (control != null) {
      await HomeWidget.saveWidgetData<bool>('bot_killed', control['killed'] ?? false);
    }
  } catch (_) {
    // Swallow - widget keeps showing the last known kill-switch state.
  } finally {
    await HomeWidget.updateWidget(
      qualifiedAndroidName: widgetProviderQualifiedName,
    );
  }

  // Piggybacks on the exact same refresh cadence as the widget update above
  // (60s foreground, ~15min background) - see position_notifier.dart's own
  // doc comment for why this is safe to call unconditionally (no-ops if not
  // logged in). AWAITED, not fire-and-forget - the WorkManager background
  // isolate calling this can be torn down once its own returned Future
  // resolves, so an un-awaited call here could get cut off mid-flight.
  await checkPositionsAndNotify();

  return data;
}
