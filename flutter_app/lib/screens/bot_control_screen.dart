import 'package:flutter/material.dart';

import '../models/account_sizing.dart';
import '../models/risk_control.dart';
import '../models/risk_preset.dart';
import '../models/target_config.dart';
import '../services/api_client.dart';
import '../services/auth_client.dart';
import '../widgets/collapsible_card.dart';
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
  double? _currentSizingValue;
  String? _error;
  bool _loading = true;
  bool _actionInFlight = false;

  TargetConfig? _targetConfig;
  String? _targetsError;
  List<AccountSizing>? _accountSizing;
  String? _sizingError;
  ProtectiveExits? _protectiveExits;
  String? _protectiveError;

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
        _currentSizingValue = control?['sizing_value'] as double?;
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
    // Each section fails independently - one backend hiccup shouldn't blank
    // the whole screen when the risk-preset section above already loaded.
    await _refreshTargets();
    await _refreshSizing();
    await _refreshProtectiveExits();
  }

  Future<void> _refreshProtectiveExits() async {
    try {
      final exits = await AuthClient.fetchProtectiveExits();
      if (!mounted) return;
      setState(() {
        _protectiveExits = exits;
        _protectiveError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _protectiveError = e.toString());
    }
  }

  Future<void> _saveProtectiveExits(ProtectiveExits next) async {
    final parts = <String>[];
    parts.add(next.stopEnabled
        ? 'Stop-loss ${next.stopLossPct!.toStringAsFixed(2)}%'
        : 'Stop-loss OFF');
    parts.add(next.takeProfitEnabled
        ? 'Take-profit ${next.takeProfitPct!.toStringAsFixed(2)}%'
        : 'Take-profit OFF');
    if (next.flattenEnabled) {
      parts.add('flatten ${next.flattenBeforeCloseMinutes}min before close');
    }
    final password = await showPasswordConfirmDialog(
      context: context,
      title: 'Update protective exits?',
      message: '${parts.join(', ')}.\n\nApplies to positions opened FROM NOW ON — '
          'anything already open was submitted without a bracket and is unaffected. '
          'Enter your password to confirm.',
      confirmLabel: 'Save',
    );
    if (password == null || !mounted) return;

    setState(() => _actionInFlight = true);
    try {
      await AuthClient.saveProtectiveExits(next, password);
      if (!mounted) return;
      setState(() => _protectiveExits = next);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Protective exits saved.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString()), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _actionInFlight = false);
    }
  }

  Future<void> _refreshTargets() async {
    try {
      final config = await AuthClient.fetchTargetConfig();
      if (!mounted) return;
      setState(() {
        _targetConfig = config;
        _targetsError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _targetsError = e.toString());
    }
  }

  Future<void> _refreshSizing() async {
    try {
      final sizing = await AuthClient.fetchAccountSizing();
      if (!mounted) return;
      setState(() {
        _accountSizing = sizing;
        _sizingError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _sizingError = e.toString());
    }
  }

  Future<void> _saveTargets(String mode, List<String> tickers, String strategyName) async {
    final modeLabel = mode == 'roster' ? 'Adaptive roster' : 'Manual';
    final message = mode == 'roster'
        ? 'Switches to Adaptive roster - the bot promotes/demotes tickers and '
            'strategies on its own. Enter your password to confirm.'
        : 'Trades exactly ${tickers.join(', ')} using $strategyName. Takes effect '
            'from the next poll cycle. Enter your password to confirm.';
    final password = await showPasswordConfirmDialog(
      context: context,
      title: 'Switch to $modeLabel?',
      message: message,
      confirmLabel: 'Save',
    );
    if (password == null || !mounted) return;

    setState(() => _actionInFlight = true);
    try {
      await AuthClient.setTargetConfig(
        mode: mode,
        tickers: tickers,
        strategyName: strategyName,
        password: password,
      );
      await _refreshTargets();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Trading targets saved.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toString()), backgroundColor: Colors.red));
    } finally {
      if (mounted) setState(() => _actionInFlight = false);
    }
  }

  Future<void> _saveSizing(AccountSizing account, double slideStartPct, double slideFloorNotional) async {
    final message = slideStartPct == 0
        ? 'Disables the sliding-scale sizing for ${account.nickname} - it will '
            'size every trade at the flat ${account.targetPct.toStringAsFixed(1)}% '
            'target rate. Enter your password to confirm.'
        : 'Sizes ${account.nickname} starting at ${slideStartPct.toStringAsFixed(0)}% of '
            'equity (was ${account.slideStartPct.toStringAsFixed(0)}%), sliding down to the '
            '${account.targetPct.toStringAsFixed(1)}% target as equity grows. Enter your '
            'password to confirm.';
    final password = await showPasswordConfirmDialog(
      context: context,
      title: 'Update sizing for ${account.nickname}?',
      message: message,
      confirmLabel: 'Save',
    );
    if (password == null || !mounted) return;

    setState(() => _actionInFlight = true);
    try {
      await AuthClient.setAccountSizing(
        accountId: account.accountId,
        slideStartPct: slideStartPct,
        slideFloorNotional: slideFloorNotional,
        password: password,
      );
      await _refreshSizing();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Sizing saved for ${account.nickname}.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toString()), backgroundColor: Colors.red));
    } finally {
      if (mounted) setState(() => _actionInFlight = false);
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

  Future<void> _saveCustomSizing(double value) async {
    if (_actionInFlight) return;
    final password = await showPasswordConfirmDialog(
      context: context,
      title: 'Set sizing to ${value.toStringAsFixed(1)}%?',
      message: 'Sizes each new trade at ${value.toStringAsFixed(1)}% of account equity '
          '(was ${_currentSizingValue?.toStringAsFixed(1) ?? 'unset'}%). Takes effect from the '
          'next trade onward - anything already open is unaffected. This does not change which '
          'preset name is shown as active. Enter your password to confirm.',
      confirmLabel: 'Set sizing',
    );
    if (password == null || !mounted) return;

    setState(() => _actionInFlight = true);
    try {
      await AuthClient.setCustomSizing(value, password);
      if (!mounted) return;
      setState(() => _currentSizingValue = value);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Sizing set to ${value.toStringAsFixed(1)}%.')));
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
      padding: EdgeInsets.fromLTRB(8, 12, 8, 24 + MediaQuery.of(context).padding.bottom),
      children: [
        CollapsibleCard(
          title: const Text('Risk preset', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          trailing: _activePreset != null
              ? Text(_activePreset!, style: TextStyle(color: Colors.grey[600], fontSize: 12))
              : null,
          children: [
            Text(
              'Changes position sizing, volatility targeting, and drawdown/giveback '
              'protection together. Takes effect on the next trade. Six roster tickers also carry '
              'their own liquidity ceiling on top of this (2026-08-16) - PSKY in particular caps '
              'well below the others regardless of preset, since it loses far more to slippage at '
              'large size. Check a position\'s own "Sized at" line below to see what actually applied.',
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
            const SizedBox(height: 12),
            _CustomSizingCard(
              key: ValueKey('custom-sizing-${_currentSizingValue ?? 0}'),
              currentValue: _currentSizingValue,
              enabled: !_actionInFlight,
              onSave: _saveCustomSizing,
            ),
          ],
        ),
        CollapsibleCard(
          title: const Text('Trading targets', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          trailing: _targetConfig != null
              ? Text(_targetConfig!.mode == 'roster' ? 'Adaptive' : 'Manual',
                  style: TextStyle(color: Colors.grey[600], fontSize: 12))
              : null,
          children: [
            Text(
              'Manual mode trades a fixed ticker list with one strategy. Adaptive roster '
              'promotes/demotes combos on its own.',
              style: TextStyle(color: Colors.grey[600], fontSize: 13),
            ),
            const SizedBox(height: 12),
            if (_targetsError != null)
              Text(_targetsError!, style: const TextStyle(color: Colors.red))
            else if (_targetConfig == null)
              const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()))
            else
              _TargetsSection(
                key: ValueKey(
                  '${_targetConfig!.mode}-${_targetConfig!.tickers.join(",")}-${_targetConfig!.strategyName}',
                ),
                config: _targetConfig!,
                enabled: !_actionInFlight,
                onSave: _saveTargets,
              ),
          ],
        ),
        CollapsibleCard(
          title: const Text('Sliding-scale sizing', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          initiallyExpanded: false,
          children: [
            Text(
              'For accounts using a small-account slide instead of a flat rate - see what '
              'each one is actually sizing at right now, and nudge the starting rate up or '
              'down as it proves itself.',
              style: TextStyle(color: Colors.grey[600], fontSize: 13),
            ),
            const SizedBox(height: 12),
            if (_sizingError != null)
              Text(_sizingError!, style: const TextStyle(color: Colors.red))
            else if (_accountSizing == null)
              const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()))
            else if (_accountSizing!.isEmpty)
              Text(
                'No accounts currently selected for auto-trading - pick one on the '
                'dashboard\'s Auto Trading tab first.',
                style: TextStyle(color: Colors.grey[600], fontSize: 13),
              )
            else
              for (final account in _accountSizing!)
                _SizingCard(
                  key: ValueKey('${account.accountId}-${account.slideStartPct}-${account.slideFloorNotional}'),
                  account: account,
                  enabled: !_actionInFlight,
                  onSave: (start, floor) => _saveSizing(account, start, floor),
                ),
          ],
        ),
        CollapsibleCard(
          title: const Text('Protective exits', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          initiallyExpanded: false,
          children: [
            if (_protectiveError != null)
              Text(_protectiveError!, style: const TextStyle(color: Colors.red))
            else if (_protectiveExits == null)
              const Center(
                  child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()))
            else
              _ProtectiveExitsCard(
                key: ValueKey('pe-${_protectiveExits!.stopLossPct}-'
                    '${_protectiveExits!.takeProfitPct}-${_protectiveExits!.flattenBeforeCloseMinutes}'),
                exits: _protectiveExits!,
                enabled: !_actionInFlight,
                onSave: _saveProtectiveExits,
              ),
          ],
        ),
      ],
    );
  }
}

/// Stop-loss / take-profit, with the evidence behind the defaults stated on
/// the card itself. Deliberately verbose for a phone screen: these are the one
/// set of controls here where the intuitive choice and the measured one
/// disagree, and a number changed on a train without that context is exactly
/// how a tested setting quietly becomes an untested one.
class _ProtectiveExitsCard extends StatefulWidget {
  final ProtectiveExits exits;
  final bool enabled;
  final Future<void> Function(ProtectiveExits) onSave;

  const _ProtectiveExitsCard({
    super.key,
    required this.exits,
    required this.enabled,
    required this.onSave,
  });

  @override
  State<_ProtectiveExitsCard> createState() => _ProtectiveExitsCardState();
}

class _ProtectiveExitsCardState extends State<_ProtectiveExitsCard> {
  late bool _stopOn = widget.exits.stopEnabled;
  late bool _tpOn = widget.exits.takeProfitEnabled;
  late bool _flatOn = widget.exits.flattenEnabled;
  late double _stopPct = widget.exits.stopLossPct ?? 1.0;
  late double _tpPct = widget.exits.takeProfitPct ?? 1.5;
  late int _flatMin = widget.exits.flattenBeforeCloseMinutes ?? 10;

  bool get _dirty =>
      _stopOn != widget.exits.stopEnabled ||
      _tpOn != widget.exits.takeProfitEnabled ||
      _flatOn != widget.exits.flattenEnabled ||
      (_stopOn && _stopPct != widget.exits.stopLossPct) ||
      (_tpOn && _tpPct != widget.exits.takeProfitPct) ||
      (_flatOn && _flatMin != widget.exits.flattenBeforeCloseMinutes);

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Attached to the OPENING order as broker-side brackets, so they keep working '
              'even if the bot process is down.',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
            const Divider(),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Take-profit'),
              subtitle: Text(
                _tpOn ? '${_tpPct.toStringAsFixed(2)}% in favour of entry' : 'Off',
                style: const TextStyle(fontSize: 12),
              ),
              value: _tpOn,
              onChanged: widget.enabled ? (v) => setState(() => _tpOn = v) : null,
            ),
            if (_tpOn)
              Slider(
                value: _tpPct, min: 0.25, max: 5.0, divisions: 19,
                label: '${_tpPct.toStringAsFixed(2)}%',
                onChanged: widget.enabled ? (v) => setState(() => _tpPct = v) : null,
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Stop-loss'),
              subtitle: Text(
                _stopOn ? '${_stopPct.toStringAsFixed(2)}% adverse to entry' : 'Off',
                style: const TextStyle(fontSize: 12),
              ),
              value: _stopOn,
              onChanged: widget.enabled ? (v) => setState(() => _stopOn = v) : null,
            ),
            if (_stopOn)
              Slider(
                value: _stopPct, min: 0.25, max: 5.0, divisions: 19,
                label: '${_stopPct.toStringAsFixed(2)}%',
                onChanged: widget.enabled ? (v) => setState(() => _stopPct = v) : null,
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Flatten before close'),
              subtitle: Text(
                _flatOn ? '$_flatMin min before the bell' : 'Off — tested WORSE, see below',
                style: const TextStyle(fontSize: 12),
              ),
              value: _flatOn,
              onChanged: widget.enabled ? (v) => setState(() => _flatOn = v) : null,
            ),
            if (_flatOn)
              Slider(
                value: _flatMin.toDouble(), min: 5, max: 60, divisions: 11,
                label: '$_flatMin min',
                onChanged:
                    widget.enabled ? (v) => setState(() => _flatMin = v.round()) : null,
              ),
            const Divider(),
            Text(
              'From a walk-forward sweep (6 combos, selected on Jun 2026, tested on Jul + Aug):\n'
              '• Take-profit ~1.5% was the only setting that improved P&L out-of-sample, '
              'though the best value moved between windows.\n'
              '• A 1% stop costs ~15% of expected return and cuts the worst single trade by '
              '60-90%. It is NOT a guaranteed cap — an overnight gap fills through it.\n'
              '• Flattening before the close LOST money in all three windows. It is here '
              'because not holding overnight is a valid preference, not a recommendation.',
              style: TextStyle(fontSize: 11, color: Colors.grey[600]),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: (widget.enabled && _dirty)
                    ? () => widget.onSave(ProtectiveExits(
                          stopLossPct: _stopOn ? _stopPct : null,
                          takeProfitPct: _tpOn ? _tpPct : null,
                          flattenBeforeCloseMinutes: _flatOn ? _flatMin : null,
                        ))
                    : null,
                child: Text(_dirty ? 'Save protective exits' : 'No changes'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Free-form sizing % - the escape hatch for anything the three named
/// presets don't cover (e.g. going back to the old 1% default, or any other
/// value). Mirrors the dashboard's Advanced Settings sizing field, which has
/// always allowed this; this is the same capability for the phone.
class _CustomSizingCard extends StatefulWidget {
  final double? currentValue;
  final bool enabled;
  final Future<void> Function(double) onSave;

  const _CustomSizingCard({
    super.key,
    required this.currentValue,
    required this.enabled,
    required this.onSave,
  });

  @override
  State<_CustomSizingCard> createState() => _CustomSizingCardState();
}

class _CustomSizingCardState extends State<_CustomSizingCard> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.currentValue?.toStringAsFixed(1) ?? '',
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double? get _value => double.tryParse(_controller.text);
  bool get _isValid => _value != null && _value! >= 1.0 && _value! <= 100.0;
  bool get _isDirty => _value != null && _value != widget.currentValue;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Custom sizing', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            const SizedBox(height: 4),
            Text(
              'Any value 1-100% of equity per trade, if none of the presets above are quite '
              'right - the range risk_dial_sizing_sweep.py actually walk-forward tested. Sharpe '
              'came back flat across that whole range, so there is no "best" number here, only '
              'the risk/return trade-off you\'re comfortable with.',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    enabled: widget.enabled,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: 'Sizing %',
                      suffixText: '%',
                      border: const OutlineInputBorder(),
                      errorText: _controller.text.isNotEmpty && !_isValid
                          ? '1-100 only'
                          : null,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: (widget.enabled && _isValid && _isDirty)
                      ? () => widget.onSave(_value!)
                      : null,
                  child: const Text('Set'),
                ),
              ],
            ),
          ],
        ),
      ),
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

/// Manual/Adaptive roster mode switch, plus the ticker list + strategy for
/// Manual mode - mirrors app.py's Auto Trading tab mode radio + fields.
/// Rebuilt fresh (via the parent's ValueKey) whenever the server-side config
/// changes, so its local edit buffer always starts in sync with reality.
class _TargetsSection extends StatefulWidget {
  final TargetConfig config;
  final bool enabled;
  final void Function(String mode, List<String> tickers, String strategyName) onSave;

  const _TargetsSection({super.key, required this.config, required this.enabled, required this.onSave});

  @override
  State<_TargetsSection> createState() => _TargetsSectionState();
}

class _TargetsSectionState extends State<_TargetsSection> {
  late String _mode;
  late TextEditingController _tickersController;
  late String _strategyName;

  @override
  void initState() {
    super.initState();
    _mode = widget.config.mode;
    _tickersController = TextEditingController(text: widget.config.tickers.join(', '));
    _strategyName = widget.config.availableStrategies.contains(widget.config.strategyName)
        ? widget.config.strategyName
        : (widget.config.availableStrategies.isNotEmpty ? widget.config.availableStrategies.first : '');
  }

  @override
  void dispose() {
    _tickersController.dispose();
    super.dispose();
  }

  List<String> get _tickers => _tickersController.text
      .split(',')
      .map((t) => t.trim().toUpperCase())
      .where((t) => t.isNotEmpty)
      .toList();

  bool get _isValid => _mode == 'roster' || (_tickers.isNotEmpty && _strategyName.isNotEmpty);

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'manual', label: Text('Manual')),
                ButtonSegment(value: 'roster', label: Text('Adaptive roster')),
              ],
              selected: {_mode},
              onSelectionChanged: widget.enabled
                  ? (s) => setState(() => _mode = s.first)
                  : null,
            ),
            if (_mode == 'manual') ...[
              const SizedBox(height: 12),
              TextField(
                controller: _tickersController,
                enabled: widget.enabled,
                decoration: const InputDecoration(
                  labelText: 'Tickers (comma-separated)',
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _strategyName.isNotEmpty ? _strategyName : null,
                items: widget.config.availableStrategies
                    .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                    .toList(),
                onChanged: widget.enabled ? (v) => setState(() => _strategyName = v ?? '') : null,
                decoration: const InputDecoration(labelText: 'Strategy', border: OutlineInputBorder()),
              ),
            ],
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: (widget.enabled && _isValid)
                    ? () => widget.onSave(_mode, _tickers, _strategyName)
                    : null,
                child: const Text('Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One account's sliding-scale sizing card - shows real equity and the
/// currently-computed effective rate ("what it's trading at"), plus editable
/// slide_start_pct/slide_floor_notional and a password-confirmed Save.
/// Rebuilt fresh (via the parent's ValueKey) after every successful save.
class _SizingCard extends StatefulWidget {
  final AccountSizing account;
  final bool enabled;
  final void Function(double slideStartPct, double slideFloorNotional) onSave;

  const _SizingCard({super.key, required this.account, required this.enabled, required this.onSave});

  @override
  State<_SizingCard> createState() => _SizingCardState();
}

class _SizingCardState extends State<_SizingCard> {
  late TextEditingController _startController;
  late TextEditingController _floorController;

  @override
  void initState() {
    super.initState();
    _startController = TextEditingController(text: widget.account.slideStartPct.toStringAsFixed(0));
    _floorController = TextEditingController(text: widget.account.slideFloorNotional.toStringAsFixed(2));
  }

  @override
  void dispose() {
    _startController.dispose();
    _floorController.dispose();
    super.dispose();
  }

  double? get _startValue => double.tryParse(_startController.text);
  double? get _floorValue => double.tryParse(_floorController.text);
  bool get _isValid => _startValue != null && _startValue! >= 0 && _floorValue != null && _floorValue! > 0;

  String get _statusLine {
    final a = widget.account;
    if (!a.slideEnabled) {
      return 'Flat ${a.targetPct.toStringAsFixed(1)}% (slide disabled)';
    }
    if (a.currentEffectivePct == null) {
      return 'Equity unavailable right now - can\'t compute the current rate.';
    }
    return '${a.currentEffectivePct!.toStringAsFixed(1)}% right now — sliding from '
        '${a.slideStartPct.toStringAsFixed(0)}% down to ${a.targetPct.toStringAsFixed(1)}% '
        'as equity grows.';
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.account;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${a.nickname} — ${a.broker}${a.isPaper ? ' (Paper)' : ' (LIVE)'}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                Text(
                  a.equity != null ? '\$${a.equity!.toStringAsFixed(2)} equity' : 'equity unknown',
                  style: TextStyle(color: Colors.grey[600], fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(_statusLine, style: TextStyle(color: Colors.grey[700], fontSize: 13)),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _startController,
                    enabled: widget.enabled,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Slide start % (0 = off)',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _floorController,
                    enabled: widget.enabled,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Broker min order (\$)',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: (widget.enabled && _isValid)
                    ? () => widget.onSave(_startValue!, _floorValue!)
                    : null,
                child: const Text('Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
