/// Mirrors the backend's /trading-hours JSON shape exactly (see
/// Mobile_App/backend/signal_api.py's trading_hours()) - a REGULAR weekly
/// open/close schedule per market, already converted to UK local time
/// server-side (real zoneinfo conversion, not a hardcoded offset - correct
/// through the US/UK DST mismatch weeks too). One-off market holidays are
/// NOT reflected - `note` says so explicitly, shown in the UI rather than
/// silently implied as exact.
class DaySchedule {
  final int dayIndex; // 0=Mon .. 6=Sun
  final String label; // "MON".."SUN"
  final int? openMinutes; // minutes since UK midnight, null = closed all day
  final int? closeMinutes;

  DaySchedule({
    required this.dayIndex,
    required this.label,
    required this.openMinutes,
    required this.closeMinutes,
  });

  factory DaySchedule.fromJson(Map<String, dynamic> json) {
    return DaySchedule(
      dayIndex: json['day_index'] as int,
      label: json['label'] as String,
      openMinutes: json['open_minutes'] as int?,
      closeMinutes: json['close_minutes'] as int?,
    );
  }
}

class MarketSchedule {
  final String name;
  final List<DaySchedule> days;

  MarketSchedule({required this.name, required this.days});

  factory MarketSchedule.fromJson(Map<String, dynamic> json) {
    return MarketSchedule(
      name: json['name'] as String,
      days: (json['days'] as List<dynamic>)
          .map((d) => DaySchedule.fromJson(d as Map<String, dynamic>))
          .toList(),
    );
  }
}

class TradingHours {
  final String timezone;
  final int nowDayIndex;
  final int nowMinutes;
  final String note;
  final List<MarketSchedule> markets;
  final String cryptoNote;

  TradingHours({
    required this.timezone,
    required this.nowDayIndex,
    required this.nowMinutes,
    required this.note,
    required this.markets,
    required this.cryptoNote,
  });

  factory TradingHours.fromJson(Map<String, dynamic> json) {
    return TradingHours(
      timezone: json['timezone'] as String,
      nowDayIndex: json['now_day_index'] as int,
      nowMinutes: json['now_minutes'] as int,
      note: json['note'] as String,
      markets: (json['markets'] as List<dynamic>)
          .map((m) => MarketSchedule.fromJson(m as Map<String, dynamic>))
          .toList(),
      cryptoNote: json['crypto_note'] as String,
    );
  }
}
