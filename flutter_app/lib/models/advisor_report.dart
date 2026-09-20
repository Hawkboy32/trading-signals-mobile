/// A read-only, on-demand Claude second opinion on current roster health,
/// positions, and any pending roster recommendation - fetched fresh from
/// the backend's /advisor on every request (a real, billed API call, not a
/// cached value). Purely informational: nothing here changes the roster or
/// places a trade - see backend/advisor_service.py's own docstring for why
/// that's a deliberate design guarantee, not just today's behavior.
class AdvisorFlag {
  final String severity; // "info" | "warning"
  final String combo; // e.g. "RMBS/VWAP Mean Reversion", or "portfolio"
  final String note;

  AdvisorFlag({required this.severity, required this.combo, required this.note});

  factory AdvisorFlag.fromJson(Map<String, dynamic> json) {
    return AdvisorFlag(
      severity: json['severity'] as String? ?? 'info',
      combo: json['combo'] as String? ?? '',
      note: json['note'] as String? ?? '',
    );
  }
}

class AdvisorReport {
  final String summary;
  final List<AdvisorFlag> flags;
  final String generatedAt;

  AdvisorReport({required this.summary, required this.flags, required this.generatedAt});

  factory AdvisorReport.fromJson(Map<String, dynamic> json) {
    return AdvisorReport(
      summary: json['summary'] as String? ?? '',
      flags: (json['flags'] as List<dynamic>? ?? [])
          .map((e) => AdvisorFlag.fromJson(e as Map<String, dynamic>))
          .toList(),
      generatedAt: json['generated_at'] as String? ?? '',
    );
  }
}
