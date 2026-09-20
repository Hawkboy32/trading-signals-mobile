import 'package:flutter/material.dart';

import '../models/deposit.dart';
import '../models/position.dart';
import '../services/auth_client.dart';
import '../widgets/collapsible_card.dart';
import '../widgets/password_confirm_dialog.dart';
import 'account_detail_screen.dart';
import 'login_screen.dart';

/// Live open positions + unrealized P&L, per linked account - the first
/// screen that shows real broker data rather than "what the strategy would
/// do". Requires login (same session as Stop/Re-arm), prompted automatically
/// on first visit if not already logged in. Also carries each account's
/// manual deposit log (see backtester.deposits) for a True P&L figure that
/// isn't inflated by the deposits themselves - equity and "money actually
/// in" belong together, same reasoning the dashboard's Accounts tab uses.
class PositionsScreen extends StatefulWidget {
  const PositionsScreen({super.key});

  @override
  State<PositionsScreen> createState() => _PositionsScreenState();
}

class _PositionsScreenState extends State<PositionsScreen> {
  List<AccountPositions>? _data;
  Map<String, AccountDeposits> _depositsByAccountId = {};
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _openAccountDetail(AccountPositions account) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AccountDetailScreen(
          accountId: account.accountId,
          nickname: account.nickname,
        ),
      ),
    );
    // A position may have been closed from the detail screen.
    await _refresh();
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
    await _refreshDeposits();
  }

  Future<void> _refreshDeposits() async {
    try {
      final deposits = await AuthClient.fetchDeposits();
      if (!mounted) return;
      setState(() {
        _depositsByAccountId = {for (final d in deposits) d.accountId: d};
      });
    } catch (_) {
      // Silent - True P&L is a nice-to-have overlay on this screen, not
      // core to it; positions still show fine without it.
    }
  }

  Future<void> _openDeposits(AccountPositions account) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _DepositsSheet(
        account: account,
        deposits: _depositsByAccountId[account.accountId],
      ),
    );
    if (result == true) {
      await _refreshDeposits();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Account Details')),
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
    final liveAccounts = accounts.where((a) => !a.isPaper).toList();
    final paperAccounts = accounts.where((a) => a.isPaper).toList();

    Widget accountCard(AccountPositions account) => _AccountCard(
          account: account,
          deposits: _depositsByAccountId[account.accountId],
          onTapDeposits: () => _openDeposits(account),
          onClosed: _refresh,
          onTapAccount: () => _openAccountDetail(account),
        );

    return ListView(
      padding: EdgeInsets.fromLTRB(8, 8, 8, 24 + MediaQuery.of(context).padding.bottom),
      children: [
        if (liveAccounts.isNotEmpty)
          CollapsibleCard(
            title: const Text('Live (real money)',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.red)),
            trailing: Text('${liveAccounts.length}', style: TextStyle(color: Colors.grey[600])),
            padding: const EdgeInsets.fromLTRB(6, 10, 6, 6),
            children: liveAccounts.map(accountCard).toList(),
          ),
        if (paperAccounts.isNotEmpty)
          CollapsibleCard(
            title: const Text('Paper', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            trailing: Text('${paperAccounts.length}', style: TextStyle(color: Colors.grey[600])),
            // Paper accounts aren't real money - collapsed by default so the
            // screen opens focused on what actually matters, live accounts.
            initiallyExpanded: false,
            padding: const EdgeInsets.fromLTRB(6, 10, 6, 6),
            children: paperAccounts.map(accountCard).toList(),
          ),
      ],
    );
  }
}

class _AccountCard extends StatefulWidget {
  final AccountPositions account;
  final AccountDeposits? deposits;
  final VoidCallback onTapDeposits;

  final Future<void> Function() onClosed;
  final VoidCallback onTapAccount;

  const _AccountCard({
    required this.account,
    required this.deposits,
    required this.onTapDeposits,
    required this.onClosed,
    required this.onTapAccount,
  });

  @override
  State<_AccountCard> createState() => _AccountCardState();
}

class _AccountCardState extends State<_AccountCard> {
  // Expanded by default - collapsing is purely additive, doesn't change the
  // layout anyone's already used to until they actually tap the chevron.
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final account = widget.account;
    final deposits = widget.deposits;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The whole header is the tap target for the full account view -
            // balances, all three P&L figures, and closed positions. The
            // collapse chevron is a separate tap target (below), so it
            // doesn't fight this one for taps.
            InkWell(
              onTap: widget.onTapAccount,
              child: Row(
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
                  Icon(Icons.chevron_right, size: 20, color: Theme.of(context).colorScheme.primary),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (account.equity != null)
                          Text(
                            'Equity \$${account.equity!.toStringAsFixed(2)}'
                            '${account.cash != null ? '  ·  Cash \$${account.cash!.toStringAsFixed(2)}' : ''}',
                            style: TextStyle(color: Colors.grey[600], fontSize: 13),
                          ),
                        if (account.realizedPnlToday != null)
                          Text(
                            'Today (realised) '
                            '${account.realizedPnlToday! >= 0 ? '+' : '-'}'
                            '\$${account.realizedPnlToday!.abs().toStringAsFixed(2)}',
                            style: TextStyle(
                              color: account.realizedPnlToday! >= 0 ? Colors.green : Colors.red,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                      ],
                    ),
                  ),
                  InkWell(
                    onTap: () => setState(() => _expanded = !_expanded),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: AnimatedRotation(
                        turns: _expanded ? 0.5 : 0,
                        duration: const Duration(milliseconds: 200),
                        child: Icon(Icons.expand_more, size: 20, color: Colors.grey[500]),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: InkWell(
                onTap: widget.onTapDeposits,
                child: Row(
                  children: [
                    Icon(Icons.savings_outlined, size: 15, color: Colors.grey[600]),
                    const SizedBox(width: 4),
                    Text(
                      deposits == null
                          ? 'Deposits'
                          : 'Deposited \$${deposits.totalDeposited.toStringAsFixed(2)}'
                              '${deposits.truePnl != null ? '  ·  True P&L ${deposits.truePnl! >= 0 ? '+' : ''}\$${deposits.truePnl!.toStringAsFixed(2)}' : ''}',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Icon(Icons.chevron_right, size: 16, color: Theme.of(context).colorScheme.primary),
                  ],
                ),
              ),
            ),
            AnimatedCrossFade(
              firstChild: const SizedBox(width: double.infinity, height: 0),
              secondChild: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (account.error != null) ...[
                    const SizedBox(height: 8),
                    Text(account.error!, style: const TextStyle(color: Colors.orange, fontSize: 12)),
                  ] else if (account.positions.isEmpty) ...[
                    const SizedBox(height: 8),
                    Text('Flat - no open positions.',
                        style: TextStyle(color: Colors.grey[500], fontSize: 13)),
                  ] else ...[
                    const Divider(height: 20),
                    ...account.positions.map(
                      (p) => _PositionRow(position: p, account: account, onClosed: widget.onClosed),
                    ),
                  ],
                ],
              ),
              crossFadeState: _expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
              duration: const Duration(milliseconds: 200),
              sizeCurve: Curves.easeInOut,
            ),
          ],
        ),
      ),
    );
  }
}

class _PositionRow extends StatelessWidget {
  final OpenPosition position;
  final AccountPositions account;
  final Future<void> Function() onClosed;

  const _PositionRow({
    required this.position,
    required this.account,
    required this.onClosed,
  });

  /// Manual exit, password-confirmed like every other write in this app.
  /// The message names the account AND whether it's real money, because the
  /// nicknames don't reliably say ("MyAlpaca" is paper, "AlpacaLive" is live)
  /// and this spends real money on a live account. Closing only ever reduces
  /// exposure - there is deliberately no "open" counterpart on mobile.
  Future<void> _confirmAndClose(BuildContext context) async {
    final mode = account.isPaper ? 'paper' : 'REAL MONEY';
    final pl = position.unrealizedPl;
    final password = await showPasswordConfirmDialog(
      context: context,
      title: 'Close ${position.ticker}?',
      message: 'Market-close ${position.qty.toStringAsFixed(4)} ${position.ticker} on '
          '${account.nickname} ($mode).\n\n'
          'Unrealised now: ${pl >= 0 ? '+' : '-'}\$${pl.abs().toStringAsFixed(2)}\n'
          'If the market is shut, the order queues until it next opens.',
      confirmLabel: 'Close position',
      isDestructive: true,
    );
    if (password == null || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await AuthClient.closePosition(
        accountId: account.accountId,
        ticker: position.ticker,
        password: password,
      );
      messenger.showSnackBar(SnackBar(
        content: Text(
          res['queued'] == true
              ? '${position.ticker}: order queued for the next market open.'
              : '${position.ticker} closed.',
        ),
      ));
      await onClosed();
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not close ${position.ticker}: $e'), backgroundColor: Colors.red),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isWin = position.unrealizedPl >= 0;
    final color = isWin ? Colors.green : Colors.red;
    final sign = isWin ? '+' : '-';
    final sizingLabel = position.sizingLabel;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
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
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                tooltip: 'Close ${position.ticker}',
                visualDensity: VisualDensity.compact,
                color: Colors.red[300],
                onPressed: () => _confirmAndClose(context),
              ),
            ],
          ),
          // Sizing at entry - what % of equity (or $) this specific position
          // was actually opened at, not today's global setting. Only shown
          // when known: a position opened before this was added, or opened
          // manually outside auto_trader.py, has no attribution to show.
          Padding(
            padding: const EdgeInsets.only(left: 2, top: 1),
            child: Row(
              children: [
                Icon(Icons.straighten, size: 11, color: Colors.grey[500]),
                const SizedBox(width: 3),
                Text(
                  sizingLabel == null
                      ? 'Sizing unknown (opened before tracking, or manually)'
                      : position.dollarsCommitted == null
                          ? 'Sized at $sizingLabel'
                          : 'Sized at $sizingLabel (\$${position.dollarsCommitted!.toStringAsFixed(2)})',
                  style: TextStyle(fontSize: 10.5, color: Colors.grey[500], fontStyle: FontStyle.italic),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Deposit history + add/remove for one account, opened from its card above.
/// Pops `true` if anything changed, so the caller knows to re-fetch totals.
class _DepositsSheet extends StatefulWidget {
  final AccountPositions account;
  final AccountDeposits? deposits;

  const _DepositsSheet({required this.account, required this.deposits});

  @override
  State<_DepositsSheet> createState() => _DepositsSheetState();
}

class _DepositsSheetState extends State<_DepositsSheet> {
  final _amountController = TextEditingController();
  final _noteController = TextEditingController();
  final _conversionController = TextEditingController();
  DateTime _date = DateTime.now();
  bool _actionInFlight = false;

  @override
  void dispose() {
    _amountController.dispose();
    _noteController.dispose();
    _conversionController.dispose();
    super.dispose();
  }

  Future<void> _addDeposit() async {
    final amount = double.tryParse(_amountController.text);
    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid amount.'), backgroundColor: Colors.red),
      );
      return;
    }
    final dateStr = '${_date.year.toString().padLeft(4, '0')}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}';
    final password = await showPasswordConfirmDialog(
      context: context,
      title: 'Record deposit?',
      message: 'Adds \$${amount.toStringAsFixed(2)} to ${widget.account.nickname}\'s deposit total ($dateStr).',
      confirmLabel: 'Record',
    );
    if (password == null || !mounted) return;

    setState(() => _actionInFlight = true);
    try {
      await AuthClient.addDeposit(
        accountId: widget.account.accountId,
        amount: amount,
        date: dateStr,
        note: _noteController.text.trim(),
        password: password,
      );
      if (!mounted) return;
      _amountController.clear();
      _noteController.clear();
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString()), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _actionInFlight = false);
    }
  }

  Future<void> _recordConversion() async {
    final total = double.tryParse(_conversionController.text);
    if (total == null || total <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid converted amount.'), backgroundColor: Colors.red),
      );
      return;
    }
    final password = await showPasswordConfirmDialog(
      context: context,
      title: 'Record conversion?',
      message: 'Attaches the real converted amount (\$${total.toStringAsFixed(2)}) to whichever '
          '${widget.account.nickname} deposits are still awaiting one. If several deposits sat '
          'unconverted, this splits across all of them proportionally - it does not need to '
          'match a single deposit.',
      confirmLabel: 'Record',
    );
    if (password == null || !mounted) return;

    setState(() => _actionInFlight = true);
    try {
      await AuthClient.recordConversion(
        accountId: widget.account.accountId,
        convertedTotal: total,
        password: password,
      );
      if (!mounted) return;
      _conversionController.clear();
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString()), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _actionInFlight = false);
    }
  }

  Future<void> _removeDeposit(int index, DepositEntry entry) async {
    final password = await showPasswordConfirmDialog(
      context: context,
      title: 'Remove this deposit?',
      message: '${entry.date}: \$${entry.amount.toStringAsFixed(2)}${entry.note.isNotEmpty ? ' - ${entry.note}' : ''}',
      confirmLabel: 'Remove',
      isDestructive: true,
    );
    if (password == null || !mounted) return;

    setState(() => _actionInFlight = true);
    try {
      await AuthClient.removeDeposit(accountId: widget.account.accountId, index: index, password: password);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString()), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _actionInFlight = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = widget.deposits?.entries ?? [];
    return Padding(
      padding: EdgeInsets.only(
        left: 16, right: 16, top: 16,
        bottom: 16 + MediaQuery.of(context).viewInsets.bottom + MediaQuery.of(context).padding.bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.account.nickname, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
              'Total deposited: \$${(widget.deposits?.totalDeposited ?? 0).toStringAsFixed(2)}',
              style: TextStyle(color: Colors.grey[600]),
            ),
            // Only shown once it actually differs - i.e. at least one
            // foreign-currency deposit's real conversion has been recorded.
            // Otherwise this is just noise repeating the line above.
            if (((widget.deposits?.totalDepositedEstimated ?? 0) - (widget.deposits?.totalDeposited ?? 0)).abs() > 0.005)
              Text(
                'Estimated at deposit time: \$${(widget.deposits?.totalDepositedEstimated ?? 0).toStringAsFixed(2)}',
                style: TextStyle(color: Colors.grey[500], fontSize: 12),
              ),
            const Divider(height: 24),
            if (entries.isEmpty)
              Text('No deposits recorded yet.', style: TextStyle(color: Colors.grey[500]))
            else
              ...entries.asMap().entries.map((e) {
                final entry = e.value;
                final converted = entry.convertedAmount;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${entry.date}: \$${entry.amount.toStringAsFixed(2)}'
                              '${entry.note.isNotEmpty ? ' - ${entry.note}' : ''}',
                            ),
                            if (converted != null)
                              Text(
                                'converted: \$${converted.toStringAsFixed(2)}'
                                '${entry.convertedAt != null && entry.convertedAt!.length >= 10 ? ' (${entry.convertedAt!.substring(0, 10)})' : ''}',
                                style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                              ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 20),
                        onPressed: _actionInFlight ? null : () => _removeDeposit(e.key, entry),
                      ),
                    ],
                  ),
                );
              }),
            if (entries.any((e) => e.convertedAmount == null) && entries.isNotEmpty) ...[
              const Divider(height: 24),
              Text('Record a conversion', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(
                'Once a deposit above actually gets converted (e.g. GBP to USD on the '
                "exchange), enter what it really banked - splits across whichever entries "
                "are still awaiting one.",
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _conversionController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Real converted amount (\$)', border: OutlineInputBorder()),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _actionInFlight ? null : _recordConversion,
                    child: const Text('Record'),
                  ),
                ],
              ),
            ],
            const Divider(height: 24),
            Text('Record a deposit', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _amountController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Amount (\$)', border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _actionInFlight
                      ? null
                      : () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: _date,
                            firstDate: DateTime(2020),
                            lastDate: DateTime.now(),
                          );
                          if (picked != null) setState(() => _date = picked);
                        },
                  child: Text('${_date.year}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _noteController,
              decoration: const InputDecoration(labelText: 'Note (optional)', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _actionInFlight ? null : _addDeposit,
                child: const Text('Record deposit'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
