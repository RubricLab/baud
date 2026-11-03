// A chat's info (MembersView.swift's place on the phone), in a sheet from the conversation's
// header: who it is, large and centred; its name, which anyone in a group can change; how long its
// messages stay; its people, with Add people first; and at the very bottom, on its own and in red,
// Leave group, which always asks first. A chat with one friend shows them and the timer, no Leave.
package sh.rubric.baud.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
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

/// The info, or the friends to add from it. `close` puts the sheet away; `left` is after I leave
/// the group, and goes back to Chats.
@Composable
fun ChatInfo(conv: ConversationId, close: () -> Unit, left: () -> Unit) {
    val model = LocalModel.current
    val c = model.conversation(conv) ?: return
    var adding by remember(conv) { mutableStateOf(false) }
    BackHandler(adding) { adding = false }
    if (adding) AddPeople(c) { adding = false } else About(c, close, left) { adding = true }
}

/// A group, as opposed to a chat with one friend or my notes.
private val Conversation.group: Boolean get() = !isDirect && kind != ConvKind.Home

@Composable
private fun About(c: Conversation, close: () -> Unit, left: () -> Unit, add: () -> Unit) {
    val model = LocalModel.current
    val t = LocalTones.current
    val members = model.core.members(c.id).sortedWith(compareBy<Member>({ !it.me }, { !it.online }, { model.name(it.user).lowercase() }))
    val admin = model.me.user in c.admins
    val title = model.title(c)
    // Anyone in a group chat names it; in a channel, an admin.
    val nameable = (c.kind == ConvKind.Chat && !c.isDirect) || (c.kind == ConvKind.Channel && admin)
    var renaming by remember { mutableStateOf(false) }
    var leaving by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).navigationBarsPadding().padding(bottom = 24.dp)) {
        Who(c, title, members, nameable) { renaming = true }
        DisappearRow(c)
        if (c.group) {
            SectionHeading("People")
            if (c.kind == ConvKind.Chat || admin) RowSurface(add, Modifier.semantics { contentDescription = "Add people" }, minHeight = 56.dp) {
                Box(Modifier.size(36.dp).clip(CircleShape).background(t.quiet), contentAlignment = Alignment.Center) { Glyph(Glyphs.plus, 18.dp, t.text) }
                WGap(12.dp)
                Text("Add people", style = Type.body, fontWeight = FontWeight.SemiBold)
            }
            for (m in members) key(m.user) { MemberRow(c, m, admin, close) }
        }
        // Leave, apart from everything else: a gap, a rule, and its own row, red.
        if (c.kind == ConvKind.Chat && !c.isDirect) {
            Gap(Metrics.sectionGap)
            Hairline(Modifier.padding(horizontal = Metrics.inset + Metrics.pad))
            Gap(8.dp)
            DangerRow("Leave group", { leaving = true })
        }
    }
    if (renaming) NameDialog(c.name ?: "", { renaming = false }) { model.rename(c.id, it) }
    if (leaving) Confirm("Leave $title?", "You'll stop getting its messages. Someone still in it can add you back.", "Leave", { leaving = false }) {
        if (model.leave(c.id)) left()
    }
}

/// The top, centred: a large disc, the name (a tap renames a group), and under it how many people
/// are in a group, or how the one friend is right now.
@Composable
private fun Who(c: Conversation, title: String, members: List<Member>, nameable: Boolean, rename: () -> Unit) {
    val model = LocalModel.current
    val t = LocalTones.current
    val other = if (c.isDirect) members.firstOrNull { !it.me } else null
    val friend = other?.let { o -> model.contacts.firstOrNull { it.user == o.user } }
    Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(top = 8.dp, bottom = 20.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        when {
            c.kind == ConvKind.Home -> Avatar(model.me.name, model.me.avatar, 88.dp)
            other != null -> Avatar(title, friend?.avatar, 88.dp, presence = Mark.presence(other.devices))
            else -> Avatar(title, null, 88.dp)
        }
        Gap(12.dp)
        Text(
            title, style = Type.title, color = t.heading, textAlign = TextAlign.Center, maxLines = 2, overflow = TextOverflow.Ellipsis,
            modifier = Modifier.clip(RoundedCornerShape(8.dp))
                .then(if (nameable) Modifier.clickable(onClickLabel = "Rename", role = Role.Button, onClick = rename) else Modifier)
                .padding(horizontal = 8.dp, vertical = 2.dp).semantics { heading() },
        )
        Gap(2.dp)
        val line = if (c.group) members.size.let { if (it == 1) "1 person" else "$it people" } else model.status(c)
        Text(line, style = Type.body, color = t.secondary, textAlign = TextAlign.Center, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/// One person in the group: their disc, their name ("You" for me), admin if they are, and their
/// presence word. A tap offers Message (a friend) and, to an admin, Remove from group (red, asked
/// first); there is nothing to offer on my own row.
@Composable
private fun MemberRow(c: Conversation, m: Member, admin: Boolean, close: () -> Unit) {
    val model = LocalModel.current
    val t = LocalTones.current
    val friend = model.contacts.firstOrNull { it.user == m.user }
    val name = if (m.me) "You" else friend?.name ?: m.name.ifEmpty { model.name(m.user) }
    val canMessage = !m.me && friend != null
    val canRemove = admin && !m.me
    var menu by remember { mutableStateOf(false) }
    var removing by remember { mutableStateOf(false) }
    // My own presence is this phone's: online while it reaches the network.
    val on = if (m.me) model.isOnline(model.netState) else m.online
    val word = if (m.me) (if (on) "Online" else "Offline") else presenceWord(m.devices).capitalizedFirst
    Box {
        RowSurface({ menu = true }, minHeight = 56.dp, enabled = canMessage || canRemove) {
            Avatar(if (m.me) model.me.name else name, if (m.me) model.me.avatar else friend?.avatar, 36.dp, presence = if (m.me) null else Mark.presence(m.devices))
            WGap(12.dp)
            Text(name, style = Type.body, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
            if (m.admin) { WGap(8.dp); AdminTag() }
            Fill()
            WGap(8.dp)
            StatusWord(on, word)
        }
        DropdownMenu(menu, { menu = false }, containerColor = t.card) {
            if (canMessage) DropdownMenuItem({ Text("Message", style = Type.body, color = t.text) }, { menu = false; close(); model.message(m.user) })
            if (canRemove) DropdownMenuItem({ Text("Remove from group", style = Type.body, fontWeight = FontWeight.SemiBold, color = t.danger) }, { menu = false; removing = true })
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
        modifier = Modifier.border(1.dp, t.hairline, CircleShape).padding(horizontal = 7.dp, vertical = 1.dp),
    )
}

/// Friends not in the group yet; a tap adds one and goes back to the info, where they now are.
@Composable
private fun AddPeople(c: Conversation, done: () -> Unit) {
    val model = LocalModel.current
    val t = LocalTones.current
    val friends = model.contacts.filter { it.user !in c.members }.sortedBy { it.name.lowercase() }
    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).navigationBarsPadding().padding(bottom = 24.dp)) {
        Row(Modifier.fillMaxWidth().padding(start = 6.dp, end = 16.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            IconAction(Glyphs.back, "Back", 21.dp, t.secondary, done)
            WGap(4.dp)
            Text("Add people", style = Type.heading, color = t.heading, modifier = Modifier.semantics { heading() })
        }
        if (friends.isEmpty()) EmptyLine("Every friend of yours is in it already.")
        for (k in friends) RowSurface({ model.addMember(c.id, k.user); done() }, minHeight = 56.dp) {
            Avatar(k.name, k.avatar, 36.dp, presence = Mark.presence(k.devices))
            WGap(12.dp)
            Text(k.name, style = Type.body, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            WGap(8.dp)
            Glyph(Glyphs.plus, 18.dp, t.secondary, description = "Add ${k.name}")
        }
    }
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
