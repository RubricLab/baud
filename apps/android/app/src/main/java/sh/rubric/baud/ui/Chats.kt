// Chats (IOSApp.swift's HomeTab): one scroll, Signal's way. My face (You) at the left with this
// phone's status beside it, Chats centred, New at the right; search; every chat; friends with no
// chat yet as "Say hi" rows.
package sh.rubric.baud.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import sh.rubric.baud.AppModel
import sh.rubric.baud.core.Contact
import sh.rubric.baud.core.ConvKind
import sh.rubric.baud.core.Conversation
import sh.rubric.baud.core.ConversationId
import sh.rubric.baud.core.Delivery
import sh.rubric.baud.core.sentence

@Composable
fun Chats(open: (ConversationId) -> Unit, you: () -> Unit) {
    val model = LocalModel.current
    val t = LocalTones.current
    var query by rememberSaveable { mutableStateOf("") }
    var deleting by remember { mutableStateOf<Conversation?>(null) }
    val bottom = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
    // A scroll through the chats puts the search's keyboard away.
    val tuck = rememberKeyboardTuck()
    LazyColumn(Modifier.fillMaxSize().background(t.surface).statusBarsPadding().nestedScroll(tuck), contentPadding = PaddingValues(bottom = bottom + 24.dp)) {
        item("top") {
            Box(Modifier.fillMaxWidth().padding(start = Metrics.inset + Metrics.pad, end = Metrics.inset, top = 4.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.clip(CircleShape).clickable(role = Role.Button, onClick = you).semantics { contentDescription = "You" }) {
                        Avatar(model.me.name, model.me.avatar, 34.dp)
                    }
                    WGap(8.dp)
                    Box(Modifier.widthIn(max = 104.dp)) { NetStatusChip() }
                    Fill()
                    IconAction(Glyphs.compose, "New friend", 21.dp, t.text) { model.offer = AppModel.Offer.Friend }
                }
                Text("Chats", style = Type.heading, color = t.heading, modifier = Modifier.align(Alignment.Center))
            }
        }
        item("search") { SearchField(query, { query = it }, Modifier.padding(horizontal = Metrics.inset + Metrics.pad, vertical = 8.dp)) }
        if (query.trim().length >= 2) {
            items(model.core.search(query), key = { "hit-" + it.event.id }) { h ->
                RowSurface({ open(h.conversation.id) }) {
                    Column(Modifier.padding(vertical = 6.dp)) {
                        Text("${model.name(h.event.user)}: ${h.snippet}", style = Type.body, maxLines = 2, overflow = TextOverflow.Ellipsis)
                        Text(model.title(h.conversation) + " · " + whenShort(h.event.at), style = Type.small, color = t.secondary)
                    }
                }
            }
        } else {
            items(model.chats, key = { it.id }) { c -> ChatRow(c, { open(c.id) }, { deleting = c }) }
            items(model.quiet, key = { "quiet-" + it.user }) { f -> NewChatRow(f) { model.startChat(f.user)?.let(open) } }
            if (model.chats.size <= 1 && model.quiet.isEmpty()) {
                item("new") {
                    Box(Modifier.fillMaxWidth().padding(top = 40.dp), contentAlignment = Alignment.Center) {
                        Quiet("New friend", { model.offer = AppModel.Offer.Friend }, strong = true, icon = Glyphs.plus)
                    }
                }
            }
        }
    }
    // A long press asks first, in red: my notes are cleared on every device of mine; a chat with
    // one friend leaves the list until they write again; a group is left, then gone from the list.
    deleting?.let { c ->
        val name = model.title(c)
        val friend = c.members.any { u -> u != model.me.user && model.contacts.any { it.user == u } }
        when {
            c.kind == ConvKind.Home -> Confirm("Clear your notes?", "Everything in them goes, on all your devices.", "Clear", { deleting = null }) { model.delete(c) }
            c.isDirect -> Confirm("Delete your chat with $name?", "It leaves your list until $name writes again." + if (friend) " You stay friends." else "", "Delete", { deleting = null }) { model.delete(c) }
            else -> Confirm("Leave and delete $name?", "You'll stop getting its messages. Someone still in it can add you back.", "Leave and delete", { deleting = null }) { model.delete(c) }
        }
    }
}

/// The search field, drawn in the palette.
@Composable
fun SearchField(text: String, onChange: (String) -> Unit, modifier: Modifier = Modifier, placeholder: String = "Search") {
    val t = LocalTones.current
    Row(modifier.fillMaxWidth().defaultMinSize(minHeight = 40.dp).clip(RoundedCornerShape(10.dp)).background(t.field).padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        Glyph(Glyphs.search, 17.dp, t.secondary)
        WGap(8.dp)
        BasicTextField(
            text, onChange, Modifier.weight(1f).semantics { contentDescription = placeholder },
            textStyle = Type.body.copy(color = t.text), singleLine = true, cursorBrush = SolidColor(t.strong),
            decorationBox = { inner -> Box { if (text.isEmpty()) Text(placeholder, style = Type.body, color = t.secondary); inner() } },
        )
        if (text.isNotEmpty()) Box(Modifier.clip(CircleShape).clickable { onChange("") }.padding(4.dp).semantics { contentDescription = "Clear" }) { Glyph(Glyphs.clear, 17.dp, t.secondary) }
    }
}

/// A chat: their face and presence (a group's people, gathered), the name, when, my last message's
/// delivery mark before the preview, unread. The whole row is the one thing to tap.
@Composable
private fun ChatRow(c: Conversation, onClick: () -> Unit, onLongClick: () -> Unit) {
    val model = LocalModel.current
    val t = LocalTones.current
    val other = if (c.isDirect) c.members.firstOrNull { it != model.me.user } else null
    val friend = other?.let { u -> model.contacts.firstOrNull { it.user == u } }
    RowSurface(onClick, onLongClick = onLongClick, minHeight = Metrics.chatRow) {
        if (c.kind == ConvKind.Home) Avatar(model.me.name, model.me.avatar, Metrics.face)
        else if (c.kind == ConvKind.Chat && !c.isDirect) GroupFace(c, Metrics.face)
        else Avatar(model.title(c), friend?.avatar, Metrics.face, presence = other?.let { u -> Mark.presence(friend?.devices ?: model.core.members(c.id).firstOrNull { it.user == u }?.devices.orEmpty()) })
        WGap(10.dp)
        Column(Modifier.weight(1f).padding(vertical = 8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(model.title(c), style = Type.body, fontWeight = if (c.unread > 0) FontWeight.SemiBold else FontWeight.Normal, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                WGap(4.dp)
                if (c.kind != ConvKind.Home || c.lastText != null) Text(whenShort(c.lastAt), style = Type.small.merge(Type.digits), color = t.secondary, maxLines = 1)
            }
            Gap(2.dp)
            Row(verticalAlignment = Alignment.CenterVertically) {
                val e = c.lastEvent
                if (c.lastUser == model.me.user && e != null) {
                    DeliveryMark(model.core.delivery(c.id, e), 14.dp)
                    WGap(4.dp)
                }
                Text(preview(model, c), style = Type.small, color = if (c.unread > 0) t.text else t.secondary, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                if (c.unread > 0) { WGap(4.dp); UnreadBadge(c.unread) }
            }
        }
    }
}

/// An empty second line still takes its line, so every row is two lines tall; a place sent once
/// says so in two words, not its link.
private fun preview(model: AppModel, c: Conversation): String {
    val text = c.lastText?.let { if (PlaceText.parse(it) != null) "📍 Location" else it } ?: return if (c.isDirect || c.kind == ConvKind.Home) model.status(c) else " "
    if (c.kind == ConvKind.Home) return text
    val who = when {
        c.lastUser == model.me.user -> "You: "
        c.isDirect -> ""
        else -> c.lastUser?.let { model.name(it) + ": " } ?: ""
    }
    return who + text
}

/// A friend with no chat yet: their face and name, and an invitation. Opening it makes the chat.
@Composable
private fun NewChatRow(friend: Contact, onClick: () -> Unit) {
    val t = LocalTones.current
    RowSurface(onClick, minHeight = Metrics.chatRow) {
        Avatar(friend.name, friend.avatar, Metrics.face, presence = Mark.presence(friend.devices))
        WGap(10.dp)
        Column(Modifier.weight(1f)) {
            Text(friend.name, style = Type.body, maxLines = 1)
            Gap(2.dp)
            Text("Say hi", style = Type.small, color = t.secondary, maxLines = 1)
        }
    }
}

/// A delivery mark; its sentence is its description. Only a mark: it takes no tap of its own, so a
/// tap anywhere on a chat's row opens the chat.
@Composable
fun DeliveryMark(d: Delivery, size: androidx.compose.ui.unit.Dp = 14.dp) {
    val t = LocalTones.current
    val m = Mark.delivery(d)
    Box(Modifier.clearAndSetSemantics { contentDescription = d.sentence }) { MarkView(m, size, if (m == Mark.Sending) t.secondary else t.text) }
}
