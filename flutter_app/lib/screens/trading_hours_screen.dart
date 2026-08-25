import 'package:flutter/material.dart';

import '../models/trading_hours.dart';
import '../services/api_client.dart';
import '../widgets/trading_hours_timeline.dart';

/// Week-at-a-glance market hours in UK local time - one timeline per market
/// with a genuine weekly open/close pattern (Equities, Forex), plus a plain
/// note for crypto (always open - a week of all-green bars carries no
/// information, so it isn't drawn as a timeline). See signal_api.py's
/// trading_hours() for the actual schedule computation and its one real
/// simplification (regular hours only, holidays not reflected).
class TradingHoursScreen extends StatefulWidget {
  const TradingHoursScreen({super.key});

  @override
  State<TradingHoursScreen> createState() => _TradingHoursScreenState();
}

class _TradingHoursScreenState extends State<TradingHoursScreen> {
  TradingHours? _data;
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
      final data = await ApiClient.fetchTradingHours();
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
      appBar: AppBar(title: const Text('Trading Hours')),
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
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final market in data.markets) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(market.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 16),
                  TradingHoursTimeline(
                    market: market,
                    nowDayIndex: data.nowDayIndex,
                    nowMinutes: data.nowMinutes,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(Icons.currency_bitcoin, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(child: Text(data.cryptoNote)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          data.note,
          style: TextStyle(color: Colors.grey[500], fontSize: 12, fontStyle: FontStyle.italic),
        ),
        const SizedBox(height: 4),
        Text(
          'All times shown in ${data.timezone}.',
          style: TextStyle(color: Colors.grey[500], fontSize: 12),
        ),
      ],
    );
  }
}
