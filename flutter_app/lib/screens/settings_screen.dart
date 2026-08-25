import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/api_client.dart';

const _bubbleChannel = MethodChannel('trading_signals/bubble');

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _controller = TextEditingController();
  String? _status; // null = untested, otherwise a human-readable result
  bool _checking = false;
  String? _appVersion;
  String? _backendVersion; // null until fetched, or if /health didn't have it (older backend)

  @override
  void initState() {
    super.initState();
    ApiClient.getBackendUrl().then((url) {
      if (mounted) setState(() => _controller.text = url);
    });
    // Added 2026-08-24 alongside backend_version in /health - so "which
    // build is this" is a glance at Settings instead of a guess, the exact
    // ambiguity a stale-APK mixup (2026-08-09) cost real debugging time on.
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _appVersion = '${info.version}+${info.buildNumber}');
    });
    ApiClient.fetchBackendVersion().then((v) {
      if (mounted) setState(() => _backendVersion = v);
    });
  }

  /// Auto-saves on a successful test (2026-08-24) - Test and Save used to be
  /// two fully separate actions, and a real report showed exactly the
  /// confusing failure mode that split invites: type the correct address,
  /// tap Test (genuinely reachable, shown correctly), but never tap Save -
  /// every OTHER screen keeps using whatever was persisted before (a wiped-
  /// out default after a fresh install, in the reported case), so the app
  /// looks broken everywhere except the one screen that just tested the
  /// unsaved value. A successful test IS good evidence this address is the
  /// right one to use, so acting on that immediately removes the trap
  /// rather than requiring a second, easy-to-forget tap.
  Future<void> _testConnection() async {
    setState(() {
      _checking = true;
      _status = null;
    });
    final address = _controller.text.trim();
    final reachable = await ApiClient.checkHealth(address);
    if (reachable) {
      await ApiClient.setBackendUrl(address);
    }
    if (!mounted) return;
    setState(() {
      _checking = false;
      _status = reachable ? 'Reachable - saved' : 'Could not reach backend';
    });
  }

  Future<void> _save() async {
    await ApiClient.setBackendUrl(_controller.text);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Backend address saved.')),
    );
    Navigator.of(context).pop();
  }

  /// Was previously a fire-and-forget `invokeMethod` call with no await and
  /// no error handling - any native-side exception (e.g. a blocked
  /// notification channel, a missing permission) would surface only as an
  /// unhandled-exception print to the debug console, completely invisible in
  /// a release build. Awaited + caught now so a failure actually shows
  /// something instead of silently doing nothing.
  Future<void> _showBubble() async {
    try {
      await _bubbleChannel.invokeMethod('showBubble');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Notification sent - check your notification shade.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not show bubble: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 24 + MediaQuery.of(context).padding.bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Backend address (Tailscale IP/hostname and port, e.g. '
              'http://100.x.x.x:8600). Reach it over your own tailnet - '
              'never a public address.',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              decoration: const InputDecoration(
                labelText: 'Backend URL',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _checking ? null : _testConnection,
              child: Text(_checking ? 'Checking...' : 'Test connection'),
            ),
            if (_status != null) ...[
              const SizedBox(height: 8),
              Text(
                _status!,
                style: TextStyle(
                  color: _status == 'Reachable' ? Colors.green : Colors.red,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton(onPressed: _save, child: const Text('Save')),
            const SizedBox(height: 32),
            const Divider(),
            const SizedBox(height: 8),
            Text(
              'Floating bubble (Android 11+). First tap posts a notification; '
              'long-press it and mark it "Priority" (or Settings > Apps > '
              'Trading Signals > Notifications > Conversations) to make it '
              'float from then on - a one-time step Android requires and this '
              'app cannot skip on your behalf.',
              style: TextStyle(color: Colors.grey[600], fontSize: 12),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _showBubble,
              child: const Text('Show floating bubble'),
            ),
            const SizedBox(height: 32),
            const Divider(),
            const SizedBox(height: 8),
            Center(
              child: Text(
                'App v${_appVersion ?? '…'}'
                '${_backendVersion != null ? ' · Backend v$_backendVersion' : ''}',
                style: TextStyle(color: Colors.grey[600], fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
