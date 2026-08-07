class RosterLiveStats {
  final int numTrades;
  final double? winRate;
  final double? avgPnlPct;
  final double totalPnl;
  final int currentLosingStreak;
  final double maxPnlDrawdown;

  RosterLiveStats({
    required this.numTrades,
    required this.winRate,
    required this.avgPnlPct,
    required this.totalPnl,
    required this.currentLosingStreak,
    required this.maxPnlDrawdown,
  });

  factory RosterLiveStats.fromJson(Map<String, dynamic> json) {
    return RosterLiveStats(
      numTrades: (json['num_trades'] as num?)?.toInt() ?? 0,
      winRate: (json['win_rate'] as num?)?.toDouble(),
      avgPnlPct: (json['avg_pnl_pct'] as num?)?.toDouble(),
      totalPnl: (json['total_pnl'] as num?)?.toDouble() ?? 0.0,
      currentLosingStreak: (json['current_losing_streak'] as num?)?.toInt() ?? 0,
      maxPnlDrawdown: (json['max_pnl_drawdown'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

class RosterEntry {
  final String ticker;
  final String strategyName;
  final String status; // "active" | "paused"
  final String? pauseReason;
  final RosterLiveStats? liveStats;

  RosterEntry({
    required this.ticker,
    required this.strategyName,
    required this.status,
    required this.pauseReason,
    required this.liveStats,
  });

  factory RosterEntry.fromJson(Map<String, dynamic> json) {
    return RosterEntry(
      ticker: json['ticker'] as String? ?? '',
      strategyName: json['strategy_name'] as String? ?? '',
      status: json['status'] as String? ?? 'active',
      pauseReason: json['pause_reason'] as String?,
      liveStats: json['live_stats'] != null
          ? RosterLiveStats.fromJson(json['live_stats'] as Map<String, dynamic>)
          : null,
    );
  }
}

class RosterConfig {
  final int minLiveTrades;
  final int losingStreakThreshold;
  final double winRateFloor;
  final double cumPnlFloor;
  final double maxPnlDrawdownFloor;

  RosterConfig({
    required this.minLiveTrades,
    required this.losingStreakThreshold,
    required this.winRateFloor,
    required this.cumPnlFloor,
    required this.maxPnlDrawdownFloor,
  });

  factory RosterConfig.fromJson(Map<String, dynamic> json) {
    return RosterConfig(
      minLiveTrades: (json['min_live_trades'] as num?)?.toInt() ?? 5,
      losingStreakThreshold: (json['losing_streak_threshold'] as num?)?.toInt() ?? 5,
      winRateFloor: (json['win_rate_floor'] as num?)?.toDouble() ?? 0.30,
      cumPnlFloor: (json['cum_pnl_floor'] as num?)?.toDouble() ?? 0.0,
      maxPnlDrawdownFloor: (json['max_pnl_drawdown_floor'] as num?)?.toDouble() ?? 500.0,
    );
  }
}

class RosterResponse {
  final List<RosterEntry> entries;
  final RosterConfig config;

  RosterResponse({required this.entries, required this.config});

  factory RosterResponse.fromJson(Map<String, dynamic> json) {
    return RosterResponse(
      entries: (json['entries'] as List<dynamic>? ?? [])
          .map((e) => RosterEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
      config: RosterConfig.fromJson(json['config'] as Map<String, dynamic>? ?? {}),
    );
  }
}
