// You (apps/shared/SettingsView.swift): me (face, name, colour), my devices, my friends, the
// network, staying connected, the app, and starting over. A picture, a name and a button per
// thing; no sentences.
package sh.rubric.baud.ui

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.fillMaxSize
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LifecycleResumeEffect
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import sh.rubric.baud.AppModel
import sh.rubric.baud.Updates
import sh.rubric.baud.core.Device
import sh.rubric.baud.core.FakeCore
import sh.rubric.baud.core.Peer
import sh.rubric.baud.core.RustCore
import sh.rubric.baud.core.UserId
import sh.rubric.baud.core.sentence

/// You, and a friend pushed over it full height with the way back (PersonPage.kt).
@Composable
fun You(close: () -> Unit) {
    var person by remember { mutableStateOf<UserId?>(null) }
    // Kept out here, so coming back from a friend finds the list where it was.
    val scroll = rememberScrollState()
    BackHandler(person != null) { person = null }
    AnimatedContent(
        targetState = person,
        transitionSpec = {
            val push = targetState != null
            (slideInHorizontally(tween(260)) { w -> if (push) w else -w / 4 } + fadeIn(tween(200))) togetherWith
                (slideOutHorizontally(tween(260)) { w -> if (push) -w / 4 else w } + fadeOut(tween(200)))
        },
        label = "you",
    ) { p ->
        if (p != null) Box(Modifier.fillMaxSize()) { PersonPage(p, null, back = { person = null }, close = close) }
        else Column(
            Modifier.fillMaxWidth().verticalScroll(scroll).padding(horizontal = 16.dp).padding(top = 8.dp, bottom = 40.dp).navigationBarsPadding(),
            verticalArrangement = Arrangement.spacedBy(24.dp),
        ) {
            MeCard()
            NotifyCard()
            DevicesSection(close)
            FriendsSection(close) { person = it }
            NetworkSection()
            StayCard()
            AppCard()
            StartOver(close)
        }
    }
}

@Composable
private fun MeCard() {
    val model = LocalModel.current
    val t = LocalTones.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var renaming by remember { mutableStateOf(false) }
    var name by remember { mutableStateOf(model.me.name) }
    val focus = remember { FocusRequester() }
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        uri ?: return@rememberLauncherForActivityResult
        scope.launch { withContext(Dispatchers.IO) { Picked.face(context, uri) }?.let { model.setPhoto(it) } }
    }
    fun keep() { if (name.isNotBlank() && name.trim() != model.me.name) model.setName(name.trim()); renaming = false }
    Card(null) {
        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box {
                    Avatar(model.me.name, model.me.avatar, 64.dp)
                    Box(
                        Modifier.align(Alignment.BottomEnd).offset(4.dp, 4.dp).size(26.dp).clip(CircleShape).background(t.raised).border(1.dp, t.hairline, CircleShape)
                            .clickable(role = Role.Button) { pick.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }.semantics { contentDescription = "Photo" },
                        contentAlignment = Alignment.Center,
                    ) { Glyph(Glyphs.camera, 13.dp, t.text) }
                }
                WGap(14.dp)
                // The name is the name until it is tapped; then it's a field (Done keeps it).
                if (renaming) {
                    BasicTextField(
                        name, { name = it }, Modifier.weight(1f).focusRequester(focus).onFocusChanged { if (!it.isFocused && renaming) keep() },
                        textStyle = Type.display.copy(color = t.text), singleLine = true, cursorBrush = SolidColor(t.strong),
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done), keyboardActions = KeyboardActions(onDone = { keep() }),
                    )
                    LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }
                } else {
                    Text(model.me.name, style = Type.display, maxLines = 1, overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f).clickable { name = model.me.name; renaming = true }.semantics { contentDescription = "${model.me.name}, rename" })
                }
            }
            Swatches()
        }
    }
}

/// The colour: no colour, or one of eight, in one row. The whole app is downstream of it.
@Composable
private fun Swatches() {
    val model = LocalModel.current
    val t = LocalTones.current
    androidx.compose.foundation.layout.BoxWithConstraints(Modifier.fillMaxWidth()) {
        // Ten targets across: 36 dp each where they fit, smaller on a narrow phone.
        val side = minOf(36.dp, maxWidth / 10)
        @Composable
        fun swatch(hex: String?, fill: Brush, name: String) {
            val on = model.accentHex == hex
            Box(
                Modifier.size(side).clip(CircleShape).clickable(role = Role.Button) { model.pickAccent(hex) }.semantics { contentDescription = name; selected = on },
                contentAlignment = Alignment.Center,
            ) {
                if (on) Box(Modifier.size(side - 2.dp).border(2.dp, t.text, CircleShape))
                Box(Modifier.size(side * 0.72f).clip(CircleShape).background(fill).border(1.dp, t.hairline, CircleShape))
            }
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            // No colour: white (the plain ramp, light or dark as the system is) or black (black in both).
            swatch(null, SolidColor(Color.White), "White")
            swatch(Accent.black, SolidColor(Color.Black), "Black")
            for (s in Accent.swatches) swatch(s.hex, SolidColor(Accent.color(s.hex)!!), s.name)
        }
    }
}

/// What keeps baud from saying a message came: shown only then, a line and a button.
@Composable
private fun NotifyCard() {
    val context = LocalContext.current
    val t = LocalTones.current
    var off by remember { mutableStateOf(false) }
    LifecycleResumeEffect(Unit) {
        off = Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED ||
            !androidx.core.app.NotificationManagerCompat.from(context).areNotificationsEnabled()
        onPauseOrDispose {}
    }
    if (!off) return
    Card("Notifications") {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Glyph(Glyphs.bellOff, 20.dp, t.secondary); WGap(10.dp)
            Text("Notifications are off", style = Type.body, modifier = Modifier.weight(1f))
            Quiet("Turn on", {
                context.startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }, strong = true)
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun DevicesSection(close: () -> Unit) {
    val model = LocalModel.current
    val t = LocalTones.current
    var open by remember { mutableStateOf<Device?>(null) }
    Card("Devices", pad = 8.dp) {
        FlowRow(Modifier.fillMaxWidth(), maxItemsInEachRow = 3) {
            for (d in model.me.devices) {
                val here = d.id == model.me.thisDevice
                Tile(Modifier.weight(1f), { open = d }) {
                    DeviceGlyph(DeviceShape.of(d), 52.dp, lit = here || d.online)
                    Text(Names.device(d.name), style = Type.small, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    StatusWord(here || d.online, if (here) "This one" else d.word.capitalizedFirst)
                }
            }
            Tile(Modifier.weight(1f), { close(); model.offer = AppModel.Offer.Device }) {
                DashedSquare(52.dp) { Glyph(Glyphs.plus, 18.dp, t.text) }
                Text("Add", style = Type.small, fontWeight = FontWeight.SemiBold)
                Text(" ", style = Type.small)
            }
            repeat((3 - (model.me.devices.size + 1) % 3) % 3) { Box(Modifier.weight(1f)) }
        }
    }
    open?.let { d -> BaudSheet({ open = null }) { DeviceCard(d) { open = null } } }
}

/// A tile in a grid: its picture and words, centred, a press darkening it.
@Composable
private fun Tile(modifier: Modifier, onClick: () -> Unit, content: @Composable () -> Unit) {
    Column(
        modifier.clip(RoundedCornerShape(10.dp)).clickable(role = Role.Button, onClick = onClick).padding(8.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp),
    ) { content() }
}

/// A device, opened: its picture, its name, how it is reached; remove it (red, asked first) unless
/// it is this one.
@Composable
private fun DeviceCard(d: Device, done: () -> Unit) {
    val model = LocalModel.current
    val here = d.id == model.me.thisDevice
    var confirm by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth().padding(24.dp).navigationBarsPadding(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
        DeviceGlyph(DeviceShape.of(d), 96.dp, lit = here || d.online)
        Text(d.name, style = Type.title, maxLines = 1)
        StatusWord(here || d.online, if (here) "This one" else d.word.capitalizedFirst)
        if (!here) { Gap(10.dp); DangerRow("Remove", { confirm = true }, centred = true) }
    }
    if (confirm) Confirm("Remove ${d.name}?", "It stops getting your chats and friends. You can add it again later.", "Remove", { confirm = false }) {
        model.attempt { model.core.revoke(d.id) }; model.refreshAll(); done()
    }
}

/// My friends: Add a friend first, then each of them, their presence, and the way in to who they
/// are (PersonPage.kt).
@Composable
private fun FriendsSection(close: () -> Unit, open: (UserId) -> Unit) {
    val model = LocalModel.current
    val t = LocalTones.current
    Card("Friends", pad = 0.dp) {
        Column(Modifier.padding(vertical = 6.dp)) {
            ActionRow(Glyphs.plus, "Add a friend") { close(); model.offer = AppModel.Offer.Friend }
            for (k in model.contacts) {
                RowSurface({ open(k.user) }, minHeight = Metrics.chatRow) {
                    Avatar(k.name, k.avatar, Metrics.face, presence = Mark.presence(k.devices))
                    WGap(10.dp)
                    Text(k.name, style = Type.body, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                    if (k.verified) { WGap(6.dp); MarkView(Mark.Verified, 14.dp, t.secondary) }
                    Fill()
                    WGap(8.dp)
                    StatusWord(k.online, presenceWord(k.devices).capitalizedFirst)
                    WGap(8.dp)
                    Glyph(Glyphs.chevronRight, 13.dp, t.tertiary)
                }
            }
        }
    }
}

/// The network, honestly: this phone's state in its words, and each device it reaches right now.
@Composable
private fun NetworkSection() {
    val model = LocalModel.current
    val t = LocalTones.current
    val s = model.netState
    Card("Network") {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                DeviceGlyph(DeviceShape.Phone, 30.dp, lit = s.lit)
                WGap(10.dp)
                Column(Modifier.weight(1f)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        MarkView(s.mark, 14.dp, if (s.lit) t.strong else t.secondary); WGap(5.dp)
                        Text(s.words(model.connecting), style = Type.body, fontWeight = FontWeight.SemiBold)
                    }
                    Text(s.line(model.connecting), style = Type.small, color = t.secondary)
                }
            }
            val peers = model.peers.sortedWith(compareBy<Peer>({ !it.device.online }, { !it.own }, { it.userName }))
            if (peers.isNotEmpty()) Hairline()
            for (p in peers) PeerRow(p)
            Row(Modifier.fillMaxWidth().padding(top = 4.dp), horizontalArrangement = Arrangement.spacedBy(14.dp, Alignment.CenterHorizontally)) {
                for ((m, w) in listOf(Mark.Direct to "Direct", Mark.Relayed to "Helper", Mark.Held to "Carried", Mark.Waiting to "Waiting")) {
                    Row(verticalAlignment = Alignment.CenterVertically) { MarkView(m, 14.dp, t.secondary); WGap(4.dp); Text(w, style = Type.small, color = t.secondary) }
                }
            }
        }
    }
}

/// A device, whose, how reached.
@Composable
private fun PeerRow(p: Peer) {
    val t = LocalTones.current
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.width(30.dp), contentAlignment = Alignment.Center) { DeviceGlyph(DeviceShape.of(p.device), 22.dp, lit = p.device.online) }
        WGap(10.dp)
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(p.device.name, style = Type.body, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                WGap(4.dp)
                Text(if (p.own) "yours" else p.userName, style = Type.small, color = t.secondary, maxLines = 1)
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (p.device.online) Mark.path(p.device.path)?.let { MarkView(it, 12.dp, t.secondary); WGap(4.dp) }
                Text(p.device.sentence.capitalizedFirst, style = Type.small, color = t.secondary, maxLines = 1)
            }
        }
    }
}

/// Staying reachable with baud closed (Android's own): the connection service, on or off.
@Composable
private fun StayCard() {
    val model = LocalModel.current
    val t = LocalTones.current
    Card(null) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text("Stay connected", style = Type.body, fontWeight = FontWeight.SemiBold)
                Text("Friends reach this phone with baud closed", style = Type.small, color = t.secondary)
            }
            WGap(12.dp)
            Switch(
                model.staying, { model.stay(it) },
                colors = SwitchDefaults.colors(
                    checkedThumbColor = t.onStrong, checkedTrackColor = t.strong, checkedBorderColor = t.strong,
                    uncheckedThumbColor = t.secondary, uncheckedTrackColor = t.quiet, uncheckedBorderColor = t.hairline,
                ),
                modifier = Modifier.semantics { contentDescription = "Stay connected" },
            )
        }
    }
}

/// baud itself: its version, whether a newer one is out (the record is read again when You opens,
/// unless it was just read), and the one button: Update, Updating…, Install, or Check. What went
/// wrong, in a sentence. The core underneath, in a quiet line.
@Composable
private fun AppCard() {
    val model = LocalModel.current
    val t = LocalTones.current
    val context = LocalContext.current
    val v = remember { Updates.current(context) }
    val core = remember { if (model.core is FakeCore) "Preview core" else runCatching { RustCore.version() }.getOrDefault("baud-core") }
    LaunchedEffect(Unit) { Updates.check(context, quiet = true) }
    val state = Updates.state
    Card(null) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            BaudTile()
            WGap(12.dp)
            Column(Modifier.weight(1f)) {
                Text("baud $v", style = Type.body, fontWeight = FontWeight.SemiBold)
                val words = Updates.sentence(::clock)
                if (words.isNotEmpty()) Text(words, style = Type.small, color = t.secondary, maxLines = if (state is Updates.State.Failed) 4 else 1, overflow = TextOverflow.Ellipsis)
                Text(core, style = Type.small, color = t.secondary, maxLines = 1)
            }
            WGap(8.dp)
            when (state) {
                is Updates.State.Available -> Quiet("Update", { Updates.update(context) }, strong = true)
                is Updates.State.Downloading, is Updates.State.Installing -> Quiet("Updating…", {}, enabled = false)
                is Updates.State.Ready -> Quiet("Install", { Updates.update(context) }, strong = true)
                else -> Quiet("Check", { Updates.check(context) }, enabled = state != Updates.State.Checking)
            }
        }
    }
}

/// Start over on this phone: keys, store, friends here, everything. Red, at the very bottom, and
/// a confirmation says so.
@Composable
private fun StartOver(close: () -> Unit) {
    val model = LocalModel.current
    val scope = rememberCoroutineScope()
    var confirm by remember { mutableStateOf(false) }
    DangerRow("Start over", { confirm = true }, centred = true)
    if (confirm) ConfirmErase({ confirm = false }) { close(); scope.launch { model.wipe() } }
}
