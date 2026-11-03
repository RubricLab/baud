// Location in a chat (apps/shared/Location.swift), from first principles: what people do is say
// where they are once ("here"), let others follow them for a while (on the way, meeting up), and see
// where everyone is. One sheet from the composer's + does the first two; a place sent once is a
// small tile in the chat; and while anyone shares live, a slim bar under the header lists them.
package sh.rubric.baud.ui

import android.content.Intent
import android.location.Location
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import sh.rubric.baud.Whereabouts
import sh.rubric.baud.core.ConversationId
import sh.rubric.baud.core.Draft
import sh.rubric.baud.core.Place
import sh.rubric.baud.core.list
import java.math.BigDecimal
import java.math.RoundingMode
import java.text.NumberFormat
import java.time.Duration
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.util.Locale
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.log10
import kotlin.math.max

// MARK: a place, once

data class LatLon(val lat: Double, val lon: Double)

/// A place sent once is a message in plain words (a pin and an Apple Maps link), so every baud
/// reads it, old or new, on any device: this one draws it as a tile, an older one shows the link.
/// The same text and the same reading as PlaceText in Location.swift, so the apps read each other's.
object PlaceText {
    const val prefix = "📍 https://maps.apple.com/?ll="

    fun make(lat: Double, lon: Double): String = prefix + fixed5(lat) + "," + fixed5(lon)

    fun parse(s: String?): LatLon? {
        if (s == null || !s.startsWith(prefix)) return null
        // Swift's split drops empty pieces: "1,,2" is two numbers there, so it is here.
        val parts = s.substring(prefix.length).split(',').filter { it.isNotEmpty() }
        if (parts.size != 2) return null
        val lat = number(parts[0]) ?: return null
        val lon = number(parts[1]) ?: return null
        if (!(abs(lat) <= 90 && abs(lon) <= 180)) return null
        return LatLon(lat, lon)
    }

    /// printf's "%.5f", as String(format:) writes it: the double's exact value rounded half to
    /// even, never a locale's comma, and its sign kept ("-0.00000").
    internal fun fixed5(v: Double): String {
        val body = BigDecimal(abs(v)).setScale(5, RoundingMode.HALF_EVEN).toPlainString()
        return if (v < 0 || (v == 0.0 && 1.0 / v < 0)) "-$body" else body
    }

    private val decimal = Regex("[+-]?(\\d+\\.?\\d*|\\.\\d+)([eE][+-]?\\d+)?")
    private val hex = Regex("[+-]?0[xX]([0-9a-fA-F]+\\.?[0-9a-fA-F]*|\\.[0-9a-fA-F]+)([pP][+-]?\\d+)?")

    /// A number as Swift's Double(String) reads one: decimal or hexadecimal, a sign and an exponent
    /// if it likes, and nothing around it (no space, no suffix). Infinity and NaN never make a place.
    internal fun number(s: String): Double? = when {
        decimal.matches(s) -> s.toDoubleOrNull()
        hex.matches(s) -> runCatching { java.lang.Double.parseDouble(if ('p' in s || 'P' in s) s else s + "p0") }.getOrNull()
        else -> null
    }
}

/// "120 m", "1.2 km", or feet and miles (yards and miles in Britain) where the person reads those:
/// the iPhone's road distances (Measurement's .road usage), rounded as it rounds them.
fun distance(metres: Double, locale: Locale = Locale.getDefault()): String {
    val m = max(5.0, metres)
    fun round(v: Double, step: Int): Double = BigDecimal(v).divide(BigDecimal(step)).setScale(0, RoundingMode.HALF_EVEN).multiply(BigDecimal(step)).toDouble()
    fun words(v: Double, decimals: Int): String = NumberFormat.getNumberInstance(locale).apply {
        maximumFractionDigits = decimals; minimumFractionDigits = 0; isGroupingUsed = true
    }.format(BigDecimal(v).setScale(decimals, RoundingMode.HALF_EVEN).toDouble())
    /// A short way: whole units under ten, then tens, then fifties past `fifties`.
    fun near(v: Double, fifties: Int): String = when {
        v < 10 -> words(v, 0)
        v < fifties -> words(round(v, 10), 0)
        else -> words(round(v, 50), 0)
    }
    /// A long way: two figures, and never less than whole units.
    fun far(v: Double): String = words(v, max(0, 2 - (floor(log10(v)).toInt() + 1)))
    val mi = m / 1609.344
    return when (locale.country) {
        "US", "LR", "MM" -> if (mi >= 0.5) "${far(mi)} mi" else "${near(m / 0.3048, 100)} ft"
        "GB" -> if (mi >= 0.5) "${far(mi)} mi" else "${near(m / 0.9144, 100)} yd"
        else -> if (m >= 900) "${far(m / 1000)} km" else "${near(m, 300)} m"
    }
}

/// A place in the chat: a tile in the chat's colour, the sender's face at the spot, and whose it
/// is. A tap opens it in the phone's maps app; a long press is the message's menu.
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun PlaceBubble(face: Face, mine: Boolean, open: () -> Unit, longPress: () -> Unit) {
    val t = LocalTones.current
    val first = face.name.split(" ").firstOrNull { it.isNotEmpty() } ?: face.name
    val ink = if (mine) t.onMine else t.text
    val shape = RoundedCornerShape(13.dp)
    Column(
        Modifier.widthIn(max = 236.dp).clip(shape).combinedClickable(onClickLabel = "Open in Maps", onLongClick = longPress, onClick = open)
            .clearAndSetSemantics {
                contentDescription = if (mine) "Your location" else "${face.name}'s location"
                onClick("Open in Maps") { open(); true }
            },
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        PlaceTile(face, Modifier.fillMaxWidth().aspectRatio(236f / 148f).clip(shape).border(1.dp, t.hairline, shape))
        Row(Modifier.padding(horizontal = 3.dp), verticalAlignment = Alignment.CenterVertically) {
            Glyph(Glyphs.pinFill, 13.dp, ink)
            WGap(5.dp)
            Text(if (mine) "Your location" else "$first's location", style = Type.small, fontWeight = FontWeight.SemiBold, color = ink, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

// MARK: the sheet

/// What the sheet knows about where I am: refused, still looking, or found to within so many metres.
data class Fix(val denied: Boolean = false, val finding: Boolean = true, val found: Boolean = false, val accuracy: Double? = null)

/// Location, from the composer's +: where I am, then the two things to do with it. Sending it once is
/// first (it's what "where are you?" wants); sharing live, for how long, under it; and who sees it,
/// said plainly.
@Composable
fun LocationSheet(conv: ConversationId, done: () -> Unit) {
    val model = LocalModel.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val c = model.conversation(conv)
    var fix by remember { mutableStateOf<Location?>(null) }
    var finding by remember { mutableStateOf(true) }
    var denied by remember { mutableStateOf(false) }
    fun locate() { finding = true; scope.launch { fix = model.whereabouts.once(); finding = false } }
    // The first time, the system asks; refused, the sheet says where to turn it on.
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { got ->
        if (got.values.any { it }) { denied = false; locate() } else { denied = true; finding = false }
    }
    LaunchedEffect(Unit) { if (Whereabouts.granted(context)) locate() else ask.launch(Whereabouts.PERMISSIONS) }
    // Back from Settings with it on: carry on.
    LifecycleResumeEffect(denied) {
        if (denied && Whereabouts.granted(context)) { denied = false; locate() }
        onPauseOrDispose {}
    }
    val who = c?.let { if (it.isDirect) "Only ${model.title(it)} sees it." else "Everyone in ${model.title(it)} sees it, and nobody else." } ?: "Only this chat sees it."
    val f = fix
    BaudSheet(done, full = true) {
        LocationBody(
            me = Face(model.me.name, model.me.avatar),
            fix = Fix(denied, finding, f != null, f?.takeIf { it.hasAccuracy() }?.accuracy?.toDouble()),
            sharing = model.sharing.containsKey(conv), until = model.sharing[conv], who = who,
            close = done,
            send = {
                if (f != null) { model.send(conv, Draft(PlaceText.make(f.latitude, f.longitude))); done() }
            },
            share = { until -> model.share(conv, until); done() },
            stop = { model.stopSharing(conv); done() },
            settings = {
                runCatching {
                    context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                }
            },
        )
    }
}

/// The sheet itself, drawn from what it's told (a preview draws it too).
@Composable
fun LocationBody(
    me: Face, fix: Fix, sharing: Boolean, until: Instant?, who: String,
    close: () -> Unit, send: () -> Unit, share: (Instant?) -> Unit, stop: () -> Unit, settings: () -> Unit,
) {
    val t = LocalTones.current
    Column(Modifier.fillMaxWidth()) {
        Box(Modifier.fillMaxWidth().height(200.dp)) {
            PlaceTile(if (fix.found) me else null, Modifier.fillMaxWidth().fillMaxHeight(), fill = t.quiet, pin = 34.dp)
            if (!fix.found && fix.finding) CircularProgressIndicator(Modifier.align(Alignment.Center).size(30.dp), color = t.secondary, strokeWidth = 2.5.dp)
            Box(Modifier.align(Alignment.TopEnd).padding(8.dp)) {
                Box(Modifier.align(Alignment.Center).size(34.dp).clip(CircleShape).background(t.surface.copy(alpha = 0.9f)))
                IconAction(Glyphs.xmark, "Close", 14.dp, t.text, onClick = close)
            }
        }
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = Parts.side, vertical = Parts.gap).navigationBarsPadding(),
            verticalArrangement = Arrangement.spacedBy(Parts.gap),
        ) {
            if (fix.denied) {
                ListCard(footer = "baud looks for where you are only when you send it or share it.") {
                    ActionRow(Glyphs.locationOff, "Turn on Location for baud", onClick = settings)
                }
            } else {
                ListCard {
                    val value = if (fix.found) fix.accuracy?.let { "within ${distance(it)}" } else if (fix.finding) "Finding you…" else null
                    ActionRow(Glyphs.pin, "Send where you are", value = value, enabled = fix.found, onClick = send)
                }
                if (sharing) {
                    ListCard(title = "Sharing live", footer = "Your place updates here as you move.") {
                        ActionRow(Glyphs.locationFill, if (until == null) "Until you stop" else "Until ${clock(until)}")
                        ActionRow(Glyphs.locationOff, "Stop sharing", danger = true, onClick = stop)
                    }
                } else {
                    ListCard(title = "Share live", footer = "Your place updates as you move, until then, and stops by itself.") {
                        ActionRow(Glyphs.clock, "For 1 hour") { share(Instant.now().plusSeconds(3600)) }
                        ActionRow(Glyphs.moon, "Until tonight") { share(LocalDate.now().plusDays(1).atStartOfDay(ZoneId.systemDefault()).toInstant()) }
                        ActionRow(Glyphs.infinity, "Until you stop") { share(null) }
                    }
                }
            }
            Text("$who It goes straight to their devices, through no server.", style = Type.small, color = t.secondary, modifier = Modifier.padding(horizontal = 4.dp))
        }
    }
}

// MARK: live

/// The bar's words: who shares live here, and whether I do.
fun liveLine(names: List<String>, mine: Boolean, until: Instant?, clock: (Instant) -> String): String {
    if (names.isEmpty() && mine) return if (until == null) "You're sharing live" else "You're sharing live until ${clock(until)}"
    return "${list(names)} ${if (names.size == 1) "is" else "are"} sharing live" + if (mine) " · you too" else ""
}

/// How fresh a place is: "Just now", "4 min ago", "At 6:30 PM".
fun liveAgo(at: Instant, clock: (Instant) -> String): String {
    val s = Duration.between(at, Instant.now()).seconds
    return if (s < 60) "Just now" else if (s < 3600) "${s / 60} min ago" else "At ${clock(at)}"
}

/// While anyone shares live in this chat: their faces and who, in one line under the header, 44 dp
/// tall, and my own share's Stop right there. A tap opens everyone sharing, how fresh, how far.
@Composable
fun LiveBar(conv: ConversationId, share: () -> Unit) {
    val model = LocalModel.current
    val t = LocalTones.current
    // "2 min ago" moves on its own, and a share whose time is up leaves without a word.
    var tick by remember { mutableIntStateOf(0) }
    LaunchedEffect(conv) { while (true) { delay(30_000); tick++; model.refreshPlaces() } }
    val theirs = remember(conv, model.placesTick, tick) { runCatching { model.core.places(conv) }.getOrDefault(emptyList()) }
    val mine = model.sharing.containsKey(conv)
    var open by remember { mutableStateOf(false) }
    AnimatedVisibility(theirs.isNotEmpty() || mine, enter = expandVertically() + fadeIn(), exit = shrinkVertically() + fadeOut()) {
        val shape = RoundedCornerShape(14.dp)
        Row(
            Modifier.padding(start = 12.dp, end = 12.dp, top = 6.dp).fillMaxWidth().height(44.dp).glass(shape, t).clip(shape),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Row(
                Modifier.weight(1f).fillMaxHeight().clickable(onClickLabel = "Who's sharing") { open = true }.padding(start = 12.dp, end = if (mine) 4.dp else 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Faces(theirs.take(3).map { Face(model.name(it.user), model.contacts.firstOrNull { c -> c.user == it.user }?.avatar) })
                WGap(10.dp)
                val names = theirs.map { model.name(it.user).split(" ").firstOrNull { w -> w.isNotEmpty() } ?: "" }
                Text(liveLine(names, mine, model.sharing[conv], ::clock), style = Type.small, fontWeight = FontWeight.SemiBold, color = t.text, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                if (!mine) { WGap(4.dp); Glyph(Glyphs.chevronRight, 13.dp, t.tertiary) }
            }
            if (mine) Box(
                Modifier.fillMaxHeight().widthIn(min = 56.dp).clickable(onClickLabel = "Stop sharing") { model.stopSharing(conv) }.padding(horizontal = 12.dp),
                contentAlignment = Alignment.Center,
            ) { Text("Stop", style = Type.small, fontWeight = FontWeight.Bold, color = t.danger) }
        }
    }
    if (open) LiveList(conv, theirs, done = { open = false }, share = { open = false; share() })
}

/// Up to three faces, overlapped, each on a ring of the ground; the arrow when it's only me.
@Composable
private fun Faces(faces: List<Face>) {
    val t = LocalTones.current
    if (faces.isEmpty()) { Box(Modifier.size(24.dp), contentAlignment = Alignment.Center) { Glyph(Glyphs.locationFill, 14.dp, t.text) }; return }
    Box(Modifier.width(24.dp + 15.dp * (faces.size - 1)).height(27.dp)) {
        faces.forEachIndexed { i, f ->
            Box(Modifier.align(Alignment.CenterStart).offset(x = 15.dp * i - 1.5.dp).size(27.dp).clip(CircleShape).background(t.surface), contentAlignment = Alignment.Center) {
                Avatar(f.name, f.hash, 24.dp)
            }
        }
    }
}

/// Everyone sharing live in the chat, each with how fresh and how far (a tap opens them in the
/// phone's maps app); my own share's stop under them, or a way to start one.
@Composable
private fun LiveList(conv: ConversationId, theirs: List<Place>, done: () -> Unit, share: () -> Unit) {
    val model = LocalModel.current
    val t = LocalTones.current
    val context = LocalContext.current
    val me = remember { model.whereabouts.lastFix }
    val mine = model.sharing.containsKey(conv)
    val until = model.sharing[conv]
    BaudSheet(done) {
        Column(Modifier.fillMaxWidth().navigationBarsPadding().padding(bottom = 12.dp)) {
            for (p in theirs) {
                val name = model.name(p.user)
                RowSurface({ openInMaps(context, p.lat, p.lon, name) { model.error = it } }, minHeight = Metrics.chatRow) {
                    Avatar(name, model.contacts.firstOrNull { it.user == p.user }?.avatar, Metrics.face)
                    WGap(10.dp)
                    Column(Modifier.weight(1f)) {
                        Text(name, style = Type.body, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(liveAgo(p.at, ::clock) + (p.until?.let { " · until ${clock(it)}" } ?: ""), style = Type.small, color = t.secondary, maxLines = 1)
                    }
                    if (me != null) {
                        WGap(8.dp)
                        val d = FloatArray(1).also { Location.distanceBetween(me.latitude, me.longitude, p.lat, p.lon, it) }[0]
                        Text(distance(d.toDouble()), style = Type.small, fontWeight = FontWeight.SemiBold, color = t.secondary, maxLines = 1)
                    }
                }
            }
            if (theirs.isNotEmpty()) Hairline(Modifier.padding(horizontal = Parts.side, vertical = 4.dp))
            if (mine) Row(Modifier.fillMaxWidth().padding(start = Metrics.inset + Metrics.pad, end = 6.dp).height(Metrics.chatRow), verticalAlignment = Alignment.CenterVertically) {
                Text(if (until == null) "You're sharing until you stop" else "You're sharing until ${clock(until)}", style = Type.body, modifier = Modifier.weight(1f))
                Box(
                    Modifier.height(48.dp).widthIn(min = 64.dp).clip(RoundedCornerShape(8.dp)).clickable(onClickLabel = "Stop sharing") { model.stopSharing(conv) }.padding(horizontal = 12.dp),
                    contentAlignment = Alignment.Center,
                ) { Text("Stop", style = Type.body, fontWeight = FontWeight.Bold, color = t.danger) }
            } else Quiet("Share yours", share, Modifier.padding(horizontal = Parts.side, vertical = 8.dp).fillMaxWidth(), strong = true, large = true, icon = Glyphs.location)
        }
    }
}
