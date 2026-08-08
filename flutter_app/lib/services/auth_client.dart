import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

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

  static Future<String?> getToken() async {
    return _storage.read(key: _tokenKey);
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

  /// {enabled, killed} from /health - unauthenticated, just enough to decide
  /// which of Stop/Start to show.
  static Future<Map<String, bool>?> fetchControlState() async {
    try {
      final base = await ApiClient.getBackendUrl();
      final resp = await http.get(Uri.parse('$base/health')).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return null;
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      return {
        'enabled': body['enabled'] as bool? ?? false,
        'killed': body['killed'] as bool? ?? false,
      };
    } catch (_) {
      return null;
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

  static String _extractError(http.Response resp, String fallback) {
    try {
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      return body['detail'] as String? ?? fallback;
    } catch (_) {
      return fallback;
    }
  }
}
