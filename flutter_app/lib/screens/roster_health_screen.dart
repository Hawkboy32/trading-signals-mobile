import 'package:flutter/material.dart';

import '../models/roster.dart';
import '../services/api_client.dart';

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
    if (data.entries.isEmpty) {
      return ListView(
        children: [
          const SizedBox(height: 80),
          Center(
            child: Text('No active or paused combos right now.', style: TextStyle(color: Colors.grey[600])),
          ),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: data.entries.map((e) => _RosterCard(entry: e, config: data.config)).toList(),
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
                      Text(entry.strategyName, style: TextStyle(color: Colors.grey[600], fontSize: 13)),
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
                  Text('${numTrades} trades', style: const TextStyle(fontSize: 13)),
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
