/// One tier's fixed terms (backtester.challenge_state.TIERS) - all three
/// tiers share the identical +12%/-3% band, differing only in starting
/// balance and one-time fee.
class ChallengeTier {
  final String key;
  final String label;
  final double startingBalance;
  final double feeUsd;

  ChallengeTier({
    required this.key,
    required this.label,
    required this.startingBalance,
    required this.feeUsd,
  });

  factory ChallengeTier.fromJson(String key, Map<String, dynamic> json) => ChallengeTier(
        key: key,
        label: json['label'] as String? ?? key,
        startingBalance: (json['starting_balance'] as num?)?.toDouble() ?? 0.0,
        feeUsd: (json['fee_usd'] as num?)?.toDouble() ?? 0.0,
      );
}

/// One challenge attempt (backtester.challenge_state.ChallengeAttempt), with
/// current_balance/progress_fraction attached server-side only for the
/// active attempt - a finished attempt's own ending_balance is the record,
/// it never needs a fresh broker read.
class ChallengeAttempt {
  final String tier;
  final int attemptNumber;
  final String accountId;
  final String startedAt;
  final double startingBalance;
  final String strategyName;
  final double sizingPct; // fraction, e.g. 0.20 for 20%
  final String status; // "active" | "passed" | "failed"
  final String? endedAt;
  final double? endingBalance;
  final double target;
  final double floor;
  final double? currentBalance; // only set for the active attempt
  final double? progressFraction; // 0.0 at floor, 1.0 at target

  ChallengeAttempt({
    required this.tier,
    required this.attemptNumber,
    required this.accountId,
    required this.startedAt,
    required this.startingBalance,
    required this.strategyName,
    required this.sizingPct,
    required this.status,
    required this.endedAt,
    required this.endingBalance,
    required this.target,
    required this.floor,
    required this.currentBalance,
    required this.progressFraction,
  });

  factory ChallengeAttempt.fromJson(Map<String, dynamic> json) => ChallengeAttempt(
        tier: json['tier'] as String? ?? '',
        attemptNumber: (json['attempt_number'] as num?)?.toInt() ?? 0,
        accountId: json['account_id'] as String? ?? '',
        startedAt: json['started_at'] as String? ?? '',
        startingBalance: (json['starting_balance'] as num?)?.toDouble() ?? 0.0,
        strategyName: json['strategy_name'] as String? ?? '',
        sizingPct: (json['sizing_pct'] as num?)?.toDouble() ?? 0.0,
        status: json['status'] as String? ?? 'active',
        endedAt: json['ended_at'] as String?,
        endingBalance: (json['ending_balance'] as num?)?.toDouble(),
        target: (json['target'] as num?)?.toDouble() ?? 0.0,
        floor: (json['floor'] as num?)?.toDouble() ?? 0.0,
        currentBalance: (json['current_balance'] as num?)?.toDouble(),
        progressFraction: (json['progress_fraction'] as num?)?.toDouble(),
      );
}

class ChallengeState {
  final ChallengeAttempt? active;
  final Map<String, ChallengeTier> tiers;
  final List<ChallengeAttempt> attempts;

  ChallengeState({required this.active, required this.tiers, required this.attempts});

  factory ChallengeState.fromJson(Map<String, dynamic> json) {
    final activeJson = json['active'] as Map<String, dynamic>?;
    final tiersJson = json['tiers'] as Map<String, dynamic>? ?? {};
    final attemptsJson = json['attempts'] as List<dynamic>? ?? [];
    return ChallengeState(
      active: activeJson == null ? null : ChallengeAttempt.fromJson(activeJson),
      tiers: tiersJson.map(
        (k, v) => MapEntry(k, ChallengeTier.fromJson(k, v as Map<String, dynamic>)),
      ),
      attempts: attemptsJson.map((a) => ChallengeAttempt.fromJson(a as Map<String, dynamic>)).toList(),
    );
  }
}
