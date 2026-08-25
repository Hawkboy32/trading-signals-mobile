package com.blindbandit.tradingsignals.trading_signals.widget

import android.content.Context
import android.content.Intent
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.LocalSize
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.color.ColorProvider
import androidx.glance.currentState
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.width
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

// Same hologram-blue-on-dark palette as the dashboard/app, deliberately kept
// in sync (see main.dart's own comment on this same palette). Named here
// once so the HUD chrome below (border, dots, dividers) all draw from the
// same values as the text colors, instead of scattered literals.
private val COL_BG = Color(0xFF0B0E14)
private val COL_ACCENT = Color(0xFF3DC7F0)
private val COL_GOLD = Color(0xFFE0A94A)
private val COL_SUCCESS = Color(0xFF4CAF50)
private val COL_DANGER = Color(0xFFF44336)
private val COL_DIM = Color(0xFF5B7386)
private val COL_DIMMER = Color(0xFF3C4C5C)

/**
 * Home-screen widget: a HUD-style readout of the same combos the app itself
 * shows (see signal_list_screen.dart) - ticker, signal, price, plus (at
 * larger sizes) today's realized P&L, open P&L, market status, and roster
 * health. Data comes from prefs written by widget_service.dart's
 * refreshWidget() - this class only ever READS the last saved value, never
 * fetches anything itself (Glance widgets can't make network calls
 * directly). Parsing/formatting is shared with the bubble content screen
 * via SignalsData.kt, since both read the exact same saved keys.
 *
 * Redesigned 2026-08-17 from a plain text list toward a genuine HUD look -
 * a few things are deliberately simplified from the original mockup because
 * Glance's layout primitives are narrower than full Compose: no per-side
 * corner brackets (Glance's Box applies one contentAlignment to all
 * children, not a per-child align()), so the "framed" look here comes from
 * a solid-color Box behind an inset darker Box instead - same visual result
 * (a 1dp cyan frame), built from primitives (background + padding) this
 * file already used before the redesign. No glow/shadow on the status
 * dots - Glance has no blur primitive - flat solid color instead. No grid
 * background texture - Glance's background() only takes a solid color or a
 * drawable resource, not a repeating pattern; skipped rather than shipping
 * a new drawable asset for it.
 *
 * Resizable (android:resizeMode="horizontal|vertical" in
 * signals_widget_info.xml already allowed dragging the widget's frame
 * smaller/larger); SizeMode.Responsive snaps LocalSize.current to whichever
 * of SMALL/MEDIUM/LARGE below is closest to the frame the user drags it to,
 * and works on every API level this app supports, not just the newest
 * (unlike Exact, which needs API 31+).
 */
class SignalsWidget : GlanceAppWidget() {

    companion object {
        private val SMALL = DpSize(140.dp, 100.dp)
        private val MEDIUM = DpSize(250.dp, 180.dp)
        private val LARGE = DpSize(352.dp, 339.dp)
    }

    override val stateDefinition = HomeWidgetGlanceStateDefinition()
    override val sizeMode = SizeMode.Responsive(setOf(SMALL, MEDIUM, LARGE))

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        provideContent {
            WidgetContent(context, currentState<HomeWidgetGlanceState>())
        }
    }

    @Composable
    private fun StatusDot(color: Color, sizeDp: androidx.compose.ui.unit.Dp = 6.dp) {
        Box(modifier = GlanceModifier.width(sizeDp).height(sizeDp).background(color)) {}
    }

    @Composable
    private fun Divider() {
        Box(
            modifier = GlanceModifier
                .fillMaxWidth()
                .height(1.dp)
                .background(COL_ACCENT)
                .padding(bottom = 6.dp),
        ) {}
    }

    // Fixed dp width rather than a flex weight (Glance's defaultWeight()
    // isn't resolvable against this project's Glance version - confirmed by
    // a real build failure, not assumed) - half of LARGE's own declared
    // width, minus the frame/padding this Column already applies, so the
    // two cells split the row evenly at the one size they're actually shown.
    private val STAT_CELL_WIDTH = 155.dp

    @Composable
    private fun StatCell(label: String, value: Double, modifier: GlanceModifier = GlanceModifier) {
        val sign = if (value >= 0) "+" else ""
        Column(modifier = modifier.width(STAT_CELL_WIDTH).padding(4.dp)) {
            Text(text = label, style = TextStyle(color = solidColor(COL_DIM), fontSize = 9.sp))
            Text(
                text = "$sign${"%.2f".format(value)}",
                style = TextStyle(
                    color = solidColor(if (value >= 0) COL_SUCCESS else COL_DANGER),
                    fontWeight = FontWeight.Bold,
                    fontSize = 13.sp,
                ),
            )
        }
    }

    @Composable
    private fun WidgetContent(context: Context, state: HomeWidgetGlanceState) {
        val rows = SignalsData.parseSignals(SignalsData.readString(state.preferences, "signals_json", "").ifBlank { null })
        val lastRefreshed = SignalsData.readString(state.preferences, "last_refreshed", "").ifBlank { null }
        val botKilled = SignalsData.readBoolean(state.preferences, "bot_killed")
        val positionsAvailable = SignalsData.readBoolean(state.preferences, "positions_available")
        val openCount = SignalsData.readInt(state.preferences, "open_positions_count")
        val openPnl = SignalsData.readDouble(state.preferences, "open_positions_pnl")
        val marketOpen = SignalsData.readBoolean(state.preferences, "market_open")
        val realizedToday = SignalsData.readDouble(state.preferences, "realized_pnl_today")
        val rosterActive = SignalsData.readInt(state.preferences, "roster_active_count")
        val rosterSize = SignalsData.readInt(state.preferences, "roster_size")
        val rosterPaused = SignalsData.readString(state.preferences, "roster_paused_ticker")
        val equitiesHours = SignalsData.readString(state.preferences, "equities_hours", "").ifBlank { null }
        val forexHours = SignalsData.readString(state.preferences, "forex_hours", "").ifBlank { null }

        // Glance guarantees LocalSize.current is exactly one of the declared
        // breakpoints in Responsive mode, so a straight height comparison is
        // enough to pick a tier - no need to match both dimensions.
        val size = LocalSize.current
        val maxRows = if (size.height < MEDIUM.height) 1 else if (size.height < LARGE.height) 3 else 8
        val showExtras = size.height >= MEDIUM.height
        val isLarge = size.height >= LARGE.height

        // Frame: a solid-color Column behind a padded, inset darker Column -
        // the "1dp border" this file can build without a border() modifier
        // (see class doc comment for why). Root kept as a Column, not a Box
        // (matches the pre-redesign root exactly) - a Box root here was the
        // one real regression found on-device (2026-08-17): the widget
        // stopped resizing. Root cause not confirmed with certainty without
        // deeper RemoteViews debugging, but Column-rooted is what was
        // already proven to resize correctly, so that's what stayed.
        Column(
            modifier = GlanceModifier
                .fillMaxSize()
                .background(COL_ACCENT)
                .padding(1.dp)
                .clickable(actionStartActivity(Intent(context, MainActivity::class.java))),
        ) {
            Column(
                modifier = GlanceModifier
                    .fillMaxSize()
                    .background(COL_BG)
                    .padding(12.dp),
            ) {
                Row(modifier = GlanceModifier.fillMaxWidth()) {
                    StatusDot(if (botKilled) COL_DANGER else COL_SUCCESS)
                    Text(
                        text = "  Datapad",
                        style = TextStyle(color = solidColor(COL_ACCENT), fontWeight = FontWeight.Bold, fontSize = 14.sp),
                    )
                    if (isLarge) {
                        Text(
                            text = "  ${if (marketOpen) "● OPEN" else "○ CLOSED"}",
                            style = TextStyle(
                                color = solidColor(if (marketOpen) COL_SUCCESS else COL_DIM),
                                fontWeight = FontWeight.Bold,
                                fontSize = 8.sp,
                            ),
                        )
                    }
                    if (botKilled) {
                        Text(
                            text = "  STOPPED",
                            style = TextStyle(color = solidColor(COL_DANGER), fontWeight = FontWeight.Bold, fontSize = 12.sp),
                        )
                    }
                }
                // Today's actual open/close digits, same schedule the
                // Trading Hours screen shows (2026-08-23) - only at the
                // LARGE tier, same as the OPEN/CLOSED pill above, since this
                // is exactly the kind of "extra" that tier exists for.
                if (isLarge && (equitiesHours != null || forexHours != null)) {
                    Text(
                        text = listOfNotNull(
                            equitiesHours?.let { "Equities $it" },
                            forexHours?.let { "Forex $it" },
                        ).joinToString("   "),
                        style = TextStyle(color = solidColor(COL_DIM), fontSize = 9.sp),
                    )
                }
                Divider()
                if (rows.isEmpty()) {
                    Text(
                        text = "No data yet - open the app",
                        style = TextStyle(color = solidColor(Color.LightGray), fontSize = 12.sp),
                    )
                } else {
                    // Nested Column, not a flat forEach directly inside the
                    // root Column - Glance hard-caps every Column at 10
                    // DIRECT children (throws IllegalArgumentException and
                    // silently keeps showing the widget's last successful
                    // render otherwise - confirmed via real device logcat
                    // 2026-08-18, "Truncated Column container from 13 to 10
                    // elements"). At LARGE/maxRows=8 the root Column already
                    // has header+divider+P&L box+roster row+timestamp = 7
                    // other children, so 8 flattened row siblings pushed it
                    // to 13-14 and every render silently failed. Wrapping the
                    // rows collapses them to ONE child of the root Column
                    // regardless of row count.
                    Column {
                        rows.take(maxRows).forEach { row ->
                            Row(
                                modifier = GlanceModifier.fillMaxWidth().padding(top = 4.dp),
                            ) {
                                StatusDot(Color(SignalsData.colorFor(row.signal)), 7.dp)
                                Text(
                                    text = "  ${row.ticker}",
                                    style = TextStyle(color = solidColor(Color.White), fontWeight = FontWeight.Bold, fontSize = 13.sp),
                                )
                                Text(
                                    text = "  ${row.signal.uppercase()}",
                                    style = TextStyle(
                                        color = solidColor(Color(SignalsData.colorFor(row.signal))),
                                        fontWeight = FontWeight.Bold,
                                        fontSize = 10.sp,
                                    ),
                                )
                                if (showExtras && row.price > 0) {
                                    Text(
                                        text = "  ${"%.2f".format(row.price)}",
                                        style = TextStyle(color = solidColor(COL_DIM), fontSize = 10.sp),
                                    )
                                }
                            }
                        }
                    }
                }
                if (isLarge && positionsAvailable) {
                    Box(
                        modifier = GlanceModifier
                            .fillMaxWidth()
                            .padding(top = 6.dp)
                            .background(COL_GOLD)
                            .padding(start = 1.dp),
                    ) {
                        Row(modifier = GlanceModifier.fillMaxWidth().background(COL_BG)) {
                            StatCell("TODAY", realizedToday)
                            StatCell("OPEN · $openCount", openPnl)
                        }
                    }
                } else if (showExtras && positionsAvailable) {
                    val pnlSign = if (openPnl >= 0) "+" else ""
                    Text(
                        text = "$openCount open · $pnlSign${"%.2f".format(openPnl)}",
                        style = TextStyle(
                            color = solidColor(if (openPnl >= 0) COL_SUCCESS else COL_DANGER),
                            fontSize = 12.sp,
                        ),
                        modifier = GlanceModifier.padding(top = 8.dp),
                    )
                }
                if (isLarge && rosterSize > 0) {
                    Row(modifier = GlanceModifier.fillMaxWidth().padding(top = 5.dp)) {
                        StatusDot(COL_GOLD, 5.dp)
                        Text(
                            text = "  Roster $rosterActive/$rosterSize active" +
                                if (rosterPaused.isNotEmpty()) " · $rosterPaused paused" else "",
                            style = TextStyle(color = solidColor(COL_DIM), fontSize = 9.sp),
                        )
                    }
                }
                if (showExtras) {
                    Text(
                        text = SignalsData.relativeTime(lastRefreshed),
                        style = TextStyle(color = solidColor(COL_DIMMER), fontSize = 9.sp),
                        modifier = GlanceModifier.padding(top = 6.dp),
                    )
                }
            }
        }
    }
}
