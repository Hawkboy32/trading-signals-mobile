import 'package:flutter/material.dart';

import '../models/account_detail.dart';
import '../models/position.dart';
import '../models/trade.dart';
import '../services/auth_client.dart';
import '../widgets/collapsible_card.dart';
import '../widgets/password_confirm_dialog.dart';

/// One account, in full: balances, the three P&L figures, what's open right
/// now, and what's already been closed. Reached by tapping an account on the
/// Account Details list.
class AccountDetailScreen extends StatefulWidget {
  final String accountId;
  final String nickname;

  const AccountDetailScreen({super.key, required this.accountId, required this.nickname});

  @override
  State<AccountDetailScreen> createState() => _AccountDetailScreenState();
}

class _AccountDetailScreenState extends State<AccountDetailScreen> {
  AccountDetail? _detail;
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
      final d = await AuthClient.fetchAccountDetail(widget.accountId);
      if (!mounted) return;
      setState(() {
        _detail = d;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _closePosition(OpenPosition p) async {
    final d = _detail!;
    final mode = d.isPaper ? 'paper' : 'REAL MONEY';
    final password = await showPasswordConfirmDialog(
      context: context,
      title: 'Close ${p.ticker}?',
      message: 'Market-close ${p.qty.toStringAsFixed(4)} ${p.ticker} on ${d.nickname} ($mode).\n\n'
          'Unrealised now: ${p.unrealizedPl >= 0 ? '+' : '-'}\$${p.unrealizedPl.abs().toStringAsFixed(2)}\n'
          'If the market is shut, the order queues until it next opens.',
      confirmLabel: 'Close position',
      isDestructive: true,
    );
    if (password == null || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await AuthClient.closePosition(
        accountId: widget.accountId, ticker: p.ticker, password: password);
      messenger.showSnackBar(SnackBar(
        content: Text(res['queued'] == true
            ? '${p.ticker}: order queued for the next market open.'
            : '${p.ticker} closed.'),
      ));
      await _refresh();
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not close ${p.ticker}: $e'), backgroundColor: Colors.red),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.nickname)),
      body: RefreshIndicator(onRefresh: _refresh, child: _body()),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return ListView(children: [
        const SizedBox(height: 80),
        Icon(Icons.cloud_off, size: 48, color: Colors.grey[400]),
        const SizedBox(height: 12),
        Center(child: Text(_error!, style: TextStyle(color: Colors.grey[600]))),
      ]);
    }
    final d = _detail!;
    return ListView(
      padding: EdgeInsets.fromLTRB(8, 8, 8, 24 + MediaQuery.of(context).padding.bottom),
      children: [
        if (d.error != null)
          Card(
            color: Colors.orange.withValues(alpha: 0.15),
            child: ListTile(
              leading: const Icon(Icons.warning_amber, color: Colors.orange),
              title: Text('Broker unreachable: ${d.error}',
                  style: const TextStyle(fontSize: 13)),
              subtitle: const Text('Balances and open positions are unavailable. '
                  'Closed trades below are still accurate.',
                  style: TextStyle(fontSize: 12)),
            ),
          ),
        _balancesCard(d),
        _pnlCard(d),
        _feesCard(d),
        _openPositionsCard(d),
        _closedTradesCard(d),
      ],
    );
  }

  Widget _money(double? v) => Text(
        v == null ? '-' : '\$${v.toStringAsFixed(2)}',
        style: const TextStyle(fontWeight: FontWeight.w600),
      );

  Widget _row(String label, Widget value, {String? help}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label),
                  if (help != null)
                    Text(help, style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                ],
              ),
            ),
            value,
          ],
        ),
      );

  Widget _balancesCard(AccountDetail d) => CollapsibleCard(
        title: const Text('Balances', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        trailing: Chip(
          label: Text(d.isPaper ? 'PAPER' : 'LIVE',
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
          backgroundColor: d.isPaper ? Colors.blueGrey.shade100 : Colors.amber.shade200,
          visualDensity: VisualDensity.compact,
        ),
        children: [
          const Divider(),
          _row('Equity', _money(d.equity), help: 'Cash plus what open positions are worth'),
          _row('Cash', _money(d.cash)),
          _row('Buying power', _money(d.buyingPower), help: 'What it can actually spend now'),
        ],
      );

  /// Three DIFFERENT questions, deliberately not merged into one number.
  Widget _pnlCard(AccountDetail d) {
    Widget signed(double? v) {
      if (v == null) return const Text('-');
      final c = v >= 0 ? Colors.green : Colors.red;
      return Text('${v >= 0 ? '+' : '-'}\$${v.abs().toStringAsFixed(2)}',
          style: TextStyle(color: c, fontWeight: FontWeight.bold));
    }

    return CollapsibleCard(
      title: const Text('Profit & loss', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
      trailing: signed(d.realizedPnlToday),
      children: [
        const Divider(),
        _row('Today (realised)', signed(d.realizedPnlToday),
            help: 'Closed trades only, today - does NOT include today\'s move on '
                'anything still open (see Unrealised below)'),
        _row('Unrealised', signed(d.unrealizedPnl),
            help: 'On positions still open - not banked yet'),
        _row('Realised (gross)', signed(d.realizedPnl),
            help: 'From ${d.closedTrades.length} closed round trip'
                '${d.closedTrades.length == 1 ? '' : 's'} - BEFORE broker fees'),
        if (d.feesSupported) ...[
          _row('Trading fees', signed(d.tradingFees),
              help: 'Cost of trading - a near-fixed daily toll, see below'),
          _row('Realised (after trading fees)', signed(d.realizedPnlAfterTradingFees),
              help: 'Is the strategy paying for the act of trading'),
          _row('Funding fees', signed(d.fundingFees),
              help: 'Currency conversion on deposits - not a trading cost'),
          _row('Realised (net)', signed(d.realizedPnlNet),
              help: 'After ALL fees - what actually reached the account'),
        ],
        const Divider(),
        _row('Deposited', _money(d.totalDeposited), help: 'Money you put in (manually logged)'),
        // Only shown once it actually differs from the line above - i.e. a
        // foreign-currency deposit's real conversion has been recorded, see
        // AuthClient.recordConversion. Otherwise it's identical noise.
        if ((d.totalDepositedEstimated - d.totalDeposited).abs() > 0.005)
          _row(
            'Deposited (estimated at the time)',
            Text('\$${d.totalDepositedEstimated.toStringAsFixed(2)}',
                style: TextStyle(fontWeight: FontWeight.w600, color: Colors.grey[600])),
            help: 'What live equity showed when each deposit landed, before its real '
                'conversion was known - kept to show the trend, not used for True P&L',
          ),
        _row(
          'True P&L',
          d.truePnl == null
              ? Text(d.totalDeposited > 0 ? '-' : 'n/a',
                  style: TextStyle(color: Colors.grey[600]))
              : signed(d.truePnl),
          help: d.totalDeposited > 0
              ? 'Equity minus deposits - has it actually made anything'
              : 'Log a deposit to see this (without one it is just the balance)',
        ),
      ],
    );
  }

  /// Broker charges, split by what actually drives them, because the two
  /// respond to completely different things:
  ///   - conversion is ~1.5% of each DEPOSIT, so it stays proportional to what
  ///     goes in no matter how large the account gets
  ///   - regulatory fees are charged per selling DAY and each rounds UP to a
  ///     $0.01 minimum, so they behave as a near-fixed daily toll rather than a
  ///     percentage (measured on AlpacaLive 11-13 Aug: sell proceeds tripled,
  ///     $5.69 -> $17.46, and the fee stayed $0.03/day)
  /// Merging them into one total hides which cost is which.
  Widget _feesCard(AccountDetail d) {
    if (!d.feesSupported) {
      return Card(
        child: ListTile(
          leading: Icon(Icons.receipt_long, color: Colors.grey[500]),
          title: const Text('Fees', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          subtitle: Text(
            'This broker does not report fees through its API, so they are not '
            'shown here. True P&L below still includes them.',
            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
          ),
        ),
      );
    }

    final conversion = d.fees.where((f) => f.isFunding).toList();
    final trading = d.fees.where((f) => !f.isFunding).toList();
    // Totals come from the server (summarize_fees), not re-summed here, so the
    // app can never disagree with the dashboard about what a cost was.
    final convTotal = d.fundingFees;
    final tradeTotal = d.tradingFees;
    final tradingDays = trading.map((f) => f.date).toSet().length;

    Widget amount(double v) => Text('-\$${v.abs().toStringAsFixed(2)}',
        style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold));

    return CollapsibleCard(
      title: const Text('Fees', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
      trailing: amount(d.totalFees),
      children: [
        const Divider(),
        if (d.fees.isEmpty)
          Text('No fees charged yet.', style: TextStyle(color: Colors.grey[500], fontSize: 13))
        else ...[
          if (conversion.isNotEmpty) ...[
            _row('Currency conversion', amount(convTotal),
                help: 'Charged on each DEPOSIT, not on trades'),
            ...conversion.map((f) => Padding(
                  padding: const EdgeInsets.only(left: 12, bottom: 2),
                  child: Text('${f.date}  -\$${f.amount.abs().toStringAsFixed(2)}',
                      style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                )),
            const SizedBox(height: 6),
          ],
          if (trading.isNotEmpty) ...[
            _row('Trading (REG/TAF/CAT)', amount(tradeTotal),
                help: '${trading.length} regulatory charges over $tradingDays '
                    'selling day${tradingDays == 1 ? '' : 's'}'),
            Padding(
              padding: const EdgeInsets.only(left: 12, top: 2),
              child: Text(
                '≈ \$${(tradeTotal.abs() / (tradingDays == 0 ? 1 : tradingDays)).toStringAsFixed(2)}'
                '/day. Each rounds up to a \$0.01 minimum, so this barely moves '
                'as trade size grows - it is a fixed daily cost, not a percentage.',
                style: TextStyle(fontSize: 11, color: Colors.grey[600]),
              ),
            ),
          ],
        ],
      ],
    );
  }

  Widget _openPositionsCard(AccountDetail d) => CollapsibleCard(
        title: Text('Open positions (${d.openPositions.length})',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        children: [
              const Divider(),
              if (d.openPositions.isEmpty)
                Text('Flat - nothing open.', style: TextStyle(color: Colors.grey[500], fontSize: 13))
              else
                ...d.openPositions.map((p) {
                  final win = p.unrealizedPl >= 0;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(children: [
                      Expanded(
                        flex: 2,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${p.ticker} · ${p.side}',
                                style: const TextStyle(fontWeight: FontWeight.w600)),
                            Text('${p.qty.toStringAsFixed(4)} @ ${p.avgEntryPrice.toStringAsFixed(4)}',
                                style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                          ],
                        ),
                      ),
                      Text(
                        '${win ? '+' : '-'}\$${p.unrealizedPl.abs().toStringAsFixed(2)}',
                        style: TextStyle(
                            color: win ? Colors.green : Colors.red, fontWeight: FontWeight.bold),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        color: Colors.red[300],
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Close ${p.ticker}',
                        onPressed: () => _closePosition(p),
                      ),
                    ]),
                  );
                }),
        ],
      );

  Widget _closedTradesCard(AccountDetail d) {
    final trades = d.closedTrades;
    final wins = trades.where((t) => t.pnl > 0).length;
    return CollapsibleCard(
      title: Text('Closed positions (${trades.length})',
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
      initiallyExpanded: false,
      children: [
        if (trades.isNotEmpty)
          Text('$wins won, ${trades.length - wins} lost'
              '  ·  ${(wins / trades.length * 100).toStringAsFixed(0)}% win rate',
              style: TextStyle(fontSize: 12, color: Colors.grey[600])),
        const Divider(),
        if (trades.isEmpty)
          Text('No closed trades yet on this account.',
              style: TextStyle(color: Colors.grey[500], fontSize: 13))
        else
          ...trades.map(_closedRow),
      ],
    );
  }

  Widget _closedRow(TradeRecord t) {
    final win = t.pnl >= 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        Expanded(
          flex: 3,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.ticker, style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(t.strategyName, style: TextStyle(fontSize: 11, color: Colors.grey[600])),
              Text(
                '${t.entryPrice.toStringAsFixed(4)} → ${t.exitPrice.toStringAsFixed(4)}'
                '  ·  ${t.exitTime.length >= 10 ? t.exitTime.substring(0, 10) : t.exitTime}',
                style: TextStyle(fontSize: 11, color: Colors.grey[500]),
              ),
            ],
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text('${win ? '+' : '-'}\$${t.pnl.abs().toStringAsFixed(2)}',
                style: TextStyle(
                    color: win ? Colors.green : Colors.red, fontWeight: FontWeight.bold)),
            Text('${(t.pnlPct * 100).toStringAsFixed(2)}%',
                style: TextStyle(fontSize: 11, color: Colors.grey[600])),
          ],
        ),
      ]),
    );
  }
}
