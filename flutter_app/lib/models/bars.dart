/// Mirrors the backend's /bars JSON shape exactly (see
/// Mobile_App/backend/signal_api.py's bars()) - OHLC at a requested
/// granularity, for the expanded candle view's 1m/5m/15m toggle (2026-08-25).
///
/// Separate from TradingSignal's own recentOpens/recentCloses/etc: those
/// ride along with the signal itself at a fixed 1-minute granularity and
/// cost no extra call, so they stay the default the detail screen opens
/// with. This is only fetched when the user actually switches granularity,
/// rather than making every card's data heavier for a view most taps never
/// reach.
///
/// `source` is the live broker the bars actually came from (e.g. "CBAPI
/// (direct)", "AlpacaLive (direct)") - surfaced in the UI for the same
/// reason the signal card shows it: Polygon is backtesting-only now, so
/// seeing "Polygon" on a live chart is itself a signal something fell back.
class BarSeries {
  final String ticker;
  final int multiplier;
  final String timespan;
  final String source;
  final String computedAt;
  final List<double> opens;
  final List<double> highs;
  final List<double> lows;
  final List<double> closes;

  BarSeries({
    required this.ticker,
    required this.multiplier,
    required this.timespan,
    required this.source,
    required this.computedAt,
    required this.opens,
    required this.highs,
    required this.lows,
    required this.closes,
  });

  static List<double> _doubles(dynamic raw) =>
      (raw as List<dynamic>? ?? []).map((e) => (e as num).toDouble()).toList();

  factory BarSeries.fromJson(Map<String, dynamic> json) {
    return BarSeries(
      ticker: json['ticker'] as String? ?? '',
      multiplier: json['multiplier'] as int? ?? 1,
      timespan: json['timespan'] as String? ?? 'minute',
      source: json['source'] as String? ?? '',
      computedAt: json['computed_at'] as String? ?? '',
      opens: _doubles(json['opens']),
      highs: _doubles(json['highs']),
      lows: _doubles(json['lows']),
      closes: _doubles(json['closes']),
    );
  }
}
