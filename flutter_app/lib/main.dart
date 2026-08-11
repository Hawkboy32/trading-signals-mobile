import 'package:flutter/material.dart';
import 'package:workmanager/workmanager.dart';

import 'screens/signal_list_screen.dart';
import 'services/widget_service.dart';

const String _widgetRefreshTask = 'widgetBackgroundRefresh';

/// Entry point WorkManager invokes in a background isolate - marked as a VM
/// entry-point so it survives being called while the app process itself
/// isn't running (the whole reason a background task is needed at all: the
/// widget must stay roughly fresh even when the app is closed).
@pragma('vm:entry-point')
void _callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (task == _widgetRefreshTask) {
      await refreshWidget();
    }
    return Future.value(true);
  });
}

void main() {
  // Workmanager's plugin calls go over a platform channel, which needs the
  // binding initialized first - calling these before ensureInitialized()
  // throws "Binding has not yet been initialized" (caught by the error zone,
  // non-fatal, but the periodic task silently never registers).
  WidgetsFlutterBinding.ensureInitialized();
  Workmanager().initialize(_callbackDispatcher);
  // 15 minutes is Android's practical floor for periodic background work -
  // not a number chosen for convenience, see Mobile_App/CLAUDE_NOTES.txt.
  Workmanager().registerPeriodicTask(
    _widgetRefreshTask,
    _widgetRefreshTask,
    frequency: const Duration(minutes: 15),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
  );
  runApp(const TradingSignalsApp());
}

class TradingSignalsApp extends StatelessWidget {
  const TradingSignalsApp({super.key});

  @override
  Widget build(BuildContext context) {
    // "Holotable"/"Datapad" theme: hologram blue + a warm gold secondary,
    // for no reason other than the user wanted a Star Wars-ish palette to
    // match the rename. Same seed hues as the widget's own colors
    // (SignalsWidget.kt) and the backtester dashboard's .streamlit/config.toml,
    // kept in sync across all three surfaces deliberately.
    const hologramBlue = Color(0xFF3DC7F0);
    const warmGold = Color(0xFFE0A94A);
    return MaterialApp(
      title: 'Trading Signals',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: hologramBlue,
          secondary: warmGold,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: hologramBlue,
          secondary: warmGold,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const SignalListScreen(),
    );
  }
}
