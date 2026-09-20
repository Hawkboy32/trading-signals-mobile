import 'dart:async';
import 'package:flutter/material.dart';

import '../models/signal.dart';
import '../services/auth_client.dart';
import '../services/widget_service.dart';
import '../widgets/password_confirm_dialog.dart';
import 'bot_control_screen.dart';
import 'login_screen.dart';
import 'positions_screen.dart';
import 'roster_health_screen.dart';
import 'settings_screen.dart';
import 'signal_detail_screen.dart';
import 'tax_screen.dart';
import 'trade_history_screen.dart';
import 'trading_hours_screen.dart';

const _pollInterval = Duration(seconds: 60);

class SignalListScreen extends StatefulWidget {
  const SignalListScreen({super.key});

  @override
  State<SignalListScreen> createState() => _SignalListScreenState();
}

class _SignalListScreenState extends State<SignalListScreen> {
  SignalsResponse? _data;
  String? _error;
  bool _loading = true;
  Timer? _timer;
  Map<String, dynamic>? _controlState;
  bool _controlActionInFlight = false;

  @override
  void initState() {
    super.initState();
    _refresh();
    _refreshControlState();
    _timer = Timer.periodic(_pollInterval, (_) {
      _refresh();
      _refreshControlState();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      // refreshWidget() does the actual fetch AND pushes the same data to
      // the home-screen widget - one network call serves both.
      final data = await refreshWidget();
      if (data == null) throw Exception('refresh failed');
      if (!mounted) return;
      setState(() {
        _data = data;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      // Shows the REAL exception when we have one (lastSignalsFetchError,
      // set inside refreshWidget()'s own catch - see that file's doc
      // comment) rather than always the same generic text regardless of
      // cause - added 2026-08-24 after a real report where "Could not
      // reach backend" turned out unhelpful for telling a genuine network
      // failure apart from something else (e.g. a slow connection timing
      // out, or a response the app failed to parse) that shows the exact
      // same symptom to the user otherwise.
      final detail = lastSignalsFetchError;
      setState(() {
        _error = detail != null
            ? 'Could not reach backend - check Settings.\n\n($detail)'
            : 'Could not reach backend - check Settings.';
        _loading = false;
      });
    }
  }

  Future<void> _refreshControlState() async {
    final state = await AuthClient.fetchControlState();
    if (!mounted || state == null) return;
    setState(() => _controlState = state);
  }

  bool get _isArmed =>
      (_controlState?['enabled'] ?? false) &&
      !(_controlState?['killed'] ?? false);

  /// Stop/re-arm entry point: ensures a login first (if needed), then always
  /// requires the password fresh in THIS dialog even if already logged in -
  /// a standing session alone is never enough to trigger the action, only to
  /// unlock being asked for the password. Guards against a fat-fingered tap
  /// either way.
  Future<void> _handleControlTap() async {
    if (!await AuthClient.isLoggedIn()) {
      if (!mounted) return;
      final loggedIn = await Navigator.of(
        context,
      ).push<bool>(MaterialPageRoute(builder: (_) => const LoginScreen()));
      if (loggedIn != true) return;
    }
    if (!mounted) return;

    final armed = _isArmed;
    final password = await showPasswordConfirmDialog(
      context: context,
      title: armed ? 'Stop trading?' : 'Re-arm trading?',
      message: armed
          ? 'This immediately stops the bot from opening or managing any new trades. '
                'Enter your password to confirm.'
          : 'This resumes live trading on the account(s) already configured on the desktop. '
                'Enter your password to confirm.',
      confirmLabel: armed ? 'Stop trading' : 'Re-arm trading',
      isDestructive: armed,
    );
    if (password == null || !mounted) return;

    setState(() => _controlActionInFlight = true);
    try {
      if (armed) {
        await AuthClient.stopTrading(password);
      } else {
        await AuthClient.rearmTrading(password);
      }
      await _refreshControlState();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(armed ? 'Trading stopped.' : 'Trading re-armed.'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString()), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _controlActionInFlight = false);
    }
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chopper'),
        // Horizontally scrollable, not a plain actions list - 8 icons no
        // longer fit AppBar's fixed-width actions row on a normal phone
        // width (they were starting to run off-screen on the right).
        // AppBar.actions itself doesn't scroll or wrap, so this wraps the
        // whole icon row in its own SingleChildScrollView instead - same
        // icons, same order, same behavior, just swipeable when they don't
        // all fit.
        //
        // Real bug found on-device 2026-08-24: a bare SingleChildScrollView
        // here didn't scroll at all - AppBar lays out actions in a Row with
        // mainAxisSize.min (unconstrained/intrinsic width), so the scroll
        // view never got a BOUNDED width to scroll within and just rendered
        // at its full natural content width instead, identical to before.
        // The SizedBox below gives it an explicit width so there's genuine
        // overflow to scroll through - deliberately less than all 8 icons'
        // combined width (~48dp each) so scrolling is actually exercised,
        // not just theoretically wired up.
        actions: [
          SizedBox(
            width: 216,
            child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
          IconButton(
            icon: _controlActionInFlight
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    Icons.power_settings_new,
                    color: _controlState == null
                        ? Colors.grey
                        : (_isArmed ? Colors.green : Colors.red),
                  ),
            tooltip: _controlState == null
                ? 'Trading status unknown'
                : (_isArmed ? 'Stop trading' : 'Re-arm trading'),
            onPressed: _controlActionInFlight ? null : _handleControlTap,
          ),
          IconButton(
            icon: const Icon(Icons.account_balance_wallet),
            tooltip: 'Account details',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PositionsScreen()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'Trade history',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const TradeHistoryScreen()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.insights),
            tooltip: 'Roster health',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const RosterHealthScreen()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.schedule),
            tooltip: 'Trading hours',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const TradingHoursScreen()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.receipt_long),
            tooltip: 'Tax (GBP estimate)',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const TaxScreen()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: 'Bot control',
            onPressed: () async {
              await Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const BotControlScreen()));
              _refreshControlState();
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () async {
              await Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
              _refresh();
            },
          ),
            ]),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(onRefresh: _refresh, child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return ListView(
        children: [
          const SizedBox(height: 80),
          Icon(Icons.cloud_off, size: 48, color: Colors.grey[400]),
          const SizedBox(height: 12),
          Center(
            child: Text(_error!, style: const TextStyle(color: Colors.grey)),
          ),
        ],
      );
    }
    final signals = _data?.signals ?? [];
    if (signals.isEmpty) {
      return ListView(
        children: const [
          SizedBox(height: 80),
          Center(
            child: Text(
              'No combos configured yet.',
              style: TextStyle(color: Colors.grey),
            ),
          ),
        ],
      );
    }

    // Market Open first, then Market Closed, then Unknown (no account
    // currently trades that ticker's asset class - rare, but shown rather
    // than silently dropped) - per the user's own framing: "top of the list
    // market open... below market closed".
    final open = signals.where((s) => s.marketOpen == true).toList();
    final closed = signals.where((s) => s.marketOpen == false).toList();
    final unknown = signals.where((s) => s.marketOpen == null).toList();

    final items = <_ListItem>[
      if (open.isNotEmpty) _ListItem.header('Market Open'),
      ...open.map(_ListItem.signal),
      if (closed.isNotEmpty) _ListItem.header('Market Closed'),
      ...closed.map(_ListItem.signal),
      if (unknown.isNotEmpty) _ListItem.header('Unknown'),
      ...unknown.map(_ListItem.signal),
    ];

    return ListView.builder(
      padding: EdgeInsets.fromLTRB(8, 8, 8, 24 + MediaQuery.of(context).padding.bottom),
      itemCount: items.length + 1,
      itemBuilder: (context, index) {
        if (index == items.length) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: Text(
                _data?.lastRefreshed != null
                    ? 'Last refreshed: ${_data!.lastRefreshed}'
                    : '',
                style: const TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ),
          );
        }
        final item = items[index];
        if (item.isHeader) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
            child: Text(
              item.header!,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: Colors.grey[600],
                letterSpacing: 0.5,
              ),
            ),
          );
        }
        return _SignalCard(signal: item.signal!);
      },
    );
  }
}

/// Flat representation of the grouped list - either a section header or a
/// signal card - so ListView.builder can walk one simple indexed list rather
/// than juggling per-group index math directly in itemBuilder.
class _ListItem {
  final String? header;
  final TradingSignal? signal;

  _ListItem._(this.header, this.signal);

  factory _ListItem.header(String text) => _ListItem._(text, null);
  factory _ListItem.signal(TradingSignal signal) => _ListItem._(null, signal);

  bool get isHeader => header != null;
}

class _SignalCard extends StatelessWidget {
  final TradingSignal signal;

  const _SignalCard({required this.signal});

  Color get _badgeColor {
    switch (signal.signal) {
      case 'buy':
        return Colors.green;
      case 'sell':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  /// "as of Xm ago" from computedAt, or null if unparseable/blank. A rough,
  /// no-dependency freshness readout - the actual staleness policy lives
  /// backend-side (see signal_service.SNAPSHOT_STALE_SECONDS); this is just
  /// so the user can SEE how current a card is, e.g. spotting the same
  /// frozen-close bug that motivated this whole detail pass in the first
  /// place (see backtester's CLAUDE_NOTES.txt).
  String? _freshnessLabel() {
    if (signal.computedAt.isEmpty) return null;
    final ts = DateTime.tryParse(signal.computedAt);
    if (ts == null) return null;
    final age = DateTime.now().toUtc().difference(ts.toUtc());
    if (age.inSeconds < 0) return 'just now';
    if (age.inMinutes < 1) return '${age.inSeconds}s ago';
    if (age.inHours < 1) return '${age.inMinutes}m ago';
    return '${age.inHours}h ${age.inMinutes % 60}m ago';
  }

  bool get _isStale {
    if (signal.computedAt.isEmpty) return false;
    final ts = DateTime.tryParse(signal.computedAt);
    if (ts == null) return false;
    return DateTime.now().toUtc().difference(ts.toUtc()).inMinutes >= 5;
  }

  /// Turns the strategy's raw levels map into a short, ordered, human-readable
  /// line - covers the two currently-live strategies (VWAP MR, Bollinger MR)
  /// by key name, falls back to a generic "key: value" join for anything else
  /// so a future strategy's levels() still shows SOMETHING without a UI change.
  String _levelsLine(Map<String, double> levels) {
    if (levels.containsKey('vwap')) {
      final vwap = levels['vwap']!.toStringAsFixed(4);
      final dev = levels['deviation_pct']?.toStringAsFixed(2);
      final thresh = levels['entry_threshold_pct']?.toStringAsFixed(2);
      return 'VWAP $vwap  ·  dev ${dev ?? '?'}% (entry at $thresh%)';
    }
    if (levels.containsKey('lower') && levels.containsKey('upper')) {
      final lower = levels['lower']!.toStringAsFixed(4);
      final mid = levels['mid']?.toStringAsFixed(4);
      final upper = levels['upper']!.toStringAsFixed(4);
      return 'Bands $lower — $upper  (mid $mid)';
    }
    return levels.entries
        .map((e) => '${e.key}: ${e.value.toStringAsFixed(4)}')
        .join('  ·  ');
  }

  @override
  Widget build(BuildContext context) {
    final conviction = signal.conviction;
    final freshness = _freshnessLabel();
    final closes = signal.recentCloses;
    final levels = signal.levels;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: InkWell(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => SignalDetailScreen(signal: signal),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          signal.ticker,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          signal.strategyName,
                          style: TextStyle(
                            color: Colors.grey[600],
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
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
              const SizedBox(height: 10),
              if (closes != null && closes.length >= 2) ...[
                SizedBox(
                  height: 36,
                  width: double.infinity,
                  child: _Sparkline(values: closes, color: _badgeColor),
                ),
                const SizedBox(height: 6),
              ],
              Row(
                children: [
                  Text(
                    signal.signal == 'hold'
                        ? 'Price: ${signal.price.toStringAsFixed(4)}'
                        : '${signal.signal == 'buy' ? 'Would buy' : 'Would sell'} near ${signal.price.toStringAsFixed(4)}',
                    style: const TextStyle(fontSize: 13),
                  ),
                  const Spacer(),
                  if (conviction != null)
                    Text(
                      'Conviction: ${(conviction * 100).toStringAsFixed(0)}%',
                      style: const TextStyle(fontSize: 13),
                    ),
                ],
              ),
              if (conviction != null) ...[
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: conviction,
                    minHeight: 6,
                    backgroundColor: Colors.grey[300],
                    valueColor: AlwaysStoppedAnimation<Color>(_badgeColor),
                  ),
                ),
              ],
              if (levels != null && levels.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  _levelsLine(levels),
                  style: TextStyle(color: Colors.grey[700], fontSize: 12),
                ),
              ],
              if (freshness != null || signal.source != null) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    if (freshness != null)
                      Icon(
                        Icons.access_time,
                        size: 12,
                        color: _isStale ? Colors.orange : Colors.grey[500],
                      ),
                    if (freshness != null) const SizedBox(width: 3),
                    if (freshness != null)
                      Text(
                        freshness,
                        style: TextStyle(
                          fontSize: 11,
                          color: _isStale ? Colors.orange : Colors.grey[500],
                        ),
                      ),
                    if (freshness != null && signal.source != null)
                      const SizedBox(width: 10),
                    if (signal.source != null)
                      Text(
                        signal.source!,
                        style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                      ),
                  ],
                ),
              ],
              if (signal.tradingAccounts != null &&
                  signal.tradingAccounts!.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  'Trades on: ${signal.tradingAccounts!.join(', ')}',
                  style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                ),
              ],
              if (signal.error != null) ...[
                const SizedBox(height: 6),
                Text(
                  signal.error!,
                  style: const TextStyle(color: Colors.orange, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Minimal dependency-free line-chart of recent closes, so a glance at a
/// card shows what price action the strategy is actually reacting to - no
/// chart package needed for a single trend line.
class _Sparkline extends StatelessWidget {
  final List<double> values;
  final Color color;

  const _Sparkline({required this.values, required this.color});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _SparklinePainter(values: values, color: color),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  final List<double> values;
  final Color color;

  _SparklinePainter({required this.values, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final minV = values.reduce((a, b) => a < b ? a : b);
    final maxV = values.reduce((a, b) => a > b ? a : b);
    final range = (maxV - minV).abs() < 1e-9 ? 1.0 : (maxV - minV);

    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = size.width * i / (values.length - 1);
      final y = size.height - ((values[i] - minV) / range) * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter oldDelegate) =>
      oldDelegate.values != values || oldDelegate.color != color;
}
