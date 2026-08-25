import 'dart:convert';
import 'package:home_widget/home_widget.dart';

import 'api_client.dart';
import 'auth_client.dart';
import 'position_notifier.dart';
import 'roster_notifier.dart';
import '../models/signal.dart';
import '../models/trading_hours.dart';

const _minutesPerDay = 24 * 60;

/// "09:30–16:00", "Open all day", or "Closed" - same digit format (and the
/// same 2026-08-23 midnight-wraparound fix) as the on-screen weekly timeline
/// (trading_hours_timeline.dart's _fmt/_DayRow), duplicated rather than
/// shared since the widget side has no Flutter widget tree to reuse it from.
/// close=1440 means "runs to the end of this calendar day" - formatting it
/// with the same mod-24 used for a START time wraps it to "00:00", which
/// reads as closed/zero-duration instead of open all day (real bug: Forex's
/// Mon-Thu full-day window showed as "00:00–00:00" until this was fixed).
String _fmtHours(int? openMinutes, int? closeMinutes) {
  if (openMinutes == null || closeMinutes == null) return 'Closed';
  if (openMinutes == 0 && closeMinutes == _minutesPerDay) return 'Open all day';
  String two(int m) => m.toString().padLeft(2, '0');
  final oh = (openMinutes ~/ 60) % 24, om = openMinutes % 60;
  final closeStr = closeMinutes == _minutesPerDay
      ? '24:00'
      : '${two((closeMinutes ~/ 60) % 24)}:${two(closeMinutes % 60)}';
  return '${two(oh)}:${two(om)}–$closeStr';
}

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

/// The real exception from the last refreshWidget() call's signals fetch,
/// if it failed - added 2026-08-24 after a real report where the app-wide
/// "Could not reach backend" message turned out unhelpful for actually
/// diagnosing what was wrong (it fires on ANY exception, network failure or
/// otherwise, and the original exception was being silently swallowed
/// below). SignalListScreen reads this immediately after a failed refresh
/// to show something more specific than the generic message alone. Cleared
/// to null at the start of every refreshWidget() call, whether it ends up
/// succeeding or not - always reflects the MOST RECENT attempt, not a
/// stale error from a previous one.
String? lastSignalsFetchError;

/// Fetches fresh signals, pushes them to the widget, and returns the data
/// so callers that ALSO need it (SignalListScreen) don't fetch twice.
/// Returns null on failure - the widget just keeps showing whatever it last
/// successfully saved, and the caller falls back to its own error handling.
Future<SignalsResponse?> refreshWidget() async {
  SignalsResponse? data;
  lastSignalsFetchError = null;
  try {
    data = await ApiClient.fetchSignals();
    final compact = data.signals
        .map((s) => {
              'ticker': s.ticker,
              'signal': s.signal,
              'price': s.price,
            })
        .toList();
    await HomeWidget.saveWidgetData<String>('signals_json', jsonEncode(compact));
    await HomeWidget.saveWidgetData<String>('last_refreshed', data.lastRefreshed ?? '');
    // Widget-wide OPEN/CLOSED readout (2026-08-17 HUD redesign) - a single
    // flag standing in for a genuinely per-ticker/per-asset-class value
    // (equities vs forex/crypto keep different hours), on the same
    // reasoning the widget already condenses everything else: ANY tracked
    // ticker being open means the bot could act on something right now,
    // which is the actual question a glance at the home screen is asking.
    // null (unknown asset class) counts as closed for this purpose, not
    // open - the honest default when we don't actually know.
    final anyOpen = data.signals.any((s) => s.marketOpen == true);
    await HomeWidget.saveWidgetData<bool>('market_open', anyOpen);
  } catch (e) {
    lastSignalsFetchError = e.toString();
    // Swallow - see doc comment above.
  }

  // Today's actual open/close digits (2026-08-23), same schedule the
  // Trading Hours screen shows - independent try/catch, same reasoning as
  // everything else here: a failure here shouldn't blank the ticker list.
  try {
    final hours = await ApiClient.fetchTradingHours();
    MarketSchedule? findMarket(String name) =>
        hours.markets.where((m) => m.name == name).cast<MarketSchedule?>().firstWhere((m) => m != null, orElse: () => null);
    DaySchedule? today(MarketSchedule? m) =>
        m?.days.cast<DaySchedule?>().firstWhere((d) => d!.dayIndex == hours.nowDayIndex, orElse: () => null);

    final equitiesToday = today(findMarket('Equities (NYSE)'));
    final forexToday = today(findMarket('Forex'));
    await HomeWidget.saveWidgetData<String>(
      'equities_hours', _fmtHours(equitiesToday?.openMinutes, equitiesToday?.closeMinutes),
    );
    await HomeWidget.saveWidgetData<String>(
      'forex_hours', _fmtHours(forexToday?.openMinutes, forexToday?.closeMinutes),
    );
  } catch (_) {
    // Swallow - widget keeps showing the last known hours.
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
      var realizedToday = 0.0;
      for (final account in accounts) {
        openCount += account.positions.length;
        for (final position in account.positions) {
          totalPnl += position.unrealizedPl;
        }
        // Same figure the phone's Account Details/detail screens show
        // (positions_service.py's realized_pnl_today) - realized-only, not
        // a mark-to-market day's-change, see that field's own doc comment.
        realizedToday += account.realizedPnlToday ?? 0.0;
      }
      await HomeWidget.saveWidgetData<int>('open_positions_count', openCount);
      await HomeWidget.saveWidgetData<double>('open_positions_pnl', totalPnl);
      await HomeWidget.saveWidgetData<double>('realized_pnl_today', realizedToday);
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
  }

  // Roster health (2026-08-17 HUD redesign) - unauthenticated read, same as
  // the signals fetch above, so this doesn't depend on being logged in.
  // Only the FIRST paused entry's ticker is surfaced (not a full list) -
  // the widget has room for one HUD line here, not a roster dump; opening
  // the app shows the rest.
  try {
    final rosterData = await ApiClient.fetchRoster();
    final activeCount = rosterData.entries.where((e) => e.status == 'active').length;
    final pausedEntries = rosterData.entries.where((e) => e.status == 'paused').toList();
    await HomeWidget.saveWidgetData<int>('roster_active_count', activeCount);
    await HomeWidget.saveWidgetData<int>('roster_size', rosterData.config.rosterSize);
    await HomeWidget.saveWidgetData<String>(
      'roster_paused_ticker',
      pausedEntries.isNotEmpty ? pausedEntries.first.ticker : '',
    );
  } catch (_) {
    // Swallow - widget keeps showing the last known roster summary.
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
  // try/catch added 2026-08-24 to match every other optional extra above -
  // these two were the one gap (an uncaught exception here used to escape
  // refreshWidget() entirely and get misread by callers as a backend
  // failure, even though the actual throw had nothing to do with the
  // network - see getToken()'s own doc comment for the real incident).
  try {
    await checkPositionsAndNotify();
  } catch (_) {
    // Swallow - optional enhancement, not a core function.
  }
  // Same cadence, same on-device diff-and-notify pattern as positions above -
  // fires a LOCAL notification (from this app, not the external ntfy push)
  // when a genuinely new roster recommendation appears.
  try {
    await checkRosterRecommendationAndNotify();
  } catch (_) {
    // Swallow - optional enhancement, not a core function.
  }

  return data;
}
