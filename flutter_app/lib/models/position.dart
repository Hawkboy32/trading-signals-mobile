/// Mirrors positions_service.py's AccountView/PositionView JSON shape.
class OpenPosition {
  final String ticker;
  final double qty;
  final String side; // "long" / "short"
  final double avgEntryPrice;
  final double? currentPrice;
  final double marketValue;
  final double unrealizedPl;
  // From position_attribution.py (2026-08-16) - the EFFECTIVE sizing THIS
  // entry actually used (already resolved through any per-account slide and
  // the GARCH size_multiplier), not today's global setting. All three null
  // for a position opened before this existed, or opened manually outside
  // auto_trader.py - "sizing unknown", never guessed.
  final String? sizingMode; // "pct_equity" / "fixed_dollars" / "fixed_shares"
  final double? sizingValue;
  final double? dollarsCommitted;

  OpenPosition({
    required this.ticker,
    required this.qty,
    required this.side,
    required this.avgEntryPrice,
    required this.currentPrice,
    required this.marketValue,
    required this.unrealizedPl,
    this.sizingMode,
    this.sizingValue,
    this.dollarsCommitted,
  });

  /// Human-readable "sized at" label, or null if unknown - the widget
  /// decides how to render "unknown" rather than this model guessing.
  String? get sizingLabel {
    if (sizingMode == null || sizingValue == null) return null;
    switch (sizingMode) {
      case 'pct_equity':
        return '${sizingValue!.toStringAsFixed(1)}% of equity';
      case 'fixed_dollars':
        return r'$' '${sizingValue!.toStringAsFixed(2)} fixed';
      case 'fixed_shares':
        return '${sizingValue!.toStringAsFixed(0)} shares fixed';
      default:
        return null;
    }
  }

  factory OpenPosition.fromJson(Map<String, dynamic> json) {
    return OpenPosition(
      ticker: json['ticker'] as String,
      qty: (json['qty'] as num).toDouble(),
      side: json['side'] as String,
      avgEntryPrice: (json['avg_entry_price'] as num).toDouble(),
      currentPrice: (json['current_price'] as num?)?.toDouble(),
      marketValue: (json['market_value'] as num).toDouble(),
      unrealizedPl: (json['unrealized_pl'] as num).toDouble(),
      sizingMode: json['sizing_mode'] as String?,
      sizingValue: (json['sizing_value'] as num?)?.toDouble(),
      dollarsCommitted: (json['dollars_committed'] as num?)?.toDouble(),
    );
  }
}

class AccountPositions {
  final String accountId;
  final String nickname;
  final String broker;
  final bool isPaper;
  final double? equity;
  final double? cash;
  final List<OpenPosition> positions;
  final String? error;
  // REALIZED P&L today only (closed trades) - not a mark-to-market
  // day's-change figure, since most brokers here have no equity-history API
  // to diff against. See positions_service.py's AccountView docstring.
  final double? realizedPnlToday;

  AccountPositions({
    required this.accountId,
    required this.nickname,
    required this.broker,
    required this.isPaper,
    required this.equity,
    required this.cash,
    required this.positions,
    required this.error,
    this.realizedPnlToday,
  });

  factory AccountPositions.fromJson(Map<String, dynamic> json) {
    return AccountPositions(
      accountId: json['account_id'] as String? ?? '',
      nickname: json['nickname'] as String,
      broker: json['broker'] as String? ?? '',
      isPaper: json['is_paper'] as bool? ?? true,
      equity: (json['equity'] as num?)?.toDouble(),
      cash: (json['cash'] as num?)?.toDouble(),
      positions: (json['positions'] as List<dynamic>? ?? [])
          .map((e) => OpenPosition.fromJson(e as Map<String, dynamic>))
          .toList(),
      error: json['error'] as String?,
      realizedPnlToday: (json['realized_pnl_today'] as num?)?.toDouble(),
    );
  }
}
