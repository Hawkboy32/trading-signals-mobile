/// A computed-but-not-yet-applied roster change - fetched from the backend's
/// /roster-recommendation. Nothing has changed yet; approving or dismissing
/// it is the only thing that does.
class RosterRecommendation {
  final String computedAt;
  final int scanRunId;
  final int numScanResults;
  final List<String> summary;

  RosterRecommendation({
    required this.computedAt,
    required this.scanRunId,
    required this.numScanResults,
    required this.summary,
  });

  factory RosterRecommendation.fromJson(Map<String, dynamic> json) {
    return RosterRecommendation(
      computedAt: json['computed_at'] as String? ?? '',
      scanRunId: (json['scan_run_id'] as num?)?.toInt() ?? 0,
      numScanResults: (json['num_scan_results'] as num?)?.toInt() ?? 0,
      summary: (json['summary'] as List<dynamic>? ?? []).map((e) => e as String).toList(),
    );
  }
}
