import 'package:flutter/material.dart';

import '../models/position.dart';
import '../services/auth_client.dart';
import 'login_screen.dart';

/// Live open positions + unrealized P&L, per linked account - the first
/// screen that shows real broker data rather than "what the strategy would
/// do". Requires login (same session as Stop/Re-arm), prompted automatically
/// on first visit if not already logged in.
class PositionsScreen extends StatefulWidget {
  const PositionsScreen({super.key});

  @override
  State<PositionsScreen> createState() => _PositionsScreenState();
}

class _PositionsScreenState extends State<PositionsScreen> {
  List<AccountPositions>? _data;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    if (!await AuthClient.isLoggedIn()) {
      if (!mounted) return;
      final loggedIn = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
      );
      if (loggedIn != true) {
        if (!mounted) return;
        setState(() {
          _error = 'Login required to view positions.';
          _loading = false;
        });
        return;
      }
    }
    try {
      final data = await AuthClient.fetchPositions();
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Open Positions')),
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
    final accounts = _data ?? [];
    if (accounts.isEmpty) {
      return ListView(
        children: [
          const SizedBox(height: 80),
          Center(child: Text('No linked accounts.', style: TextStyle(color: Colors.grey[600]))),
        ],
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: accounts.length,
      itemBuilder: (context, i) => _AccountCard(account: accounts[i]),
    );
  }
}

class _AccountCard extends StatelessWidget {
  final AccountPositions account;

  const _AccountCard({required this.account});

  @override
  Widget build(BuildContext context) {
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
                  child: Text(
                    account.nickname,
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                  ),
                ),
                Text(
                  account.isPaper ? 'Paper' : 'LIVE',
                  style: TextStyle(
                    color: account.isPaper ? Colors.grey[600] : Colors.red,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
            if (account.equity != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  'Equity \$${account.equity!.toStringAsFixed(2)}'
                  '${account.cash != null ? '  ·  Cash \$${account.cash!.toStringAsFixed(2)}' : ''}',
                  style: TextStyle(color: Colors.grey[600], fontSize: 13),
                ),
              ),
            if (account.error != null) ...[
              const SizedBox(height: 8),
              Text(account.error!, style: const TextStyle(color: Colors.orange, fontSize: 12)),
            ] else if (account.positions.isEmpty) ...[
              const SizedBox(height: 8),
              Text('Flat - no open positions.', style: TextStyle(color: Colors.grey[500], fontSize: 13)),
            ] else ...[
              const Divider(height: 20),
              ...account.positions.map((p) => _PositionRow(position: p)),
            ],
          ],
        ),
      ),
    );
  }
}

class _PositionRow extends StatelessWidget {
  final OpenPosition position;

  const _PositionRow({required this.position});

  @override
  Widget build(BuildContext context) {
    final isWin = position.unrealizedPl >= 0;
    final color = isWin ? Colors.green : Colors.red;
    final sign = isWin ? '+' : '-';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(
              '${position.ticker} · ${position.side}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: Text(
              '${position.qty.toStringAsFixed(4)} @ ${position.avgEntryPrice.toStringAsFixed(4)}',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ),
          Text(
            '$sign\$${position.unrealizedPl.abs().toStringAsFixed(2)}',
            style: TextStyle(color: color, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}
