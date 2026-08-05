import 'dart:async';
import 'package:flutter/material.dart';

import '../models/signal.dart';
import '../services/widget_service.dart';
import 'settings_screen.dart';

const _pollInterval = Duration(seconds: 60);

class SignalListScreen extends StatefulWidget {
  const SignalListScreen({super.key});

  @override
  State<SignalListScreen> createState() => _SignalListScreenState();
}

class _SignalListScreenState extends State<SignalListScreen> {
  SignalsResponse? _data;
  String? _error;
  bool _loading = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(_pollInterval, (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      // refreshWidget() does the actual fetch AND pushes the same data to
      // the home-screen widget - one network call serves both.
      final data = await refreshWidget();
      if (data == null) throw Exception('refresh failed');
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
      appBar: AppBar(
        title: const Text('Trading Signals'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
              _refresh();
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: _buildBody(),
      ),
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
    final signals = _data?.signals ?? [];
    if (signals.isEmpty) {
      return ListView(
        children: const [
          SizedBox(height: 80),
          Center(child: Text('No combos configured yet.', style: TextStyle(color: Colors.grey))),
        ],
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: signals.length + 1,
      itemBuilder: (context, index) {
        if (index == signals.length) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: Text(
                _data?.lastRefreshed != null
                    ? 'Last refreshed: ${_data!.lastRefreshed}'
                    : '',
                style: const TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ),
          );
        }
        return _SignalCard(signal: signals[index]);
      },
    );
  }
}

class _SignalCard extends StatelessWidget {
  final TradingSignal signal;

  const _SignalCard({required this.signal});

  Color get _badgeColor {
    switch (signal.signal) {
      case 'buy':
        return Colors.green;
      case 'sell':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    final conviction = signal.conviction;
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
                      Text(signal.ticker,
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      Text(signal.strategyName,
                          style: TextStyle(color: Colors.grey[600], fontSize: 13)),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: _badgeColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: _badgeColor),
                  ),
                  child: Text(
                    signal.signal.toUpperCase(),
                    style: TextStyle(color: _badgeColor, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Text('Price: ${signal.price.toStringAsFixed(4)}',
                    style: const TextStyle(fontSize: 13)),
                const Spacer(),
                if (conviction != null)
                  Text('Conviction: ${(conviction * 100).toStringAsFixed(0)}%',
                      style: const TextStyle(fontSize: 13)),
              ],
            ),
            if (conviction != null) ...[
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: conviction,
                  minHeight: 6,
                  backgroundColor: Colors.grey[300],
                  valueColor: AlwaysStoppedAnimation<Color>(_badgeColor),
                ),
              ),
            ],
            if (signal.error != null) ...[
              const SizedBox(height: 6),
              Text(signal.error!, style: const TextStyle(color: Colors.orange, fontSize: 12)),
            ],
          ],
        ),
      ),
    );
  }
}
