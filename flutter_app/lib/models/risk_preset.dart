/// Mirrors backtester.risk_presets.RISK_PRESETS's per-preset shape - fetched
/// from the backend's /risk-presets rather than hardcoded here, so the app
/// always shows the real current values instead of a copy that could drift.
class RiskPreset {
  final double sizingValue;
  final double volTargetAnn;
  final double maxDrawdownPct;
  final bool givebackEnabled;
  final double givebackPct;

  RiskPreset({
    required this.sizingValue,
    required this.volTargetAnn,
    required this.maxDrawdownPct,
    required this.givebackEnabled,
    required this.givebackPct,
  });

  factory RiskPreset.fromJson(Map<String, dynamic> json) {
    return RiskPreset(
      sizingValue: (json['sizing_value'] as num?)?.toDouble() ?? 0.0,
      volTargetAnn: (json['vol_target_ann'] as num?)?.toDouble() ?? 0.0,
      maxDrawdownPct: (json['max_drawdown_pct'] as num?)?.toDouble() ?? 0.0,
      givebackEnabled: json['giveback_enabled'] as bool? ?? false,
      givebackPct: (json['giveback_pct'] as num?)?.toDouble() ?? 0.0,
    );
  }
}
