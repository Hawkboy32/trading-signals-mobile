package com.blindbandit.tradingsignals.trading_signals.bubble

import android.app.Activity
import android.os.Bundle
import android.widget.TextView

/**
 * Minimal bubble-content Activity - the empirical spike for the "floating
 * chat head" idea (see Mobile_App/CLAUDE_NOTES.txt). Deliberately plain
 * native content, NOT an embedded Flutter view - the open question this is
 * meant to answer is narrowly "does Android's Bubbles API actually bubble a
 * notification from THIS app on THIS device/OEM skin at all", not "does the
 * full trimmed-signal-card UI work inside one". Answer that first (cheap),
 * then decide whether investing in the real UI is worth it.
 */
class BubbleActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val text = TextView(this).apply {
            text = "Bubble spike OK - this Activity is running inside a real Android bubble."
            textSize = 16f
            setPadding(32, 32, 32, 32)
        }
        setContentView(text)
    }
}
