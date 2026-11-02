// Sharing where I am in a chat (apps/shared/Places.swift): the pin in its header starts a share
// for an hour, until the end of the day, or until I stop, and stops it; the people sharing in it
// show on a card at its top, their faces and how long ago, and a tap opens the place in the
// phone's own maps app (a geo: link). No map here: no tiles, no SDK, nobody else told.
package sh.rubric.baud.ui

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import sh.rubric.baud.Whereabouts
import sh.rubric.baud.core.ConversationId
import sh.rubric.baud.core.Place
import sh.rubric.baud.core.ago
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.util.Locale

/// The pin in a chat's header: start sharing, for how long, or stop.
@Composable
fun ShareSpot(conv: ConversationId) {
    val model = LocalModel.current
    val t = LocalTones.current
    val context = LocalContext.current
    val sharing = model.sharing.containsKey(conv)
    var menu by remember { mutableStateOf(false) }
    // A share asked for before the permission: the words first, then the system's question.
    var asking by remember { mutableStateOf<Instant?>(null) }
    var why by remember { mutableStateOf(false) }
    var forever by remember { mutableStateOf(false) }
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { got ->
        if (got.values.any { it }) model.share(conv, if (forever) null else asking)
        else model.error = "baud can't see where you are. Turn on Location for baud in Settings to share it."
    }
    fun start(until: Instant?) {
        menu = false
        if (Whereabouts.granted(context)) model.share(conv, until) else { asking = until; forever = until == null; why = true }
    }
    Box {
        Box(
            Modifier.size(36.dp).clip(CircleShape).background(if (sharing) t.strong else androidx.compose.ui.graphics.Color.Transparent).clickable { menu = true },
            contentAlignment = Alignment.Center,
        ) { Glyph(if (sharing) Glyphs.pinFill else Glyphs.pin, 19.dp, if (sharing) t.onStrong else t.secondary, if (sharing) "Sharing your location" else "Share your location") }
        DropdownMenu(menu, { menu = false }, containerColor = t.card) {
            val until = model.sharing[conv]
            if (sharing) {
                Text(if (until == null) "Sharing until you stop" else "Sharing until ${clock(until)}", style = Type.small, color = t.secondary, modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
                DropdownMenuItem({ Text("Stop sharing", style = Type.body, color = t.text, fontWeight = FontWeight.SemiBold) }, { menu = false; model.stopSharing(conv) })
            } else {
                Text("Share your location here", style = Type.small, color = t.secondary, modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
                DropdownMenuItem({ Text("For 1 hour", style = Type.body, color = t.text) }, { start(Instant.now().plusSeconds(3600)) })
                DropdownMenuItem({ Text("Until the end of the day", style = Type.body, color = t.text) }, {
                    start(LocalDate.now().plusDays(1).atStartOfDay(ZoneId.systemDefault()).toInstant())
                })
                DropdownMenuItem({ Text("Until I stop", style = Type.body, color = t.text) }, { start(null) })
            }
        }
    }
    if (why) AlertDialog(
        onDismissRequest = { why = false },
        confirmButton = { TextButton({ why = false; ask.launch(Whereabouts.PERMISSIONS) }) { Text("Continue", color = t.text, fontWeight = FontWeight.Bold) } },
        dismissButton = { TextButton({ why = false }) { Text("Not now", color = t.secondary) } },
        title = { Text("Share where you are", style = Type.heading) },
        text = { Text(Whereabouts.WHY, style = Type.body, color = t.secondary) },
        containerColor = t.card, titleContentColor = t.text, textContentColor = t.secondary,
    )
}

/// The people sharing where they are in this chat, at its top; me too, when I am. Each row opens
/// that place in the phone's maps app.
@Composable
fun PlacesCard(conv: ConversationId) {
    val model = LocalModel.current
    val t = LocalTones.current
    val context = LocalContext.current
    // "2 min ago" moves on its own, and a share whose time is up leaves without a word.
    var tick by remember { mutableIntStateOf(0) }
    LaunchedEffect(conv) { while (true) { delay(30_000); tick++; model.refreshPlaces() } }
    val theirs = remember(conv, model.placesTick, tick) { runCatching { model.core.places(conv) }.getOrDefault(emptyList()) }
    val mine = model.sharing[conv]
    val sharing = model.sharing.containsKey(conv)
    if (theirs.isEmpty() && !sharing) return
    fun open(p: Place) {
        val name = model.name(p.user).split(" ").first()
        val at = String.format(Locale.US, "%.6f,%.6f", p.lat, p.lon)
        val uri = Uri.parse("geo:$at?q=$at(${Uri.encode(name)})")
        try { context.startActivity(Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
        catch (e: ActivityNotFoundException) { model.error = "There's no maps app on this phone to show it in." }
    }
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp).glass(16.dp, t).clip(RoundedCornerShape(16.dp))) {
        for (p in theirs) {
            val name = model.name(p.user)
            Row(Modifier.fillMaxWidth().clickable { open(p) }.padding(horizontal = 12.dp, vertical = 9.dp), verticalAlignment = Alignment.CenterVertically) {
                Avatar(name, model.contacts.firstOrNull { it.user == p.user }?.avatar, 28.dp)
                WGap(10.dp)
                Column(Modifier.weight(1f)) {
                    Text("${name.split(" ").first()} is sharing · ${ago(p.at)}", style = Type.body, color = t.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(if (p.until == null) "Until they stop · open in Maps" else "Until ${clock(p.until)} · open in Maps", style = Type.small, color = t.secondary, maxLines = 1)
                }
                Glyph(Glyphs.pin, 17.dp, t.secondary)
            }
        }
        if (sharing) Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 9.dp), verticalAlignment = Alignment.CenterVertically) {
            Glyph(Glyphs.pinFill, 15.dp, t.secondary)
            WGap(8.dp)
            Text(if (mine == null) "You're sharing until you stop" else "You're sharing until ${clock(mine)}", style = Type.small, color = t.text, maxLines = 1, modifier = Modifier.weight(1f))
            Text("Stop", style = Type.small, color = t.text, fontWeight = FontWeight.SemiBold, modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable { model.stopSharing(conv) }.padding(horizontal = 6.dp, vertical = 2.dp))
        }
    }
}
