/// GBP capital-gains ESTIMATE per account - matches backtester.tax's own
/// module docstring for exactly what this is and isn't: the simple
/// realized-P&L-sum method for the current UK tax year, not HMRC Section
/// 104 share pooling, and not a substitute for an actual Self Assessment.
class TaxLine {
  final String accountId;
  final String nickname;
  final String currency; // "GBP" or "USD"
  final double realizedGainNative;
  final double? realizedGainGbp; // null when a USD account has no FX rate set yet

  TaxLine({
    required this.accountId,
    required this.nickname,
    required this.currency,
    required this.realizedGainNative,
    required this.realizedGainGbp,
  });

  factory TaxLine.fromJson(Map<String, dynamic> json) {
    return TaxLine(
      accountId: json['account_id'] as String? ?? '',
      nickname: json['nickname'] as String? ?? '',
      currency: json['currency'] as String? ?? 'USD',
      realizedGainNative: (json['realized_gain_native'] as num?)?.toDouble() ?? 0.0,
      realizedGainGbp: (json['realized_gain_gbp'] as num?)?.toDouble(),
    );
  }
}

class TaxSummary {
  final String taxYearStart;
  final String taxYearEnd;
  final List<TaxLine> lines;
  final double totalGainGbp;
  final List<String> missingFxAccounts;
  final double allowanceGbp;
  final double taxableGainGbp;
  final double ratePct;
  final double estimatedTaxGbp;

  TaxSummary({
    required this.taxYearStart,
    required this.taxYearEnd,
    required this.lines,
    required this.totalGainGbp,
    required this.missingFxAccounts,
    required this.allowanceGbp,
    required this.taxableGainGbp,
    required this.ratePct,
    required this.estimatedTaxGbp,
  });

  factory TaxSummary.fromJson(Map<String, dynamic> json) {
    return TaxSummary(
      taxYearStart: json['tax_year_start'] as String? ?? '',
      taxYearEnd: json['tax_year_end'] as String? ?? '',
      lines: (json['lines'] as List<dynamic>? ?? [])
          .map((e) => TaxLine.fromJson(e as Map<String, dynamic>))
          .toList(),
      totalGainGbp: (json['total_gain_gbp'] as num?)?.toDouble() ?? 0.0,
      missingFxAccounts: (json['missing_fx_accounts'] as List<dynamic>? ?? [])
          .map((e) => e as String)
          .toList(),
      allowanceGbp: (json['allowance_gbp'] as num?)?.toDouble() ?? 0.0,
      taxableGainGbp: (json['taxable_gain_gbp'] as num?)?.toDouble() ?? 0.0,
      ratePct: (json['rate_pct'] as num?)?.toDouble() ?? 0.0,
      estimatedTaxGbp: (json['estimated_tax_gbp'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

/// Allowance/rate/FX default to 0 server-side until the user sets a real
/// value - never assumed, since none of them are things this app can
/// reliably know are current.
class TaxSettings {
  final double cgtAllowanceGbp;
  final double cgtRatePct;
  final double gbpUsdRate;
  final Map<String, String> accountCurrencies; // account_id -> "GBP"/"USD"

  TaxSettings({
    required this.cgtAllowanceGbp,
    required this.cgtRatePct,
    required this.gbpUsdRate,
    required this.accountCurrencies,
  });

  factory TaxSettings.fromJson(Map<String, dynamic> json) {
    return TaxSettings(
      cgtAllowanceGbp: (json['cgt_allowance_gbp'] as num?)?.toDouble() ?? 0.0,
      cgtRatePct: (json['cgt_rate_pct'] as num?)?.toDouble() ?? 0.0,
      gbpUsdRate: (json['gbp_usd_rate'] as num?)?.toDouble() ?? 0.0,
      accountCurrencies: (json['account_currencies'] as Map<String, dynamic>? ?? {})
          .map((k, v) => MapEntry(k, v as String)),
    );
  }
}
