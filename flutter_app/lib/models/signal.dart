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
  final String? source; // which feed the bars came from, e.g. "MyAlpaca (live)" or "Polygon"
  final List<double>? recentCloses; // trailing closes for the sparkline
  final Map<String, double>? levels; // strategy's own reference levels (VWAP, bands, ...)
  final bool? marketOpen; // null = unknown (no account currently trades this ticker's asset class)
  final List<String>? tradingAccounts; // account nickname(s) that actually trade this ticker

  TradingSignal({
    required this.ticker,
    required this.strategyName,
    required this.signal,
    required this.conviction,
    required this.price,
    required this.computedAt,
    required this.error,
    required this.source,
    required this.recentCloses,
    required this.levels,
    required this.marketOpen,
    required this.tradingAccounts,
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
      source: json['source'] as String?,
      recentCloses: (json['recent_closes'] as List<dynamic>?)
          ?.map((e) => (e as num).toDouble())
          .toList(),
      levels: (json['levels'] as Map<String, dynamic>?)
          ?.map((k, v) => MapEntry(k, (v as num).toDouble())),
      marketOpen: json['market_open'] as bool?,
      tradingAccounts: (json['trading_accounts'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList(),
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
