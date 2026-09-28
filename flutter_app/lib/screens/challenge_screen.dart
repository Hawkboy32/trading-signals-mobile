import 'package:flutter/material.dart';

import '../models/challenge.dart';
import '../models/risk_control.dart';
import '../services/auth_client.dart';
import '../widgets/password_confirm_dialog.dart';

/// Kraken Funded challenge tracking - deliberately its OWN section rather
/// than folded into the regular account views, because a challenge tracks a
/// FIXED +12%/-3% band from one starting balance, not a rolling drawdown.
/// See challenge_state.py/challenge_trader.py on the backend for why this is
/// a genuinely different kind of problem from everything else Chopper does.
class ChallengeScreen extends StatefulWidget {
  const ChallengeScreen({super.key});

  @override
  State<ChallengeScreen> createState() => _ChallengeScreenState();
}

class _ChallengeScreenState extends State<ChallengeScreen> {
  ChallengeState? _data;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      final data = await AuthClient.fetchChallenge();
      if (!mounted) return;
      setState(() {
        _data = data;
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

  Future<void> _openStartChallengeSheet() async {
    final started = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _StartChallengeSheet(),
    );
    if (started == true) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Challenges')),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: _buildBody(),
      ),
      floatingActionButton: (_data?.active == null && !_loading)
          ? FloatingActionButton.extended(
              onPressed: _openStartChallengeSheet,
              icon: const Icon(Icons.add),
              label: const Text('Start attempt'),
            )
          : null,
    );
  }

  Widget _buildBody() {
    if (_loading && _data == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _data == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, textAlign: TextAlign.center),
        ),
      );
    }
    final data = _data!;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (data.active != null)
          _ActiveAttemptCard(attempt: data.active!, tier: data.tiers[data.active!.tier])
        else
          const Card(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'No active challenge attempt.\n\nStart one below once bot/API trading on '
                'the Kraken Funded account is confirmed.',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        const SizedBox(height: 24),
        if (data.attempts.where((a) => a.status != 'active').isNotEmpty) ...[
          Text('History', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ...data.attempts.where((a) => a.status != 'active').toList().reversed.map(
                (a) => _HistoryTile(attempt: a, tier: data.tiers[a.tier]),
              ),
        ],
      ],
    );
  }
}

class _ActiveAttemptCard extends StatelessWidget {
  final ChallengeAttempt attempt;
  final ChallengeTier? tier;

  const _ActiveAttemptCard({required this.attempt, required this.tier});

  @override
  Widget build(BuildContext context) {
    final balance = attempt.currentBalance;
    final progress = attempt.progressFraction;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${tier?.label ?? attempt.tier} - Attempt #${attempt.attemptNumber}',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const Chip(label: Text('Active')),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${attempt.strategyName} - ${(attempt.sizingPct * 100).toStringAsFixed(0)}% sizing per entry',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 20),
            if (balance != null && progress != null)
              _ChallengeProgressBar(
                floor: attempt.floor,
                start: attempt.startingBalance,
                target: attempt.target,
                current: balance,
                progressFraction: progress,
              )
            else
              const Text('Could not read the account balance.'),
          ],
        ),
      ),
    );
  }
}

/// Horizontal bar spanning floor (-3%) to target (+12%) - NOT centered on the
/// starting balance, since that sits only 20% of the way in from the floor
/// end (a 15-point span, -3 to 0 is 3 of those 15 points). Matches the same
/// asymmetric layout the Datapad widget's own version of this bar uses, so
/// the two surfaces agree on what "close to failing" looks like.
class _ChallengeProgressBar extends StatelessWidget {
  final double floor;
  final double start;
  final double target;
  final double current;
  final double progressFraction;

  const _ChallengeProgressBar({
    required this.floor,
    required this.start,
    required this.target,
    required this.current,
    required this.progressFraction,
  });

  @override
  Widget build(BuildContext context) {
    final clamped = progressFraction.clamp(0.0, 1.0);
    final startFraction = (start - floor) / (target - floor);
    final scheme = Theme.of(context).colorScheme;
    final barColor = current <= floor
        ? scheme.error
        : (current >= target ? Colors.green : scheme.primary);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('\$${current.toStringAsFixed(2)}', style: Theme.of(context).textTheme.headlineSmall),
            Text(
              '${((current - start) / start * 100).toStringAsFixed(2)}%',
              style: TextStyle(color: barColor, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            return SizedBox(
              height: 28,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    height: 10,
                    margin: const EdgeInsets.only(top: 9),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(5),
                    ),
                  ),
                  Container(
                    height: 10,
                    width: width * clamped,
                    margin: const EdgeInsets.only(top: 9),
                    decoration: BoxDecoration(
                      color: barColor,
                      borderRadius: BorderRadius.circular(5),
                    ),
                  ),
                  // Tick marking the starting balance (0%), between the floor
                  // and target ends - the reference point everything above
                  // and below it is measured against.
                  Positioned(
                    left: (width * startFraction).clamp(0.0, width) - 1,
                    top: 4,
                    child: Container(width: 2, height: 20, color: scheme.outline),
                  ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Floor \$${floor.toStringAsFixed(0)} (-3%)', style: Theme.of(context).textTheme.bodySmall),
            Text('Start \$${start.toStringAsFixed(0)}', style: Theme.of(context).textTheme.bodySmall),
            Text('Target \$${target.toStringAsFixed(0)} (+12%)', style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ],
    );
  }
}

class _HistoryTile extends StatelessWidget {
  final ChallengeAttempt attempt;
  final ChallengeTier? tier;

  const _HistoryTile({required this.attempt, required this.tier});

  @override
  Widget build(BuildContext context) {
    final passed = attempt.status == 'passed';
    return Card(
      child: ListTile(
        leading: Icon(
          passed ? Icons.check_circle : Icons.cancel,
          color: passed ? Colors.green : Colors.red,
        ),
        title: Text('${tier?.label ?? attempt.tier} - Attempt #${attempt.attemptNumber}'),
        subtitle: Text(
          '${attempt.strategyName}\nEnded ${attempt.endedAt?.split("T").first ?? "?"} at '
          '\$${attempt.endingBalance?.toStringAsFixed(2) ?? "?"}',
        ),
        isThreeLine: true,
        trailing: Text(passed ? 'PASSED' : 'FAILED', style: TextStyle(color: passed ? Colors.green : Colors.red)),
      ),
    );
  }
}

/// Form to start a new attempt - tier, which linked account, strategy, and
/// per-entry sizing. Sizing has no single "proven" default yet (see
/// kraken_funded_challenge_sim.py's sweep) so it's a plain editable field,
/// not a locked-in constant.
class _StartChallengeSheet extends StatefulWidget {
  const _StartChallengeSheet();

  @override
  State<_StartChallengeSheet> createState() => _StartChallengeSheetState();
}

class _StartChallengeSheetState extends State<_StartChallengeSheet> {
  List<AccountRiskStatus> _accounts = [];
  bool _loadingAccounts = true;
  bool _submitting = false;
  String? _error;

  String _tier = 'starter';
  String? _accountId;
  final _strategyController = TextEditingController(text: 'VWAP Mean Reversion');
  final _sizingController = TextEditingController(text: '20');

  @override
  void initState() {
    super.initState();
    _loadAccounts();
  }

  Future<void> _loadAccounts() async {
    try {
      final accounts = await AuthClient.fetchAccountRisk();
      if (!mounted) return;
      setState(() {
        _accounts = accounts;
        _accountId = accounts.isNotEmpty ? accounts.first.accountId : null;
        _loadingAccounts = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load linked accounts: $e';
        _loadingAccounts = false;
      });
    }
  }

  Future<void> _submit() async {
    final accountId = _accountId;
    final sizingPct = double.tryParse(_sizingController.text);
    if (accountId == null) {
      setState(() => _error = 'Pick an account first.');
      return;
    }
    if (sizingPct == null || sizingPct < 1 || sizingPct > 100) {
      setState(() => _error = 'Sizing must be a number between 1 and 100.');
      return;
    }

    final password = await showPasswordConfirmDialog(
      context: context,
      title: 'Start challenge attempt?',
      message: 'Records a new active $_tier attempt on this account, sized at '
          '${sizingPct.toStringAsFixed(0)}% of equity per entry. This does NOT start '
          'live trading by itself - challenge_trader.py still has to be run separately.',
      confirmLabel: 'Start',
    );
    if (password == null || !mounted) return;

    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await AuthClient.startChallenge(
        tier: _tier,
        accountId: accountId,
        strategyName: _strategyController.text.trim(),
        sizingPct: sizingPct,
        password: password,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _submitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Start challenge attempt', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _tier,
            decoration: const InputDecoration(labelText: 'Tier'),
            items: const [
              DropdownMenuItem(value: 'starter', child: Text('Starter - \$1,000 (\$20 fee)')),
              DropdownMenuItem(value: 'mid', child: Text('Mid - \$5,000 (\$50 fee)')),
              DropdownMenuItem(value: 'anchor', child: Text('Anchor - \$10,000 (\$90 fee)')),
            ],
            onChanged: (v) => setState(() => _tier = v ?? 'starter'),
          ),
          const SizedBox(height: 12),
          if (_loadingAccounts)
            const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator())
          else
            DropdownButtonFormField<String>(
              initialValue: _accountId,
              decoration: const InputDecoration(labelText: 'Account'),
              items: _accounts
                  .map((a) => DropdownMenuItem(value: a.accountId, child: Text(a.nickname)))
                  .toList(),
              onChanged: (v) => setState(() => _accountId = v),
            ),
          const SizedBox(height: 12),
          TextField(
            controller: _strategyController,
            decoration: const InputDecoration(labelText: 'Strategy'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _sizingController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Sizing (% of equity per entry)'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _submitting ? null : _submit,
            child: _submitting
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Start attempt'),
          ),
        ],
      ),
    );
  }
}
