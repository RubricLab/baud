// Every swatch in both modes, through the same Tones the app draws with: the contrast of the words
// on each ground they sit on, as drawn (8-bit sRGB), printed as a table. Held to the floors: the
// main ink and the secondary at 4.5:1 on the window, the side and the card, the tertiary at 3:1,
// and the red of what can't be undone at 4.5:1 on the window and the side and 3:1 on the card (it
// aims for 4.5:1 there too, and reaches it everywhere but a deep colour in light, where it's listed).
// The solver's own targets (the ink at 7:1 on the window, my message's words at 4.5:1 on the loud
// fill) are measured against pure white in Theme.swift, while the ink drawn is L 0.985 or 0.99 with
// a trace of the hue, so a deep pick lands a hair under them; those are listed, not failed.
package sh.rubric.baud.ui

import androidx.compose.ui.graphics.Color
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Locale

class TonesTest {
    private val picks = listOf("none" to null) + Accent.swatches.map { it.name to it.hex }

    private fun hex(c: Color) = String.format(Locale.US, "%02X%02X%02X", (c.red * 255).toInt(), (c.green * 255).toInt(), (c.blue * 255).toInt())
    private fun r(a: Color, b: Color) = OKLCH.contrast(a, b)
    private fun f(x: Double) = String.format(Locale.US, "%5.2f", x)

    @Test
    fun contrast() {
        val out = StringBuilder()
        out.append("swatch  mode   surface raised card   loud   | text/sur text/rai text/crd | sec/sur sec/rai sec/crd | ter/sur | onLoud/loud | danger  dng/sur dng/rai dng/crd\n")
        val misses = mutableListOf<String>()
        val short = mutableListOf<String>()
        for ((name, hex) in picks) for (dark in listOf(false, true)) {
            val t = Tones.make(hex, dark)
            val mode = if (dark) "dark " else "light"
            val row = listOf(r(t.text, t.surface), r(t.text, t.raised), r(t.text, t.card), r(t.secondary, t.surface), r(t.secondary, t.raised), r(t.secondary, t.card), r(t.tertiary, t.surface), r(t.onLoud, t.loud))
            out.append(String.format(Locale.US, "%-7s %s  %s %s %s %s |", name, mode, hex(t.surface), hex(t.raised), hex(t.card), hex(t.loud)))
            val red = listOf(r(t.danger, t.surface), r(t.danger, t.raised), r(t.danger, t.card))
            out.append("   ${f(row[0])}    ${f(row[1])}    ${f(row[2])} |  ${f(row[3])}   ${f(row[4])}   ${f(row[5])} |  ${f(row[6])} |  ${f(row[7])}      | ${hex(t.danger)} ${f(red[0])}   ${f(red[1])}   ${f(red[2])}\n")
            fun need(what: String, v: Double, min: Double) { if (v < min) misses += "$name $mode $what ${f(v)} < $min" }
            fun aim(what: String, v: Double, target: Double) { if (v < target) short += "$name $mode $what ${f(v)} (target $target)" }
            need("text/surface", row[0], 4.5); need("text/raised", row[1], 4.5); need("text/card", row[2], 4.5)
            need("secondary/surface", row[3], 4.5); need("secondary/raised", row[4], 4.5); need("secondary/card", row[5], 4.5)
            need("tertiary/surface", row[6], 3.0)
            need("danger/surface", red[0], 4.5); need("danger/raised", red[1], 4.5); need("danger/card", red[2], 3.0)
            aim("danger/card", red[2], 4.5)
            aim("text/surface", row[0], 7.0)
            aim("onLoud/loud", row[7], 4.5)
        }
        println(out)
        if (short.isNotEmpty()) println("short of the solver's target:\n" + short.joinToString("\n"))
        assertTrue(misses.joinToString("; "), misses.isEmpty())
    }
}
