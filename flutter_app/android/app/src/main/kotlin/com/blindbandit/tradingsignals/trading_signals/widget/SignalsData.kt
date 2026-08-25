package com.blindbandit.tradingsignals.trading_signals.widget

import android.content.SharedPreferences
import org.json.JSONArray

/** Shared between the Glance widget (SignalsWidget.kt) and the bubble content
 * screen (bubble/BubbleContentActivity.kt) - both read the exact same
 * signals_json/last_refreshed data saved by widget_service.dart's
 * refreshWidget(), so the parsing/formatting logic lives here once rather
 * than being duplicated across two native surfaces.
 *
 * price: added 2026-08-17 HUD redesign - optional (0.0 default) so an
 * older cached signals_json blob (written before this field existed, still
 * possible right after an app update until the next refresh) parses fine
 * rather than crashing the widget's whole render pass. */
data class SignalRow(val ticker: String, val signal: String, val price: Double = 0.0)

object SignalsData {
    /** Best-effort parse - a malformed/missing value just yields an empty
     * list rather than crashing either surface's render pass. */
    fun parseSignals(json: String?): List<SignalRow> {
        if (json.isNullOrBlank()) return emptyList()
        return try {
            val arr = JSONArray(json)
            (0 until arr.length()).map { i ->
                val obj = arr.getJSONObject(i)
                SignalRow(
                    obj.getString("ticker"),
                    obj.getString("signal"),
                    obj.optDouble("price", 0.0),
                )
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

    /** home_widget's own plugin (HomeWidgetPlugin.kt) stores a Dart `double`
     * as a raw bit-encoded Long (`Double.doubleToRawLongBits`), NOT as a
     * Float - reading a double-backed key with getFloat() throws a
     * ClassCastException that crashes the widget's whole render pass (the
     * real cause of "can't show content" found 2026-08-09). Every value
     * widget_service.dart saves with HomeWidget.saveWidgetData<double>
     * MUST be read through this, not getFloat(). */
    fun readDouble(prefs: SharedPreferences, key: String): Double {
        return try {
            java.lang.Double.longBitsToDouble(prefs.getLong(key, 0L))
        } catch (_: Exception) {
            0.0
        }
    }

    /** Defensive wrappers for every OTHER prefs type the widget reads
     * (2026-08-17) - a single wrong-type read anywhere in WidgetContent()
     * throws a ClassCastException that kills the ENTIRE Compose render pass,
     * and because RemoteViews updates are atomic, Android just silently
     * keeps showing whatever the widget last rendered successfully instead
     * of any visible error - "the widget looks unchanged" is exactly what
     * that failure mode looks like from the outside, same class of bug as
     * the double/getFloat one above, just for Int/Boolean/String. Every
     * prefs read in WidgetContent() goes through one of these now, not the
     * raw SharedPreferences getters, so one bad key degrades that one field
     * to its default instead of blanking the whole widget. */
    fun readInt(prefs: SharedPreferences, key: String, default: Int = 0): Int {
        return try {
            prefs.getInt(key, default)
        } catch (_: Exception) {
            default
        }
    }

    fun readBoolean(prefs: SharedPreferences, key: String, default: Boolean = false): Boolean {
        return try {
            prefs.getBoolean(key, default)
        } catch (_: Exception) {
            default
        }
    }

    fun readString(prefs: SharedPreferences, key: String, default: String = ""): String {
        return try {
            prefs.getString(key, default) ?: default
        } catch (_: Exception) {
            default
        }
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
