import 'package:flutter/material.dart';

import '../models/advisor_report.dart';
import '../models/roster.dart';
import '../models/risk_control.dart';
import '../models/roster_recommendation.dart';
import '../services/api_client.dart';
import '../services/auth_client.dart';
import '../widgets/collapsible_card.dart';
import '../widgets/password_confirm_dialog.dart';

/// "Active 3d ago" / "Paused 5h ago" - same coarse Xm/Xh/Xd granularity as
/// the home-screen widget's own relative-time label, kept consistent rather
/// than inventing a second format.
String _relativeTime(DateTime when) {
  final diff = DateTime.now().toUtc().difference(when.toUtc());
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  return '${diff.inDays}d ago';
}

/// Shows each roster combo's live performance against the bot's own
/// demotion thresholds (roster.py's RosterConfig) - answers "why is this
/// paused" / "is it learning yet" without asking, matching what got
/// explained in chat a few times before this screen existed.
class RosterHealthScreen extends StatefulWidget {
  const RosterHealthScreen({super.key});

  @override
  State<RosterHealthScreen> createState() => _RosterHealthScreenState();
}

class _RosterHealthScreenState extends State<RosterHealthScreen> {
  RosterResponse? _data;
  String? _error;
  bool _loading = true;

  RosterRecommendation? _recommendation;
  bool _recActionInFlight = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final data = await ApiClient.fetchRoster();
      if (!mounted) return;
      setState(() {
        _data = data;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not reach backend - check Settings.';
        _loading = false;
      });
    }
    await _refreshRecommendation();
  }

  Future<void> _refreshRecommendation() async {
    // Login-gated (real trading-config data) - this screen is otherwise
    // fully public, so a not-logged-in visitor just doesn't see the banner
    // rather than being forced to log in for a read-only roster view.
    if (!await AuthClient.isLoggedIn()) return;
    try {
      final rec = await AuthClient.fetchRosterRecommendation();
      if (!mounted) return;
      setState(() => _recommendation = rec);
    } catch (_) {
      // Silent - same reasoning as the entry-price overlay on the signal
      // detail chart: a nice-to-have, not core to this screen.
    }
  }

  Future<void> _respondToRecommendation(String action) async {
    final rec = _recommendation;
    if (rec == null || _recActionInFlight) return;
    final verb = action == 'apply' ? 'Apply' : 'Dismiss';
    final message = action == 'apply'
        ? 'Updates the live roster to match this recommendation:\n\n${rec.summary.join('\n')}'
        : 'Leaves the roster exactly as it is now - this recommendation will be discarded.';
    final password = await showPasswordConfirmDialog(
      context: context,
      title: '$verb roster recommendation?',
      message: message,
      confirmLabel: verb,
    );
    if (password == null || !mounted) return;

    setState(() => _recActionInFlight = true);
    try {
      await AuthClient.respondToRosterRecommendation(action: action, password: password);
      if (!mounted) return;
      setState(() => _recommendation = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(action == 'apply' ? 'Roster updated.' : 'Recommendation dismissed.')),
      );
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString()), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _recActionInFlight = false);
    }
  }

  Future<void> _openRosterSettings() async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _RosterSettingsSheet(),
    );
    if (changed == true) await _refresh();
  }

  Future<void> _openAccountRisk() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _AccountRiskSheet(),
    );
  }

  Future<void> _openAdvisor() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _AdvisorSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Roster Health'),
        actions: [
          IconButton(
            icon: const Icon(Icons.auto_awesome_outlined),
            tooltip: 'Ask Claude advisor',
            onPressed: _openAdvisor,
          ),
          IconButton(
            icon: const Icon(Icons.health_and_safety_outlined),
            tooltip: 'Account risk / circuit breakers',
            onPressed: _openAccountRisk,
          ),
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: 'Roster settings',
            onPressed: _openRosterSettings,
          ),
        ],
      ),
      body: RefreshIndicator(onRefresh: _refresh, child: _buildBody()),
    );
  }

  List<Widget> _recommendationBannerWidgets() {
    final rec = _recommendation;
    if (rec == null) return [];
    return [
      Card(
        margin: const EdgeInsets.fromLTRB(8, 8, 8, 4),
        color: Theme.of(context).colorScheme.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.notifications_active, size: 18),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text('Roster change ready to review', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'From scan run #${rec.scanRunId} (${rec.numScanResults} results). Nothing applied yet.',
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 6),
              for (final line in rec.summary) Text('• $line', style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 10),
              Row(
                children: [
                  FilledButton(
                    onPressed: _recActionInFlight ? null : () => _respondToRecommendation('apply'),
                    child: const Text('Apply'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: _recActionInFlight ? null : () => _respondToRecommendation('dismiss'),
                    child: const Text('Dismiss'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ];
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
        ],
      );
    }
    final data = _data!;
    final activeCount = data.entries.where((e) => e.status == 'active').length;

    if (data.entries.isEmpty && data.candidates.isEmpty) {
      return ListView(
        children: [
          ..._recommendationBannerWidgets(),
          const SizedBox(height: 80),
          Center(
            child: Text('No active, paused, or candidate combos right now.', style: TextStyle(color: Colors.grey[600])),
          ),
        ],
      );
    }
    return ListView(
      // Bottom padding well past the default 8dp - the last card was getting
      // clipped by the system nav bar/gesture area on the real device.
      padding: EdgeInsets.fromLTRB(8, 8, 8, 24 + MediaQuery.of(context).padding.bottom),
      children: [
        ..._recommendationBannerWidgets(),
        CollapsibleCard(
          title: const Text('Active roster', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          trailing: Text('$activeCount/${data.config.rosterSize}', style: TextStyle(color: Colors.grey[600])),
          padding: const EdgeInsets.fromLTRB(6, 10, 6, 6),
          children: data.entries.isEmpty
              ? [
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text('No active or paused combos right now.', style: TextStyle(color: Colors.grey[600])),
                  ),
                ]
              : data.entries.map((e) => _RosterCard(entry: e, config: data.config, onChanged: _refresh)).toList(),
        ),
        if (data.candidates.isNotEmpty)
          CollapsibleCard(
            title: const Text('Candidates', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            trailing: Text('top ${data.candidates.length} of ${data.config.numCandidates}',
                style: TextStyle(color: Colors.grey[600], fontSize: 12)),
            // Not yet promoted / not actionable - secondary to the active
            // roster above, so collapsed by default.
            initiallyExpanded: false,
            padding: const EdgeInsets.fromLTRB(6, 10, 6, 6),
            children: data.candidates.map((e) => _CandidateCard(entry: e)).toList(),
          ),
      ],
    );
  }
}

class _RosterCard extends StatelessWidget {
  final RosterEntry entry;
  final RosterConfig config;
  final Future<void> Function() onChanged;

  const _RosterCard({required this.entry, required this.config, required this.onChanged});

  bool get _isPaused => entry.status == 'paused';

  Color get _statusColor => _isPaused ? Colors.orange : Colors.green;

  /// Manual override of the automatic pause/promote rules. Activating grants
  /// the same one-trade streak grace an auto-release does - without it a
  /// combo benched on a frozen losing streak would be re-paused on the very
  /// next poll and the button would appear to do nothing.
  Future<void> _setStatus(BuildContext context, String action) async {
    final activating = action == 'activate';
    final password = await showPasswordConfirmDialog(
      context: context,
      title: activating ? 'Activate ${entry.ticker}?' : 'Pause ${entry.ticker}?',
      message: activating
          ? '${entry.ticker} / ${entry.strategyName} starts trading again on the next '
              'poll cycle, overriding the automatic rules.\n\n'
              'It gets one trade of grace on the losing-streak rule, then is judged normally.'
          : '${entry.ticker} / ${entry.strategyName} stops opening new positions. '
              'It can still CLOSE anything it currently holds.',
      confirmLabel: activating ? 'Activate' : 'Pause',
      isDestructive: !activating,
    );
    if (password == null || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      await AuthClient.setRosterEntryStatus(
        ticker: entry.ticker,
        strategyName: entry.strategyName,
        action: action,
        password: password,
      );
      messenger.showSnackBar(SnackBar(
        content: Text('${entry.ticker} ${activating ? 'activated' : 'paused'}.'),
      ));
      await onChanged();
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not update ${entry.ticker}: $e'), backgroundColor: Colors.red),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final stats = entry.liveStats;
    final numTrades = stats?.numTrades ?? 0;
    final judged = numTrades >= config.minLiveTrades;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(entry.ticker, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      Text(
                        '${entry.strategyName} - backtest score ${entry.backtestScore.toStringAsFixed(2)}',
                        style: TextStyle(color: Colors.grey[600], fontSize: 13),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    border: Border.all(color: _statusColor),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    entry.status.toUpperCase(),
                    style: TextStyle(color: _statusColor, fontWeight: FontWeight.bold, fontSize: 12),
                  ),
                ),
              ],
            ),
            if (_isPaused && entry.pausedAt != null)
              Text('Paused ${_relativeTime(entry.pausedAt!)}', style: TextStyle(color: Colors.grey[500], fontSize: 11))
            else if (!_isPaused && entry.promotedAt != null)
              Text('Active since ${_relativeTime(entry.promotedAt!)}', style: TextStyle(color: Colors.grey[500], fontSize: 11)),
            if (_isPaused && entry.pauseReason != null) ...[
              const SizedBox(height: 6),
              Text(entry.pauseReason!, style: const TextStyle(color: Colors.orange, fontSize: 12)),
            ],
            const SizedBox(height: 10),
            if (!judged) ...[
              Text(
                '$numTrades / ${config.minLiveTrades} trades - not enough sample yet to be judged',
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
              const SizedBox(height: 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: (numTrades / config.minLiveTrades).clamp(0.0, 1.0),
                  minHeight: 6,
                  backgroundColor: Colors.grey[300],
                ),
              ),
            ] else ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('$numTrades trades', style: const TextStyle(fontSize: 13)),
                  if (stats?.winRate != null)
                    Text('${(stats!.winRate! * 100).toStringAsFixed(0)}% win rate', style: const TextStyle(fontSize: 13)),
                  Text(
                    '${(stats?.totalPnl ?? 0) >= 0 ? '+' : ''}\$${(stats?.totalPnl ?? 0).toStringAsFixed(2)}',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: (stats?.totalPnl ?? 0) >= 0 ? Colors.green : Colors.red,
                    ),
                  ),
                ],
              ),
            ],
            if (stats != null && stats.currentLosingStreak > 0) ...[
              const SizedBox(height: 4),
              Text(
                '${stats.currentLosingStreak} losing streak (pauses at ${config.losingStreakThreshold})',
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
            ],
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                icon: Icon(_isPaused ? Icons.play_arrow : Icons.pause, size: 18),
                label: Text(_isPaused ? 'Activate' : 'Pause'),
                style: TextButton.styleFrom(
                  foregroundColor: _isPaused ? Colors.green : Colors.orange,
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () => _setStatus(context, _isPaused ? 'activate' : 'pause'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact - a candidate hasn't traded live yet (or has too little history
/// to mean much), so there's no win-rate/P&L row to show, just what it's
/// waiting to prove itself with: ticker, strategy, and the backtest score
/// it's ranked on against every other candidate for the next open slot.
class _CandidateCard extends StatelessWidget {
  final RosterEntry entry;

  const _CandidateCard({required this.entry});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.ticker, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                  Text(entry.strategyName, style: TextStyle(color: Colors.grey[600], fontSize: 12)),
                ],
              ),
            ),
            Text(
              'score ${entry.backtestScore.toStringAsFixed(2)}',
              style: TextStyle(color: Colors.grey[600], fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

/// Edit the roster's own rules. Only the fields shown here are sent; the
/// backend carries every other config value forward, so saving from the phone
/// can't blank a setting the app doesn't display.
class _RosterSettingsSheet extends StatefulWidget {
  const _RosterSettingsSheet();

  @override
  State<_RosterSettingsSheet> createState() => _RosterSettingsSheetState();
}

class _RosterSettingsSheetState extends State<_RosterSettingsSheet> {
  RosterSettings? _settings;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await AuthClient.fetchRosterSettings();
      if (mounted) setState(() => _settings = s);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _save() async {
    final s = _settings;
    if (s == null) return;
    final password = await showPasswordConfirmDialog(
      context: context,
      title: 'Save roster settings?',
      message: 'Changes take effect on the next poll cycle. Existing entries are '
          're-checked against the new thresholds.',
      confirmLabel: 'Save',
    );
    if (password == null || !mounted) return;

    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      await AuthClient.saveRosterSettings(s, password);
      messenger.showSnackBar(const SnackBar(content: Text('Roster settings saved.')));
      navigator.pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        messenger.showSnackBar(
          SnackBar(content: Text('Could not save: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Widget _stepper(String label, String help, int value, int min, int max, ValueChanged<int> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(help, style: TextStyle(fontSize: 11, color: Colors.grey[600])),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: value > min ? () => onChanged(value - 1) : null,
          ),
          SizedBox(
            width: 28,
            child: Text('$value',
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ),
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            onPressed: value < max ? () => onChanged(value + 1) : null,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = _settings;
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: 16 + MediaQuery.of(context).viewInsets.bottom + MediaQuery.of(context).padding.bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Roster settings',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            if (_error != null)
              Text(_error!, style: const TextStyle(color: Colors.red))
            else if (s == null)
              const Center(
                  child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))
            else ...[
              _stepper('Roster size', 'Max combos trading at once', s.rosterSize, 1, 20,
                  (v) => setState(() => _settings = s.copyWith(rosterSize: v))),
              _stepper('Pause after N losses', 'Consecutive live losses before benching',
                  s.losingStreakThreshold, 1, 20,
                  (v) => setState(() => _settings = s.copyWith(losingStreakThreshold: v))),
              _stepper('Max per strategy', '0 = no limit', s.maxPerStrategy, 0, 20,
                  (v) => setState(() => _settings = s.copyWith(maxPerStrategy: v))),
              _stepper('Max per sector', '0 = no limit', s.maxPerSector, 0, 20,
                  (v) => setState(() => _settings = s.copyWith(maxPerSector: v))),
              _stepper('Review every N days', 'Auto re-scan cadence', s.reviewCadenceDays, 1, 60,
                  (v) => setState(() => _settings = s.copyWith(reviewCadenceDays: v))),
              _stepper('Release pause after N days', '0 = pauses never auto-release',
                  s.pauseReleaseDays, 0, 60,
                  (v) => setState(() => _settings = s.copyWith(pauseReleaseDays: v))),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? 'Saving...' : 'Save settings'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Per-account max-drawdown circuit breakers, and the manual re-arm.
/// Deliberately never self-healing: once tripped an account stays halted even
/// if equity recovers, until cleared here (or on the dashboard).
class _AccountRiskSheet extends StatefulWidget {
  const _AccountRiskSheet();

  @override
  State<_AccountRiskSheet> createState() => _AccountRiskSheetState();
}

class _AccountRiskSheetState extends State<_AccountRiskSheet> {
  List<AccountRiskStatus>? _accounts;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final a = await AuthClient.fetchAccountRisk();
      if (mounted) setState(() => _accounts = a);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _reset(AccountRiskStatus a) async {
    final password = await showPasswordConfirmDialog(
      context: context,
      title: 'Re-arm ${a.nickname}?',
      message: 'Clears the drawdown breaker and re-baselines peak equity to this '
          'account CURRENT equity, so it will not immediately re-trip against the old '
          'high-water mark.\n\nThe account can open new positions again straight away.',
      confirmLabel: 'Re-arm',
      isDestructive: true,
    );
    if (password == null || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      await AuthClient.resetAccountBreaker(accountId: a.accountId, password: password);
      messenger.showSnackBar(SnackBar(content: Text('${a.nickname} re-armed.')));
      await _load();
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not re-arm: $e'), backgroundColor: Colors.red),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final accounts = _accounts;
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: 16 + MediaQuery.of(context).padding.bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Account circuit breakers',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
              'An account that falls too far below its peak equity is halted from opening '
              'new positions and stays halted until re-armed here.',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
            const SizedBox(height: 12),
            if (_error != null)
              Text(_error!, style: const TextStyle(color: Colors.red))
            else if (accounts == null)
              const Center(
                  child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))
            else
              ...accounts.map(
                (a) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    a.blocked ? Icons.block : Icons.check_circle_outline,
                    color: a.blocked ? Colors.red : Colors.green,
                  ),
                  title: Text('${a.nickname}${a.isPaper ? '' : '  (LIVE)'}'),
                  subtitle: Text(
                    a.blocked
                        ? (a.reason ?? 'Halted.')
                        : 'OK${a.peakEquity != null ? '  -  peak \$${a.peakEquity!.toStringAsFixed(2)}' : ''}',
                    style: TextStyle(fontSize: 12, color: a.blocked ? Colors.red : Colors.grey[600]),
                  ),
                  trailing: a.blocked
                      ? TextButton(onPressed: () => _reset(a), child: const Text('Re-arm'))
                      : null,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// On-demand Claude second opinion on current roster health/positions - see
/// backend/advisor_service.py's own docstring for the full design reasoning.
/// Fetches fresh on open (a real, billed API call - never cached, never
/// auto-triggered elsewhere in this screen) with an explicit "Ask again"
/// to re-run rather than any auto-refresh. Read-only: there is nothing here
/// that changes the roster - unlike the recommendation banner above, this
/// sheet has no Apply/Dismiss action, on purpose.
class _AdvisorSheet extends StatefulWidget {
  const _AdvisorSheet();

  @override
  State<_AdvisorSheet> createState() => _AdvisorSheetState();
}

class _AdvisorSheetState extends State<_AdvisorSheet> {
  AdvisorReport? _report;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final report = await AuthClient.fetchAdvisorReport();
      if (mounted) setState(() => _report = report);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Color _severityColor(String severity) => severity == 'warning' ? Colors.orange : Colors.grey[600]!;

  IconData _severityIcon(String severity) =>
      severity == 'warning' ? Icons.warning_amber_rounded : Icons.info_outline;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: 16 + MediaQuery.of(context).padding.bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.auto_awesome_outlined, size: 20),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('Claude advisor', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'A second opinion, read-only - it never changes the roster or places a trade. '
              'Each "Ask again" is a real API call.',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
            const SizedBox(height: 12),
            if (_loading)
              const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))
            else if (_error != null) ...[
              Text(_error!, style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(onPressed: _load, child: const Text('Try again')),
              ),
            ] else if (_report != null) ...[
              Text(_report!.summary, style: const TextStyle(fontSize: 14)),
              if (_report!.flags.isEmpty) ...[
                const SizedBox(height: 12),
                Text('No flags raised.', style: TextStyle(fontSize: 13, color: Colors.grey[600])),
              ] else ...[
                const SizedBox(height: 12),
                for (final flag in _report!.flags)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(_severityIcon(flag.severity), size: 18, color: _severityColor(flag.severity)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(flag.combo,
                                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: _severityColor(flag.severity))),
                              Text(flag.note, style: const TextStyle(fontSize: 13)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Ask again'),
                  onPressed: _load,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
