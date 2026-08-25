import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/roster_recommendation.dart';
import 'auth_client.dart';

const _lastNotifiedRunIdKey = 'last_notified_roster_scan_run_id';

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

/// Same pattern as position_notifier.dart's checkPositionsAndNotify(), for
/// the roster recommendation instead of open positions: fires a native
/// on-device local notification (separate from the backend's ntfy push,
/// which goes through an external app/service) so approval requests show up
/// as coming from THIS app, the same way a new open position already does.
/// Diffs against the last-notified scan_run_id (persisted in
/// SharedPreferences) so the same still-pending recommendation doesn't
/// re-notify every poll cycle - only a genuinely NEW one does.
///
/// Silently does nothing if not logged in, same reasoning as
/// checkPositionsAndNotify() - this is an optional on-device enhancement
/// layered on top of the roster health screen's own banner, not core.
Future<void> checkRosterRecommendationAndNotify() async {
  if (!await AuthClient.isLoggedIn()) return;

  RosterRecommendation? rec;
  try {
    rec = await AuthClient.fetchRosterRecommendation();
  } catch (_) {
    return; // network/auth hiccup - try again next cycle, don't alarm the user
  }
  if (rec == null) return;

  final prefs = await SharedPreferences.getInstance();
  final lastNotifiedRunId = prefs.getInt(_lastNotifiedRunIdKey);
  if (lastNotifiedRunId == rec.scanRunId) return; // already notified for this one

  await _ensureInitialized();
  await _notifications.show(
    id: 'roster_recommendation'.hashCode,
    title: 'Roster change ready to review',
    body: 'Nothing applied yet - approve or dismiss in the app.\n${rec.summary.join('\n')}',
    notificationDetails: const NotificationDetails(
      android: AndroidNotificationDetails(
        'roster_recommendation',
        'Roster recommendations',
        channelDescription: 'Alerts when a roster change is ready for approval',
        importance: Importance.high,
        priority: Priority.high,
      ),
    ),
  );

  await prefs.setInt(_lastNotifiedRunIdKey, rec.scanRunId);
}
