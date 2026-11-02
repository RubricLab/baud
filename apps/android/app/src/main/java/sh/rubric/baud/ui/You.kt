// You (apps/shared/SettingsView.swift): me (face, name, colour), my devices, my friends, the
// network, staying connected, the app, and starting over. A picture, a name and a button per
// thing; no sentences.
package sh.rubric.baud.ui

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
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
import sh.rubric.baud.core.Contact
import sh.rubric.baud.core.Device
import sh.rubric.baud.core.FakeCore
import sh.rubric.baud.core.Peer
import sh.rubric.baud.core.RustCore
import sh.rubric.baud.core.sentence

@Composable
fun You(close: () -> Unit) {
    Column(
        Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(top = 8.dp, bottom = 40.dp).navigationBarsPadding(),
        verticalArrangement = Arrangement.spacedBy(24.dp),
    ) {
        MeCard()
        NotifyCard()
        DevicesSection(close)
        FriendsSection(close)
        NetworkSection()
        StayCard()
        AppCard()
        StartOver(close)
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

/// A device, opened: its picture, its name, how it is reached; remove it unless it is this one.
@Composable
private fun DeviceCard(d: Device, done: () -> Unit) {
    val model = LocalModel.current
    val here = d.id == model.me.thisDevice
    var confirm by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth().padding(24.dp).navigationBarsPadding(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
        DeviceGlyph(DeviceShape.of(d), 96.dp, lit = here || d.online)
        Text(d.name, style = Type.title, maxLines = 1)
        StatusWord(here || d.online, if (here) "This one" else d.word.capitalizedFirst)
        if (!here) Quiet("Remove", { confirm = true }, danger = true)
    }
    if (confirm) Confirm("Remove ${d.name}?", "Remove", { confirm = false }) { model.attempt { model.core.revoke(d.id) }; model.refreshAll(); done() }
}

@Composable
private fun FriendsSection(close: () -> Unit) {
    val model = LocalModel.current
    var open by remember { mutableStateOf<Contact?>(null) }
    Card("Friends", pad = 0.dp) {
        Column(Modifier.padding(vertical = 6.dp)) {
            for (k in model.contacts) {
                RowSurface({ open = k }, minHeight = 44.dp) {
                    Avatar(k.name, k.avatar, 32.dp)
                    WGap(10.dp)
                    Text(k.name, style = Type.body, fontWeight = FontWeight.Medium, maxLines = 1)
                    if (k.verified) { WGap(6.dp); MarkView(Mark.Verified, 14.dp, LocalTones.current.secondary) }
                    Fill()
                    StatusWord(k.online, presenceWord(k.devices).capitalizedFirst)
                }
            }
            RowSurface({ close(); model.offer = AppModel.Offer.Friend }, minHeight = 44.dp) {
                Glyph(Glyphs.plus, 18.dp); WGap(8.dp)
                Text("Add", style = Type.body, fontWeight = FontWeight.SemiBold, modifier = Modifier.semantics { contentDescription = "Add a friend" })
            }
        }
    }
    open?.let { k -> BaudSheet({ open = null }) { FriendCard(model.contacts.firstOrNull { it.user == k.user } ?: k, close) { open = null } } }
}

/// A friend, opened: face, name, their devices, Message, and Remove friend.
@Composable
private fun FriendCard(k: Contact, closeYou: () -> Unit, done: () -> Unit) {
    val model = LocalModel.current
    val t = LocalTones.current
    var confirm by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth().padding(24.dp).navigationBarsPadding(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Avatar(k.name, k.avatar, 72.dp)
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(k.name, style = Type.title)
            WGap(6.dp)
            MarkView(if (k.verified) Mark.Verified else if (k.vouched) Mark.Vouched else Mark.Unverified, 16.dp, if (k.verified) t.text else t.secondary)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            for (d in k.devices) Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                DeviceGlyph(DeviceShape.of(d), 40.dp, lit = d.online)
                StatusWord(d.online, d.word.capitalizedFirst)
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Quiet("Message", { done(); closeYou(); model.message(k.user) }, strong = true)
            Quiet("Remove friend", { confirm = true }, danger = true)
        }
    }
    if (confirm) Confirm("Remove ${k.name}?", "Remove", { confirm = false }) { model.unfriend(k.user); done() }
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

/// baud itself: its version, whether a newer one is out (the feed is read when You opens), and
/// Download when it is. The core underneath, in a quiet line.
@Composable
private fun AppCard() {
    val model = LocalModel.current
    val t = LocalTones.current
    val context = LocalContext.current
    val v = remember { sh.rubric.baud.Updates.current(context) }
    val core = remember { if (model.core is FakeCore) "Preview core" else runCatching { RustCore.version() }.getOrDefault("baud-core") }
    LaunchedEffect(Unit) { sh.rubric.baud.Updates.check(context) }
    val state = sh.rubric.baud.Updates.state
    Card(null) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            BaudTile()
            WGap(12.dp)
            Column(Modifier.weight(1f)) {
                Text("baud $v", style = Type.body, fontWeight = FontWeight.SemiBold)
                val word = sh.rubric.baud.Updates.word(::clock)
                if (word.isNotEmpty()) Text(word, style = Type.small, color = t.secondary, maxLines = 1)
                Text(core, style = Type.small, color = t.secondary, maxLines = 1)
            }
            if (state is sh.rubric.baud.Updates.State.Available) {
                WGap(8.dp)
                Quiet("Download", { sh.rubric.baud.Updates.download(context, state.release) }, strong = true)
            }
        }
    }
}

/// Start over on this phone: keys, store, friends here, everything; a confirmation says so.
@Composable
private fun StartOver(close: () -> Unit) {
    val model = LocalModel.current
    val scope = rememberCoroutineScope()
    var confirm by remember { mutableStateOf(false) }
    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) { Quiet("Start over", { confirm = true }, danger = true) }
    if (confirm) Confirm("Erase this phone?", "Erase chats, friends and keys", { confirm = false }) { close(); scope.launch { model.wipe() } }
}
