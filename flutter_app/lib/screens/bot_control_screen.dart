import 'package:flutter/material.dart';

import '../models/risk_preset.dart';
import '../services/api_client.dart';
import '../services/auth_client.dart';
import '../widgets/password_confirm_dialog.dart';
import 'login_screen.dart';

const _presetOrder = ['Conservative', 'Moderate', 'Aggressive'];

/// Live-bot controls beyond start/stop - currently just the risk preset
/// switch (Conservative/Moderate/Aggressive), the same backtester.
/// risk_presets.RISK_PRESETS the dashboard's own buttons apply, reached
/// through the same password-confirmed flow as stop/re-arm. Deliberately NOT
/// a backtest or account/broker-credential surface - scoped to exactly what
/// changes the live bot's own behavior.
class BotControlScreen extends StatefulWidget {
  const BotControlScreen({super.key});

  @override
  State<BotControlScreen> createState() => _BotControlScreenState();
}

class _BotControlScreenState extends State<BotControlScreen> {
  Map<String, RiskPreset>? _presets;
  String? _activePreset;
  String? _error;
  bool _loading = true;
  bool _actionInFlight = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    if (!await AuthClient.isLoggedIn()) {
      if (!mounted) return;
      final loggedIn = await Navigator.of(
        context,
      ).push<bool>(MaterialPageRoute(builder: (_) => const LoginScreen()));
      if (loggedIn != true) {
        if (!mounted) return;
        setState(() {
          _error = 'Login required to view or change bot controls.';
          _loading = false;
        });
        return;
      }
    }
    try {
      final presets = await ApiClient.fetchRiskPresets();
      final control = await AuthClient.fetchControlState();
      if (!mounted) return;
      setState(() {
        _presets = presets;
        _activePreset = control?['risk_preset'] as String?;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _selectPreset(String name) async {
    if (name == _activePreset || _actionInFlight) return;
    final preset = _presets![name]!;
    final password = await showPasswordConfirmDialog(
      context: context,
      title: 'Switch to $name?',
      message:
          'Sizes each new trade at ${preset.sizingValue.toStringAsFixed(1)}% of account equity '
          '(was ${_activePreset ?? 'unset'}). Takes effect from the next trade onward - '
          'anything already open is unaffected. Enter your password to confirm.',
      confirmLabel: 'Switch to $name',
    );
    if (password == null || !mounted) return;

    setState(() => _actionInFlight = true);
    try {
      await AuthClient.setRiskPreset(name, password);
      if (!mounted) return;
      setState(() => _activePreset = name);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Switched to $name.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString()), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _actionInFlight = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Bot Control')),
      body: RefreshIndicator(onRefresh: _refresh, child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return ListView(
        children: [
          const SizedBox(height: 80),
          Icon(Icons.cloud_off, size: 48, color: Colors.grey[400]),
          const SizedBox(height: 12),
          Center(child: Text(_error!, style: TextStyle(color: Colors.grey[600]))),
          const SizedBox(height: 16),
          Center(
            child: OutlinedButton(onPressed: _refresh, child: const Text('Try again')),
          ),
        ],
      );
    }
    final presets = _presets ?? {};
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text(
          'Risk preset',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        Text(
          'Changes position sizing, volatility targeting, and drawdown/giveback '
          'protection together. Takes effect on the next trade.',
          style: TextStyle(color: Colors.grey[600], fontSize: 13),
        ),
        const SizedBox(height: 12),
        for (final name in _presetOrder)
          if (presets.containsKey(name))
            _PresetCard(
              name: name,
              preset: presets[name]!,
              isActive: name == _activePreset,
              enabled: !_actionInFlight,
              onTap: () => _selectPreset(name),
            ),
        if (_activePreset == null) ...[
          const SizedBox(height: 8),
          Text(
            'No preset applied yet from either the app or the dashboard - '
            'current settings may not match any preset exactly.',
            style: TextStyle(color: Colors.grey[500], fontSize: 12),
          ),
        ],
      ],
    );
  }
}

class _PresetCard extends StatelessWidget {
  final String name;
  final RiskPreset preset;
  final bool isActive;
  final bool enabled;
  final VoidCallback onTap;

  const _PresetCard({
    required this.name,
    required this.preset,
    required this.isActive,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = isActive ? Theme.of(context).colorScheme.primary : Colors.grey[400]!;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: color, width: isActive ? 2 : 1),
      ),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          name,
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        if (isActive) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: color.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              'ACTIVE',
                              style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 11),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${preset.sizingValue.toStringAsFixed(1)}% per trade  ·  '
                      'vol target ${preset.volTargetAnn.toStringAsFixed(0)}%  ·  '
                      'max drawdown ${preset.maxDrawdownPct.toStringAsFixed(0)}%'
                      '${preset.givebackEnabled ? '  ·  giveback guard ${preset.givebackPct.toStringAsFixed(0)}%' : ''}',
                      style: TextStyle(color: Colors.grey[600], fontSize: 12),
                    ),
                  ],
                ),
              ),
              if (!isActive) Icon(Icons.chevron_right, color: Colors.grey[400]),
            ],
          ),
        ),
      ),
    );
  }
}
