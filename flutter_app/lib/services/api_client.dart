import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/roster.dart';
import '../models/signal.dart';

/// Talks to the read-only signal API (Mobile_App/backend). The backend
/// address is always user-configured (a Tailscale IP/hostname specific to
/// the user's own tailnet) - never hardcoded, per the plan.
class ApiClient {
  static const _prefsKey = 'backend_url';
  static const _defaultUrl = 'http://100.x.x.x:8600';

  static Future<String> getBackendUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefsKey) ?? _defaultUrl;
  }

  static Future<void> setBackendUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, url.trim());
  }

  static Future<SignalsResponse> fetchSignals() async {
    final base = await getBackendUrl();
    final resp = await http
        .get(Uri.parse('$base/signals'))
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) {
      throw Exception('Backend returned HTTP ${resp.statusCode}');
    }
    return SignalsResponse.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  static Future<RosterResponse> fetchRoster() async {
    final base = await getBackendUrl();
    final resp = await http
        .get(Uri.parse('$base/roster'))
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) {
      throw Exception('Backend returned HTTP ${resp.statusCode}');
    }
    return RosterResponse.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  /// Returns true if the backend is reachable, for the settings screen's
  /// connectivity check - never throws.
  static Future<bool> checkHealth(String url) async {
    try {
      final resp = await http
          .get(Uri.parse('$url/health'))
          .timeout(const Duration(seconds: 5));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
