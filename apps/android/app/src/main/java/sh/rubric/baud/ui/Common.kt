// The pieces every screen is made of (Rows.swift, Theme.swift, MembersView.swift's Quiet): a face,
// a row that darkens when pressed, the quiet and strong buttons, the red row for what can't be
// undone, a small icon action, the pill, a section heading, an empty line, the unread badge, and
// the few glyphs drawn in baud's stroke.
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
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
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
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.semantics.clearAndSetSemantics
import kotlin.math.abs
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
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
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
/// Where a face's photo comes from: the model's blobs in the app, nothing in a preview (initials).
val LocalFaces = staticCompositionLocalOf<(BlobHash, Int) -> ImageBitmap?> { { _, _ -> null } }

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
    val timer = make("timer", listOf("M12 5.5a7.5 7.5 0 1 0 0 15a7.5 7.5 0 1 0 0-15z", "M12 9.2V13l2.6 1.6", "M10 2.8h4"), width = 1.9f)
    val check = make("check", listOf("M5.5 12.5l4.2 4.2L18.5 7.8"), width = 2.2f)
    val chevronRight = make("chevronRight", listOf("M9 5l7 7-7 7"), width = 2.2f)
    val chevronUpDown = make("chevronUpDown", listOf("M8 9.5l4-4 4 4", "M8 14.5l4 4 4-4"), width = 2.1f)
    val pencil = make("pencil", listOf("M4.5 19.5h3.8L19 8.8 15.2 5 4.5 15.7z", "M13 7.2l3.8 3.8"), width = 1.9f)
    val bubble = make("bubble", listOf(), listOf("M12 3.8c4.8 0 8.7 3.3 8.7 7.4s-3.9 7.4-8.7 7.4c-1 0-2-0.1-2.9-0.4L4.6 20.2l1.3-3.9C4.3 14.9 3.3 13.1 3.3 11.2 3.3 7.1 7.2 3.8 12 3.8z"))
    val shield = make("shield", listOf("M12 3l7.2 3v5.6c0 4.5-3 8.1-7.2 9.6-4.2-1.5-7.2-5.1-7.2-9.6V6z"), width = 1.9f)
    val shieldCheck = make("shieldCheck", listOf("M12 3l7.2 3v5.6c0 4.5-3 8.1-7.2 9.6-4.2-1.5-7.2-5.1-7.2-9.6V6z", "M8.7 12.1l2.4 2.4 4.3-4.6"), width = 1.9f)
    /// Where I am: the arrow, open (location), solid (location.fill), struck through (off).
    val location = make("location", listOf("M20 4L3.8 10.9l7.1 2.2 2.2 7.1z"), width = 1.9f)
    val locationFill = make("locationFill", listOf(), listOf("M20.4 3.6a0.6 0.6 0 0 1 0.1 0.6l-6.9 16.3a0.6 0.6 0 0 1-1.1 0l-2.2-6.8-6.8-2.2a0.6 0.6 0 0 1 0-1.1l16.3-6.9a0.6 0.6 0 0 1 0.6 0.1z"))
    val locationOff = make("locationOff", listOf("M20 4L3.8 10.9l7.1 2.2 2.2 7.1z", "M3.5 3.5l17 17"), width = 1.9f)
    val clock = make("clock", listOf("M12 3.5a8.5 8.5 0 1 0 0 17a8.5 8.5 0 1 0 0-17z", "M12 7.5V12l3 2"), width = 1.9f)
    val moon = make("moon", listOf("M19.8 14.6A8 8 0 0 1 9.4 4.2a8 8 0 1 0 10.4 10.4z"), width = 1.9f)
    val infinity = make("infinity", listOf("M12 12c-1.8-2.3-3.3-3.6-5.1-3.6a3.6 3.6 0 0 0 0 7.2c1.8 0 3.3-1.3 5.1-3.6zm0 0c1.8 2.3 3.3 3.6 5.1 3.6a3.6 3.6 0 0 0 0-7.2c-1.8 0-3.3 1.3-5.1 3.6z"), width = 1.9f)
    val people = make("people", listOf("M9 4.5a3.3 3.3 0 1 0 0 6.6a3.3 3.3 0 1 0 0-6.6z", "M2.6 19.5c0.4-3.4 3-5.7 6.4-5.7s6 2.3 6.4 5.7", "M15.8 4.8a3 3 0 0 1 0 6", "M17.6 14c2.2 0.6 3.6 2.6 3.9 5.5"), width = 1.9f)
    val personMinus = make("personMinus", listOf("M10 4a3.6 3.6 0 1 0 0 7.2a3.6 3.6 0 1 0 0-7.2z", "M3.4 20c0.4-3.7 3.1-6.2 6.6-6.2 1.5 0 2.9 0.5 4 1.3", "M16 18h6"), width = 1.9f)
    val personX = make("personX", listOf("M10 4a3.6 3.6 0 1 0 0 7.2a3.6 3.6 0 1 0 0-7.2z", "M3.4 20c0.4-3.7 3.1-6.2 6.6-6.2 1.5 0 2.9 0.5 4 1.3", "M16.6 15.6l4.4 4.4", "M21 15.6l-4.4 4.4"), width = 1.9f)
    val leave = make("leave", listOf("M13 4H7a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h6", "M10.5 12H21", "M17.5 8.5L21 12l-3.5 3.5"), width = 1.9f)
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
    val faces = LocalFaces.current
    val img = hash?.let { faces(it, if (size > 60.dp) 1000 else 200) }
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
/// in any colour, light or dark. Nothing runs to the edge. Not enabled, it's the same row, still.
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
fun RowSurface(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    selected: Boolean = false,
    onLongClick: (() -> Unit)? = null,
    minHeight: Dp = 0.dp,
    enabled: Boolean = true,
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
                .combinedClickable(source, null, enabled = enabled, onLongClick = onLongClick, onClick = onClick)
                .padding(horizontal = Metrics.pad).defaultMinSize(minHeight = minHeight),
            verticalAlignment = Alignment.CenterVertically,
            content = content,
        )
    }
}

/// baud's button: quiet (a fill a step off the surface, a hairline) or strong (the loud fill, its
/// words on it); large on first run and the Add screen. What can't be undone is never one of
/// these: it is a DangerRow.
@Composable
fun Quiet(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    strong: Boolean = false,
    large: Boolean = false,
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
            .then(if (strong) Modifier else Modifier.border(1.dp, t.hairline, shape))
            .clickable(source, null, enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(horizontal = if (large) 18.dp else 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
    ) {
        if (icon != null) { Glyph(icon, 17.dp, fg); Spacer(Modifier.width(6.dp)) }
        Text(text, style = Type.body, fontWeight = FontWeight.SemiBold, color = fg, maxLines = 1)
    }
}

/// What can't be undone (leave, remove, delete, erase), in a row of its own: red words, nothing
/// filled, never beside another button, darker pressed. Whatever it does asks first (Confirm).
@Composable
fun DangerRow(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, centred: Boolean = false) {
    val t = LocalTones.current
    RowSurface(onClick, modifier.semantics { role = Role.Button }, minHeight = Metrics.compactRow) {
        Text(
            text, style = Type.body, fontWeight = FontWeight.SemiBold, color = t.danger, maxLines = 1,
            textAlign = if (centred) TextAlign.Center else TextAlign.Start, modifier = Modifier.weight(1f),
        )
    }
}

/// A small action in a heading or a header: a 48 dp target around a glyph (under a finger, the
/// misses stop), darkening pressed.
@Composable
fun IconAction(v: ImageVector, description: String, size: Dp = 18.dp, color: Color? = null, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val t = LocalTones.current
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    Box(
        modifier.size(48.dp).clip(CircleShape).background(if (pressed) t.pressed else Color.Transparent)
            .clickable(source, null, role = Role.Button, onClick = onClick).semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) { Glyph(v, size, color ?: t.secondary) }
}

/// Back, at a screen's left edge: a wide target from the edge itself (a thumb that lands a little
/// right still goes back), the chevron in ink, a little smaller and dimmer under the finger.
@Composable
fun BackButton(onClick: () -> Unit, modifier: Modifier = Modifier) {
    val t = LocalTones.current
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    Box(
        modifier.size(width = 58.dp, height = 48.dp)
            .clickable(source, null, role = Role.Button, onClick = onClick).semantics { contentDescription = "Back" }
            .padding(start = 14.dp),
        contentAlignment = Alignment.CenterStart,
    ) {
        Glyph(Glyphs.back, 22.dp, t.text, modifier = Modifier.graphicsLayer { val s = if (pressed) 0.94f else 1f; scaleX = s; scaleY = s; alpha = if (pressed) 0.55f else 1f })
    }
}

/// The top of a page in a sheet: Back at the left edge, or a title at the left; its name centred
/// when it was pushed; Close at the right; a hairline under it.
@Composable
fun PageBar(title: String? = null, back: (() -> Unit)? = null, close: (() -> Unit)? = null) {
    val t = LocalTones.current
    Box(Modifier.fillMaxWidth().height(52.dp)) {
        if (back != null) BackButton(back, Modifier.align(Alignment.CenterStart))
        if (title != null) Text(
            title, style = Type.heading, color = t.heading, maxLines = 1, overflow = TextOverflow.Ellipsis,
            textAlign = if (back != null) TextAlign.Center else TextAlign.Start,
            modifier = Modifier.align(if (back != null) Alignment.Center else Alignment.CenterStart)
                .padding(horizontal = if (back != null) 64.dp else Parts.side).semantics { heading() },
        )
        if (close != null) IconAction(Glyphs.xmark, "Close", 15.dp, t.secondary, Modifier.align(Alignment.CenterEnd).padding(end = 4.dp), close)
    }
    Hairline()
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

// MARK: the parts every page is made of (apps/shared/Parts.swift)

/// A section is a heading over a card; a card holds rows; a row is a glyph, words and what it leads
/// to; and anything that can't be undone is last, on its own, in red, and asks first.
object Parts {
    /// Between sections, around a page.
    val gap = 20.dp
    val side = 16.dp
    /// A card's corner.
    val corner = 16.dp
}

/// A section's name over its card: one size, one weight, one ink, everywhere. Quieter than the
/// page's own title and the card's words, so the cards carry the page.
@Composable
fun SectionTitle(text: String) =
    Text(text, style = Type.body, fontWeight = FontWeight.SemiBold, color = LocalTones.current.secondary, modifier = Modifier.padding(start = 4.dp).semantics { heading() })

/// A heading over a card of rows, and a quiet sentence under it. The rows run edge to edge inside.
@Composable
fun ListCard(title: String? = null, footer: String? = null, content: @Composable ColumnScope.() -> Unit) {
    val t = LocalTones.current
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (title != null) SectionTitle(title)
        Column(Modifier.fillMaxWidth().glass(Parts.corner, t).padding(vertical = 6.dp), content = content)
        if (footer != null) Text(footer, style = Type.small, color = t.secondary, modifier = Modifier.padding(horizontal = 4.dp))
    }
}

/// One row of a card: a glyph in a disc the size of a face, its words, and on the right a value or
/// where it leads. With `onClick` it's a row you can press; in red when it can't be undone.
@Composable
fun ActionRow(glyph: ImageVector, title: String, value: String? = null, danger: Boolean = false, enabled: Boolean = true, onClick: (() -> Unit)? = null) {
    val body: @Composable RowScope.() -> Unit = {
        val t = LocalTones.current
        val ink = if (danger) t.danger else t.text
        Box(Modifier.size(Metrics.face).clip(CircleShape).background(t.quiet), contentAlignment = Alignment.Center) { Glyph(glyph, 19.dp, ink) }
        WGap(10.dp)
        Text(title, style = Type.body, fontWeight = FontWeight.Medium, color = ink, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false).alpha(if (enabled) 1f else 0.5f))
        Fill()
        if (value != null) { WGap(6.dp); Text(value, style = Type.body, color = t.secondary, maxLines = 1) }
    }
    if (onClick != null) RowSurface(onClick, Modifier.semantics { role = Role.Button }, minHeight = Metrics.chatRow, enabled = enabled, content = body)
    else Row(Modifier.fillMaxWidth().padding(horizontal = Metrics.inset + Metrics.pad).defaultMinSize(minHeight = Metrics.chatRow), verticalAlignment = Alignment.CenterVertically, content = body)
}

/// One of a few equal tiles side by side, a glyph over a word: what a page is for, a tap each.
@Composable
fun ActionTile(glyph: ImageVector, title: String, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val t = LocalTones.current
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    androidx.compose.foundation.layout.Column(
        modifier.height(64.dp).graphicsLayer { val s = if (pressed) 0.96f else 1f; scaleX = s; scaleY = s; alpha = if (pressed) 0.8f else 1f }
            .glass(Parts.corner, t).clip(RoundedCornerShape(Parts.corner))
            .clickable(source, null, role = Role.Button, onClickLabel = title, onClick = onClick),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterVertically),
    ) {
        Glyph(glyph, 21.dp, t.text)
        Text(title, style = Type.small, fontWeight = FontWeight.SemiBold, color = t.text, maxLines = 1)
    }
}

/// What can't be undone (leaving a group, removing someone): its own card, last on the page, in
/// red; the press asks first, saying what will happen, and only the answer does it.
@Composable
fun DangerCard(glyph: ImageVector, title: String, question: String, detail: String, answer: String, action: () -> Unit) {
    var asking by remember { mutableStateOf(false) }
    ListCard { ActionRow(glyph, title, danger = true) { asking = true } }
    if (asking) Confirm(question, detail, answer, { asking = false }, action)
}

/// A person as a group shows them: a name and maybe a photo.
data class Face(val name: String, val hash: BlobHash? = null)

/// Everyone but me, photos first, then by name; three at most.
fun gather(faces: List<Face>): List<Face> = faces.sortedWith(compareBy<Face>({ it.hash == null }, { it.name })).take(3)

/// A group's faces, read from the model.
fun groupFaces(model: AppModel, c: sh.rubric.baud.core.Conversation): List<Face> =
    gather(c.members.filter { it != model.me.user }.map { u -> Face(model.name(u), model.contacts.firstOrNull { it.user == u }?.avatar) })

/// A group's face: the people in it, two or three of their faces gathered in one circle, each
/// later one cut a ring out of the one under it (photos first), so a group never looks like a
/// person and you can see who's in it at a glance.
@Composable
fun GroupFace(c: sh.rubric.baud.core.Conversation, size: Dp) {
    val model = LocalModel.current
    GroupFace(groupFaces(model, c), model.title(c), size)
}

@Composable
fun GroupFace(faces: List<Face>, title: String, size: Dp, modifier: Modifier = Modifier) {
    val gap = maxOf(1.5f, size.value / 24f).dp
    // Where each face sits, from the middle, as a share of the whole.
    val (d, spots) = when (faces.size) {
        2 -> (size.value * 0.62f).roundToInt().dp.let { d -> d to ((size - d) / 2 / size).let { o -> listOf(-o to -o, o to o) } }
        else -> (size.value * 0.56f).roundToInt().dp to listOf(-0.22f to 0.17f, 0.22f to 0.17f, 0f to -0.22f)
    }
    Box(
        modifier.size(size).graphicsLayer(compositingStrategy = CompositingStrategy.Offscreen).clearAndSetSemantics { contentDescription = title },
        contentAlignment = Alignment.Center,
    ) {
        when (faces.size) {
            0 -> Avatar(title, null, size)
            1 -> Avatar(faces[0].name, faces[0].hash, size)
            else -> faces.take(3).forEachIndexed { i, f ->
                val (x, y) = spots[i]
                if (i > 0) Canvas(Modifier.offset(size * x, size * y).size(d + gap * 2)) { drawCircle(Color.Black, blendMode = BlendMode.Clear) }
                Avatar(f.name, f.hash, d, modifier = Modifier.offset(size * x, size * y))
            }
        }
    }
}

/// Ticked or not, at the end of a row you pick: a ring, or a solid disc with the tick knocked out.
@Composable
fun TickCircle(on: Boolean, size: Dp = 22.dp) {
    val t = LocalTones.current
    Canvas(Modifier.size(size).graphicsLayer(compositingStrategy = CompositingStrategy.Offscreen)) {
        val r = this.size.minDimension / 2
        if (on) {
            drawCircle(t.strong, r)
            val s = this.size.minDimension / 24f
            val tick = androidx.compose.ui.graphics.Path().apply { moveTo(7.2f * s, 12.4f * s); lineTo(10.4f * s, 15.6f * s); lineTo(16.9f * s, 8.8f * s) }
            drawPath(tick, Color.Black, style = Stroke(2.2.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round), blendMode = BlendMode.Clear)
        } else drawCircle(t.tertiary, r - 0.8.dp.toPx(), style = Stroke(1.6.dp.toPx()))
    }
}

/// A finger scrolling a list puts the keyboard away (`downOnly`: only a pull toward the bottom, as
/// Messages does with a chat), and whatever had the cursor lets it go.
@Composable
fun rememberKeyboardTuck(downOnly: Boolean = false): NestedScrollConnection {
    val keyboard = LocalSoftwareKeyboardController.current
    val focus = LocalFocusManager.current
    return remember(keyboard, focus, downOnly) {
        object : NestedScrollConnection {
            override fun onPreScroll(available: Offset, source: NestedScrollSource): Offset {
                if (source == NestedScrollSource.UserInput && (if (downOnly) available.y > 1f else abs(available.y) > 1f)) {
                    focus.clearFocus(); keyboard?.hide()
                }
                return Offset.Zero
            }
        }
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
