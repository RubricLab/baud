// One hue, a full ramp of it, and nothing else (apps/shared/Theme.swift, the same numbers): every
// surface is a solid step of the colour the person chose, never a veil or a gradient. In light the
// window is the colour itself at full strength (deep picks deepened until white words read at 7:1,
// pale ones under near-black ink); in dark the window is the colour's own near-black and the
// colour, still at full strength, is what's loud on it: my messages, the selected row, the count,
// the send button. None is the same in greys. Every word is a solid colour solved for contrast,
// never text with its opacity turned down. Material 3 sits underneath, filled from these.
//
// The iPhone draws each tone in Display P3; Compose paints through an sRGB int, so here each tone
// is the sRGB colour of the same lightness and hue with as much chroma as fits, and the contrast is
// solved against that same colour: the searches and their numbers are Theme.swift's, the luminance
// they measure is of what is drawn. TonesTest prints and checks it.
package sh.rubric.baud.ui

import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cbrt
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

@Immutable
data class Tones(
    val tinted: Boolean,
    /// The person's appearance (the system's).
    val dark: Boolean,
    val hue: Double,
    val chroma: Double,
    /// The window's lightness, and whether its words are light.
    val base: Double,
    val light: Boolean,
    /// The window: header, timeline and composer on one ground.
    val surface: Color,
    /// The same colour a step deeper, never paler: what sits beside the window.
    val raised: Color,
    /// What you type into, and quiet raised things (a field's words are `text`).
    val field: Color,
    /// Their messages: a card lifted off the ground.
    val card: Color,
    /// The loudest fill: my messages, the selected row, the send button, a count, an online light.
    val loud: Color,
    val onLoud: Color,
    val onLoudSecondary: Color,
    /// Words: the main ink, a solid step under it (at least 5:1), and one for marks (3:1).
    val text: Color,
    val secondary: Color,
    val tertiary: Color,
    val hairline: Color,
    val hover: Color,
    val pressed: Color,
    /// Under reactions, tiles and the like.
    val quiet: Color,
    /// The disc behind initials, and what is written on it.
    val face: Color,
    val onFace: Color,
    /// Shadows are the hue's own deep step, never grey.
    val shade: Color,
    /// A device's face, and its screen.
    val device: Color,
    val deviceScreen: Color,
) {
    val selected: Color get() = loud
    val heading: Color get() = text
    /// Buttons, the send mark, dots, rings: the loud colour.
    val strong: Color get() = loud
    val onStrong: Color get() = onLoud
    /// My messages, and their words.
    val mine: Color get() = loud
    val onMine: Color get() = onLoud
    val onMineSecondary: Color get() = onLoudSecondary
    /// The system chrome the window wants (status bar icons, sheets, the keyboard): dark under white words.
    val chromeDark: Boolean get() = light

    /// The same tones for what sits on a loud fill (the selected row, my message): its words flip.
    val onLoudTones: Tones by lazy {
        val flipFace = !dark || !tinted
        copy(
            text = onLoud, secondary = onLoudSecondary, tertiary = onLoudSecondary,
            surface = loud, hairline = onLoudSecondary,
            loud = onLoud, onLoud = loud, onLoudSecondary = loud,
            face = if (flipFace) onLoud else face, onFace = if (flipFace) loud else onFace,
        )
    }

    /// The colour of the mark on the app icon: the hue itself, light enough to read on the tile.
    val iconMark: Color get() = if (tinted) OKLCH.color(0.82, chroma, hue) else OKLCH.grey(0.96)

    /// The app icon's tile: the family's near-black, or the whole tile in the nearest swatch, a
    /// breath lighter at the top (top, bottom, mark). apps/icon draws the same.
    val iconTile: Triple<Color, Color, Color>
        get() {
            fun gap(a: Double, b: Double): Double { val d = abs(a - b) % (2 * PI); return min(d, 2 * PI - d) }
            val lch = if (tinted && chroma >= 0.04) Accent.swatches.mapNotNull { OKLCH.parse(it.hex) }.minByOrNull { gap(it.h, hue) } else null
            lch ?: return Triple(OKLCH.grey(0.16), OKLCH.grey(0.05), OKLCH.grey(0.96))
            return Triple(OKLCH.color(lch.l + 0.05, lch.c, lch.h), OKLCH.color(lch.l - 0.07, lch.c, lch.h), if (lch.l > 0.75) Color(0xFF08090A) else Color.White)
        }

    companion object {
        private val made = ConcurrentHashMap<String, Tones>()

        fun make(hex: String?, dark: Boolean): Tones = made.getOrPut("${hex ?: "-"}$dark") { build(hex, dark) }

        private fun build(hex: String?, dark: Boolean): Tones {
            val lch = hex?.let { OKLCH.parse(it) } ?: return greys(dark)
            // A pick with no colour in it: black is black in either light; white or a grey is the
            // plain ramp (its hue would be noise, and its own lightness can't carry a loud fill).
            if (lch.c < 0.03) return if (lch.l < 0.4) blacks() else greys(dark)
            val h = lch.h; val c0 = lch.c
            fun p(l: Double, c: Double): Color = OKLCH.color(l, c, h)
            fun y(l: Double, c: Double): Double = OKLCH.luminance(l, c, h)
            // A pale pick (orange, amber) reads under near-black ink; a deep one under white.
            val pale = lch.l >= 0.66
            val inkL = 0.17; val inkC = min(c0, 0.06)
            val whiteC = min(c0, 0.02)
            if (dark) {
                // Warm hues (orange, amber) go brown when deep: their near-black keeps less chroma,
                // so it reads as a warm black under the colour, not as mud.
                val warm = max(0.0, cos(min(1.0, abs(h * 180 / PI - 65) / 50) * PI / 2))
                val cg = min(c0, 0.06) * (1 - 0.6 * warm)
                val g = 0.19
                // The colour at full strength: white words at 4.5:1 or better on a deep pick, near-black on a pale one.
                // Solved against the white actually drawn on it, not pure white.
                // A very deep pick is lifted to the middle, so it is still loud on the near-black.
                val loudL = if (pale) lch.l else max(0.5, OKLCH.deepest(lch.l, c0, h, y(0.99, whiteC), 4.6))
                val secL = OKLCH.reach(g, 0.975, cg * 0.8, h, listOf(y(g, cg), y(0.165, cg), y(0.29, cg * 1.25)), 4.6)
                val terL = OKLCH.reach(g, 0.975, cg, h, listOf(y(g, cg), y(0.165, cg)), 3.1)
                return Tones(
                    tinted = true, dark = true, hue = h, chroma = c0, base = g, light = true,
                    surface = p(g, cg), raised = p(0.165, cg), field = p(0.265, cg * 1.1), card = p(0.29, cg * 1.25),
                    loud = p(loudL, c0), onLoud = if (pale) p(inkL, inkC) else p(0.99, whiteC),
                    onLoudSecondary = if (pale) p(0.3, min(c0, 0.09)) else p(0.92, min(c0, 0.04)),
                    text = p(0.975, min(c0, 0.015)), secondary = p(secL, cg * 0.8), tertiary = p(terL, cg),
                    hairline = p(0.29, cg), hover = p(0.235, cg), pressed = p(0.27, cg), quiet = p(0.28, cg * 1.2),
                    face = p(0.4, cg * 1.6), onFace = p(0.985, whiteC), shade = p(0.07, cg).copy(alpha = 0.55f),
                    device = p(0.36, cg), deviceScreen = p(0.14, cg),
                )
            }
            if (pale) {
                // The colour itself, lifted just enough that its near-black ink reads at 7:1.
                val g = OKLCH.shallowest(lch.l, c0, h, y(inkL, inkC), 7.0)
                val side = g - 0.045
                val white = p(0.985, min(c0 * 0.12, 0.02))
                val secL = OKLCH.reach(side, inkL, c0, h, listOf(y(g, c0), y(side, c0)), 5.0)
                val terL = OKLCH.reach(side, inkL, c0, h, listOf(y(g, c0), y(side, c0)), 3.1)
                return Tones(
                    tinted = true, dark = false, hue = h, chroma = c0, base = g, light = false,
                    surface = p(g, c0), raised = p(side, c0 * 1.04), field = white, card = white,
                    loud = p(0.2, min(c0, 0.085)), onLoud = p(0.985, whiteC), onLoudSecondary = p(0.8, min(c0, 0.08)),
                    text = p(inkL, inkC), secondary = p(secL, min(c0, 0.14)), tertiary = p(terL, c0),
                    hairline = p(g - 0.13, c0), hover = p(side - 0.05, c0), pressed = p(side - 0.09, c0), quiet = p(g - 0.07, c0),
                    face = p(0.2, min(c0, 0.085)), onFace = p(0.985, whiteC), shade = p(0.25, c0 * 0.8).copy(alpha = 0.3f),
                    device = white, deviceScreen = p(g - 0.12, c0),
                )
            }
            // Deep: the colour, deepened until white reads at 7:1.
            // Never so deep that the sidebar a step below it has nowhere to go.
            val g = max(0.14, OKLCH.deepest(min(lch.l, 0.55), c0, h, y(0.985, whiteC), 7.0))
            val side = g - 0.045
            val card = g + 0.075
            val secL = OKLCH.reach(card, 0.985, c0 * 0.35, h, listOf(y(g, c0), y(side, c0), y(card, c0)), 4.6)
            val terL = OKLCH.reach(g, 0.985, c0 * 0.5, h, listOf(y(g, c0), y(side, c0)), 3.1)
            return Tones(
                tinted = true, dark = false, hue = h, chroma = c0, base = g, light = true,
                surface = p(g, c0), raised = p(side, c0), field = p(card, c0 * 0.95), card = p(card, c0 * 0.95),
                loud = p(0.975, min(c0 * 0.15, 0.03)), onLoud = p(0.36, c0), onLoudSecondary = p(0.5, c0),
                text = p(0.985, whiteC), secondary = p(secL, c0 * 0.35), tertiary = p(terL, c0 * 0.5),
                hairline = p(g + 0.1, c0), hover = p(g + 0.02, c0), pressed = p(side - 0.06, c0), quiet = p(g + 0.07, c0),
                face = p(0.975, min(c0 * 0.15, 0.03)), onFace = p(0.36, c0), shade = p(0.14, c0).copy(alpha = 0.4f),
                device = p(g + 0.12, c0), deviceScreen = p(side - 0.05, c0),
            )
        }

        /// Black, picked: the window black in light and dark alike, white the loud fill.
        private fun blacks(): Tones {
            fun g(l: Double): Color = OKLCH.color(l, 0.0, 0.0)
            return Tones(
                tinted = false, dark = true, hue = 0.0, chroma = 0.0, base = 0.1, light = true,
                surface = g(0.1), raised = g(0.065), field = g(0.2), card = g(0.225),
                loud = g(0.97), onLoud = g(0.12), onLoudSecondary = g(0.42),
                text = g(0.97), secondary = g(0.72), tertiary = g(0.56), hairline = g(0.24), hover = g(0.15), pressed = g(0.19), quiet = g(0.2),
                face = g(0.32), onFace = g(0.97), shade = Color.Black.copy(alpha = 0.6f), device = g(0.3), deviceScreen = g(0.06),
            )
        }

        /// No colour: the same ramp in greys.
        private fun greys(dark: Boolean): Tones {
            fun g(l: Double): Color = OKLCH.color(l, 0.0, 0.0)
            if (dark) return Tones(
                tinted = false, dark = true, hue = 0.0, chroma = 0.0, base = 0.175, light = true,
                surface = g(0.175), raised = g(0.15), field = g(0.25), card = g(0.275),
                loud = g(0.97), onLoud = g(0.16), onLoudSecondary = g(0.42),
                text = g(0.97), secondary = g(0.74), tertiary = g(0.58), hairline = g(0.28), hover = g(0.215), pressed = g(0.25), quiet = g(0.26),
                face = g(0.36), onFace = g(0.97), shade = Color.Black.copy(alpha = 0.5f), device = g(0.34), deviceScreen = g(0.12),
            )
            return Tones(
                tinted = false, dark = false, hue = 0.0, chroma = 0.0, base = 1.0, light = false,
                surface = g(1.0), raised = g(0.968), field = g(0.94), card = g(0.935),
                loud = g(0.18), onLoud = g(0.985), onLoudSecondary = g(0.78),
                text = g(0.16), secondary = g(0.45), tertiary = g(0.6), hairline = g(0.89), hover = g(0.935), pressed = g(0.9), quiet = g(0.935),
                face = g(0.88), onFace = g(0.16), shade = Color.Black.copy(alpha = 0.13f), device = g(1.0), deviceScreen = g(0.9),
            )
        }

        fun ink(onLightness: Double, hue: Double, chroma: Double): Color =
            if (onLightness > 0.62) OKLCH.color(0.18, min(chroma, 0.05), hue) else OKLCH.color(0.98, min(chroma, 0.02), hue)
    }
}

val LocalTones = staticCompositionLocalOf { Tones.make(null, false) }

/// OKLCH in and sRGB out, with chroma pulled in until the colour fits the gamut.
object OKLCH {
    data class LCH(val l: Double, val c: Double, val h: Double)

    fun parse(hex: String): LCH? {
        val v = hex.trim().trimStart('#').toLongOrNull(16) ?: return null
        val r = lin(((v shr 16) and 0xFF) / 255.0); val g = lin(((v shr 8) and 0xFF) / 255.0); val b = lin((v and 0xFF) / 255.0)
        val l_ = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        val m_ = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        val s_ = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        val L = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_
        val a = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_
        val bb = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
        return LCH(L, sqrt(a * a + bb * bb), atan2(bb, a))
    }

    /// The lowest lightness at or over `l` where text of luminance `text` reads at `ratio` on it.
    fun shallowest(l0: Double, c: Double, h: Double, text: Double, ratio: Double): Double {
        var l = l0
        while (l < 0.95) {
            val y = luminance(l, c, h)
            if ((max(text, y) + 0.05) / (min(text, y) + 0.05) >= ratio) return l
            l += 0.01
        }
        return l
    }

    /// The first lightness from `from` toward `to` where this colour reads at `ratio` on every one of
    /// `on` (luminances): a secondary ink as close to its ground as it can be and still be read.
    fun reach(from: Double, to: Double, c: Double, h: Double, on: List<Double>, ratio: Double): Double {
        val dir = if (to > from) 0.005 else -0.005
        var l = from
        while (if (dir > 0) l < to else l > to) {
            val y = luminance(l, c, h)
            if (on.all { (max(it, y) + 0.05) / (min(it, y) + 0.05) >= ratio }) return l
            l += dir
        }
        return to
    }

    /// Relative luminance of an OKLCH colour as it is drawn (`color`: chroma pulled in to the gamut).
    fun luminance(l: Double, c0: Double, h: Double): Double {
        val rgb = fit(l, c0, h)
        return 0.2126 * lin(rgb[0]) + 0.7152 * lin(rgb[1]) + 0.0722 * lin(rgb[2])
    }

    /// The highest lightness at or under `l` where text of luminance `against` reads at `ratio`.
    fun deepest(l0: Double, c: Double, h: Double, against: Double, ratio: Double): Double {
        var l = l0
        while (l > 0.2) {
            val y = luminance(l, c, h)
            if ((max(against, y) + 0.05) / (min(against, y) + 0.05) >= ratio) return l
            l -= 0.01
        }
        return l
    }

    /// The colour to draw: its lightness and hue kept, with as much of its chroma as sRGB holds. The
    /// iPhone keeps nearly all of it in P3; pulling it in by whole steps here would grey a deep pick
    /// (a blue ground, an orange's near-black) well past what the gamut asks.
    fun color(l: Double, c0: Double, h: Double): Color {
        val rgb = fit(l, c0, h)
        return Color(rgb[0].toFloat(), rgb[1].toFloat(), rgb[2].toFloat())
    }

    /// sRGB of the colour with the most of its chroma that fits.
    private fun fit(l: Double, c0: Double, h: Double): DoubleArray {
        srgb(l, c0, h)?.let { return it }
        var lo = 0.0; var hi = c0
        repeat(18) { val mid = (lo + hi) / 2; if (srgb(l, mid, h) != null) lo = mid else hi = mid }
        return srgb(l, lo, h) ?: srgb(l, 0.0, h) ?: doubleArrayOf(0.5, 0.5, 0.5)
    }

    /// SwiftUI's `Color(white:)`: a grey whose sRGB components are all that value.
    fun grey(white: Double): Color = Color(white.toFloat(), white.toFloat(), white.toFloat())

    /// WCAG relative luminance of a colour as drawn (sRGB), and the contrast of two.
    fun luminance(c: Color): Double = 0.2126 * lin(c.red.toDouble()) + 0.7152 * lin(c.green.toDouble()) + 0.0722 * lin(c.blue.toDouble())
    fun contrast(a: Color, b: Color): Double { val x = luminance(a); val y = luminance(b); return (max(x, y) + 0.05) / (min(x, y) + 0.05) }

    private fun srgb(l: Double, c: Double, h: Double): DoubleArray? {
        val a = c * cos(h); val b = c * sin(h)
        val l_ = l + 0.3963377774 * a + 0.2158037573 * b
        val m_ = l - 0.1055613458 * a - 0.0638541728 * b
        val s_ = l - 0.0894841775 * a - 1.2914855480 * b
        val L = l_ * l_ * l_; val M = m_ * m_ * m_; val S = s_ * s_ * s_
        val r = 4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S
        val g = -1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S
        val bl = -0.0041960863 * L - 0.7034186147 * M + 1.7076147010 * S
        val eps = 0.002
        if (r < -eps || r > 1 + eps || g < -eps || g > 1 + eps || bl < -eps || bl > 1 + eps) return null
        return doubleArrayOf(gam(r.coerceIn(0.0, 1.0)), gam(g.coerceIn(0.0, 1.0)), gam(bl.coerceIn(0.0, 1.0)))
    }

    private fun lin(v: Double): Double = if (v <= 0.04045) v / 12.92 else ((v + 0.055) / 1.055).pow(2.4)
    private fun gam(v: Double): Double = if (v <= 0.0031308) 12.92 * v else 1.055 * v.pow(1 / 2.4) - 0.055
}

object Accent {
    data class Swatch(val name: String, val hex: String)
    /// Black, as the swatch row offers it beside white (no colour).
    const val black = "000000"
    /// Bold, saturated, equal weight: the row of swatches in You.
    val swatches = listOf(
        Swatch("red", "E5484D"), Swatch("orange", "F76B15"), Swatch("amber", "FFB224"), Swatch("green", "30A46C"),
        Swatch("teal", "12A594"), Swatch("blue", "0090FF"), Swatch("violet", "6E56CF"), Swatch("pink", "E93D82"),
    )
    fun color(hex: String?): Color? = hex?.trimStart('#')?.toLongOrNull(16)?.let { Color(0xFF000000 or it) }
}
