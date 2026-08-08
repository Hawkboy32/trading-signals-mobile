package com.blindbandit.tradingsignals.trading_signals

import com.blindbandit.tradingsignals.trading_signals.bubble.BubbleTrigger
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

private const val BUBBLE_CHANNEL = "trading_signals/bubble"

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BUBBLE_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "showBubble") {
                BubbleTrigger.show(applicationContext)
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
    }
}
