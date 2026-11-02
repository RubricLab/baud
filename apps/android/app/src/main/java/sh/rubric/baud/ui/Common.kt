// The pieces every screen is made of (Rows.swift, Theme.swift, MembersView.swift's Quiet): a face,
// a row that darkens when pressed, the quiet and strong buttons, a small icon action, the pill, a
// section heading, an empty line, the unread badge, and the few glyphs drawn in baud's stroke.
package sh.rubric.baud.ui

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.PathParser
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.exifinterface.media.ExifInterface
import sh.rubric.baud.AppModel
import sh.rubric.baud.core.BlobHash
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import kotlin.math.roundToInt

val LocalModel = staticCompositionLocalOf<AppModel> { error("no model") }

// MARK: glyphs, in the family's stroke on the 24 grid

object Glyphs {
    private fun make(name: String, strokes: List<String>, fills: List<String> = emptyList(), width: Float = 1.9f): ImageVector =
        ImageVector.Builder(name, 24.dp, 24.dp, 24f, 24f).apply {
            for (d in strokes) addPath(PathParser().parsePathString(d).toNodes(), stroke = SolidColor(Color.Black), strokeLineWidth = width, strokeLineCap = StrokeCap.Round, strokeLineJoin = StrokeJoin.Round)
            for (d in fills) addPath(PathParser().parsePathString(d).toNodes(), fill = SolidColor(Color.Black))
        }.build()

    val back = make("back", listOf("M15 4.5L7.5 12l7.5 7.5"), width = 2.2f)
    val plus = make("plus", listOf("M12 5v14", "M5 12h14"), width = 2.2f)
    val arrowUp = make("up", listOf("M12 19V5.5", "M6 11l6-6 6 6"), width = 2.4f)
    val xmark = make("x", listOf("M6.5 6.5l11 11", "M17.5 6.5l-11 11"), width = 2.2f)
    val search = make("search", listOf("M10.5 4a6.5 6.5 0 1 0 0 13a6.5 6.5 0 1 0 0-13z", "M15.5 15.5L20 20"), width = 2.1f)
    val clear = make("clear", listOf(), listOf("M12 2a10 10 0 1 0 0 20a10 10 0 1 0 0-20zM8.6 7.2L12 10.6l3.4-3.4 1.4 1.4-3.4 3.4 3.4 3.4-1.4 1.4-3.4-3.4-3.4 3.4-1.4-1.4 3.4-3.4-3.4-3.4z"))
    val compose = make("compose", listOf("M11 4H6.5A2.5 2.5 0 0 0 4 6.5v11A2.5 2.5 0 0 0 6.5 20h11a2.5 2.5 0 0 0 2.5-2.5V13", "M17.6 3.4a1.9 1.9 0 0 1 2.7 2.7L12.5 14l-3.6 0.9 0.9-3.6z"), width = 2f)
    val camera = make("camera", listOf(), listOf("M9.2 4h5.6l1.6 2.2H19a2.5 2.5 0 0 1 2.5 2.5v8.8A2.5 2.5 0 0 1 19 20H5a2.5 2.5 0 0 1-2.5-2.5V8.7A2.5 2.5 0 0 1 5 6.2h2.6zM12 9a4 4 0 1 0 0 8a4 4 0 1 0 0-8zm0 1.8a2.2 2.2 0 1 1 0 4.4a2.2 2.2 0 1 1 0-4.4z"))
    val scan = make("scan", listOf("M4 8.5V6a2 2 0 0 1 2-2h2.5", "M15.5 4H18a2 2 0 0 1 2 2v2.5", "M20 15.5V18a2 2 0 0 1-2 2h-2.5", "M8.5 20H6a2 2 0 0 1-2-2v-2.5"), listOf("M8 8h3.2v3.2H8z", "M12.8 8H16v3.2h-3.2z", "M8 12.8h3.2V16H8z", "M12.8 12.8H16V16h-3.2z"), width = 2f)
    val share = make("share", listOf("M12 3.5v11", "M8.2 7.2L12 3.5l3.8 3.7", "M8.5 10H7a2 2 0 0 0-2 2v7a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-7a2 2 0 0 0-2-2h-1.5"), width = 2f)
    val person = make("person", listOf(), listOf("M12 3.5a4.2 4.2 0 1 0 0 8.4a4.2 4.2 0 1 0 0-8.4z", "M3.8 20.5c0.4-4.2 3.9-6.9 8.2-6.9s7.8 2.7 8.2 6.9z"))
    val smile = make("smile", listOf("M12 3a9 9 0 1 0 0 18a9 9 0 1 0 0-18z", "M8.3 14.2c0.9 1.4 2.2 2.1 3.7 2.1s2.8-0.7 3.7-2.1"), listOf("M9 8.6a1.3 1.3 0 1 0 0 2.6a1.3 1.3 0 1 0 0-2.6z", "M15 8.6a1.3 1.3 0 1 0 0 2.6a1.3 1.3 0 1 0 0-2.6z"), width = 1.8f)
    val photo = make("photo", listOf("M5.5 4.5h13a2 2 0 0 1 2 2v11a2 2 0 0 1-2 2h-13a2 2 0 0 1-2-2v-11a2 2 0 0 1 2-2z", "M3.8 16l4.4-4.4 3.3 3.3 2.7-2.7 6.3 5.8"), listOf("M15.5 7.4a1.6 1.6 0 1 0 0 3.2a1.6 1.6 0 1 0 0-3.2z"), width = 1.8f)
    val doc = make("doc", listOf("M6.5 3h7l4.5 4.5V19a2 2 0 0 1-2 2h-9.5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z", "M13.5 3v4.5H18"), width = 1.8f)
    val bellOff = make("bell", listOf("M18 15.5V11a6 6 0 0 0-9.4-4.9", "M6.2 9.6C6.1 10 6 10.5 6 11v4.5L4.5 17.5h11.5", "M10 20.5a2 2 0 0 0 4 0", "M4 4l16 16"), width = 1.9f)
    val ellipsis = make("more", listOf(), listOf("M6 10.4a1.6 1.6 0 1 0 0 3.2a1.6 1.6 0 1 0 0-3.2z", "M12 10.4a1.6 1.6 0 1 0 0 3.2a1.6 1.6 0 1 0 0-3.2z", "M18 10.4a1.6 1.6 0 1 0 0 3.2a1.6 1.6 0 1 0 0-3.2z"))
    val pin = make("pin", listOf("M12 21s-6.5-6.1-6.5-11a6.5 6.5 0 0 1 13 0c0 4.9-6.5 11-6.5 11z", "M12 7.6a2.4 2.4 0 1 0 0 4.8a2.4 2.4 0 1 0 0-4.8z"), width = 1.9f)
    val pinFill = make("pinFill", listOf(), listOf("M12 2.6a7.2 7.2 0 0 0-7.2 7.2c0 5.3 6.4 11.3 6.7 11.6a0.7 0.7 0 0 0 1 0c0.3-0.3 6.7-6.3 6.7-11.6A7.2 7.2 0 0 0 12 2.6zm0 4.6a2.6 2.6 0 1 1 0 5.2a2.6 2.6 0 1 1 0-5.2z"))
    val issue = make("issue", listOf(), listOf("M12 2a10 10 0 1 0 0 20a10 10 0 1 0 0-20zm-1.2 5h2.4l-0.3 7h-1.8zM12 15.4a1.4 1.4 0 1 1 0 2.8a1.4 1.4 0 1 1 0-2.8z"))
}

@Composable
fun Glyph(v: ImageVector, size: Dp = 18.dp, color: Color = LocalTones.current.text, description: String? = null, modifier: Modifier = Modifier) =
    Icon(v, description, modifier.size(size), tint = color)

// MARK: a face

fun initials(name: String): String = name.split(" ").filter { it.isNotEmpty() }.take(2).mapNotNull { it.firstOrNull()?.toString() }.joinToString("").uppercase()

/// A face: their photo, or their initials on a solid disc; when they're online, a light cut into
/// the bottom corner (whatever is behind shows through the cut, on any row). Away and never seen
/// draw nothing on the face: the words beside it say so, and a list of mostly-away friends stays
/// clean, so the ones who are here stand out.
@Composable
fun Avatar(name: String, hash: BlobHash? = null, size: Dp = 24.dp, presence: Mark? = null, ring: Boolean = false, modifier: Modifier = Modifier) {
    val t = LocalTones.current
    val model = LocalModel.current
    val img = hash?.let { model.image(it, if (size > 60.dp) 1000 else 200) }
    val lit = presence == Mark.Online || presence == Mark.OnlineRelayed
    val badge = maxOf(8f, (size.value * 0.36f).roundToInt().toFloat()).dp
    val gap = maxOf(3f, size.value / 10f).dp
    val letters = initials(name).ifEmpty { "?" }
    // The initials keep to the disc whatever the person's text size.
    val type = with(LocalDensity.current) { (size * if (letters.length > 1) 0.38f else 0.44f).toSp() }
    Box(modifier.size(size).semantics { contentDescription = if (lit) "$name, ${presence?.meaning}" else name }) {
        Box(
            Modifier.size(size).graphicsLayer(compositingStrategy = CompositingStrategy.Offscreen).drawWithContent {
                drawContent()
                if (ring) drawCircle(t.strong, radius = this.size.minDimension / 2 - maxOf(1.5.dp.toPx(), size.toPx() / 16) / 2, style = Stroke(maxOf(1.5.dp.toPx(), size.toPx() / 16)))
                if (lit) {
                    val r = (badge + gap).toPx() / 2
                    val c = this.size.width - r + 1.5.dp.toPx()
                    drawCircle(Color.Black, radius = r, center = Offset(c, c), blendMode = BlendMode.Clear)
                }
            },
        ) {
            if (img != null) Image(img, null, Modifier.size(size).clip(CircleShape), contentScale = ContentScale.Crop)
            else Box(Modifier.size(size).clip(CircleShape).background(t.face), contentAlignment = Alignment.Center) {
                Text(letters, color = t.onFace, fontSize = type, lineHeight = type, fontWeight = FontWeight.Bold, maxLines = 1)
            }
        }
        if (lit) PresenceLight(presence == Mark.OnlineRelayed, badge, Modifier.align(Alignment.BottomEnd).offset(1.5.dp - gap / 2, 1.5.dp - gap / 2))
    }
}

/// Online: a solid light in the loud colour. Through a helper, the same light with its middle
/// open, so the difference is there for whoever looks and quiet for whoever doesn't.
@Composable
fun PresenceLight(relayed: Boolean = false, size: Dp = 8.dp, modifier: Modifier = Modifier) {
    val t = LocalTones.current
    Canvas(
        modifier.size(size).graphicsLayer(compositingStrategy = CompositingStrategy.Offscreen)
            .semantics { contentDescription = if (relayed) "Online, through a helper" else "Online" },
    ) {
        drawCircle(t.loud)
        if (relayed) drawCircle(Color.Black, radius = this.size.minDimension * 0.2f, blendMode = BlendMode.Clear)
    }
}

// MARK: rows and buttons

/// The look of every row you can open (RowStyle): the fill inset from the edges and rounded,
/// darker pressed. Selected, it takes the loud fill and its words flip to read on it: unmistakable
/// in any colour, light or dark. Nothing runs to the edge.
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
fun RowSurface(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    selected: Boolean = false,
    onLongClick: (() -> Unit)? = null,
    minHeight: Dp = 0.dp,
    content: @Composable RowScope.() -> Unit,
) {
    val t = LocalTones.current
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    val on = selected && !pressed
    CompositionLocalProvider(LocalTones provides if (on) t.onLoudTones else t, LocalContentColor provides if (on) t.onLoud else t.text) {
        Row(
            modifier.fillMaxWidth().padding(horizontal = Metrics.inset).clip(RoundedCornerShape(9.dp))
                .background(if (pressed) t.pressed else if (selected) t.loud else Color.Transparent)
                .combinedClickable(source, null, onLongClick = onLongClick, onClick = onClick)
                .padding(horizontal = Metrics.pad).defaultMinSize(minHeight = minHeight),
            verticalAlignment = Alignment.CenterVertically,
            content = content,
        )
    }
}

/// baud's button: quiet (a fill a step off the surface, a hairline) or strong (the loud fill, its
/// words on it); large on first run and the Add screen; danger for the irreversible, edged in a
/// solid step of the ink.
@Composable
fun Quiet(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    strong: Boolean = false,
    large: Boolean = false,
    danger: Boolean = false,
    enabled: Boolean = true,
    icon: ImageVector? = null,
) {
    val t = LocalTones.current
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    val shape = RoundedCornerShape(8.dp)
    val fg = if (strong) t.onStrong else t.text
    Row(
        modifier.alpha(if (enabled) 1f else 0.45f).defaultMinSize(minHeight = if (large) 46.dp else 40.dp).clip(shape)
            // Pressed, the loud fill settles a step toward the ground: solid, not see-through.
            .background(if (strong) (if (pressed) lerp(t.loud, t.surface, 0.22f) else t.loud) else if (pressed) t.pressed else t.quiet)
            .then(if (strong) Modifier else Modifier.border(1.dp, if (danger) t.tertiary else t.hairline, shape))
            .clickable(source, null, enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(horizontal = if (large) 18.dp else 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
    ) {
        if (icon != null) { Glyph(icon, 17.dp, fg); Spacer(Modifier.width(6.dp)) }
        Text(text, style = Type.body, fontWeight = FontWeight.SemiBold, color = fg, maxLines = 1)
    }
}

/// A small action in a heading or a header: a 36 dp target around a glyph, darkening pressed.
@Composable
fun IconAction(v: ImageVector, description: String, size: Dp = 18.dp, color: Color? = null, onClick: () -> Unit) {
    val t = LocalTones.current
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    Box(
        Modifier.size(40.dp).clip(CircleShape).background(if (pressed) t.pressed else Color.Transparent)
            .clickable(source, null, role = Role.Button, onClick = onClick).semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) { Glyph(v, size, color ?: t.secondary) }
}

/// A small capsule control: darkens pressed, the loud fill when on (its words flipped to read on it).
@Composable
fun Pill(onClick: () -> Unit, modifier: Modifier = Modifier, on: Boolean = false, content: @Composable RowScope.() -> Unit) {
    val t = LocalTones.current
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    CompositionLocalProvider(LocalTones provides if (on && !pressed) t.onLoudTones else t) {
        Row(
            modifier.clip(CircleShape).background(if (pressed) t.pressed else if (on) t.loud else Color.Transparent)
                .clickable(source, null, role = Role.Button, onClick = onClick),
            verticalAlignment = Alignment.CenterVertically,
            content = content,
        )
    }
}

@Composable
fun Hairline(modifier: Modifier = Modifier) = Box(modifier.fillMaxWidth().height(1.dp).background(LocalTones.current.hairline))

/// A section's heading: set apart by size and the space above it.
@Composable
fun SectionHeading(title: String, first: Boolean = false, trailing: @Composable RowScope.() -> Unit = {}) {
    Row(
        Modifier.fillMaxWidth().padding(start = Metrics.inset + Metrics.pad, end = Metrics.inset + 2.dp, top = if (first) 10.dp else Metrics.sectionGap, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, style = Type.heading, color = LocalTones.current.heading, modifier = Modifier.weight(1f).semantics { heading() })
        trailing()
    }
}

/// A quiet sentence where a section is empty: what it is for and the one thing to do.
@Composable
fun EmptyLine(text: String) =
    Text(text, style = Type.small, color = LocalTones.current.secondary, modifier = Modifier.padding(horizontal = Metrics.inset + Metrics.pad, vertical = 4.dp))

/// Unread: a count, heavy, on a solid pill of the loud colour.
@Composable
fun UnreadBadge(count: Int) {
    val t = LocalTones.current
    Box(Modifier.defaultMinSize(18.dp, 18.dp).clip(CircleShape).background(t.loud).padding(horizontal = 5.dp), contentAlignment = Alignment.Center) {
        Text(if (count > 99) "99+" else "$count", fontSize = 12.sp, lineHeight = 14.sp, fontWeight = FontWeight.ExtraBold, color = t.onLoud, style = Type.digits)
    }
}

/// A titled card (You): the section's name at the heading size, its things on a solid card lifted
/// off the ground.
@Composable
fun Card(title: String?, modifier: Modifier = Modifier, pad: Dp = 16.dp, content: @Composable () -> Unit) {
    val t = LocalTones.current
    androidx.compose.foundation.layout.Column(modifier.fillMaxWidth()) {
        if (title != null) {
            Text(title, style = Type.heading, color = t.heading, modifier = Modifier.semantics { heading() })
            Spacer(Modifier.height(8.dp))
        }
        Box(Modifier.fillMaxWidth().glass(Metrics.cardCorner, t).padding(pad)) { content() }
    }
}

/// The light and at most two words: "Online", "Away 2 h", "This one".
@Composable
fun StatusWord(on: Boolean, word: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Light(on, 6.dp)
        Spacer(Modifier.width(4.dp))
        Text(word, style = Type.small, color = LocalTones.current.secondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/// baud's icon, small: the family tile, or the whole tile in the chosen colour.
@Composable
fun BaudTile(side: Dp = 44.dp) {
    val (top, bottom, mark) = LocalTones.current.iconTile
    Box(
        Modifier.size(side).clip(RoundedCornerShape(side * 0.23f)).background(androidx.compose.ui.graphics.Brush.verticalGradient(listOf(top, bottom)))
            .border(1.dp, Color.White.copy(alpha = 0.12f), RoundedCornerShape(side * 0.23f)),
        contentAlignment = Alignment.Center,
    ) { MarkView(Mark.Direct, side * 0.64f, mark) }
}

/// A box that keeps a fixed width for its content's alignment, for the face column of a row.
@Composable
fun FaceColumn(width: Dp, content: @Composable BoxScope.() -> Unit) = Box(Modifier.width(width), contentAlignment = Alignment.Center, content = content)

@Composable
fun DashedSquare(side: Dp, corner: Dp = 10.dp, content: @Composable BoxScope.() -> Unit) {
    val t = LocalTones.current
    Box(Modifier.size(side), contentAlignment = Alignment.Center) {
        Canvas(Modifier.size(side)) {
            drawRoundRect(t.hairline, cornerRadius = androidx.compose.ui.geometry.CornerRadius(corner.toPx()), style = Stroke(1.dp.toPx(), pathEffect = androidx.compose.ui.graphics.PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 3.dp.toPx()))))
        }
        content()
    }
}

// MARK: time in words

private val zone: ZoneId get() = ZoneId.systemDefault()
fun clock(d: Instant): String = DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).format(d.atZone(zone))
fun dayTitle(d: LocalDate): String {
    val today = LocalDate.now(zone)
    return when (d) {
        today -> "Today"
        today.minusDays(1) -> "Yesterday"
        else -> DateTimeFormatter.ofPattern("EEEE, MMM d").format(d)
    }
}
fun whenShort(d: Instant): String {
    val day = d.atZone(zone).toLocalDate()
    val today = LocalDate.now(zone)
    return when (day) {
        today -> clock(d)
        today.minusDays(1) -> "Yesterday"
        else -> DateTimeFormatter.ofPattern("MMM d").format(day)
    }
}

// MARK: pictures

object Images {
    /// A photo drawn small enough (and turned the way it was taken), off the main thread.
    fun load(path: String, maxPixels: Int): Bitmap? {
        val o = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, o)
        if (o.outWidth <= 0) return null
        var sample = 1
        while (maxOf(o.outWidth, o.outHeight) / (sample * 2) >= maxPixels) sample *= 2
        val bmp = BitmapFactory.decodeFile(path, BitmapFactory.Options().apply { inSampleSize = sample }) ?: return null
        val deg = runCatching { ExifInterface(path).rotationDegrees }.getOrDefault(0)
        val scale = minOf(1f, maxPixels.toFloat() / maxOf(bmp.width, bmp.height))
        if (deg == 0 && scale >= 1f) return bmp
        val m = Matrix().apply { postScale(scale, scale); postRotate(deg.toFloat()) }
        return Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, m, true)
    }
}

@Composable
fun Gap(h: Dp) = Spacer(Modifier.height(h))
@Composable
fun RowScope.Fill() = Spacer(Modifier.weight(1f))
@Composable
fun WGap(w: Dp) = Spacer(Modifier.width(w))

/// A width cap for content on a wide screen (a tablet, a foldable open).
fun Modifier.readable(): Modifier = this.widthIn(max = 720.dp)
