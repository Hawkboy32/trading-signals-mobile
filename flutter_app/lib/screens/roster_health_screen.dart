import 'package:flutter/material.dart';

import '../models/roster.dart';
import '../services/api_client.dart';

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
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Roster Health')),
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
        ],
      );
    }
    final data = _data!;
    final activeCount = data.entries.where((e) => e.status == 'active').length;

    if (data.entries.isEmpty && data.candidates.isEmpty) {
      return ListView(
        children: [
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
