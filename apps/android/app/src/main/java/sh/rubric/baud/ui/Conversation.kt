// A conversation (ConversationView.swift): the header with its honest status line, the live bar
// while anyone shares where they are (Location.kt), the timeline (TimelineView.kt) and the composer
// (Composer.kt), all on one solid ground: no band behind the header or the composer, just a
// hairline under the header. A tap on the name opens the chat's info (ChatInfo.kt). Calls are not
// in this version.
package sh.rubric.baud.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import sh.rubric.baud.core.ConvKind
import sh.rubric.baud.core.Conversation
import sh.rubric.baud.core.ConversationId
import sh.rubric.baud.core.Event

@Composable
fun ConversationScreen(conv: ConversationId, back: () -> Unit) {
    val model = LocalModel.current
    val t = LocalTones.current
    val c = model.conversation(conv)
    val timeline = remember(conv) { model.timeline(conv) }
    var reply by remember(conv) { mutableStateOf<Event?>(null) }
    var info by remember(conv) { mutableStateOf(false) }
    var locating by remember(conv) { mutableStateOf(false) }
    DisposableEffect(conv) {
        model.onScreen = conv
        timeline.reload()
        timeline.markRead()
        sh.rubric.baud.Notifier.clearShown(model.context, conv)
        onDispose { if (model.onScreen == conv) model.onScreen = null }
    }
    // Read only while in front: each new event, while the app is in front and this chat on screen.
    LaunchedEffect(timeline.events.size, model.front) { timeline.markRead() }
    Column(Modifier.fillMaxSize().background(t.surface).imePadding()) {
        if (c == null) { Box(Modifier.weight(1f)); return@Column }
        Header(c, back) { info = true }
        LiveBar(c.id) { locating = true }
        TimelineList(timeline, { reply = it }, Modifier.weight(1f))
        Composer(c, reply, clearReply = { reply = null }, locate = { locating = true })
    }
    // Leaving the group closes the info and the chat: back to Chats.
    if (info && c != null) BaudSheet(onDismiss = { info = false }, full = true) { ChatInfo(c.id, close = { info = false }, left = { info = false; back() }) }
    // Location, from the composer's + (or the live list's Share yours).
    if (locating && c != null) LocationSheet(c.id) { locating = false }
}

/// Name, topic, and the status sentence: the presence light when they're here, then "Online ·
/// direct, 14 ms", "Last online 2 h ago", "3 online", in ink while someone is here. The name and
/// the sentence under it open the chat's info.
@Composable
private fun Header(c: Conversation, back: () -> Unit, info: () -> Unit) {
    val model = LocalModel.current
    val t = LocalTones.current
    val others = model.core.members(c.id).filter { !it.me }
    // My chat with myself is live when another of my devices is.
    val own = c.kind == ConvKind.Home
    val live = if (own) model.me.devices.any { it.online && it.id != model.me.thisDevice } else others.any { it.online }
    Column(Modifier.background(t.surface).statusBarsPadding()) {
        Row(Modifier.fillMaxWidth().defaultMinSize(minHeight = 56.dp).padding(end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            // Back: a wide target from the screen's edge, and a gap before the name, which opens the details.
            BackButton(back)
            WGap(6.dp)
            Column(
                Modifier.weight(1f).clip(RoundedCornerShape(9.dp)).clickable(onClickLabel = "Chat info", role = Role.Button, onClick = info)
                    .padding(vertical = 6.dp, horizontal = 4.dp),
                verticalArrangement = Arrangement.spacedBy(3.dp),
            ) {
                Row(verticalAlignment = Alignment.Bottom) {
                    Text(model.title(c), style = Type.title, color = t.heading, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                    c.topic?.takeIf { it.isNotEmpty() }?.let { WGap(8.dp); Text(it, style = Type.small, color = t.secondary, maxLines = 1) }
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    if (c.isDirect) others.firstOrNull()?.let { o ->
                        val p = Mark.presence(o.devices)
                        AnimatedVisibility(p == Mark.Online || p == Mark.OnlineRelayed, enter = scaleIn() + fadeIn(), exit = scaleOut() + fadeOut()) {
                            Row { PresenceLight(p == Mark.OnlineRelayed, 8.dp); WGap(5.dp) }
                        }
                    } else c.space?.let { model.conversation(it) }?.let { s ->
                        Text(s.name ?: "", style = Type.small, fontWeight = FontWeight.SemiBold, color = t.secondary, maxLines = 1)
                        WGap(5.dp); Text("·", style = Type.small, color = t.secondary); WGap(5.dp)
                    }
                    AnimatedContent(model.status(c) to live, transitionSpec = { fadeIn(tween(200)) togetherWith fadeOut(tween(200)) }, label = "status") { (s, on) ->
                        Text(s, style = Type.small, fontWeight = FontWeight.Medium, color = if (on) t.text else t.secondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
            if (c.kind != ConvKind.Space) DisappearMark(c, info)
        }
        Hairline()
    }
}
