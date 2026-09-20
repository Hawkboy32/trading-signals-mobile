import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../models/bars.dart';
import '../models/signal.dart';
import '../services/api_client.dart';
import '../services/auth_client.dart';

/// The bigger, tap-through view of a signal card's sparkline - by default the
/// same `recentCloses` data (no new backend call for the price line itself),
/// drawn as a proper chart with the strategy's own reference levels (VWAP,
/// or the Bollinger bands) overlaid as horizontal lines, and real axis
/// labels.
///
/// A 1m/5m/15m granularity toggle (2026-08-25) sits above the chart. 1m is the
/// default and costs nothing extra (it's the data the signal already
/// carries, and the granularity the strategies genuinely evaluate on);
/// picking 5m or 15m fetches from the backend's /bars endpoint, which resolves
/// through the same live-broker chain as everything else. Switching swaps
/// all four OHLC arrays together, never mixing granularities.
///
/// Bars have no per-point timestamp (only the LAST bar's
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

  /// Selected candle granularity, in minutes. 1 is the default because the
  /// signal already CARRIES 1-minute bars (recentCloses etc.) - opening this
  /// screen costs no extra network call at all, and only switching to a
  /// coarser bar fetches anything. Also the honest default: 1m is the granularity the
  /// strategies themselves actually evaluate on, so it's what the signal
  /// badge and levels above the chart genuinely correspond to.
  int _granularityMinutes = 1;
  BarSeries? _fetchedBars; // non-null only once a non-default granularity loaded
  bool _loadingBars = false;
  String? _barsError;

  @override
  void initState() {
    super.initState();
    _loadEntryLines();
  }

  Future<void> _selectGranularity(int minutes) async {
    if (minutes == _granularityMinutes && (minutes == 1 || _fetchedBars != null)) {
      return; // already showing this, and not in a failed state worth retrying
    }
    setState(() {
      _granularityMinutes = minutes;
      _barsError = null;
    });
    if (minutes == 1) {
      // Back to the signal's own bundled bars - no fetch needed.
      setState(() => _fetchedBars = null);
      return;
    }
    setState(() => _loadingBars = true);
    try {
      final series = await ApiClient.fetchBars(
        widget.signal.ticker, multiplier: minutes, timespan: 'minute',
      );
      if (!mounted) return;
      setState(() {
        _fetchedBars = series;
        _loadingBars = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingBars = false;
        _barsError = e.toString();
      });
    }
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
          // avgEntryPrice == 0.0 means "unknown", not "entered at $0" - some
          // brokers (Kraken) have no cost-basis field at all and always
          // report 0.0 there (see kraken.py's get_positions() docstring).
          // Drawing that as a real entry line would both mislabel it and
          // wreck the chart's y-axis autoscale below by dragging minY to 0.
          if (position.ticker == widget.signal.ticker && position.avgEntryPrice > 0) {
            lines.add(
              _LevelLine(
                // "LIVE" spelled out, not left to the nickname: the real
                // account names are actively misleading about this
                // ("MyAlpaca" is paper, "AlpacaLive" is live), and this line
                // marks where real money went in.
                account.isPaper
                    ? 'Entry ${account.nickname}'
                    : 'Entry ${account.nickname} (LIVE)',
                position.avgEntryPrice,
                _entryLineColor(account.isPaper),
              ),
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
    // At 1m the signal's own bundled bars are used verbatim; at any other
    // granularity the freshly fetched series replaces all four OHLC arrays
    // together (never mixed - a close from one granularity against a high
    // from another would be silently wrong).
    final series = _fetchedBars;
    final usingFetched = series != null && _granularityMinutes != 1;
    final closes = usingFetched ? series.closes : (signal.recentCloses ?? []);
    final opens = usingFetched ? series.opens : signal.recentOpens;
    final highs = usingFetched ? series.highs : signal.recentHighs;
    final lows = usingFetched ? series.lows : signal.recentLows;
    final barsSource = usingFetched ? series.source : signal.source;
    final barsComputedAt = usingFetched ? series.computedAt : signal.computedAt;
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
            const SizedBox(height: 16),
            Row(
              children: [
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 1, label: Text('1m')),
                    ButtonSegment(value: 5, label: Text('5m')),
                    ButtonSegment(value: 15, label: Text('15m')),
                  ],
                  selected: {_granularityMinutes},
                  onSelectionChanged: _loadingBars
                      ? null
                      : (selected) => _selectGranularity(selected.first),
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
                if (_loadingBars) ...[
                  const SizedBox(width: 12),
                  const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 16),
            if (_barsError != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Column(
                  children: [
                    Text(
                      'Could not load ${_granularityMinutes}m bars.',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _barsError!,
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: () => _selectGranularity(_granularityMinutes),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              )
            else if (closes.length >= 2)
              SizedBox(
                height: 320,
                child: _DetailChart(
                  closes: closes,
                  color: _badgeColor,
                  levelLines: levelLines,
                  opens: opens,
                  highs: highs,
                  lows: lows,
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
              'Last ${closes.length} × ${_granularityMinutes}m bars · oldest to '
              'newest, left to right. Latest bar $barsComputedAt.',
              style: TextStyle(fontSize: 11, color: Colors.grey[500]),
            ),
            if (barsSource != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  barsSource,
                  style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                ),
              ),
            // The strategy evaluates on 1-minute bars, so the signal badge,
            // conviction and every reference level above were all computed
            // from 1m data. They stay valid as PRICE levels on a 5m chart
            // (a price is a price), but the candles no longer match the
            // granularity the decision was actually made on - said plainly
            // rather than left for the user to infer.
            if (_granularityMinutes != 1)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Signal, conviction and levels are computed on 1m bars - '
                  'only the candles above are ${_granularityMinutes}m.',
                  style: TextStyle(fontSize: 11, color: Colors.amber[700]),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Entry-line colour by account type. The same ticker is usually held on
/// several accounts at DIFFERENT average entry prices, so the chart can show
/// several entry lines at once - without this they were all one colour and
/// you couldn't tell which line was real money. Amber (live) deliberately
/// carries more visual weight than grey (paper); grey is also kept clear of
/// the band/VWAP colours below so nothing reads as a strategy level.
Color _entryLineColor(bool isPaper) => isPaper ? Colors.blueGrey.shade300 : Colors.amber;

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
