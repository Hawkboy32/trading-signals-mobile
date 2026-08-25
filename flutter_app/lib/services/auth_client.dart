import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../models/account_detail.dart';
import '../models/account_sizing.dart';
import '../models/deposit.dart';
import '../models/position.dart';
import '../models/risk_control.dart';
import '../models/roster_recommendation.dart';
import '../models/target_config.dart';
import '../models/tax.dart';
import 'api_client.dart';

/// Login + the two password-confirmed control actions (stop/re-arm). The
/// session token is the only thing stored on-device, in the Android
/// Keystore-backed secure storage - same "credentials never touch plaintext"
/// standard already used for broker creds via the OS keyring on the desktop
/// side. The token proves "logged in earlier"; /kill and /rearm each also
/// need the password sent fresh in that same request, which this class never
/// stores anywhere - it only ever passes it straight through to the backend.
class AuthException implements Exception {
  final String message;
  AuthException(this.message);
  @override
  String toString() => message;
}

class AuthClient {
  static const _storage = FlutterSecureStorage();
  static const _tokenKey = 'session_token';

  static Future<void> _saveToken(String token) async {
    await _storage.write(key: _tokenKey, value: token);
  }

  /// The Android Keystore key backing this value can be invalidated (e.g. by
  /// a reinstall, or certain OS-level security/lock-screen changes), which
  /// makes the stored blob permanently undecryptable - flutter_secure_storage
  /// then throws PlatformException(BadPaddingException) instead of returning
  /// null (real report 2026-08-24: this propagated, unhandled, all the way
  /// out of isLoggedIn() into refreshWidget()'s unguarded
  /// checkPositionsAndNotify() call, surfacing everywhere as a generic
  /// "Could not reach backend" even though the backend was never involved).
  /// The old token is unusable either way, so treat a decrypt failure as
  /// logged-out and clear it - every caller already handles "no token" as
  /// the normal case.
  static Future<String?> getToken() async {
    try {
      return await _storage.read(key: _tokenKey);
    } catch (_) {
      await _storage.delete(key: _tokenKey);
      return null;
    }
  }

  static Future<void> logout() async {
    await _storage.delete(key: _tokenKey);
  }

  static Future<bool> isLoggedIn() async {
    return (await getToken()) != null;
  }

  static Future<void> login({
    required String username,
    required String password,
    required String totpCode,
  }) async {
    final base = await ApiClient.getBackendUrl();
    final resp = await http
        .post(
          Uri.parse('$base/login'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'username': username,
            'password': password,
            'totp_code': totpCode,
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) {
      throw AuthException(_extractError(resp, 'Login failed.'));
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    await _saveToken(body['token'] as String);
  }

  /// {enabled, killed, risk_preset, sizing_value} from /health -
  /// unauthenticated, just enough to decide which of Stop/Start to show,
  /// which risk preset (if any) is currently highlighted as active, and what
  /// to prefill the custom sizing field with.
  static Future<Map<String, dynamic>?> fetchControlState() async {
    try {
      final base = await ApiClient.getBackendUrl();
      final resp = await http.get(Uri.parse('$base/health')).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return null;
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      return {
        'enabled': body['enabled'] as bool? ?? false,
        'killed': body['killed'] as bool? ?? false,
        'risk_preset': body['risk_preset'] as String?,
        'sizing_value': (body['sizing_value'] as num?)?.toDouble(),
      };
    } catch (_) {
      return null;
    }
  }

  /// Switches the live bot's risk preset (Conservative/Moderate/Aggressive) -
  /// same password-confirmation requirement as stopTrading/rearmTrading,
  /// since this changes real position sizing from the next trade onward.
  static Future<void> setRiskPreset(String preset, String password) async {
    final token = await getToken();
    if (token == null) {
      throw AuthException('Not logged in.');
    }
    final base = await ApiClient.getBackendUrl();
    final resp = await http
        .post(
          Uri.parse('$base/risk-preset'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode({'preset': preset, 'password': password}),
        )
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode == 401) {
      final detail = _extractError(resp, 'Not authorized.');
      if (detail.toLowerCase().contains('session')) {
        await logout();
      }
      throw AuthException(detail);
    }
    if (resp.statusCode != 200) {
      throw AuthException(_extractError(resp, 'Request failed.'));
    }
  }

  /// Sets per-trade sizing to any value between 1 and 100 (% of equity), not
  /// just the three named presets - same password-confirmation requirement
  /// as setRiskPreset, since this changes real position sizing from the next
  /// trade onward. Applying a custom value does not update whichever preset
  /// name /health still reports as active, same as the dashboard's own
  /// Advanced Settings field - see risk_presets.py's own docstring.
  static Future<void> setCustomSizing(double sizingValue, String password) async {
    final token = await getToken();
    if (token == null) {
      throw AuthException('Not logged in.');
    }
    final base = await ApiClient.getBackendUrl();
    final resp = await http
        .post(
          Uri.parse('$base/custom-sizing'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode({'sizing_value': sizingValue, 'password': password}),
        )
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode == 401) {
      final detail = _extractError(resp, 'Not authorized.');
      if (detail.toLowerCase().contains('session')) {
        await logout();
      }
      throw AuthException(detail);
    }
    if (resp.statusCode != 200) {
      throw AuthException(_extractError(resp, 'Request failed.'));
    }
  }

  /// Live open positions + unrealized P&L per linked account - requires
  /// login (same session token as /kill and /rearm) but no password
  /// re-confirmation, since this is a read, not an action.
  static Future<List<AccountPositions>> fetchPositions() async {
    final token = await getToken();
    if (token == null) {
      throw AuthException('Not logged in.');
    }
    final base = await ApiClient.getBackendUrl();
    final resp = await http
        .get(Uri.parse('$base/positions'), headers: {'Authorization': 'Bearer $token'})
        // Real broker round-trips across every linked account, measured up to ~20s
        // when a slower broker (IBKR/IG paper) is in the mix - 15s was cutting it
        // close to a legitimately-still-working request, not an actual hang.
        .timeout(const Duration(seconds: 30));
    if (resp.statusCode == 401) {
      await logout();
      throw AuthException(_extractError(resp, 'Session expired - log in again.'));
    }
    if (resp.statusCode != 200) {
      throw AuthException(_extractError(resp, 'Could not load positions.'));
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['accounts'] as List<dynamic>? ?? [])
        .map((e) => AccountPositions.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// What the live bot is currently configured to trade - requires login
  /// (same session token as /positions) but no password re-confirmation,
  /// since this is a read, not an action.
  static Future<TargetConfig> fetchTargetConfig() async {
    final token = await getToken();
    if (token == null) {
      throw AuthException('Not logged in.');
    }
    final base = await ApiClient.getBackendUrl();
    final resp = await http
        .get(Uri.parse('$base/targets'), headers: {'Authorization': 'Bearer $token'})
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode == 401) {
      await logout();
      throw AuthException(_extractError(resp, 'Session expired - log in again.'));
    }
    if (resp.statusCode != 200) {
      throw AuthException(_extractError(resp, 'Could not load trading targets.'));
    }
    return TargetConfig.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  /// Switches Manual/Adaptive roster mode and, in Manual mode, the ticker
  /// list + strategy - same password-confirmation requirement as
  /// setRiskPreset, since this changes what the bot trades from the next
  /// poll cycle onward.
  static Future<void> setTargetConfig({
    required String mode,
    required List<String> tickers,
    required String strategyName,
    required String password,
  }) async {
    final token = await getToken();
    if (token == null) {
      throw AuthException('Not logged in.');
    }
    final base = await ApiClient.getBackendUrl();
    final resp = await http
        .post(
          Uri.parse('$base/targets'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode({
            'mode': mode,
            'tickers': tickers,
            'strategy_name': strategyName,
            'password': password,
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode == 401) {
      final detail = _extractError(resp, 'Not authorized.');
      if (detail.toLowerCase().contains('session')) {
        await logout();
      }
      throw AuthException(detail);
    }
    if (resp.statusCode != 200) {
      throw AuthException(_extractError(resp, 'Request failed.'));
    }
  }

  /// Per-account sliding-scale sizing state - requires login, no password
  /// re-confirmation, same reasoning as fetchTargetConfig/fetchPositions.
  static Future<List<AccountSizing>> fetchAccountSizing() async {
    final token = await getToken();
    if (token == null) {
      throw AuthException('Not logged in.');
    }
    final base = await ApiClient.getBackendUrl();
    final resp = await http
        .get(Uri.parse('$base/sizing'), headers: {'Authorization': 'Bearer $token'})
        // Reuses positions_service's same all-accounts broker fetch as /positions -
        // same generous timeout for the same reason, see fetchPositions above.
        .timeout(const Duration(seconds: 30));
    if (resp.statusCode == 401) {
      await logout();
      throw AuthException(_extractError(resp, 'Session expired - log in again.'));
    }
    if (resp.statusCode != 200) {
      throw AuthException(_extractError(resp, 'Could not load sizing.'));
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['accounts'] as List<dynamic>? ?? [])
        .map((e) => AccountSizing.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Sets or clears (slideStartPct 0) one account's sliding-scale sizing
  /// override - same password-confirmation requirement as setRiskPreset,
  /// since this changes real position sizing from the next trade onward.
  /// Callers re-fetch fetchAccountSizing() afterward for the fresh list
  /// rather than patching a single-account response in place.
  static Future<void> setAccountSizing({
    required String accountId,
    required double slideStartPct,
    required double slideFloorNotional,
    required String password,
  }) async {
    final token = await getToken();
    if (token == null) {
      throw AuthException('Not logged in.');
    }
    final base = await ApiClient.getBackendUrl();
    final resp = await http
        .post(
          Uri.parse('$base/sizing'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode({
            'account_id': accountId,
            'slide_start_pct': slideStartPct,
            'slide_floor_notional': slideFloorNotional,
            'password': password,
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode == 401) {
      final detail = _extractError(resp, 'Not authorized.');
      if (detail.toLowerCase().contains('session')) {
        await logout();
      }
      throw AuthException(detail);
    }
    if (resp.statusCode != 200) {
      throw AuthException(_extractError(resp, 'Request failed.'));
    }
  }

  static Future<void> stopTrading(String password) async {
    await _confirmedAction('/kill', password);
  }

  static Future<void> rearmTrading(String password) async {
    await _confirmedAction('/rearm', password);
  }

  static Future<void> _confirmedAction(String path, String password) async {
    final token = await getToken();
    if (token == null) {
      throw AuthException('Not logged in.');
    }
    final base = await ApiClient.getBackendUrl();
    final resp = await http
        .post(
          Uri.parse('$base$path'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode({'password': password}),
        )
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode == 401) {
      final detail = _extractError(resp, 'Not authorized.');
      // A session that's actually expired should send the user back to the
      // login screen rather than looking like a wrong-password error forever.
      if (detail.toLowerCase().contains('session')) {
        await logout();
      }
      throw AuthException(detail);
    }
    if (resp.statusCode != 200) {
      throw AuthException(_extractError(resp, 'Request failed.'));
    }
  }

  /// A computed-but-not-yet-applied roster change, if the overnight
  /// post-close check found one - null otherwise. Login-gated, no password
  /// (a read, like fetchAccountSizing).
  static Future<RosterRecommendation?> fetchRosterRecommendation() async {
    final token = await getToken();
    if (token == null) {
      throw AuthException('Not logged in.');
    }
    final base = await ApiClient.getBackendUrl();
    final resp = await http
        .get(Uri.parse('$base/roster-recommendation'), headers: {'Authorization': 'Bearer $token'})
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode == 401) {
      await logout();
      throw AuthException(_extractError(resp, 'Session expired - log in again.'));
    }
    if (resp.statusCode != 200) {
      throw AuthException(_extractError(resp, 'Could not load roster recommendation.'));
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final rec = body['recommendation'] as Map<String, dynamic>?;
    return rec == null ? null : RosterRecommendation.fromJson(rec);
  }

  /// Approve ("apply") or reject ("dismiss") the pending roster
  /// recommendation - same password-confirmation friction as setRiskPreset,
  /// since applying changes what the live bot trades.
  static Future<void> respondToRosterRecommendation({
    required String action,
    required String password,
  }) async {
    final token = await getToken();
    if (token == null) {
      throw AuthException('Not logged in.');
    }
    final base = await ApiClient.getBackendUrl();
    final resp = await http
        .post(
          Uri.parse('$base/roster-recommendation'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode({'action': action, 'password': password}),
        )
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode == 401) {
      final detail = _extractError(resp, 'Not authorized.');
      if (detail.toLowerCase().contains('session')) {
        await logout();
      }
      throw AuthException(detail);
    }
    if (resp.statusCode != 200) {
      throw AuthException(_extractError(resp, 'Request failed.'));
    }
  }

  /// Per-account deposit log + True P&L - login-gated, no password (a read,
  /// like fetchPositions/fetchAccountSizing).
  static Future<List<AccountDeposits>> fetchDeposits() async {
    final token = await getToken();
    if (token == null) {
      throw AuthException('Not logged in.');
    }
    final base = await ApiClient.getBackendUrl();
    final resp = await http
        .get(Uri.parse('$base/deposits'), headers: {'Authorization': 'Bearer $token'})
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode == 401) {
      await logout();
      throw AuthException(_extractError(resp, 'Session expired - log in again.'));
    }
    if (resp.statusCode != 200) {
      throw AuthException(_extractError(resp, 'Could not load deposits.'));
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['accounts'] as List<dynamic>? ?? [])
        .map((e) => AccountDeposits.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Records a deposit - password-confirmed like every other write here,
  /// since it's a financial record the True P&L figure relies on.
  static Future<void> addDeposit({
    required String accountId,
    required double amount,
    required String date,
    required String note,
    required String password,
  }) async {
    final token = await getToken();
    if (token == null) {
      throw AuthException('Not logged in.');
    }
    final base = await ApiClient.getBackendUrl();
    final resp = await http
        .post(
          Uri.parse('$base/deposits'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode({
            'account_id': accountId,
            'amount': amount,
            'date': date,
            'note': note,
            'password': password,
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode == 401) {
      final detail = _extractError(resp, 'Not authorized.');
      if (detail.toLowerCase().contains('session')) {
        await logout();
      }
      throw AuthException(detail);
    }
    if (resp.statusCode != 200) {
      throw AuthException(_extractError(resp, 'Request failed.'));
    }
  }

  /// index into that account's AccountDeposits.entries (most-recent-first) -
  /// same password-confirmation as addDeposit.
  static Future<void> removeDeposit({
    required String accountId,
    required int index,
    required String password,
  }) async {
    final token = await getToken();
    if (token == null) {
      throw AuthException('Not logged in.');
    }
    final base = await ApiClient.getBackendUrl();
    final resp = await http
        .post(
          Uri.parse('$base/deposits/remove'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode({'account_id': accountId, 'index': index, 'password': password}),
        )
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode == 401) {
      final detail = _extractError(resp, 'Not authorized.');
      if (detail.toLowerCase().contains('session')) {
        await logout();
      }
      throw AuthException(detail);
    }
    if (resp.statusCode != 200) {
      throw AuthException(_extractError(resp, 'Request failed.'));
    }
  }

  /// GBP capital-gains ESTIMATE for the current UK tax year - login-gated,
  /// no password (a read, like fetchDeposits).
  static Future<TaxSummary> fetchTaxSummary() async {
    final token = await getToken();
    if (token == null) {
      throw AuthException('Not logged in.');
    }
    final base = await ApiClient.getBackendUrl();
    final resp = await http
        .get(Uri.parse('$base/tax-summary'), headers: {'Authorization': 'Bearer $token'})
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode == 401) {
      await logout();
      throw AuthException(_extractError(resp, 'Session expired - log in again.'));
    }
    if (resp.statusCode != 200) {
      throw AuthException(_extractError(resp, 'Could not load tax summary.'));
    }
    return TaxSummary.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  static Future<TaxSettings> fetchTaxSettings() async {
    final token = await getToken();
    if (token == null) {
      throw AuthException('Not logged in.');
    }
    final base = await ApiClient.getBackendUrl();
    final resp = await http
        .get(Uri.parse('$base/tax-settings'), headers: {'Authorization': 'Bearer $token'})
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode == 401) {
      await logout();
      throw AuthException(_extractError(resp, 'Session expired - log in again.'));
    }
    if (resp.statusCode != 200) {
      throw AuthException(_extractError(resp, 'Could not load tax settings.'));
    }
    return TaxSettings.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  /// Password-confirmed like addDeposit, even though this only changes a
  /// display calculation - it's a financial figure the user relies on.
  static Future<void> updateTaxSettings({
    required double cgtAllowanceGbp,
    required double cgtRatePct,
    required double gbpUsdRate,
    required Map<String, String> accountCurrencies,
    required String password,
  }) async {
    final token = await getToken();
    if (token == null) {
      throw AuthException('Not logged in.');
    }
    final base = await ApiClient.getBackendUrl();
    final resp = await http
        .post(
          Uri.parse('$base/tax-settings'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode({
            'cgt_allowance_gbp': cgtAllowanceGbp,
            'cgt_rate_pct': cgtRatePct,
            'gbp_usd_rate': gbpUsdRate,
            'account_currencies': accountCurrencies,
            'password': password,
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode == 401) {
      final detail = _extractError(resp, 'Not authorized.');
      if (detail.toLowerCase().contains('session')) {
        await logout();
      }
      throw AuthException(detail);
    }
    if (resp.statusCode != 200) {
      throw AuthException(_extractError(resp, 'Request failed.'));
    }
  }

  // ---------------------------------------------------------------------
  // Manual controls. Every one of these is a WRITE, so the backend demands
  // the password fresh in the request on top of the session token — see the
  // /kill and /rearm precedent. Note there is deliberately NO "open a
  // position" method here: mobile can close a position but never opens one,
  // so a mis-tap on a phone can only ever reduce exposure.
  // ---------------------------------------------------------------------

  /// Shared plumbing for a password-confirmed POST: identical auth, session
  /// expiry and error extraction across all of them, so a new control can't
  /// accidentally skip a step.
  static Future<Map<String, dynamic>> _postAuthed(String path, Map<String, dynamic> body) async {
    final token = await getToken();
    if (token == null) {
      throw AuthException('Not logged in.');
    }
    final base = await ApiClient.getBackendUrl();
    final resp = await http
        .post(
          Uri.parse('$base$path'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 30)); // broker round-trips are slower than a config write
    if (resp.statusCode == 401) {
      final detail = _extractError(resp, 'Not authorized.');
      if (detail.toLowerCase().contains('session')) {
        await logout();
      }
      throw AuthException(detail);
    }
    if (resp.statusCode != 200) {
      throw AuthException(_extractError(resp, 'Request failed.'));
    }
    try {
      return jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  static Future<Map<String, dynamic>> _getAuthed(String path) async {
    final token = await getToken();
    if (token == null) {
      throw AuthException('Not logged in.');
    }
    final base = await ApiClient.getBackendUrl();
    final resp = await http
        .get(Uri.parse('$base$path'), headers: {'Authorization': 'Bearer $token'})
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode == 401) {
      await logout();
      throw AuthException(_extractError(resp, 'Session expired - log in again.'));
    }
    if (resp.statusCode != 200) {
      throw AuthException(_extractError(resp, 'Request failed.'));
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// Market-close one open position in full. Returns the broker's response;
  /// `queued` is true when the market was shut and the order sits until the
  /// next open (normal, not a failure).
  static Future<Map<String, dynamic>> closePosition({
    required String accountId,
    required String ticker,
    required String password,
  }) =>
      _postAuthed('/positions/close',
          {'account_id': accountId, 'ticker': ticker, 'password': password});

  /// Balances, all three P&L figures, open positions and closed round trips
  /// for one account - assembled server-side into a single call.
  static Future<AccountDetail> fetchAccountDetail(String accountId) async =>
      AccountDetail.fromJson(await _getAuthed('/account-detail?account_id=$accountId'));

  /// Per-account drawdown-breaker state (which accounts are halted, and why).
  static Future<List<AccountRiskStatus>> fetchAccountRisk() async {
    final body = await _getAuthed('/account-risk');
    return (body['accounts'] as List<dynamic>? ?? [])
        .map((e) => AccountRiskStatus.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Clear a tripped max-drawdown breaker. Re-baselines peak equity to the
  /// account's CURRENT equity, otherwise it would re-trip immediately.
  static Future<void> resetAccountBreaker({
    required String accountId,
    required String password,
  }) async =>
      _postAuthed('/account-risk/reset', {'account_id': accountId, 'password': password});

  static Future<RosterSettings> fetchRosterSettings() async =>
      RosterSettings.fromJson(await _getAuthed('/roster-settings'));

  static Future<void> saveRosterSettings(RosterSettings s, String password) async =>
      _postAuthed('/roster-settings', {...s.toJson(), 'password': password});

  static Future<ProtectiveExits> fetchProtectiveExits() async =>
      ProtectiveExits.fromJson(await _getAuthed('/protective-exits'));

  /// Stop-loss / take-profit for positions opened FROM NOW ON — anything
  /// already open was submitted without a bracket and is unaffected.
  static Future<void> saveProtectiveExits(ProtectiveExits e, String password) async =>
      _postAuthed('/protective-exits', {...e.toJson(), 'password': password});

  /// Manually bench or re-activate one roster combo, overriding the automatic
  /// rules. Activating grants the same one-trade streak grace an auto-release
  /// does, so a frozen losing streak can't instantly re-pause it.
  static Future<void> setRosterEntryStatus({
    required String ticker,
    required String strategyName,
    required String action, // 'pause' | 'activate'
    required String password,
  }) async =>
      _postAuthed('/roster/entry-status', {
        'ticker': ticker,
        'strategy_name': strategyName,
        'action': action,
        'password': password,
      });

  static String _extractError(http.Response resp, String fallback) {
    try {
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      return body['detail'] as String? ?? fallback;
    } catch (_) {
      return fallback;
    }
  }
}
