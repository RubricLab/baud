// baud's marks (apps/shared/Marks.swift): one family of small drawings on the 24 grid at the family
// stroke (2.25, round caps and joins), the family dot (a 4.5 disc) as the light. Delivery (sending,
// carried, delivered, read), propagation (direct, through a helper, carried, waiting), presence
// (online, online relayed, away, never seen), identity (verified, vouched, unverified), and stable.
// The same drawings as the Mac and the iPhone.
package sh.rubric.baud.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Fill
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import sh.rubric.baud.core.Delivery
import sh.rubric.baud.core.DeliveryState
import sh.rubric.baud.core.Device
import sh.rubric.baud.core.DeviceKind
import sh.rubric.baud.core.best
import java.time.Duration
import java.time.Instant
import sh.rubric.baud.core.Path as CorePath

enum class Mark(val meaning: String) {
    // delivery: what happened to a message I sent
    Sending("Sending: still only on this device"),
    Carried("Carried: a device is holding it for them"),
    Delivered("Delivered to their device"),
    Read("Read"),
    // propagation: how bytes travel between two devices
    Direct("Direct: device to device, nothing in between"),
    Relayed("Through a helper: a friend's or your own device forwards it"),
    Held("Carried by a device until they come back"),
    Waiting("Waiting: nobody online to carry it yet"),
    // presence: a person or a device, right now
    Online("Online, direct"),
    OnlineRelayed("Online, through a helper"),
    Away("Away"),
    NeverSeen("Never seen online"),
    // identity
    Verified("Verified by you"),
    Vouched("Vouched for by someone you verified"),
    Unverified("Not verified"),
    // a device reachable from outside
    Stable("Reachable");

    class Part(val path: Path, val kind: Kind, val dash: FloatArray? = null, val opacity: Float = 1f)
    enum class Kind { Stroke, Fill, Knock }

    /// The drawing in 24-grid units.
    val parts: List<Part> by lazy { draw(this) }

    companion object {
        fun delivery(d: Delivery): Mark = when (d.best) {
            DeliveryState.Sent -> Sending
            is DeliveryState.Carried -> Carried
            DeliveryState.Delivered -> Delivered
            DeliveryState.Read -> Read
        }
        fun presence(d: Device): Mark {
            if (d.online) return if (d.path is CorePath.Relay) OnlineRelayed else Online
            return if (d.lastOnline == null) NeverSeen else Away
        }
        /// A person: their best device.
        fun presence(devices: List<Device>): Mark {
            val marks = devices.map { presence(it) }
            for (m in listOf(Online, OnlineRelayed, Away)) if (m in marks) return m
            return NeverSeen
        }
        fun path(p: CorePath): Mark? = when (p) {
            is CorePath.Direct, CorePath.Nearby -> Direct
            is CorePath.Relay -> Relayed
            else -> null
        }
    }
}

private fun line(vararg pts: Float): Path = Path().apply {
    moveTo(pts[0], pts[1]); var i = 2
    while (i < pts.size) { lineTo(pts[i], pts[i + 1]); i += 2 }
}
private fun oval(x: Float, y: Float, w: Float, h: Float): Path = Path().apply { addOval(Rect(x, y, x + w, y + h)) }

private fun draw(m: Mark): List<Mark.Part> {
    val d = mutableListOf<Mark.Part>()
    fun stroke(p: Path, dash: FloatArray? = null, opacity: Float = 1f) { d += Mark.Part(p, Mark.Kind.Stroke, dash, opacity) }
    fun fill(p: Path, opacity: Float = 1f) { d += Mark.Part(p, Mark.Kind.Fill, null, opacity) }
    fun knock(p: Path) { d += Mark.Part(p, Mark.Kind.Knock) }
    /// The family dot: a 4.5 disc.
    fun dot(x: Float, y: Float) = fill(oval(x - 2.25f, y - 2.25f, 4.5f, 4.5f))
    when (m) {
        // The light, not out yet: a ring left open at the top, so it reads as on its way, not as a letter.
        Mark.Sending -> stroke(Path().apply { arcTo(Rect(4.75f, 4.75f, 19.25f, 19.25f), -55f, 290f, true) })
        Mark.Carried -> stroke(line(5f, 12.5f, 9.5f, 17f, 19f, 6.5f))
        Mark.Delivered -> { stroke(line(2f, 12.5f, 6.5f, 17f, 15.5f, 7f)); stroke(line(10f, 15f, 12f, 17f, 21f, 7f)) }
        Mark.Read -> {
            fill(oval(1f, 1f, 22f, 22f))
            knock(line(5f, 12.5f, 8.25f, 15.75f, 14.5f, 8.75f))
            knock(line(11.25f, 14.5f, 12.5f, 15.75f, 19f, 8.75f))
        }
        // baud's own mark: two lights and the line between them, nothing in the middle.
        Mark.Direct -> { dot(4.5f, 12f); dot(19.5f, 12f); stroke(line(9.5f, 12f, 14.5f, 12f)) }
        // the two ends, and a helper above them the path bends through.
        Mark.Relayed -> {
            dot(3.5f, 17f); dot(20.5f, 17f); dot(12f, 5f)
            stroke(line(6.4f, 12.9f, 9.1f, 9.1f)); stroke(line(14.9f, 9.1f, 17.6f, 12.9f))
        }
        // a light held in a cup: a device keeping it until they come back.
        Mark.Held -> {
            stroke(Path().apply {
                moveTo(5f, 7.5f); lineTo(5f, 12.5f)
                arcTo(Rect(5f, 5.5f, 19f, 19.5f), 180f, -180f, false)
                lineTo(19f, 7.5f)
            })
            dot(12f, 11f)
        }
        // the light still here, the way on not there yet.
        Mark.Waiting -> { dot(4.5f, 12f); stroke(line(10f, 12f, 21f, 12f), floatArrayOf(1.5f, 3.25f)) }
        Mark.Online -> { fill(oval(2f, 2f, 20f, 20f), 0.22f); fill(oval(6.5f, 6.5f, 11f, 11f)) }
        Mark.OnlineRelayed -> { stroke(oval(3.25f, 3.25f, 17.5f, 17.5f)); fill(oval(8.25f, 8.25f, 7.5f, 7.5f)) }
        // the light, off: its outline only.
        Mark.Away -> stroke(oval(6.25f, 6.25f, 11.5f, 11.5f))
        Mark.NeverSeen -> stroke(oval(6.25f, 6.25f, 11.5f, 11.5f), floatArrayOf(2.2f, 2.6f), 0.6f)
        Mark.Verified -> { stroke(oval(3.25f, 3.25f, 17.5f, 17.5f)); stroke(line(8.25f, 12.25f, 10.9f, 14.9f, 15.9f, 9.25f)) }
        Mark.Vouched -> { stroke(oval(3.25f, 3.25f, 17.5f, 17.5f), floatArrayOf(3f, 2.5f)); stroke(line(8.25f, 12.25f, 10.9f, 14.9f, 15.9f, 9.25f)) }
        Mark.Unverified -> stroke(oval(3.25f, 3.25f, 17.5f, 17.5f), floatArrayOf(0.01f, 3.6f), 0.7f)
        // a house with its light on: the device that is always home.
        Mark.Stable -> {
            stroke(line(3.5f, 11f, 12f, 3.75f, 20.5f, 11f))
            stroke(line(6f, 9.5f, 6f, 20f, 18f, 20f, 18f, 9.5f))
            dot(12f, 14.5f)
        }
    }
    return d
}

/// Draws a mark into a square of `side` px at the scope's origin. `weight` thickens the stroke for
/// a mark set beside small type.
fun DrawScope.drawMark(mark: Mark, color: Color, side: Float = size.minDimension, weight: Float = 1f) {
    val s = side / 24f
    val w = 2.25f * weight
    scale(s, s, pivot = Offset.Zero) {
        for (p in mark.parts) {
            when (p.kind) {
                Mark.Kind.Stroke -> drawPath(p.path, color, alpha = p.opacity, style = Stroke(w, cap = StrokeCap.Round, join = StrokeJoin.Round, pathEffect = p.dash?.let { PathEffect.dashPathEffect(it) }))
                Mark.Kind.Fill -> drawPath(p.path, color, alpha = p.opacity, style = Fill)
                Mark.Kind.Knock -> drawPath(p.path, Color.Black, style = Stroke(w, cap = StrokeCap.Round, join = StrokeJoin.Round), blendMode = BlendMode.Clear)
            }
        }
    }
}

/// The mark at a size, in the colour of the text around it unless told otherwise. Optical size: a
/// mark beside small type keeps a stroke you can see (1.4 at 12, not 1.1).
@Composable
fun MarkView(mark: Mark, size: Dp = 14.dp, color: Color? = null, modifier: Modifier = Modifier) {
    val c = color ?: LocalTones.current.text
    val weight = if (size < 18.dp) 1.25f else 1f
    Canvas(
        modifier.size(size).graphicsLayer(compositingStrategy = CompositingStrategy.Offscreen)
            .semantics { contentDescription = mark.meaning },
    ) { drawMark(mark, c, weight = weight) }
}

/// Online or not, beside a name: the family's light, small.
@Composable
fun Light(on: Boolean, size: Dp = 7.dp) {
    val t = LocalTones.current
    Canvas(Modifier.size(size).semantics { contentDescription = if (on) "Online" else "Away" }) {
        val r = this.size.minDimension / 2
        if (on) drawCircle(t.strong, r) else drawCircle(t.secondary, r - 0.6.dp.toPx(), style = Stroke(1.2.dp.toPx()))
    }
}

// MARK: devices

/// What a device is, for its glyph: the kind the core gives, sharpened by its name.
enum class DeviceShape(val word: String) {
    Iphone("iPhone"), Ipad("iPad"), Macbook("Mac"), Imac("Mac"), MacMini("Mac mini"), MacStudio("Mac Studio"),
    PcLaptop("computer"), PcTower("computer"), Phone("phone");

    companion object {
        fun of(d: Device): DeviceShape {
            val n = d.name.lowercase()
            if ("ipad" in n) return Ipad
            return when (d.kind) {
                DeviceKind.Iphone -> Iphone
                DeviceKind.Android -> Phone
                DeviceKind.Mac -> when { "mini" in n -> MacMini; "studio" in n -> MacStudio; "imac" in n -> Imac; else -> Macbook }
                DeviceKind.Node -> PcLaptop
            }
        }
    }
}

private class Art(val body: List<Path>, val screen: List<Path>, val dark: List<Path>, val detail: List<Path>, val mark: Set<String>)
private fun rr(x: Float, y: Float, w: Float, h: Float, r: Float) = Path().apply { addRoundRect(RoundRect(x, y, x + w, y + h, CornerRadius(r, r))) }
private fun poly(vararg p: Float) = Path().apply { moveTo(p[0], p[1]); var i = 2; while (i < p.size) { lineTo(p[i], p[i + 1]); i += 2 }; close() }

/// The parts of a device on the 24 grid (apps/icon/devices/make.py), the phone drawn the same way.
private val arts: Map<DeviceShape, Art> by lazy {
    mapOf(
        DeviceShape.Iphone to Art(listOf(rr(6.55f, 5.4f, 0.7f, 0.8f, 0.25f), rr(6.55f, 7.4f, 0.7f, 1.6f, 0.25f), rr(6.55f, 9.8f, 0.7f, 1.6f, 0.25f), rr(16.75f, 8f, 0.7f, 2.8f, 0.25f), rr(7f, 1.5f, 10f, 21f, 2.6f)), listOf(rr(7.8f, 2.3f, 8.4f, 19.4f, 1.9f)), listOf(rr(10.7f, 3.1f, 2.6f, 0.8f, 0.4f)), listOf(), setOf("body", "screen")),
        DeviceShape.Phone to Art(listOf(rr(16.75f, 5.6f, 0.7f, 1.6f, 0.25f), rr(16.75f, 8.2f, 0.7f, 3.2f, 0.25f), rr(7f, 1.5f, 10f, 21f, 2.2f)), listOf(rr(7.8f, 2.3f, 8.4f, 19.4f, 1.5f)), listOf(rr(11.55f, 3.05f, 0.9f, 0.9f, 0.45f)), listOf(), setOf("body", "screen")),
        DeviceShape.Ipad to Art(listOf(rr(4.5f, 1.5f, 15f, 21f, 1.9f)), listOf(rr(5.5f, 2.5f, 13f, 19f, 1.1f)), listOf(), listOf(), setOf("body", "screen")),
        DeviceShape.Macbook to Art(listOf(rr(3.5f, 4f, 17f, 12.2f, 1.1f), rr(1.25f, 16.2f, 21.5f, 1.4f, 0.7f)), listOf(rr(4.4f, 4.9f, 15.2f, 10.8f, 0.45f)), listOf(rr(10.9f, 4.9f, 2.2f, 0.7f, 0.35f)), listOf(rr(10.4f, 16.2f, 3.2f, 0.45f, 0.22f), rr(3f, 17.6f, 1.6f, 0.5f, 0.25f), rr(19.4f, 17.6f, 1.6f, 0.5f, 0.25f)), setOf("body", "screen")),
        DeviceShape.Imac to Art(listOf(poly(10.2f, 17.4f, 13.8f, 17.4f, 14.4f, 20.6f, 9.6f, 20.6f), rr(8.4f, 20.3f, 7.2f, 0.9f, 0.45f), rr(2f, 2.5f, 20f, 15f, 1.3f)), listOf(rr(2.9f, 3.4f, 18.2f, 10.6f, 0.4f)), listOf(), listOf(), setOf("body", "screen")),
        DeviceShape.MacMini to Art(listOf(rr(4f, 14.9f, 16f, 1.6f, 0.7f), rr(2.5f, 8.25f, 19f, 7.25f, 2.2f)), listOf(), listOf(), listOf(rr(6f, 11.2f, 0.7f, 1.6f, 0.35f), rr(7.5f, 11.2f, 0.7f, 1.6f, 0.35f)), setOf("body", "detail")),
        DeviceShape.MacStudio to Art(listOf(rr(4.4f, 14.6f, 15.2f, 1.6f, 0.7f), rr(3f, 6.25f, 18f, 9.25f, 2.4f)), listOf(), listOf(), listOf(rr(5.6f, 11.4f, 0.7f, 1.6f, 0.35f), rr(7.1f, 11.4f, 0.7f, 1.6f, 0.35f), rr(9.4f, 12.1f, 3.2f, 0.6f, 0.3f)), setOf("body", "detail")),
        DeviceShape.PcLaptop to Art(listOf(rr(3.25f, 4f, 17.5f, 12.2f, 0.6f), rr(1.25f, 16.2f, 21.5f, 1.4f, 0.4f)), listOf(rr(4.2f, 4.9f, 15.6f, 10.6f, 0.2f)), listOf(), listOf(rr(10.4f, 16.2f, 3.2f, 0.45f, 0.22f)), setOf("body", "screen")),
        DeviceShape.PcTower to Art(listOf(rr(6.5f, 1.5f, 11f, 21f, 1.1f)), listOf(), listOf(), listOf(rr(8.6f, 4.2f, 6.8f, 0.6f, 0.3f), rr(8.6f, 6f, 6.8f, 0.6f, 0.3f)), setOf("body", "detail")),
    )
}

/// A device as the family's tile: front-on, the face one step off the surface, a hairline outline
/// and a soft 1 px shadow, the screen a plain inset. Small (28 and under) keeps the silhouette.
@Composable
fun DeviceGlyph(shape: DeviceShape, size: Dp = 20.dp, lit: Boolean = true, modifier: Modifier = Modifier) {
    val t = LocalTones.current
    val a = arts.getValue(shape)
    val small = size <= 28.dp
    val keep = if (small) a.mark else setOf("body", "screen", "dark", "detail")
    Canvas(modifier.size(size).graphicsLayer(alpha = if (lit) 1f else 0.4f).semantics { contentDescription = shape.word }) {
        val s = this.size.minDimension / 24f
        scale(s, s, pivot = Offset.Zero) {
            val shadow = Color.Black.copy(alpha = if (t.dark) 0.5f else 0.14f)
            val off = 0.7.dp.toPx() / s
            for (p in a.body) { translateBy(0f, off) { drawPath(p, shadow) } }
            for (p in a.body) drawPath(p, t.device)
            for (p in a.body) drawPath(p, t.text.copy(alpha = 0.2f), style = Stroke(1f / s))
            if ("screen" in keep) for (p in a.screen) drawPath(p, t.deviceScreen)
            if ("dark" in keep) for (p in a.dark) drawPath(p, Color.Black.copy(alpha = 0.88f))
            if ("detail" in keep) for (p in a.detail.take(if (small) 1 else 99)) drawPath(p, t.text.copy(alpha = 0.38f))
        }
    }
}

private inline fun DrawScope.translateBy(x: Float, y: Float, block: DrawScope.() -> Unit) {
    drawContext.transform.translate(x, y); block(); drawContext.transform.translate(-x, -y)
}

// MARK: presence in words

/// "2 h", "3 d", "now".
fun agoShort(d: Instant): String {
    val s = Duration.between(d, Instant.now()).seconds
    return when {
        s < 60 -> "now"
        s < 3600 -> "${s / 60} min"
        s < 86_400 -> "${s / 3600} h"
        else -> "${s / 86_400} d"
    }
}

/// One short word or two for a row: "online", "via Jo's Mac", "away 2 h", "never seen".
val Device.word: String
    get() {
        if (online) {
            (path as? CorePath.Relay)?.let { return "via ${it.name}" }
            (path as? CorePath.Direct)?.ms?.let { return "direct, $it ms" }
            return "online"
        }
        if (path == CorePath.Waiting) return "reaching…"
        lastOnline?.let { return "away " + agoShort(it) }
        return "never seen"
    }

/// A person's devices in one short phrase: "online", "relayed", "away 2 h", "never seen".
fun presenceWord(devices: List<Device>): String = when (Mark.presence(devices)) {
    Mark.Online -> devices.count { it.online }.let { if (it > 1) "online on $it" else "online" }
    Mark.OnlineRelayed -> "online, relayed"
    Mark.Away -> devices.mapNotNull { it.lastOnline }.maxOrNull()?.let { "away " + agoShort(it) } ?: "away"
    else -> "never seen"
}

/// Names as the pictures show them: the first name or the short device name, a middle ellipsis past 14.
object Names {
    fun cap(s: String): String = if (s.length <= 14) s else s.take(7) + "…" + s.takeLast(6)
    fun device(name: String): String {
        val n = name.replace('’', '\'')
        val i = n.indexOf("'s ")
        return if (i >= 0) cap(n.substring(i + 3)) else cap(name)
    }
    fun first(name: String): String = cap(name.split(" ").firstOrNull() ?: name)
}

val String.capitalizedFirst: String get() = replaceFirstChar { it.uppercase() }
