/// One account's sliding-scale sizing (backtester.execution.sliding_pct_equity)
/// state - fetched from the backend's /sizing. currentEffectivePct is the
/// live "what's it actually trading at right now" figure, recomputed by the
/// backend from real equity on every request - not a fixed number anywhere
/// else, since the slide itself recomputes fresh at every trade entry.
class AccountSizing {
  final String accountId;
  final String nickname;
  final String broker;
  final bool isPaper;
  final double? equity;
  final double slideStartPct;
  final double slideFloorNotional;
  final double targetPct;
  final double? currentEffectivePct;

  AccountSizing({
    required this.accountId,
    required this.nickname,
    required this.broker,
    required this.isPaper,
    required this.equity,
    required this.slideStartPct,
    required this.slideFloorNotional,
    required this.targetPct,
    required this.currentEffectivePct,
  });

  bool get slideEnabled => slideStartPct > 0;

  factory AccountSizing.fromJson(Map<String, dynamic> json) {
    return AccountSizing(
      accountId: json['account_id'] as String? ?? '',
      nickname: json['nickname'] as String? ?? '',
      broker: json['broker'] as String? ?? '',
      isPaper: json['is_paper'] as bool? ?? true,
      equity: (json['equity'] as num?)?.toDouble(),
      slideStartPct: (json['slide_start_pct'] as num?)?.toDouble() ?? 0.0,
      slideFloorNotional: (json['slide_floor_notional'] as num?)?.toDouble() ?? 1.0,
      targetPct: (json['target_pct'] as num?)?.toDouble() ?? 0.0,
      currentEffectivePct: (json['current_effective_pct'] as num?)?.toDouble(),
    );
  }
}
