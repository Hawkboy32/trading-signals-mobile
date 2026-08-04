import 'package:flutter_test/flutter_test.dart';

import 'package:trading_signals/main.dart';

void main() {
  testWidgets('App builds and shows the Trading Signals title', (WidgetTester tester) async {
    await tester.pumpWidget(const TradingSignalsApp());
    await tester.pump();

    expect(find.text('Trading Signals'), findsOneWidget);
  });
}
