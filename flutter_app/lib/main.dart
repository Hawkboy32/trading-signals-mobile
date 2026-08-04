import 'package:flutter/material.dart';

import 'screens/signal_list_screen.dart';

void main() {
  runApp(const TradingSignalsApp());
}

class TradingSignalsApp extends StatelessWidget {
  const TradingSignalsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Trading Signals',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const SignalListScreen(),
    );
  }
}
