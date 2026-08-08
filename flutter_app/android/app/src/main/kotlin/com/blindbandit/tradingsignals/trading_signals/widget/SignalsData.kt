package com.blindbandit.tradingsignals.trading_signals.widget

import org.json.JSONArray

/** Shared between the Glance widget (SignalsWidget.kt) and the bubble content
 * screen (bubble/BubbleContentActivity.kt) - both read the exact same
 * signals_json/last_refreshed data saved by widget_service.dart's
 * refreshWidget(), so the parsing/formatting logic lives here once rather
 * than being duplicated across two native surfaces. */
data class SignalRow(val ticker: String, val signal: String)

object SignalsData {
    /** Best-effort parse - a malformed/missing value just yields an empty
     * list rather than crashing either surface's render pass. */
    fun parseSignals(json: String?): List<SignalRow> {
        if (json.isNullOrBlank()) return emptyList()
        return try {
            val arr = JSONArray(json)
            (0 until arr.length()).map { i ->
                val obj = arr.getJSONObject(i)
                SignalRow(obj.getString("ticker"), obj.getString("signal"))
            }
        } catch (_: Exception) {
            emptyList()
        }
    }

    /** Plain ARGB Int rather than a Compose Color - usable as-is by a
     * classic View's setTextColor() (bubble) and wrapped in Color(...) by
     * Glance's TextStyle (widget), so neither surface needs a dependency
     * the other doesn't already have. */
    fun colorFor(signal: String): Int = when (signal) {
        "buy" -> 0xFF4CAF50.toInt()
        "sell" -> 0xFFF44336.toInt()
        else -> 0xFF9E9E9E.toInt()
    }

    /** Best-effort "Updated Xm ago" from an ISO-8601 timestamp - a parse
     * failure or missing value just shows nothing rather than crashing. */
    fun relativeTime(iso: String?): String {
        if (iso.isNullOrBlank()) return ""
        return try {
            val instant = java.time.Instant.parse(iso)
            val minutes = java.time.Duration.between(instant, java.time.Instant.now()).toMinutes()
            when {
                minutes < 1 -> "Updated just now"
                minutes < 60 -> "Updated ${minutes}m ago"
                else -> "Updated ${minutes / 60}h ago"
            }
        } catch (_: Exception) {
            ""
        }
    }
}
