package com.blindbandit.tradingsignals.trading_signals.widget

import es.antonborri.home_widget.HomeWidgetGlanceWidgetReceiver

/** Thin registration shim - the standard pattern from home_widget's own
 * docs/example, does no work of its own beyond pointing at the widget. */
class SignalsWidgetReceiver : HomeWidgetGlanceWidgetReceiver<SignalsWidget>() {
    override val glanceAppWidget = SignalsWidget()
}
