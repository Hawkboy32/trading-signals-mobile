package com.blindbandit.tradingsignals.trading_signals.widget

import android.content.Context
import android.content.Intent
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.color.ColorProvider
import androidx.glance.currentState
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.padding
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import es.antonborri.home_widget.HomeWidgetGlanceState
import es.antonborri.home_widget.HomeWidgetGlanceStateDefinition

import com.blindbandit.tradingsignals.trading_signals.MainActivity

/** ColorProvider in this Glance version always needs both day/night values -
 * this widget doesn't do day/night theming, so both are just the same
 * fixed color (a deliberate simplification, not a bug). */
private fun solidColor(color: Color) = ColorProvider(day = color, night = color)

/**
 * Home-screen widget: a compact list of the same combos the app itself
 * shows (see signal_list_screen.dart), just condensed - ticker + a
 * color-coded signal word, no price/conviction (not enough space, and
 * that detail is one tap away by opening the app). Data comes from
 * signals_json, written by widget_service.dart's refreshWidget() - this
 * class only ever READS the last value that was saved; it never fetches
 * anything itself (Glance widgets can't make network calls directly).
 * Parsing/formatting is shared with the bubble content screen via
 * SignalsData.kt, since both read the exact same saved keys.
 */
class SignalsWidget : GlanceAppWidget() {

    override val stateDefinition = HomeWidgetGlanceStateDefinition()

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        provideContent {
            WidgetContent(context, currentState<HomeWidgetGlanceState>())
        }
    }

    @Composable
    private fun WidgetContent(context: Context, state: HomeWidgetGlanceState) {
        val rows = SignalsData.parseSignals(state.preferences.getString("signals_json", null))
        val lastRefreshed = state.preferences.getString("last_refreshed", null)
        val botKilled = state.preferences.getBoolean("bot_killed", false)
        val positionsAvailable = state.preferences.getBoolean("positions_available", false)
        val openCount = state.preferences.getInt("open_positions_count", 0)
        val openPnl = state.preferences.getFloat("open_positions_pnl", 0f).toDouble()

        Column(
            modifier = GlanceModifier
                .fillMaxWidth()
                .background(Color(0xFF1C1B1F))
                .padding(12.dp)
                .clickable(actionStartActivity(Intent(context, MainActivity::class.java))),
        ) {
            Row(modifier = GlanceModifier.fillMaxWidth()) {
                Text(
                    text = "Trading Signals",
                    style = TextStyle(color = solidColor(Color.White), fontWeight = FontWeight.Bold, fontSize = 14.sp),
                )
                if (botKilled) {
                    Text(
                        text = "  STOPPED",
                        style = TextStyle(color = solidColor(Color(0xFFF44336)), fontWeight = FontWeight.Bold, fontSize = 12.sp),
                    )
                }
            }
            if (rows.isEmpty()) {
                Text(
                    text = "No data yet - open the app",
                    style = TextStyle(color = solidColor(Color.LightGray), fontSize = 12.sp),
                )
            } else {
                rows.take(4).forEach { row ->
                    Row(modifier = GlanceModifier.fillMaxWidth().padding(top = 6.dp)) {
                        Text(
                            text = row.ticker,
                            style = TextStyle(color = solidColor(Color.White), fontSize = 13.sp),
                        )
                        Text(
                            text = "  ${row.signal.uppercase()}",
                            style = TextStyle(
                                color = solidColor(Color(SignalsData.colorFor(row.signal))),
                                fontWeight = FontWeight.Bold,
                                fontSize = 13.sp,
                            ),
                        )
                    }
                }
            }
            if (positionsAvailable) {
                val pnlSign = if (openPnl >= 0) "+" else ""
                Text(
                    text = "$openCount open · $pnlSign${"%.2f".format(openPnl)}",
                    style = TextStyle(
                        color = solidColor(if (openPnl >= 0) Color(0xFF4CAF50) else Color(0xFFF44336)),
                        fontSize = 12.sp,
                    ),
                    modifier = GlanceModifier.padding(top = 8.dp),
                )
            }
            Text(
                text = SignalsData.relativeTime(lastRefreshed),
                style = TextStyle(color = solidColor(Color.Gray), fontSize = 10.sp),
                modifier = GlanceModifier.padding(top = 6.dp),
            )
        }
    }
}
