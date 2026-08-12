import 'package:flutter/material.dart';

import '../models/roster.dart';
import '../models/roster_recommendation.dart';
import '../services/api_client.dart';
import '../services/auth_client.dart';
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Roster Health')),
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
      padding: EdgeInsets.only(top: 8, bottom: 24 + MediaQuery.of(context).padding.bottom),
      children: [
        ..._recommendationBannerWidgets(),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text(
            '$activeCount of ${data.config.rosterSize} active slots filled',
            style: TextStyle(color: Colors.grey[600], fontSize: 13),
          ),
        ),
        ...data.entries.map((e) => _RosterCard(entry: e, config: data.config)),
        if (data.candidates.isNotEmpty) ...[
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              'Candidates - not yet promoted (top ${data.candidates.length} of ${data.config.numCandidates}, ranked by backtest score)',
              style: TextStyle(color: Colors.grey[600], fontSize: 13),
            ),
          ),
          ...data.candidates.map((e) => _CandidateCard(entry: e)),
        ],
      ],
    );
  }
}

class _RosterCard extends StatelessWidget {
  final RosterEntry entry;
  final RosterConfig config;

  const _RosterCard({required this.entry, required this.config});

  bool get _isPaused => entry.status == 'paused';

  Color get _statusColor => _isPaused ? Colors.orange : Colors.green;

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
