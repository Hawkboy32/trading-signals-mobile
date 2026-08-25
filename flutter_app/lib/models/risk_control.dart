/// One account's max-drawdown circuit-breaker state (backtester.account_risk).
///
/// The breaker is deliberately NOT self-healing: once an account falls more
/// than max_drawdown_pct below its peak it stays blocked even if equity
/// recovers, until a human clears it. Surfacing it here is what lets that
/// human step happen from the phone instead of only at the dashboard.
class AccountRiskStatus {
  final String accountId;
  final String nickname;
  final bool isPaper;
  final bool blocked;
  final String? reason;
  final String? blockedAt;
  final double? peakEquity;

  AccountRiskStatus({
    required this.accountId,
    required this.nickname,
    required this.isPaper,
    required this.blocked,
    required this.reason,
    required this.blockedAt,
    required this.peakEquity,
  });

  factory AccountRiskStatus.fromJson(Map<String, dynamic> json) {
    return AccountRiskStatus(
      accountId: json['account_id'] as String? ?? '',
      nickname: json['nickname'] as String? ?? '',
      isPaper: json['is_paper'] as bool? ?? true,
      blocked: json['blocked'] as bool? ?? false,
      reason: json['reason'] as String?,
      blockedAt: json['blocked_at'] as String?,
      peakEquity: (json['peak_equity'] as num?)?.toDouble(),
    );
  }
}

/// The roster's own rules (backtester.roster.RosterConfig), limited to the
/// fields the phone edits. Everything else in the config is carried forward
/// server-side on save, so editing here can never blank a setting the app
/// doesn't show.
class RosterSettings {
  final int rosterSize;
  final int losingStreakThreshold;
  final double winRateFloor; // percent, e.g. 30.0
  final int maxPerStrategy;
  final int maxPerSector;
  final int reviewCadenceDays;
  final int pauseReleaseDays;

  RosterSettings({
    required this.rosterSize,
    required this.losingStreakThreshold,
    required this.winRateFloor,
    required this.maxPerStrategy,
    required this.maxPerSector,
    required this.reviewCadenceDays,
    required this.pauseReleaseDays,
  });

  factory RosterSettings.fromJson(Map<String, dynamic> json) {
    return RosterSettings(
      rosterSize: (json['roster_size'] as num?)?.toInt() ?? 4,
      losingStreakThreshold: (json['losing_streak_threshold'] as num?)?.toInt() ?? 3,
      winRateFloor: (json['win_rate_floor'] as num?)?.toDouble() ?? 30.0,
      maxPerStrategy: (json['max_per_strategy'] as num?)?.toInt() ?? 2,
      maxPerSector: (json['max_per_sector'] as num?)?.toInt() ?? 2,
      reviewCadenceDays: (json['review_cadence_days'] as num?)?.toInt() ?? 7,
      pauseReleaseDays: (json['pause_release_days'] as num?)?.toInt() ?? 5,
    );
  }

  Map<String, dynamic> toJson() => {
        'roster_size': rosterSize,
        'losing_streak_threshold': losingStreakThreshold,
        'win_rate_floor': winRateFloor,
        'max_per_strategy': maxPerStrategy,
        'max_per_sector': maxPerSector,
        'review_cadence_days': reviewCadenceDays,
        'pause_release_days': pauseReleaseDays,
      };

  RosterSettings copyWith({
    int? rosterSize,
    int? losingStreakThreshold,
    double? winRateFloor,
    int? maxPerStrategy,
    int? maxPerSector,
    int? reviewCadenceDays,
    int? pauseReleaseDays,
  }) {
    return RosterSettings(
      rosterSize: rosterSize ?? this.rosterSize,
      losingStreakThreshold: losingStreakThreshold ?? this.losingStreakThreshold,
      winRateFloor: winRateFloor ?? this.winRateFloor,
      maxPerStrategy: maxPerStrategy ?? this.maxPerStrategy,
      maxPerSector: maxPerSector ?? this.maxPerSector,
      reviewCadenceDays: reviewCadenceDays ?? this.reviewCadenceDays,
      pauseReleaseDays: pauseReleaseDays ?? this.pauseReleaseDays,
    );
  }
}

/// Stop-loss / take-profit attached to OPENING orders as broker-side bracket
/// prices, so they keep working even when the bot process is down.
///
/// Percentages are as the user sees them (1.0 = 1%), matching the API; the
/// backend converts to the fractions the engine uses.
///
/// Values chosen from a walk-forward sweep, not intuition — see
/// CLAUDE_NOTES.txt. Take-profit ~1.5% was the only setting that improved P&L
/// out-of-sample; a 1% stop costs ~15% of expected return to cut the worst
/// single trade by 60-90%; flattening before the close tested WORSE in every
/// window and is off by default.
class ProtectiveExits {
  final double? stopLossPct;
  final double? takeProfitPct;
  final int? flattenBeforeCloseMinutes;

  ProtectiveExits({this.stopLossPct, this.takeProfitPct, this.flattenBeforeCloseMinutes});

  bool get stopEnabled => stopLossPct != null;
  bool get takeProfitEnabled => takeProfitPct != null;
  bool get flattenEnabled => flattenBeforeCloseMinutes != null;

  factory ProtectiveExits.fromJson(Map<String, dynamic> json) => ProtectiveExits(
        stopLossPct: (json['stop_loss_pct'] as num?)?.toDouble(),
        takeProfitPct: (json['take_profit_pct'] as num?)?.toDouble(),
        flattenBeforeCloseMinutes: (json['flatten_before_close_minutes'] as num?)?.toInt(),
      );

  Map<String, dynamic> toJson() => {
        'stop_loss_pct': stopLossPct,
        'take_profit_pct': takeProfitPct,
        'flatten_before_close_minutes': flattenBeforeCloseMinutes,
      };

  ProtectiveExits copyWith({
    double? stopLossPct,
    double? takeProfitPct,
    int? flattenBeforeCloseMinutes,
    bool clearStop = false,
    bool clearTakeProfit = false,
    bool clearFlatten = false,
  }) =>
      ProtectiveExits(
        stopLossPct: clearStop ? null : (stopLossPct ?? this.stopLossPct),
        takeProfitPct: clearTakeProfit ? null : (takeProfitPct ?? this.takeProfitPct),
        flattenBeforeCloseMinutes:
            clearFlatten ? null : (flattenBeforeCloseMinutes ?? this.flattenBeforeCloseMinutes),
      );
}
