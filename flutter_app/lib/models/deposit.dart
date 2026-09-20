/// One recorded deposit into an account - matches backtester.deposits.Deposit.
class DepositEntry {
  final double amount;
  final String date; // YYYY-MM-DD, the date the deposit was actually made
  final String note;
  final String recordedAt;

  /// What this deposit's currency ACTUALLY turned into once really
  /// converted (e.g. GBP -> USD), vs `amount` above which is whatever the
  /// account's live equity read showed at logging time. Null until a real
  /// conversion has been recorded against this entry - see
  /// AuthClient.recordConversion and deposits.record_conversion's own
  /// docstring for why neither number is "wrong", they answer different
  /// questions.
  final double? convertedAmount;
  final String? convertedAt;

  DepositEntry({
    required this.amount,
    required this.date,
    required this.note,
    required this.recordedAt,
    this.convertedAmount,
    this.convertedAt,
  });

  factory DepositEntry.fromJson(Map<String, dynamic> json) {
    return DepositEntry(
      amount: (json['amount'] as num?)?.toDouble() ?? 0.0,
      date: json['date'] as String? ?? '',
      note: json['note'] as String? ?? '',
      recordedAt: json['recorded_at'] as String? ?? '',
      convertedAmount: (json['converted_amount'] as num?)?.toDouble(),
      convertedAt: json['converted_at'] as String?,
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
  // The original logged total, ignoring any later real conversion - stays
  // around so a trend (does the live-equity estimate at deposit time run
  // consistently high/low against what actually lands?) is visible across
  // multiple deposits. Identical to totalDeposited until a conversion is
  // recorded for at least one entry.
  final double totalDepositedEstimated;
  final double? truePnl;
  final List<DepositEntry> entries; // most-recent-first

  AccountDeposits({
    required this.accountId,
    required this.nickname,
    required this.broker,
    required this.isPaper,
    required this.equity,
    required this.totalDeposited,
    required this.totalDepositedEstimated,
    required this.truePnl,
    required this.entries,
  });

  factory AccountDeposits.fromJson(Map<String, dynamic> json) {
    final totalDeposited = (json['total_deposited'] as num?)?.toDouble() ?? 0.0;
    return AccountDeposits(
      accountId: json['account_id'] as String? ?? '',
      nickname: json['nickname'] as String? ?? '',
      broker: json['broker'] as String? ?? '',
      isPaper: json['is_paper'] as bool? ?? true,
      equity: (json['equity'] as num?)?.toDouble(),
      totalDeposited: totalDeposited,
      // Falls back to totalDeposited for an older backend that doesn't send
      // this field yet, rather than defaulting to 0 (which would make every
      // account look like it has a huge phantom "estimate vs actual" gap).
      totalDepositedEstimated:
          (json['total_deposited_estimated'] as num?)?.toDouble() ?? totalDeposited,
      truePnl: (json['true_pnl'] as num?)?.toDouble(),
      entries: (json['entries'] as List<dynamic>? ?? [])
          .map((e) => DepositEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}
