import 'package:flutter/material.dart';

import '../services/api_client.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _controller = TextEditingController();
  String? _status; // null = untested, otherwise a human-readable result
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    ApiClient.getBackendUrl().then((url) {
      if (mounted) setState(() => _controller.text = url);
    });
  }

  Future<void> _testConnection() async {
    setState(() {
      _checking = true;
      _status = null;
    });
    final reachable = await ApiClient.checkHealth(_controller.text.trim());
    if (!mounted) return;
    setState(() {
      _checking = false;
      _status = reachable ? 'Reachable' : 'Could not reach backend';
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Padding(
        padding: const EdgeInsets.all(16),
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
          ],
        ),
      ),
    );
  }
}
