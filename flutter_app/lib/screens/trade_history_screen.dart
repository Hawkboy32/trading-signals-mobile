import 'package:flutter/material.dart';

import '../models/trade.dart';
import '../services/api_client.dart';

/// Real, closed round-trip trades - not "what the bot would do right now"
/// like the main screen, but "what it actually did". Backed by
/// live_trades.db via the /trades endpoint.
class TradeHistoryScreen extends StatefulWidget {
  const TradeHistoryScreen({super.key});

  @override
  State<TradeHistoryScreen> createState() => _TradeHistoryScreenState();
}

class _TradeHistoryScreenState extends State<TradeHistoryScreen> {
  List<TradeRecord>? _trades;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final trades = await ApiClient.fetchTrades();
      if (!mounted) return;
      setState(() {
        _trades = trades;
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

  String _formatTimestamp(String iso) {
    final ts = DateTime.tryParse(iso);
    if (ts == null) return iso;
    final local = ts.toLocal();
    final h = local.hour.toString().padLeft(2, '0');
    final m = local.minute.toString().padLeft(2, '0');
    return '${local.month}/${local.day} $h:$m';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Trade History')),
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
    final trades = _trades!;
    if (trades.isEmpty) {
      return ListView(
        children: [
          const SizedBox(height: 80),
          Center(
            child: Text('No closed trades yet.', style: TextStyle(color: Colors.grey[600])),
          ),
        ],
      );
    }
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(0, 8, 0, 24 + MediaQuery.of(context).padding.bottom),
      itemCount: trades.length,
      itemBuilder: (context, i) => _TradeCard(trade: trades[i], formatTimestamp: _formatTimestamp),
    );
  }
}

class _TradeCard extends StatelessWidget {
  final TradeRecord trade;
  final String Function(String) formatTimestamp;

  const _TradeCard({required this.trade, required this.formatTimestamp});

  @override
  Widget build(BuildContext context) {
    final isWin = trade.pnl >= 0;
    final pnlColor = isWin ? Colors.green : Colors.red;

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
                      Text(trade.ticker, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      Text(trade.strategyName, style: TextStyle(color: Colors.grey[600], fontSize: 13)),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${isWin ? '+' : ''}\$${trade.pnl.toStringAsFixed(2)}',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: pnlColor),
                    ),
                    Text(
                      '${isWin ? '+' : ''}${(trade.pnlPct * 100).toStringAsFixed(2)}%',
                      style: TextStyle(fontSize: 12, color: pnlColor),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text('${trade.entryPrice.toStringAsFixed(4)}', style: const TextStyle(fontSize: 13)),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6),
                  child: Icon(Icons.arrow_forward, size: 14),
                ),
                Text('${trade.exitPrice.toStringAsFixed(4)}', style: const TextStyle(fontSize: 13)),
                const Spacer(),
                Text('qty ${trade.qty.toStringAsFixed(4)}', style: TextStyle(fontSize: 12, color: Colors.grey[600])),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${formatTimestamp(trade.entryTime)} → ${formatTimestamp(trade.exitTime)}'
              '${trade.isPaper ? '  ·  paper' : ''}',
              style: TextStyle(fontSize: 11, color: Colors.grey[500]),
            ),
          ],
        ),
      ),
    );
  }
}
