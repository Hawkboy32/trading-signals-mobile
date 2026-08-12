/// Mirrors positions_service.py's AccountView/PositionView JSON shape.
class OpenPosition {
  final String ticker;
  final double qty;
  final String side; // "long" / "short"
  final double avgEntryPrice;
  final double? currentPrice;
  final double marketValue;
  final double unrealizedPl;

  OpenPosition({
    required this.ticker,
    required this.qty,
    required this.side,
    required this.avgEntryPrice,
    required this.currentPrice,
    required this.marketValue,
    required this.unrealizedPl,
  });

  factory OpenPosition.fromJson(Map<String, dynamic> json) {
    return OpenPosition(
      ticker: json['ticker'] as String,
      qty: (json['qty'] as num).toDouble(),
      side: json['side'] as String,
      avgEntryPrice: (json['avg_entry_price'] as num).toDouble(),
      currentPrice: (json['current_price'] as num?)?.toDouble(),
      marketValue: (json['market_value'] as num).toDouble(),
      unrealizedPl: (json['unrealized_pl'] as num).toDouble(),
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

  AccountPositions({
    required this.accountId,
    required this.nickname,
    required this.broker,
    required this.isPaper,
    required this.equity,
    required this.cash,
    required this.positions,
    required this.error,
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
    );
  }
}
