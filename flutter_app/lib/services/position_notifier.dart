import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/position.dart';
import 'auth_client.dart';

const _knownPositionsKey = 'known_open_positions';

final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();
bool _notificationsInitialized = false;

Future<void> _ensureInitialized() async {
  if (_notificationsInitialized) return;
  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
  const settings = InitializationSettings(android: androidSettings);
  await _notifications.initialize(settings: settings);
  await _notifications
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.requestNotificationsPermission();
  _notificationsInitialized = true;
}

/// Compares the current open positions against the last-known set (persisted
/// in SharedPreferences) and fires a local notification for any position
/// that's newly appeared since the last check - "the app noticed a position
/// opened", entirely on-device (no FCM, no server push, no device tokens),
/// reusing the SAME 60s foreground / ~15min background refresh cadence
/// widget_service.dart already runs on (see main.dart's WorkManager task and
/// SignalListScreen's own poll timer - both call refreshWidget(), which now
/// calls this too).
///
/// Silently does nothing if not logged in - positions can't be checked
/// without a session, and this is an optional enhancement layered on top of
/// the open-positions screen, not a core function. A logged-out user simply
/// doesn't get these alerts, no error shown anywhere.
Future<void> checkPositionsAndNotify() async {
  if (!await AuthClient.isLoggedIn()) return;

  List<AccountPositions> accounts;
  try {
    accounts = await AuthClient.fetchPositions();
  } catch (_) {
    return; // network/auth hiccup - try again next cycle, don't alarm the user
  }

  final currentKeys = <String>{};
  final byKey = <String, MapEntry<AccountPositions, OpenPosition>>{};
  for (final account in accounts) {
    for (final position in account.positions) {
      final key = '${account.nickname}:${position.ticker}';
      currentKeys.add(key);
      byKey[key] = MapEntry(account, position);
    }
  }

  final prefs = await SharedPreferences.getInstance();
  final previousKeys = (prefs.getStringList(_knownPositionsKey) ?? []).toSet();
  final newlyOpened = currentKeys.difference(previousKeys);

  // Only notify when there WAS a previous check to compare against - the
  // very first check after install/login would otherwise fire one alert per
  // already-open position, which isn't "a new position just opened".
  if (newlyOpened.isNotEmpty && prefs.containsKey(_knownPositionsKey)) {
    await _ensureInitialized();
    var notificationId = DateTime.now().millisecondsSinceEpoch % 100000;
    for (final key in newlyOpened) {
      final entry = byKey[key]!;
      final account = entry.key;
      final position = entry.value;
      await _notifications.show(
        id: notificationId++,
        title: 'Position opened: ${position.ticker}',
        body: '${position.side} ${position.qty.toStringAsFixed(4)} on ${account.nickname} '
            '@ ${position.avgEntryPrice.toStringAsFixed(4)}',
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'open_positions',
            'Open positions',
            channelDescription: 'Alerts when a new position opens',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
      );
    }
  }

  await prefs.setStringList(_knownPositionsKey, currentKeys.toList());
}
