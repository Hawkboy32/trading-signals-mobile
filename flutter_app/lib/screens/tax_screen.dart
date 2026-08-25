import 'package:flutter/material.dart';

import '../models/tax.dart';
import '../services/auth_client.dart';
import '../widgets/collapsible_card.dart';
import '../widgets/password_confirm_dialog.dart';

/// GBP capital-gains ESTIMATE per account - mirrors the dashboard's own
/// Accounts-tab "Tax (GBP estimate)" section against the same
/// /tax-summary + /tax-settings endpoints. Same disclaimer as there: the
/// SIMPLE realized-P&L-sum method, not HMRC Section 104 share pooling, and
/// not a substitute for an actual Self Assessment. Allowance/rate/FX rate
/// all default to 0 server-side until set here or on the dashboard - never
/// assumed, since none of them are things this app can reliably know are
/// current.
class TaxScreen extends StatefulWidget {
  const TaxScreen({super.key});

  @override
  State<TaxScreen> createState() => _TaxScreenState();
}

class _TaxScreenState extends State<TaxScreen> {
  TaxSummary? _summary;
  String? _error;
  bool _loading = true;
  bool _saving = false;

  final _allowanceController = TextEditingController();
  final _rateController = TextEditingController();
  final _fxController = TextEditingController();
  Map<String, String> _currencyChoices = {};

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _allowanceController.dispose();
    _rateController.dispose();
    _fxController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final summary = await AuthClient.fetchTaxSummary();
      final settings = await AuthClient.fetchTaxSettings();
      if (!mounted) return;
      setState(() {
        _summary = summary;
        _allowanceController.text = settings.cgtAllowanceGbp.toStringAsFixed(2);
        _rateController.text = settings.cgtRatePct.toStringAsFixed(1);
        _fxController.text = settings.gbpUsdRate.toStringAsFixed(4);
        _currencyChoices = Map.of(settings.accountCurrencies);
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

  Future<void> _save() async {
    final allowance = double.tryParse(_allowanceController.text);
    final rate = double.tryParse(_rateController.text);
    final fx = double.tryParse(_fxController.text);
    if (allowance == null || rate == null || fx == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter valid numbers for allowance, rate, and FX rate.')),
      );
      return;
    }
    final password = await showPasswordConfirmDialog(
      context: context,
      title: 'Save tax settings?',
      message: 'Updates the allowance, rate, FX rate, and per-account currencies used for the '
          'GBP tax estimate on both the app and the dashboard. Enter your password to confirm.',
      confirmLabel: 'Save',
    );
    if (password == null || !mounted) return;

    setState(() => _saving = true);
    try {
      await AuthClient.updateTaxSettings(
        cgtAllowanceGbp: allowance,
        cgtRatePct: rate,
        gbpUsdRate: fx,
        accountCurrencies: _currencyChoices,
        password: password,
      );
      await _refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Tax settings saved.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString()), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Tax (GBP estimate)')),
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
          Center(child: Text(_error!, style: const TextStyle(color: Colors.grey))),
        ],
      );
    }
    final summary = _summary!;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          color: Colors.amber.withValues(alpha: 0.08),
          child: const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              'A running estimate only - NOT a substitute for an actual Self Assessment. Sums '
              'each account\'s REALIZED P&L (closed trades) for the current UK tax year and '
              'applies a flat allowance/rate. Simple method, not full HMRC Section 104 share '
              'pooling.',
              style: TextStyle(fontSize: 12.5),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Tax year ${summary.taxYearStart} to ${summary.taxYearEnd}',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                for (final line in summary.lines)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text('${line.nickname} (${line.currency})'),
                        ),
                        Text(
                          '${line.currency == "GBP" ? "£" : "\$"}${line.realizedGainNative.toStringAsFixed(2)}',
                          style: const TextStyle(color: Colors.grey),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          line.realizedGainGbp != null
                              ? '£${line.realizedGainGbp!.toStringAsFixed(2)}'
                              : 'no FX rate',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: line.realizedGainGbp == null ? Colors.orange : null,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (summary.missingFxAccounts.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Excluded from the total (no GBP/USD rate set): ${summary.missingFxAccounts.join(", ")}.',
              style: const TextStyle(color: Colors.orange, fontSize: 12.5),
            ),
          ),
        const SizedBox(height: 16),
        _SummaryMetric(label: 'Total realized gain', value: summary.totalGainGbp),
        _SummaryMetric(label: 'Allowance', value: summary.allowanceGbp),
        _SummaryMetric(label: 'Taxable gain', value: summary.taxableGainGbp),
        _SummaryMetric(
          label: 'Estimated tax (${summary.ratePct.toStringAsFixed(1)}%)',
          value: summary.estimatedTaxGbp,
          emphasize: true,
        ),
        const SizedBox(height: 16),
        CollapsibleCard(
          title: const Text('Settings', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          initiallyExpanded: false,
          children: [
            const Text(
              'Neither figure is assumed - type in the current allowance/rate yourself.',
              style: TextStyle(color: Colors.grey, fontSize: 12.5),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _allowanceController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Annual CGT allowance (£)', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _rateController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'CGT rate (%)', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _fxController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'GBP/USD rate (USD per £1)', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
            Text('Per-account currency', style: Theme.of(context).textTheme.titleSmall),
            for (final line in summary.lines)
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(child: Text(line.nickname)),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'GBP', label: Text('GBP')),
                      ButtonSegment(value: 'USD', label: Text('USD')),
                    ],
                    selected: {_currencyChoices[line.accountId] ?? line.currency},
                    onSelectionChanged: (selection) {
                      setState(() => _currencyChoices[line.accountId] = selection.first);
                    },
                  ),
                ],
              ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Save tax settings'),
            ),
          ],
        ),
      ],
    );
  }
}

class _SummaryMetric extends StatelessWidget {
  final String label;
  final double value;
  final bool emphasize;

  const _SummaryMetric({required this.label, required this.value, this.emphasize = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: emphasize ? const TextStyle(fontWeight: FontWeight.bold) : null),
          Text(
            '£${value.toStringAsFixed(2)}',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: emphasize ? 18 : 14,
              color: emphasize ? Theme.of(context).colorScheme.primary : null,
            ),
          ),
        ],
      ),
    );
  }
}
