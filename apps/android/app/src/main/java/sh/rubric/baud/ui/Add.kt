// Add (apps/shared/AddView.swift): one screen for a friend and for my own device. My link as a QR
// and a Share button; under it, Scan or paste. A link read from anywhere (scanned, pasted, opened)
// lands here too, already read. When nobody could reach this phone, there is no code: a link that
// cannot be met is never handed out.
package sh.rubric.baud.ui

import android.Manifest
import android.content.ClipboardManager
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import sh.rubric.baud.AppModel
import sh.rubric.baud.AppModel.Join.Phase
import sh.rubric.baud.core.CoreError
import sh.rubric.baud.core.Link
import sh.rubric.baud.core.NetState
import java.time.Instant

@Composable
fun AddView() {
    val model = LocalModel.current
    val t = LocalTones.current
    val kind = model.offer ?: AppModel.Offer.Friend
    var scanning by remember { mutableStateOf(false) }
    // Full height while my answer to a link (its code and why) is up, the rest of the time its own.
    val answering = model.join?.reply != null
    Column(
        Modifier.fillMaxWidth().then(if (answering) Modifier.fillMaxHeight() else Modifier).padding(start = 24.dp, end = 24.dp, top = 22.dp, bottom = 16.dp).navigationBarsPadding(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp, if (answering) Alignment.CenterVertically else Alignment.Top),
    ) {
        val link = model.join?.link
        val ask = model.linkAsk
        when {
            link != null -> JoinPane(link)
            scanning || model.join != null -> ScanPaste(kind) { scanning = false }
            ask != null && kind == AppModel.Offer.Device -> AskBody(ask)
            else -> {
                // Two screens from two places, never a toggle: New friend (compose) and Add a device
                // (You → Devices), each looking like what it makes.
                if (kind == AppModel.Offer.Friend) Text("New friend", style = Type.heading)
                else {
                    Text("Add a device", style = Type.heading)
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        for (d in model.me.devices) DeviceGlyph(DeviceShape.of(d), 28.dp)
                        DashedSquare(24.dp, 6.dp) { Glyph(Glyphs.plus, 11.dp, t.secondary) }
                    }
                }
                OfferPane(kind)
                Quiet("Scan or paste", { scanning = true }, icon = Glyphs.scan)
            }
        }
    }
}

/// Where whoever opens my link meets me: here, through a device I'm connected to, on this Wi-Fi only, or nowhere.
private sealed interface Meeting { data object Here : Meeting; data class Through(val name: String) : Meeting; data object SameWiFi : Meeting; data object None : Meeting }

@Composable
private fun meeting(): Meeting {
    val model = LocalModel.current
    val context = LocalContext.current
    return when (val s = model.netState) {
        NetState.Online -> Meeting.Here
        is NetState.Through -> Meeting.Through(s.name)
        is NetState.NotReachable -> {
            val cm = context.getSystemService(ConnectivityManager::class.java)
            val caps = cm?.getNetworkCapabilities(cm.activeNetwork)
            val lan = caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true || caps?.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) == true
            if (lan) Meeting.SameWiFi else Meeting.None
        }
        NetState.Offline -> Meeting.None
    }
}

/// My link: the QR (or, unreachable, the reason), Share, and who arrived.
@Composable
private fun OfferPane(kind: AppModel.Offer) {
    val model = LocalModel.current
    val t = LocalTones.current
    val context = LocalContext.current
    val m = meeting()
    var link by remember(kind) { mutableStateOf<Link?>(null) }
    var failed by remember { mutableStateOf(false) }
    val before = remember(kind) { if (kind == AppModel.Offer.Friend) model.contacts.map { it.user }.toSet() else model.me.devices.map { it.id }.toSet() }
    fun make() {
        failed = false
        try { link = if (kind == AppModel.Offer.Friend) model.core.invite() else model.core.linkDevice() } catch (e: Exception) { failed = true }
        // The smoke reads the link from a file, since nobody can scan a screenshot (debug builds:
        // `adb shell run-as sh.rubric.baud.dev cat files/link.txt`).
        if (model.debug) link?.let { l -> runCatching { java.io.File(model.context.filesDir, "link.txt").writeText(l.url) } }
    }
    LaunchedEffect(kind, m) { make() }
    // The link just works: an expired one is quietly replaced.
    LaunchedEffect(link) { while (true) { delay(30_000); if (link?.expires?.isBefore(Instant.now()) == true) make() } }
    val now = if (kind == AppModel.Offer.Friend) model.contacts.map { it.user }.toSet() else model.me.devices.map { it.id }.toSet()
    val arrived = (now - before).firstOrNull()
    LaunchedEffect(arrived) { if (arrived != null) model.markOnboarded(true) }
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
        val l = link
        when {
            arrived != null -> Arrived(arrived, kind)
            m == Meeting.None -> NotReachable(compact = true)
            l != null -> {
                QRSquare(l.url)
                when (m) {
                    is Meeting.Through -> Row(verticalAlignment = Alignment.CenterVertically) { MarkView(Mark.Stable, 14.dp, t.secondary); WGap(5.dp); Text("Through ${m.name}", style = Type.small, color = t.secondary) }
                    Meeting.Here -> Row(verticalAlignment = Alignment.CenterVertically) { MarkView(Mark.Direct, 14.dp, t.secondary); WGap(5.dp); Text("Online", style = Type.small, color = t.secondary) }
                    Meeting.SameWiFi -> Row(verticalAlignment = Alignment.CenterVertically) { MarkView(Mark.Waiting, 14.dp, t.secondary); WGap(5.dp); Text("Same Wi-Fi only", style = Type.small, color = t.secondary) }
                    Meeting.None -> {}
                }
                Quiet("Share", {
                    val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, l.web)
                    context.startActivity(Intent.createChooser(send, null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                }, strong = true, icon = Glyphs.share)
            }
            failed -> {
                Text("Try again", style = Type.body, fontWeight = FontWeight.SemiBold)
                Quiet("Try again", ::make)
            }
        }
    }
}

/// Who my link brought: their face (or the device), their name, and the one thing to do next.
@Composable
private fun Arrived(id: String, kind: AppModel.Offer) {
    val model = LocalModel.current
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        val c = model.contacts.firstOrNull { it.user == id }
        val d = model.me.devices.firstOrNull { it.id == id }
        if (kind == AppModel.Offer.Friend && c != null) {
            Avatar(c.name, c.avatar, 72.dp, Mark.presence(c.devices))
            Text(c.name, style = Type.title)
            Quiet("Message", { model.offer = null; model.message(c.user) }, strong = true)
        } else if (d != null) {
            DeviceGlyph(DeviceShape.of(d), 72.dp)
            Text(d.name, style = Type.title)
            Quiet("Done", { model.offer = null }, strong = true)
        }
    }
}

/// Why nothing reaches this phone, and what fixes it (NetStatus.swift's NotReachable).
@Composable
fun NotReachable(compact: Boolean) {
    val model = LocalModel.current
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        if (compact) Text(if (model.connecting) "Connecting" else "Not reachable yet", style = Type.body, fontWeight = FontWeight.SemiBold)
        val away = (model.netState as? NetState.NotReachable)?.away
        val s = when {
            model.connecting -> "Reaching your devices."
            model.netState == NetState.Offline -> "No network."
            away != null -> "Your circle reaches you through $away, and this phone can't reach it right now. baud has to be open there."
            else -> "This network's router opens no ports. If its settings have UPnP, turn it on. Or keep a Mac at home with baud open: you're reachable through it from anywhere."
        }
        Text(s, style = Type.body, textAlign = TextAlign.Center)
    }
}

/// A link I was given: who it is from, one button, then reaching them, then them. A friend's link
/// that isn't getting through gets my answer (a reply) for them to open or scan, in place of the
/// reaching line; their answer to my link (a reply) goes at once, as the inviter.
@Composable
private fun JoinPane(link: Link) {
    val model = LocalModel.current
    val t = LocalTones.current
    val scope = rememberCoroutineScope()
    var name by remember { mutableStateOf("") }
    val phase = model.join?.phase ?: Phase.Ready
    fun set(p: Phase) { model.join = model.join?.copy(phase = p) }
    val person = link.kind != Link.Kind.Device
    val friend = link.kind == Link.Kind.Friend
    val first = link.name.split(" ").first()
    val who = if (person) link.name else "your other device"
    fun unreached() = "Couldn't reach $who. baud has to be open there, and say Online or Through at the bottom."
    /// My answer to their link, once: this phone dials theirs from here until they open it.
    fun answerThem() {
        if (model.join?.reply != null) return
        try { val r = model.core.reply(link); model.join = model.join?.copy(reply = r); android.util.Log.i("baud", "join: answered ${link.name}'s link") }
        catch (e: Exception) { android.util.Log.i("baud", "join: no answer: $e") }
    }
    fun go() {
        // One attempt at a time: a second tap redeemed the same link again.
        if (phase != Phase.Ready) return
        if (person && !model.named) {
            model.setName(name.trim())
            if (!model.named) { set(Phase.Failed("Name didn't save")); model.error = null; return }
        }
        set(Phase.Working(System.currentTimeMillis()))
        // A friend's link still not through after a few seconds: my answer, for them to open or
        // scan. The add goes on meanwhile, and whichever meets first wins.
        val answer = if (friend) scope.launch {
            delay(if (model.join?.scanned == true) 3000 else 5000)
            if (model.join?.phase is Phase.Working) answerThem()
        } else null
        scope.launch {
            try {
                if (person) {
                    val c = model.core.add(link)
                    model.join = model.join?.copy(user = c.user)
                    model.refreshAll()
                } else model.link(link)
                model.markOnboarded(true)
                set(Phase.Done)
            } catch (e: Exception) {
                if (model.join?.phase == Phase.Done) return@launch
                val reached = model.join?.phase is Phase.Reached
                val core = e as? CoreError
                // Nothing got through: my answer waits for them (made now, if it wasn't yet).
                if (friend && !reached && (core is CoreError.Unreachable || core is CoreError.Offline || core == null)) {
                    answerThem()
                    if (model.join?.reply != null) { set(Phase.Replying); return@launch }
                }
                set(Phase.Failed(when {
                    link.kind == Link.Kind.Reply && core == CoreError.Expired -> "$first's answer ran out. Show $first a new link."
                    link.kind == Link.Kind.Reply && core == CoreError.Used -> "Your link was used by someone else. Show $first a new one."
                    link.kind == Link.Kind.Reply && core == CoreError.NotFound -> "This answers a link from another of your devices. Open baud there and try again."
                    link.kind == Link.Kind.Reply && core == CoreError.BadLink -> "That isn't a usable baud link."
                    core == CoreError.Expired -> "That code has expired. Show a new one."
                    core == CoreError.Used -> "That code was already used. Show a new one."
                    // Its first part read, the rest didn't: an app on its way cut it short.
                    core == CoreError.BadLink -> "That link was cut short on its way. Ask for a new one."
                    core is CoreError.Unreachable || core is CoreError.Offline || core == null -> if (reached) "${if (person) link.name else "Your other device"} stopped answering. Try again." else unreached()
                    else -> core.sentence
                }))
            } finally { answer?.cancel() }
        }
    }
    // Their answer to my link: I already asked for this, and they're dialing me now.
    LaunchedEffect(link.url) { if (link.kind == Link.Kind.Reply && model.named && phase == Phase.Ready) go() }
    fun finish() { if (model.named) model.markOnboarded(true); model.refreshAll(); model.join = null; model.offer = null }
    val reply = model.join?.reply
    if (reply != null && (phase is Phase.Working || phase == Phase.Replying)) {
        ReplyCard(link, reply, model.join?.scanned == true)
        return
    }
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
        if (person) Avatar(link.name, null, 72.dp) else DeviceGlyph(DeviceShape.Macbook, 72.dp)
        // A device link inherits the person: no name asked, ever; only a friend link on a first run asks.
        Text(if (person) link.name else if (phase == Phase.Done) model.me.name else "This phone becomes ${link.name}'s", style = Type.title, textAlign = TextAlign.Center, maxLines = 2)
        if (link.kind == Link.Kind.Reply && phase != Phase.Done) Text("Answered your link", style = Type.small, color = t.secondary)
        when (phase) {
            Phase.Ready -> {
                if (!model.named && person) {
                    BasicTextField(
                        name, { name = it },
                        Modifier.widthIn(max = 260.dp).fillMaxWidth().semantics { contentDescription = "Your name" },
                        textStyle = Type.heading.copy(fontWeight = FontWeight.Normal, color = t.text, textAlign = TextAlign.Center), singleLine = true, cursorBrush = SolidColor(t.strong),
                        keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words, imeAction = ImeAction.Go), keyboardActions = KeyboardActions(onGo = { go() }),
                        decorationBox = { inner -> Box(Modifier.clip(RoundedCornerShape(8.dp)).background(t.field).padding(10.dp), contentAlignment = Alignment.Center) { if (name.isEmpty()) Text("Your name", style = Type.heading.copy(fontWeight = FontWeight.Normal), color = t.secondary); inner() } },
                    )
                }
                Quiet(if (person) "Add" else "Join", ::go, strong = true, large = true, enabled = !(person && !model.named && name.isBlank()))
            }
            is Phase.Working -> {
                // Only dialing: the other side hasn't been reached yet.
                var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
                LaunchedEffect(Unit) { while (true) { delay(1000); now = System.currentTimeMillis() } }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    MarkView(Mark.Waiting, 14.dp, t.secondary); WGap(6.dp)
                    Text("Reaching $who… ${(now - phase.since) / 1000} s", style = Type.small, color = t.secondary)
                }
            }
            is Phase.Reached -> {
                val code = model.joiningCode
                if (!person && code != null) {
                    Text(if (code.length == 6) code.take(3) + " " + code.takeLast(3) else code, fontSize = 34.sp, fontWeight = FontWeight.Bold, fontFamily = FontFamily.Monospace)
                    Text("Press Add on your other device if it shows the same code.", style = Type.small, color = t.secondary, textAlign = TextAlign.Center)
                } else Row(verticalAlignment = Alignment.CenterVertically) {
                    MarkView(Mark.Relayed, 14.dp, t.secondary); WGap(6.dp)
                    Text("Reached ${link.name}", style = Type.small, color = t.secondary)
                }
            }
            Phase.Replying -> {}
            Phase.Done -> {
                val user = model.join?.user
                if (person && user != null) Quiet("Message", { finish(); model.message(user) }, strong = true, large = true)
                else Quiet("Done", ::finish, strong = true, large = true)
            }
            is Phase.Failed -> {
                Text(phase.why, style = Type.body, color = t.secondary, textAlign = TextAlign.Center)
                Quiet("Try again", { model.join = model.join?.copy(reply = null, phase = Phase.Ready) })
            }
        }
    }
}

/// My answer to a friend's link that isn't getting through: their network keeps baud out, so they
/// open this (or scan it, standing here) and both sides dial at once. It waits up to fifteen
/// minutes, never past their link.
@Composable
private fun ReplyCard(theirs: Link, reply: Link, scanned: Boolean) {
    val t = LocalTones.current
    val context = LocalContext.current
    val first = theirs.name.split(" ").first()
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) { while (true) { delay(30_000); now = System.currentTimeMillis() } }
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(if (scanned) "Let $first scan this" else "Send this back to $first", style = Type.title, textAlign = TextAlign.Center)
        Text(
            if (scanned) "$first's network isn't letting baud through. On $first's screen: Scan or paste, then point it here."
            else "$first's network isn't letting baud through. Send this to $first the way the link came. When $first opens it, you'll meet.",
            style = Type.small, color = t.secondary, textAlign = TextAlign.Center,
        )
        Box(Modifier.semantics { contentDescription = "Your answer" }) { QRSquare(reply.url) }
        Quiet("Send back", {
            val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, reply.web)
            context.startActivity(Intent.createChooser(send, null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }, strong = !scanned, icon = Glyphs.share)
        val left = maxOf(1L, (reply.expires.toEpochMilli() - now) / 60_000)
        Row(verticalAlignment = Alignment.CenterVertically) {
            MarkView(Mark.Waiting, 14.dp, t.secondary); WGap(6.dp)
            Text("Waiting for $first · $left min left", style = Type.small, color = t.secondary)
        }
    }
}

/// Text that set out as a baud link (and didn't read as one): an app on its way cut it short.
private fun cut(s: String): Boolean = s.filterNot { it.isWhitespace() }.lowercase().let { t ->
    "baud.rubric.sh/add" in t || "baud.rubric.sh/link" in t || t.startsWith("baud://") || t.startsWith("peer1.")
}

/// Scan a code with the camera, or paste one. Whatever it reads becomes the link above.
@Composable
private fun ScanPaste(expect: AppModel.Offer, done: () -> Unit) {
    val model = LocalModel.current
    val t = LocalTones.current
    val context = LocalContext.current
    var text by remember { mutableStateOf("") }
    var bad by remember { mutableStateOf(false) }
    var wrong by remember { mutableStateOf<String?>(null) }
    var camera by remember { mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) }
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { camera = it }
    LaunchedEffect(Unit) { if (!camera) ask.launch(Manifest.permission.CAMERA) }
    fun clipboard(): String? = context.getSystemService(ClipboardManager::class.java)?.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(context)?.toString()
    /// Read by the camera (`scanned`): they're standing here, and can scan my answer back.
    fun read(s: String, scanned: Boolean = false): Boolean {
        val l = model.core.parse(s.trim())
        if (l == null) { bad = s.isNotEmpty(); wrong = null; return false }
        bad = false
        // A stranger can never become my device by a scan on the wrong screen, nor my device a friend.
        // A fresh device (no friends, no other device of mine yet) is joining its person: take it.
        val fresh = model.contacts.isEmpty() && model.me.devices.size <= 1
        if (expect == AppModel.Offer.Friend && l.kind == Link.Kind.Device && !fresh) { wrong = "That's a device link. Use Devices."; return false }
        if (expect == AppModel.Offer.Device && l.kind != Link.Kind.Device) { wrong = "That's a friend link. Use New friend."; return false }
        model.join = AppModel.Join(l, scanned = scanned); done()
        return true
    }
    LaunchedEffect(Unit) { clipboard()?.let { if (model.core.parse(it) != null) text = it } }
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
        if (camera) Scanner(Modifier.fillMaxWidth().height(260.dp)) { read(it, scanned = true) }
        Row(verticalAlignment = Alignment.CenterVertically) {
            BasicTextField(
                text, { text = it },
                Modifier.weight(1f).clip(RoundedCornerShape(8.dp)).background(t.field).padding(10.dp).semantics { contentDescription = "Paste a link" },
                textStyle = Type.mono.copy(color = t.text), singleLine = true, cursorBrush = SolidColor(t.strong),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Go), keyboardActions = KeyboardActions(onGo = { read(text) }),
                decorationBox = { inner -> Box { if (text.isEmpty()) Text("Paste a link", style = Type.mono, color = t.secondary); inner() } },
            )
            WGap(8.dp)
            Quiet("Paste", { text = clipboard() ?: ""; read(text) })
        }
        if (bad) Text(if (cut(text)) "That link was cut short on its way. Ask for a new one." else "Not a baud link", style = Type.small, color = t.secondary, textAlign = TextAlign.Center)
        wrong?.let { Text(it, style = Type.small, fontWeight = FontWeight.SemiBold) }
        Quiet("Back", { model.join = null; done() })
    }
}
