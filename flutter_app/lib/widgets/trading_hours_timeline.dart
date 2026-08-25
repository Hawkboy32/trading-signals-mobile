import 'package:flutter/material.dart';

import '../models/trading_hours.dart';

const _colAccent = Color(0xFF3DC7F0);
const _colDim = Color(0xFF5B7386);
const _colDimmer = Color(0xFF1C2733);

/// A week-at-a-glance open/close timeline for one market - a horizontal
/// track per day (Mon..Sun), with the open window drawn as a highlighted
/// segment, today's row picked out, and a single vertical "now" line
/// running through all 7 rows. Same "Holotable" palette used throughout
/// this app's dashboard/widget/mobile surfaces (hologram cyan on near-black)
/// rather than inventing a new look for one screen.
///
/// Own take on the familiar broker-app "trading hours" widget, not a copy
/// of any specific one - built from this app's own color system and using
/// a plain Stack of proportional-width Positioned bars (day rows) plus one
/// Positioned vertical line, rather than any borrowed layout code.
class TradingHoursTimeline extends StatelessWidget {
  final MarketSchedule market;
  final int nowDayIndex;
  final int nowMinutes;

  const TradingHoursTimeline({
    super.key,
    required this.market,
    required this.nowDayIndex,
    required this.nowMinutes,
  });

  static const _minutesPerDay = 24 * 60;
  static const _rowHeight = 30.0;
  static const _rowGap = 14.0;
  static const _labelWidth = 44.0;

  @override
  Widget build(BuildContext context) {
    final totalHeight = market.days.length * (_rowHeight + _rowGap) - _rowGap;

    return LayoutBuilder(
      builder: (context, constraints) {
        // Must match _DayRow's own bar width exactly (total width minus the
        // day label AND the trailing digit-time column) - this "now" line is
        // computed in a separate widget from the bars it's meant to line up
        // with, so the two width calculations have to stay in sync by hand.
        // Real bug found on-device 2026-08-23: this originally only
        // subtracted _labelWidth, so the line sat further right than the
        // bars it was supposed to point at, by exactly _DayRow.timeWidth.
        final trackWidth = constraints.maxWidth - _labelWidth - _DayRow._timeWidth;
        // Fraction of the way through TODAY's row the "now" line sits at -
        // used to place one continuous vertical line at the right height
        // and the right horizontal position simultaneously.
        final nowRowIndex = market.days.indexWhere((d) => d.dayIndex == nowDayIndex);
        final nowFrac = (nowMinutes / _minutesPerDay).clamp(0.0, 1.0);
        final nowX = _labelWidth + nowFrac * trackWidth;
        final nowY = nowRowIndex >= 0
            ? nowRowIndex * (_rowHeight + _rowGap) + _rowHeight / 2
            : null;

        return SizedBox(
          height: totalHeight,
          child: Stack(
            children: [
              for (int i = 0; i < market.days.length; i++)
                Positioned(
                  top: i * (_rowHeight + _rowGap),
                  left: 0,
                  right: 0,
                  height: _rowHeight,
                  child: _DayRow(
                    day: market.days[i],
                    isToday: market.days[i].dayIndex == nowDayIndex,
                    labelWidth: _labelWidth,
                  ),
                ),
              if (nowY != null)
                Positioned(
                  left: nowX - 1,
                  top: 0,
                  bottom: 0,
                  width: 2,
                  child: Container(color: _colAccent.withValues(alpha: 0.85)),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _DayRow extends StatelessWidget {
  final DaySchedule day;
  final bool isToday;
  final double labelWidth;

  const _DayRow({required this.day, required this.isToday, required this.labelWidth});

  static const _minutesPerDay = 24 * 60;
  static const _timeWidth = 92.0;

  /// "24:00", not "00:00", for exact midnight-as-an-end-time - the mod-24
  /// wraparound that's correct for a START time (nothing starts at "24:00")
  /// is wrong for a CLOSE time, where minutes=1440 means "runs to the end of
  /// this calendar day", not "closes at midnight last night". Real bug found
  /// on-device 2026-08-23: Forex's Mon-Thu full-day window (0-1440) was
  /// showing as "00:00–00:00", reading as closed/zero-duration instead of
  /// open all day.
  static String _fmt(int minutes, {bool isClose = false}) {
    if (isClose && minutes == _minutesPerDay) return '24:00';
    final h = (minutes ~/ 60) % 24;
    final m = minutes % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final closed = day.openMinutes == null || day.closeMinutes == null;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: labelWidth,
          child: Text(
            day.label,
            style: TextStyle(
              color: isToday ? _colAccent : _colDim,
              fontWeight: isToday ? FontWeight.bold : FontWeight.w600,
              fontSize: 12,
              letterSpacing: 0.5,
            ),
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              return Container(
                height: isToday ? 10 : 6,
                decoration: BoxDecoration(
                  color: _colDimmer,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: closed
                    ? null
                    : Stack(
                        children: [
                          Positioned(
                            left: (day.openMinutes! / _minutesPerDay) * width,
                            width: ((day.closeMinutes! - day.openMinutes!) / _minutesPerDay) * width,
                            top: 0,
                            bottom: 0,
                            child: Container(
                              decoration: BoxDecoration(
                                color: isToday ? _colAccent : _colAccent.withValues(alpha: 0.55),
                                borderRadius: BorderRadius.circular(6),
                              ),
                            ),
                          ),
                        ],
                      ),
              );
            },
          ),
        ),
        SizedBox(
          width: _timeWidth,
          child: Text(
            closed
                ? 'Closed'
                : (day.openMinutes == 0 && day.closeMinutes == _minutesPerDay)
                    ? 'Open all day'
                    : '${_fmt(day.openMinutes!)}–${_fmt(day.closeMinutes!, isClose: true)}',
            textAlign: TextAlign.right,
            style: TextStyle(
              color: isToday ? _colAccent : _colDim,
              fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
              fontSize: 11,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}
