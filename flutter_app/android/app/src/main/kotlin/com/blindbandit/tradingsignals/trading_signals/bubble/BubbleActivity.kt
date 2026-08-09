package com.blindbandit.tradingsignals.trading_signals.bubble

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

import com.blindbandit.tradingsignals.trading_signals.MainActivity
import com.blindbandit.tradingsignals.trading_signals.widget.SignalsData
import es.antonborri.home_widget.HomeWidgetPlugin

/**
 * Bubble content: the real trimmed signal list, replacing the earlier
 * "Bubble spike OK" placeholder now that the spike (see
 * Mobile_App/CLAUDE_NOTES.txt's "floating chat-head bubble" entry) confirmed
 * bubbles actually work on this app/device once the conversation is marked
 * Priority. Deliberately plain native Views, not an embedded Flutter view -
 * a bubble is a small, short-lived popup, so pulling in a full Flutter
 * engine here would be a lot of weight for a read-only list Flutter's own
 * widget_service.dart already keeps in sync.
 *
 * Reads the exact same signals_json/last_refreshed/bot_killed/positions data
 * the home-screen widget renders (SignalsData.kt, shared) straight out of
 * HomeWidgetPlugin's own SharedPreferences - no separate fetch, no new data
 * path. Like the widget, this is a snapshot of the last synced data, not a
 * live connection: opening the bubble doesn't trigger a network call.
 */
class BubbleActivity : Activity() {

    private fun Int.toPx(): Int = (this * resources.displayMetrics.density).toInt()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val prefs = HomeWidgetPlugin.getData(this)
        val rows = SignalsData.parseSignals(prefs.getString("signals_json", null))
        val lastRefreshed = prefs.getString("last_refreshed", null)
        val botKilled = prefs.getBoolean("bot_killed", false)
        val positionsAvailable = prefs.getBoolean("positions_available", false)
        val openCount = prefs.getInt("open_positions_count", 0)
        val openPnl = SignalsData.readDouble(prefs, "open_positions_pnl")

        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24.toPx(), 20.toPx(), 24.toPx(), 20.toPx())
            setBackgroundColor(Color.parseColor("#0B0E14")) // matches the widget/dashboard/app theme
        }

        val titleRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        titleRow.addView(TextView(this).apply {
            text = "Trading Signals"
            setTextColor(Color.parseColor("#3DC7F0"))
            textSize = 16f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
        })
        if (botKilled) {
            titleRow.addView(TextView(this).apply {
                text = "  STOPPED"
                setTextColor(SignalsData.colorFor("sell"))
                textSize = 14f
                setTypeface(typeface, android.graphics.Typeface.BOLD)
            })
        }
        content.addView(titleRow)

        if (rows.isEmpty()) {
            content.addView(TextView(this).apply {
                text = "No data yet - open the app"
                setTextColor(Color.LTGRAY)
                textSize = 13f
                setPadding(0, 12.toPx(), 0, 0)
            })
        } else {
            rows.forEach { row ->
                val rowView = LinearLayout(this).apply {
                    orientation = LinearLayout.HORIZONTAL
                    setPadding(0, 8.toPx(), 0, 0)
                }
                rowView.addView(TextView(this).apply {
                    text = row.ticker
                    setTextColor(Color.WHITE)
                    textSize = 14f
                })
                rowView.addView(TextView(this).apply {
                    text = "  ${row.signal.uppercase()}"
                    setTextColor(SignalsData.colorFor(row.signal))
                    textSize = 14f
                    setTypeface(typeface, android.graphics.Typeface.BOLD)
                })
                content.addView(rowView)
            }
        }

        if (positionsAvailable) {
            val pnlSign = if (openPnl >= 0) "+" else ""
            content.addView(TextView(this).apply {
                text = "$openCount open · $pnlSign${"%.2f".format(openPnl)}"
                setTextColor(SignalsData.colorFor(if (openPnl >= 0) "buy" else "sell"))
                textSize = 13f
                setPadding(0, 16.toPx(), 0, 0)
            })
        }

        content.addView(TextView(this).apply {
            text = SignalsData.relativeTime(lastRefreshed)
            setTextColor(Color.GRAY)
            textSize = 11f
            setPadding(0, 10.toPx(), 0, 0)
        })

        content.addView(TextView(this).apply {
            text = "Open app"
            setTextColor(Color.parseColor("#8AB4F8"))
            textSize = 13f
            setPadding(0, 20.toPx(), 0, 0)
            setOnClickListener { startActivity(Intent(this@BubbleActivity, MainActivity::class.java)) }
        })

        val scroll = ScrollView(this).apply {
            setBackgroundColor(Color.parseColor("#0B0E14")) // matches the widget/dashboard/app theme
            addView(content)
        }
        setContentView(scroll)
    }
}
