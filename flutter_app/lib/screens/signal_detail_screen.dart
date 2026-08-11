import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../models/signal.dart';
import '../services/auth_client.dart';

/// The bigger, tap-through view of a signal card's sparkline - same
/// `recentCloses` data (no new backend call for the price line itself), but
/// drawn as a proper chart with the strategy's own reference levels (VWAP,
/// or the Bollinger bands) overlaid as horizontal lines, and real axis
/// labels. `recentCloses` has no per-point timestamp (only the LAST bar's
/// `computedAt` is known), so the x-axis is bar-index, oldest to newest -
/// same honest limitation the small sparkline already had, just labelled
/// clearly here instead of hidden. Since there's no per-point time axis, an
/// open position's entry is drawn as a horizontal PRICE line (same visual
/// language as the exit-trigger lines below), not a dot at a fabricated x
/// position - honest about what this chart can and can't show.
///
/// The exit-trigger lines aren't just "reference levels" - they're the
/// literal condition each strategy's own on_bar() watches to close a
/// position (VwapMeanReversionStrategy: price crossing back to/through
/// VWAP; BollingerMeanReversionStrategy: price closing back above the mid
/// band - see their source for the exact check), so they're labelled
/// "(exit)" directly rather than left implicit.
class SignalDetailScreen extends StatefulWidget {
  final TradingSignal signal;

  const SignalDetailScreen({super.key, required this.signal});

  @override
  State<SignalDetailScreen> createState() => _SignalDetailScreenState();
}

class _SignalDetailScreenState extends State<SignalDetailScreen> {
  List<_LevelLine> _entryLines = [];

  @override
  void initState() {
    super.initState();
    _loadEntryLines();
  }

  Future<void> _loadEntryLines() async {
    // Entry price comes from /positions, which is login-gated (real account
    // holdings) - this screen still works fully without it, just without
    // the entry marker, rather than forcing a login for a read-only chart.
    if (!await AuthClient.isLoggedIn()) return;
    try {
      final accounts = await AuthClient.fetchPositions();
      final tradingAccounts = widget.signal.tradingAccounts?.toSet() ?? {};
      final lines = <_LevelLine>[];
      for (final account in accounts) {
        if (tradingAccounts.isNotEmpty && !tradingAccounts.contains(account.nickname)) {
          continue; // a different strategy on this account may trade the same ticker
        }
        for (final position in account.positions) {
          if (position.ticker == widget.signal.ticker) {
            lines.add(
              _LevelLine('Entry (${account.nickname})', position.avgEntryPrice, Colors.amber),
            );
          }
        }
      }
      if (mounted) setState(() => _entryLines = lines);
    } catch (_) {
      // Silent - an entry marker is a nice-to-have overlay, not core to the chart.
    }
  }

  Color get _badgeColor {
    switch (widget.signal.signal) {
      case 'buy':
        return Colors.green;
      case 'sell':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  List<_LevelLine> get _exitLevelLines {
    final levels = widget.signal.levels;
    if (levels == null) return [];
    if (levels.containsKey('vwap')) {
      return [_LevelLine('VWAP (exit)', levels['vwap']!, Colors.blueAccent)];
    }
    if (levels.containsKey('lower') && levels.containsKey('upper')) {
      final lines = [
        _LevelLine('Upper', levels['upper']!, Colors.purpleAccent),
        _LevelLine('Lower', levels['lower']!, Colors.purpleAccent),
      ];
      if (levels.containsKey('mid')) {
        lines.add(
          _LevelLine(
            'Mid (exit)',
            levels['mid']!,
            Colors.purpleAccent.withValues(alpha: 0.5),
          ),
        );
      }
      return lines;
    }
    return [];
  }

  @override
  Widget build(BuildContext context) {
    final signal = widget.signal;
    final closes = signal.recentCloses ?? [];
    final levelLines = [..._entryLines, ..._exitLevelLines];

    return Scaffold(
      appBar: AppBar(title: Text('${signal.ticker} · ${signal.strategyName}')),
      body: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 24 + MediaQuery.of(context).padding.bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  signal.price.toStringAsFixed(4),
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: _badgeColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: _badgeColor),
                  ),
                  child: Text(
                    signal.signal.toUpperCase(),
                    style: TextStyle(
                      color: _badgeColor,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            if (signal.conviction != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Conviction: ${(signal.conviction! * 100).toStringAsFixed(0)}%',
                  style: TextStyle(color: Colors.grey[600]),
                ),
              ),
            const SizedBox(height: 24),
            if (closes.length >= 2)
              SizedBox(
                height: 320,
                child: _DetailChart(
                  closes: closes,
                  color: _badgeColor,
                  levelLines: levelLines,
                  opens: signal.recentOpens,
                  highs: signal.recentHighs,
                  lows: signal.recentLows,
                ),
              )
            else
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(
                  child: Text('Not enough recent data for a chart yet.'),
                ),
              ),
            if (levelLines.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 16,
                children: levelLines
                    .map(
                      (l) => Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(width: 12, height: 3, color: l.color),
                          const SizedBox(width: 4),
                          Text(
                            '${l.label}: ${l.value.toStringAsFixed(4)}',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    )
                    .toList(),
              ),
            ],
            const SizedBox(height: 12),
            Text(
              'Last ${closes.length} bars · oldest to newest, left to right. '
              'Computed at ${signal.computedAt}.',
              style: TextStyle(fontSize: 11, color: Colors.grey[500]),
            ),
            if (signal.source != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  signal.source!,
                  style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _LevelLine {
  final String label;
  final double value;
  final Color color;
  _LevelLine(this.label, this.value, this.color);
}

class _DetailChart extends StatelessWidget {
  final List<double> closes;
  final Color color;
  final List<_LevelLine> levelLines;
  final List<double>? opens;
  final List<double>? highs;
  final List<double>? lows;

  const _DetailChart({
    required this.closes,
    required this.color,
    required this.levelLines,
    this.opens,
    this.highs,
    this.lows,
  });

  bool get _hasOhlc =>
      closes.isNotEmpty &&
      opens != null && opens!.length == closes.length &&
      highs != null && highs!.length == closes.length &&
      lows != null && lows!.length == closes.length;

  // Same reserved-size/hidden-titles shape on both the real chart and the
  // transparent overlay, so their plot-area rectangles line up pixel for
  // pixel - reservedSize still consumes layout space even with
  // showTitles: false, which is what keeps the two charts' coordinate
  // systems in sync in the Stack below.
  FlTitlesData _titlesData({required bool showLeftLabels}) {
    return FlTitlesData(
      topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      bottomTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      leftTitles: AxisTitles(
        sideTitles: SideTitles(
          showTitles: showLeftLabels,
          reservedSize: 56,
          // fl_chart always draws a label at axis min/max in addition to
          // its own auto-spaced gridline labels, which collide/overlap
          // whenever an auto label lands close to either edge - skip any
          // label within 5% of the range from the boundary, since the
          // edge label already covers that value.
          getTitlesWidget: (value, meta) {
            final range = meta.max - meta.min;
            final nearMin = value != meta.min && range > 0 && (value - meta.min).abs() < range * 0.06;
            final nearMax = value != meta.max && range > 0 && (value - meta.max).abs() < range * 0.06;
            if (nearMin || nearMax) {
              return const SizedBox.shrink();
            }
            return Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Text(value.toStringAsFixed(2), style: const TextStyle(fontSize: 10)),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final allValues = [
      ...closes,
      if (_hasOhlc) ...highs!,
      if (_hasOhlc) ...lows!,
      ...levelLines.map((l) => l.value),
    ];
    final minY = allValues.reduce((a, b) => a < b ? a : b);
    final maxY = allValues.reduce((a, b) => a > b ? a : b);
    final pad = (maxY - minY).abs() < 1e-9
        ? (maxY.abs() * 0.01 + 0.01)
        : (maxY - minY) * 0.1;
    final plotMinY = minY - pad;
    final plotMaxY = maxY + pad;

    final borderData = FlBorderData(
      show: true,
      border: Border.all(color: Colors.grey.withValues(alpha: 0.3)),
    );
    final extraLines = ExtraLinesData(
      horizontalLines: [
        for (final l in levelLines)
          HorizontalLine(y: l.value, color: l.color, strokeWidth: 1.5, dashArray: [6, 4]),
      ],
    );

    if (!_hasOhlc) {
      final spots = [
        for (var i = 0; i < closes.length; i++) FlSpot(i.toDouble(), closes[i]),
      ];
      return LineChart(
        LineChartData(
          minY: plotMinY,
          maxY: plotMaxY,
          gridData: const FlGridData(show: true, drawVerticalLine: false),
          titlesData: _titlesData(showLeftLabels: true),
          borderData: borderData,
          extraLinesData: extraLines,
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipItems: (spots) => spots
                  .map((s) => LineTooltipItem(s.y.toStringAsFixed(4), const TextStyle(color: Colors.white)))
                  .toList(),
            ),
          ),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: true,
              curveSmoothness: 0.15,
              color: color,
              barWidth: 2.5,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(show: true, color: color.withValues(alpha: 0.1)),
            ),
          ],
        ),
      );
    }

    final candleSpots = [
      for (var i = 0; i < closes.length; i++)
        CandlestickSpot(x: i.toDouble(), open: opens![i], high: highs![i], low: lows![i], close: closes[i]),
    ];

    // Reference lines drawn as thin RangeAnnotations directly on the
    // candlestick chart itself, rather than a second overlaid chart widget -
    // after two real bugs from the Stack-of-two-charts approach (fl_chart's
    // LineChartPainter never draws extraLinesData with an empty/hidden
    // lineBarsData, and even once fixed, a loosely-sized Stack let the two
    // charts scale independently and misalign), this is structurally
    // guaranteed to line up: it's the SAME chart instance/coordinate system
    // as the candles, not a second one that has to match it. The trade-off
    // is a solid thin band instead of a dashed line - RangeAnnotations has
    // no dash pattern - a fine trade for something that's actually reliable.
    final thickness = (plotMaxY - plotMinY) * 0.003;
    final rangeAnnotations = RangeAnnotations(
      horizontalRangeAnnotations: [
        for (final l in levelLines)
          HorizontalRangeAnnotation(y1: l.value - thickness, y2: l.value + thickness, color: l.color),
      ],
    );

    return CandlestickChart(
      CandlestickChartData(
        minY: plotMinY,
        maxY: plotMaxY,
        candlestickSpots: candleSpots,
        gridData: const FlGridData(show: true, drawVerticalLine: false),
        titlesData: _titlesData(showLeftLabels: true),
        borderData: borderData,
        rangeAnnotations: rangeAnnotations,
        // Default painter's own up/down colors (green/red) are already the
        // standard convention and deliberately distinct from the amber
        // entry / blue VWAP / purple band line colors, so candles and
        // reference lines read as two separate visual layers with no
        // custom painter needed.
      ),
    );
  }
}
