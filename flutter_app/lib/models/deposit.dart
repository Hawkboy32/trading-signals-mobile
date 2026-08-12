/// One recorded deposit into an account - matches backtester.deposits.Deposit.
class DepositEntry {
  final double amount;
  final String date; // YYYY-MM-DD, the date the deposit was actually made
  final String note;
  final String recordedAt;

  DepositEntry({
    required this.amount,
    required this.date,
    required this.note,
    required this.recordedAt,
  });

  factory DepositEntry.fromJson(Map<String, dynamic> json) {
    return DepositEntry(
      amount: (json['amount'] as num?)?.toDouble() ?? 0.0,
      date: json['date'] as String? ?? '',
      note: json['note'] as String? ?? '',
      recordedAt: json['recorded_at'] as String? ?? '',
    );
  }
}

/// One account's deposit summary - real equity (when reachable) joined
/// against the manual deposit log for a "True P&L" that isn't inflated by
/// the deposits themselves.
class AccountDeposits {
  final String accountId;
  final String nickname;
  final String broker;
  final bool isPaper;
  final double? equity;
  final double totalDeposited;
  final double? truePnl;
  final List<DepositEntry> entries; // most-recent-first

  AccountDeposits({
    required this.accountId,
    required this.nickname,
    required this.broker,
    required this.isPaper,
    required this.equity,
    required this.totalDeposited,
    required this.truePnl,
    required this.entries,
  });

  factory AccountDeposits.fromJson(Map<String, dynamic> json) {
    return AccountDeposits(
      accountId: json['account_id'] as String? ?? '',
      nickname: json['nickname'] as String? ?? '',
      broker: json['broker'] as String? ?? '',
      isPaper: json['is_paper'] as bool? ?? true,
      equity: (json['equity'] as num?)?.toDouble(),
      totalDeposited: (json['total_deposited'] as num?)?.toDouble() ?? 0.0,
      truePnl: (json['true_pnl'] as num?)?.toDouble(),
      entries: (json['entries'] as List<dynamic>? ?? [])
          .map((e) => DepositEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}
