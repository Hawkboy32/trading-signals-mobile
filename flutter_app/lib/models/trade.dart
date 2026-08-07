class TradeRecord {
  final String ticker;
  final String strategyName;
  final bool isPaper;
  final String entryTime;
  final double entryPrice;
  final String exitTime;
  final double exitPrice;
  final double qty;
  final double pnl;
  final double pnlPct;
  final double? conviction;

  TradeRecord({
    required this.ticker,
    required this.strategyName,
    required this.isPaper,
    required this.entryTime,
    required this.entryPrice,
    required this.exitTime,
    required this.exitPrice,
    required this.qty,
    required this.pnl,
    required this.pnlPct,
    required this.conviction,
  });

  factory TradeRecord.fromJson(Map<String, dynamic> json) {
    return TradeRecord(
      ticker: json['ticker'] as String? ?? '',
      strategyName: json['strategy_name'] as String? ?? '',
      isPaper: json['is_paper'] as bool? ?? true,
      entryTime: json['entry_time'] as String? ?? '',
      entryPrice: (json['entry_price'] as num?)?.toDouble() ?? 0.0,
      exitTime: json['exit_time'] as String? ?? '',
      exitPrice: (json['exit_price'] as num?)?.toDouble() ?? 0.0,
      qty: (json['qty'] as num?)?.toDouble() ?? 0.0,
      pnl: (json['pnl'] as num?)?.toDouble() ?? 0.0,
      pnlPct: (json['pnl_pct'] as num?)?.toDouble() ?? 0.0,
      conviction: (json['conviction'] as num?)?.toDouble(),
    );
  }
}
