import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/bars.dart';
import '../models/risk_preset.dart';
import '../models/roster.dart';
import '../models/signal.dart';
import '../models/trade.dart';
import '../models/trading_hours.dart';

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

  static Future<TradingHours> fetchTradingHours() async {
    final base = await getBackendUrl();
    final resp = await http
        .get(Uri.parse('$base/trading-hours'))
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) {
      throw Exception('Backend returned HTTP ${resp.statusCode}');
    }
    return TradingHours.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  static Future<List<TradeRecord>> fetchTrades() async {
    final base = await getBackendUrl();
    final resp = await http
        .get(Uri.parse('$base/trades'))
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) {
      throw Exception('Backend returned HTTP ${resp.statusCode}');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['trades'] as List<dynamic>? ?? [])
        .map((t) => TradeRecord.fromJson(t as Map<String, dynamic>))
        .toList();
  }

  static Future<Map<String, RiskPreset>> fetchRiskPresets() async {
    final base = await getBackendUrl();
    final resp = await http
        .get(Uri.parse('$base/risk-presets'))
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) {
      throw Exception('Backend returned HTTP ${resp.statusCode}');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final presets = body['presets'] as Map<String, dynamic>? ?? {};
    return presets.map((name, v) => MapEntry(name, RiskPreset.fromJson(v as Map<String, dynamic>)));
  }

  /// OHLC bars at a specific granularity, for the detail screen's 1m/5m/15m
  /// candle toggle. Throws on failure (unlike checkHealth below) so the
  /// caller can show a real error and offer a retry - a chart the user
  /// explicitly asked to change shouldn't silently keep the old data.
  static Future<BarSeries> fetchBars(
    String ticker, {
    int multiplier = 1,
    String timespan = 'minute',
  }) async {
    final base = await getBackendUrl();
    final resp = await http
        .get(Uri.parse(
          '$base/bars?ticker=${Uri.encodeQueryComponent(ticker)}'
          '&multiplier=$multiplier&timespan=$timespan',
        ))
        .timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) {
      throw Exception('Could not load bars (HTTP ${resp.statusCode})');
    }
    return BarSeries.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
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

  /// backend_version from /health, for the settings screen footer - lets a
  /// bug report say "app v1.1.0, backend v1.0.0" instead of "it's broken",
  /// which is exactly the ambiguity a stale-build mixup (2026-08-09) cost
  /// real debugging time on. Null on any failure - never throws.
  static Future<String?> fetchBackendVersion() async {
    try {
      final base = await getBackendUrl();
      final resp = await http.get(Uri.parse('$base/health')).timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) return null;
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      return body['backend_version'] as String?;
    } catch (_) {
      return null;
    }
  }
}
