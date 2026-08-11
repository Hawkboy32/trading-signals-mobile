/// What the live bot is currently configured to trade - fetched from the
/// backend's /targets rather than hardcoded, same reasoning as RiskPreset.
class TargetConfig {
  final String mode; // "manual" or "roster"
  final List<String> tickers;
  final String strategyName;
  final List<String> availableStrategies;

  TargetConfig({
    required this.mode,
    required this.tickers,
    required this.strategyName,
    required this.availableStrategies,
  });

  bool get isManual => mode == 'manual';

  factory TargetConfig.fromJson(Map<String, dynamic> json) {
    return TargetConfig(
      mode: json['mode'] as String? ?? 'roster',
      tickers: (json['tickers'] as List<dynamic>? ?? []).map((e) => e as String).toList(),
      strategyName: json['strategy_name'] as String? ?? '',
      availableStrategies:
          (json['available_strategies'] as List<dynamic>? ?? []).map((e) => e as String).toList(),
    );
  }
}
