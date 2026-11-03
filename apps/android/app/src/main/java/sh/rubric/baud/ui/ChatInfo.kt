// A chat's details (MembersView.swift), in a sheet from the conversation's header, full height:
// its face and name (a group's renamed with a tap), how long its messages stay, its people (each
// opens to who they are, PersonPage.kt), and, last and on its own, leaving. A person and Add people
// are pushed in this same sheet, with the way back, so they open at once: never a sheet over it.
package sh.rubric.baud.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import sh.rubric.baud.core.ConvKind
import sh.rubric.baud.core.Conversation
import sh.rubric.baud.core.ConversationId
import sh.rubric.baud.core.Member
import sh.rubric.baud.core.UserId
import sh.rubric.baud.core.list

/// Where the details sheet is: its first page, a person, or the friends to add.
private sealed interface InfoPage {
    data object About : InfoPage
    data class Person(val user: UserId) : InfoPage
    data object Adding : InfoPage
}

/// The details, or a page pushed in them. `close` puts the sheet away; `left` is after I leave the
/// group, and goes back to Chats.
@Composable
fun ChatInfo(conv: ConversationId, close: () -> Unit, left: () -> Unit) {
    val model = LocalModel.current
    if (model.conversation(conv) == null) return
    var page by remember(conv) { mutableStateOf<InfoPage>(InfoPage.About) }
    BackHandler(page != InfoPage.About) { page = InfoPage.About }
    AnimatedContent(
        targetState = page,
        transitionSpec = {
            val push = targetState != InfoPage.About
            (slideInHorizontally(tween(260)) { w -> if (push) w else -w / 4 } + fadeIn(tween(200))) togetherWith
                (slideOutHorizontally(tween(260)) { w -> if (push) -w / 4 else w } + fadeOut(tween(200)))
        },
        modifier = Modifier.fillMaxSize(),
        label = "details",
    ) { p ->
        val c = model.conversation(conv)
        when {
            c == null -> Box(Modifier.fillMaxSize())
            p is InfoPage.Person -> PersonPage(p.user, conv, back = { page = InfoPage.About }, close = close)
            p == InfoPage.Adding -> AddPeople(conv) { page = InfoPage.About }
            else -> About(c, close, left, person = { page = InfoPage.Person(it) }) { page = InfoPage.Adding }
        }
    }
}

/// A group chat, as opposed to a chat with one friend, my notes, a channel or a space.
private val Conversation.group: Boolean get() = kind == ConvKind.Chat && !isDirect

@Composable
private fun About(c: Conversation, close: () -> Unit, left: () -> Unit, person: (UserId) -> Unit, add: () -> Unit) {
    val model = LocalModel.current
    val members = model.core.members(c.id).sortedWith(compareBy<Member>({ !it.me }, { !it.online }, { it.name }))
    val admin = model.me.user in c.admins
    val title = model.title(c)
    // Anyone in a group chat names it; in a channel, an admin.
    val nameable = c.group || (c.kind == ConvKind.Channel && admin)
    var renaming by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxSize()) {
        PageBar(
            when { c.kind == ConvKind.Home -> "Your devices"; c.group -> "Group info"; c.kind == ConvKind.Channel -> "Channel info"; else -> "Chat info" },
            close = close,
        )
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = Parts.side, vertical = Parts.gap).navigationBarsPadding(),
            verticalArrangement = Arrangement.spacedBy(Parts.gap),
        ) {
            Who(c, title, members, nameable) { renaming = true }
            if (c.kind != ConvKind.Space && c.kind != ConvKind.Home) ListCard(title = "Disappearing messages") { DisappearRow(c) }
            if (c.kind != ConvKind.Home) ListCard(title = if (c.group || c.kind == ConvKind.Channel) "${members.size} people" else "People") {
                if ((c.group && c.kind != ConvKind.Channel) || (admin && c.kind == ConvKind.Channel)) ActionRow(Glyphs.plus, "Add people", onClick = add)
                for (m in members) key(m.user) { MemberRow(c, m, admin, close) { person(m.user) } }
            }
            // Leave, apart from everything else: last, on its own, red, asked first.
            if (c.group) DangerCard(Glyphs.leave, "Leave group", "Leave $title?", "You'll stop getting its messages. Someone still in it can add you back.", "Leave") {
                if (model.leave(c.id)) left()
            }
        }
    }
    if (renaming) NameDialog(c.name ?: "", { renaming = false }) { model.rename(c.id, it) }
}

/// Its face, its name (a group's renamed with a tap) and, under it, how many are in it or how the
/// one other person is.
@Composable
private fun Who(c: Conversation, title: String, members: List<Member>, nameable: Boolean, rename: () -> Unit) {
    val model = LocalModel.current
    val t = LocalTones.current
    val other = if (c.isDirect) members.firstOrNull { !it.me } else null
    Column(Modifier.fillMaxWidth().padding(top = 4.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        when {
            c.kind == ConvKind.Home -> Avatar(model.me.name, model.me.avatar, 72.dp)
            c.group -> GroupFace(c, 72.dp)
            else -> Avatar(title, other?.let { o -> model.contacts.firstOrNull { it.user == o.user }?.avatar }, 72.dp, presence = other?.let { Mark.presence(it.devices) })
        }
        Row(
            Modifier.clip(RoundedCornerShape(8.dp))
                .then(if (nameable) Modifier.clickable(onClickLabel = "Rename", role = Role.Button, onClick = rename) else Modifier)
                .padding(horizontal = 8.dp, vertical = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(title, style = Type.title, color = t.heading, textAlign = TextAlign.Center, maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false).semantics { heading() })
            if (nameable) { WGap(6.dp); Glyph(Glyphs.pencil, 15.dp, t.secondary) }
        }
        Text(subtitle(c, members, other), style = Type.small, color = t.secondary, textAlign = TextAlign.Center, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
private fun subtitle(c: Conversation, members: List<Member>, other: Member?): String {
    val model = LocalModel.current
    if (c.kind == ConvKind.Home) return model.me.devices.size.let { "$it ${if (it == 1) "device" else "devices"}" }
    if (other != null) return if (model.isFriend(other.user)) "Friend · ${presenceWord(other.devices)}" else presenceWord(other.devices).capitalizedFirst
    val online = members.count { !it.me && it.online }
    return "${members.size} people" + if (online > 0) " · $online online" else ""
}

/// One person in it: face and presence, name, whether they're checked, admin; under it who they are
/// to me or who I reach them through; their devices at the end. A tap opens them; a long press
/// offers Message and, to an admin, Remove (red, asked first).
@Composable
private fun MemberRow(c: Conversation, m: Member, admin: Boolean, close: () -> Unit, open: () -> Unit) {
    val model = LocalModel.current
    val t = LocalTones.current
    val friend = model.contacts.firstOrNull { it.user == m.user }
    val name = if (m.me) model.me.name else model.name(m.user)
    val through = model.through(m, c.id)
    var menu by remember { mutableStateOf(false) }
    var removing by remember { mutableStateOf(false) }
    val canMessage = !m.me && friend != null
    val canRemove = admin && !m.me
    Box {
        RowSurface(open, onLongClick = if (canMessage || canRemove) ({ menu = true }) else null, minHeight = Metrics.chatRow) {
            Avatar(if (m.me) model.me.name else m.name, if (m.me) model.me.avatar else friend?.avatar, Metrics.face, presence = Mark.presence(m.devices))
            WGap(9.dp)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(name, style = Type.body, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                    // Checked by me, in ink; a stranger's unchecked key, dotted.
                    if (!m.me && (m.verified || friend == null)) { WGap(4.dp); MarkView(if (m.verified) Mark.Verified else Mark.Unverified, 15.dp, if (m.verified) t.text else t.secondary) }
                    if (m.admin) { WGap(4.dp); AdminTag() }
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    if (through.isNotEmpty()) { MarkView(Mark.Relayed, 14.dp, t.secondary); WGap(4.dp) }
                    Text(
                        when { m.me -> "You"; through.isNotEmpty() -> "through ${list(through)}"; friend != null -> "friend · ${presenceWord(m.devices)}"; else -> presenceWord(m.devices) },
                        style = Type.small, color = t.secondary, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            WGap(4.dp)
            Row(horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                for (d in m.devices) DeviceGlyph(DeviceShape.of(d), 14.dp, lit = d.online || d.id == model.me.thisDevice)
            }
        }
        DropdownMenu(menu, { menu = false }, containerColor = t.card) {
            if (canMessage) DropdownMenuItem({ Text("Message $name", style = Type.body, color = t.text) }, { menu = false; close(); model.message(m.user) })
            if (canRemove) DropdownMenuItem({ Text("Remove from ${model.title(c)}", style = Type.body, fontWeight = FontWeight.SemiBold, color = t.danger) }, { menu = false; removing = true })
        }
    }
    if (removing) Confirm("Remove $name?", "They'll stop getting new messages here.", "Remove", { removing = false }) { model.removeMember(c.id, m.user) }
}

/// "admin", small, in a hairline capsule beside the name.
@Composable
private fun AdminTag() {
    val t = LocalTones.current
    Text(
        "admin", style = Type.small, color = t.secondary, maxLines = 1,
        modifier = Modifier.border(1.dp, t.hairline, androidx.compose.foundation.shape.CircleShape).padding(horizontal = 7.dp, vertical = 1.dp),
    )
}

/// A group's name, in a small dialog: the field (Done or Save keeps it), Save, Cancel. A blank name
/// can't be saved.
@Composable
private fun NameDialog(current: String, dismiss: () -> Unit, save: (String) -> Unit) {
    val t = LocalTones.current
    var text by remember { mutableStateOf(TextFieldValue(current, TextRange(current.length))) }
    val focus = remember { FocusRequester() }
    val ok = text.text.isNotBlank()
    fun keep() { if (ok) { save(text.text); dismiss() } }
    val shape = RoundedCornerShape(Metrics.sheetCorner)
    AlertDialog(
        onDismissRequest = dismiss,
        confirmButton = { TextButton(::keep, enabled = ok) { Text("Save", color = if (ok) t.text else t.tertiary, fontWeight = FontWeight.Bold) } },
        dismissButton = { TextButton(dismiss) { Text("Cancel", color = t.secondary) } },
        text = {
            Column {
                Text("Name", style = Type.small, fontWeight = FontWeight.SemiBold, color = t.secondary)
                Gap(6.dp)
                BasicTextField(
                    text, { text = it },
                    Modifier.fillMaxWidth().focusRequester(focus).clip(shape).background(t.field).border(1.dp, t.hairline, shape).padding(12.dp)
                        .semantics { contentDescription = "Name" },
                    textStyle = Type.body.copy(color = t.text), singleLine = true, cursorBrush = SolidColor(t.strong),
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences, imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { keep() }),
                )
            }
        },
        containerColor = t.card, textContentColor = t.text,
    )
    LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }
}
