/// Mirrors the backend's SignalResult JSON shape exactly (see
/// Mobile_App/backend/signal_service.py) - one entry per (ticker, strategy)
/// combo the live bot is actually configured to trade.
class TradingSignal {
  final String ticker;
  final String strategyName;
  final String signal; // "buy" / "sell" / "hold"
  final double? conviction; // null when signal is "hold"
  final double price;
  final String computedAt;
  final String? error;

  TradingSignal({
    required this.ticker,
    required this.strategyName,
    required this.signal,
    required this.conviction,
    required this.price,
    required this.computedAt,
    required this.error,
  });

  factory TradingSignal.fromJson(Map<String, dynamic> json) {
    return TradingSignal(
      ticker: json['ticker'] as String,
      strategyName: json['strategy_name'] as String,
      signal: json['signal'] as String,
      conviction: (json['conviction'] as num?)?.toDouble(),
      price: (json['price'] as num?)?.toDouble() ?? 0.0,
      computedAt: json['computed_at'] as String? ?? '',
      error: json['error'] as String?,
    );
  }
}

class SignalsResponse {
  final List<TradingSignal> signals;
  final String? lastRefreshed;

  SignalsResponse({required this.signals, required this.lastRefreshed});

  factory SignalsResponse.fromJson(Map<String, dynamic> json) {
    return SignalsResponse(
      signals: (json['signals'] as List<dynamic>)
          .map((e) => TradingSignal.fromJson(e as Map<String, dynamic>))
          .toList(),
      lastRefreshed: json['last_refreshed'] as String?,
    );
  }
}
