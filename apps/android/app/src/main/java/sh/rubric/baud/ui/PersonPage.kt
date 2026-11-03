// A person, opened (apps/shared/PersonPage.swift): who they are to me, what I can do with them
// (write), whether their key is checked, their devices, the groups we share, and last, on its own,
// ending it (removing a friend, or removing them from a group). One page wherever a person is
// tapped: a friend in You, a member in a chat's details, pushed full height in the sheet it's in.
// And adding people to a group: a page of friends to tick, with the button that adds them always in
// reach at the bottom, pushed in the chat's details (never a sheet over a sheet).
package sh.rubric.baud.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import sh.rubric.baud.AppModel
import sh.rubric.baud.core.ConvKind
import sh.rubric.baud.core.Contact
import sh.rubric.baud.core.ConversationId
import sh.rubric.baud.core.Device
import sh.rubric.baud.core.DeviceId
import sh.rubric.baud.core.UserId
import sh.rubric.baud.core.list

// MARK: a person

/// A group we're both in, as the page lists it.
data class SharedGroup(val id: ConversationId, val title: String, val faces: List<Face>, val people: Int)

/// Everything the person page shows, read from the model once (or made by hand, for a preview).
data class PersonFacts(
    val name: String,
    val face: Face,
    val presence: Mark?,
    val verified: Boolean,
    val subtitle: String,
    val me: Boolean,
    /// A friend: Message, Verify and Remove friend are theirs.
    val friend: Boolean,
    val devices: List<Device>,
    val thisDevice: DeviceId,
    val groups: List<SharedGroup>,
    /// The group this page was opened from, when I'm its admin and they're in it: Remove from it.
    val removeFrom: String?,
) {
    val first: String get() = name.split(" ").firstOrNull { it.isNotEmpty() } ?: name
}

/// Under the name: "You", "Friend · online" (and the name they gave themselves when mine for them
/// differs), "Not your friend", or who I reach them through.
fun personSubtitle(me: Boolean, friendName: String?, cardName: String?, presence: String, through: List<String>): String {
    if (me) return "You"
    if (friendName != null) {
        val card = cardName ?: friendName
        return "Friend · $presence" + if (card != friendName) " · calls themself $card" else ""
    }
    return if (through.isEmpty()) "Not your friend" else "Not your friend · reached through ${list(through)}"
}

fun personFacts(model: AppModel, user: UserId, conv: ConversationId?): PersonFacts {
    val friend = model.contacts.firstOrNull { it.user == user }
    val member = conv?.let { c -> model.core.members(c).firstOrNull { it.user == user } }
    val me = user == model.me.user
    val devices = if (me) model.me.devices else friend?.devices ?: member?.devices.orEmpty()
    val name = if (me) model.me.name else model.name(user)
    // Who carries for them there: the friends in the chat it was opened from.
    val through = conv?.let { c -> member?.let { model.through(it, c) } }.orEmpty()
    val c = conv?.let { model.conversation(it) }
    val groups = if (me) emptyList() else model.conversations.filter {
        it.kind == ConvKind.Chat && !it.isDirect && it.id != conv && user in it.members && model.me.user in it.members
    }
    return PersonFacts(
        name = name,
        face = Face(name, if (me) model.me.avatar else friend?.avatar),
        presence = if (me || devices.isEmpty()) null else Mark.presence(devices),
        verified = friend?.verified ?: member?.verified ?: false,
        subtitle = personSubtitle(me, friend?.name, member?.name, presenceWord(devices), through),
        me = me,
        friend = friend != null,
        devices = devices,
        thisDevice = model.me.thisDevice,
        groups = groups.map { SharedGroup(it.id, model.title(it), groupFaces(model, it), it.members.size) },
        removeFrom = c?.takeIf { !me && it.kind == ConvKind.Chat && !it.isDirect && model.me.user in it.admins && member != null }?.let { model.title(it) },
    )
}

/// The page, under a bar with Back. `back` returns to where it was opened; `close` puts the whole
/// sheet away (Message, a group opened).
@Composable
fun PersonPage(user: UserId, conv: ConversationId?, back: () -> Unit, close: () -> Unit) {
    val model = LocalModel.current
    val facts = personFacts(model, user, conv)
    var verifying by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxSize()) {
        PageBar(back = back)
        PersonBody(
            facts,
            message = { close(); model.message(user) },
            verify = { verifying = true },
            openGroup = { id -> close(); model.reveal = id },
            removeFromGroup = { conv?.let { model.removeMember(it, user) }; back() },
            unfriend = { model.unfriend(user); back() },
        )
    }
    val friend = model.contacts.firstOrNull { it.user == user }
    if (verifying && friend != null) VerifySheet(friend) { verifying = false }
}

/// The page itself, drawn from its facts (a preview draws it too).
@Composable
fun PersonBody(
    f: PersonFacts,
    message: () -> Unit, verify: () -> Unit, openGroup: (ConversationId) -> Unit, removeFromGroup: () -> Unit, unfriend: () -> Unit,
) {
    val t = LocalTones.current
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = Parts.side, vertical = Parts.gap).navigationBarsPadding(),
        verticalArrangement = Arrangement.spacedBy(Parts.gap),
    ) {
        // Who: the face, large, the name and its check, and who they are to me.
        Column(Modifier.fillMaxWidth().padding(top = 4.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Avatar(f.face.name, f.face.hash, 96.dp, presence = f.presence)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(f.name, style = Type.title, color = t.heading, textAlign = TextAlign.Center, maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false).semantics { heading() })
                if (f.verified) { WGap(6.dp); MarkView(Mark.Verified, 18.dp, t.text) }
            }
            Text(f.subtitle, style = Type.small, color = t.secondary, textAlign = TextAlign.Center)
        }
        // Write: what a person is for, a tap. (Calls aren't in this version.)
        if (f.friend && !f.me) Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            ActionTile(Glyphs.bubble, "Message", Modifier.weight(1f), message)
        }
        if (!f.me) ListCard(
            title = "Safety number",
            footer = when {
                f.verified -> "You compared safety numbers with ${f.first}: nobody is in between."
                f.friend -> "Compare the number with ${f.first} in person or on a call. If it matches, nobody is in between."
                else -> "Only a friend's number can be compared."
            },
        ) {
            when {
                f.verified -> ActionRow(Glyphs.shieldCheck, "Verified")
                f.friend -> ActionRow(Glyphs.shield, "Verify ${f.first}", onClick = verify)
                else -> ActionRow(Glyphs.shield, "Not verified")
            }
        }
        ListCard(
            title = if (f.devices.size == 1) "Device" else "Devices",
            footer = if (f.devices.isEmpty()) "Their devices aren't shared with you: only friends see each other's addresses." else null,
        ) {
            for (d in f.devices) DeviceLine(d, d.id == f.thisDevice)
        }
        if (f.groups.isNotEmpty() && !f.me) ListCard(title = "Groups with ${f.first}") {
            for (g in f.groups) RowSurface({ openGroup(g.id) }, minHeight = Metrics.chatRow) {
                GroupFace(g.faces, g.title, Metrics.face)
                WGap(10.dp)
                Text(g.title, style = Type.body, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                WGap(8.dp)
                Text("${g.people} people", style = Type.small, color = LocalTones.current.secondary, maxLines = 1)
            }
        }
        // Last, on their own: what can't be undone, each asked first.
        f.removeFrom?.let { group ->
            DangerCard(Glyphs.personMinus, "Remove from $group", "Remove ${f.name}?", "They'll stop getting new messages here.", "Remove", removeFromGroup)
        }
        if (!f.me && f.friend) {
            DangerCard(Glyphs.personX, "Remove friend", "Remove ${f.name}?", "You'll stop being friends. Your chat leaves your list.", "Remove", unfriend)
        }
    }
}

/// One of their devices: its picture, its name, how it's reached, and its word.
@Composable
private fun DeviceLine(d: Device, here: Boolean) {
    val t = LocalTones.current
    Row(
        Modifier.fillMaxWidth().padding(horizontal = Metrics.inset + Metrics.pad).heightIn(min = Metrics.chatRow).semantics(mergeDescendants = true) {},
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(Metrics.face), contentAlignment = Alignment.Center) { DeviceGlyph(DeviceShape.of(d), 26.dp, lit = here || d.online) }
        WGap(10.dp)
        Text(d.name, style = Type.body, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
        Fill()
        WGap(8.dp)
        if (d.online && !here) Mark.path(d.path)?.let { MarkView(it, 15.dp, t.secondary); WGap(4.dp) }
        StatusWord(here || d.online, if (here) "This phone" else d.word.capitalizedFirst)
    }
}

/// Checking a friend's key: their number and its code, mine under it, and They match.
@Composable
fun VerifySheet(k: Contact, done: () -> Unit) {
    val model = LocalModel.current
    val t = LocalTones.current
    var result by remember { mutableStateOf<String?>(null) }
    BaudSheet(done) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 20.dp).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("Verify ${k.name}", style = Type.body, fontWeight = FontWeight.SemiBold)
            SelectionContainer { Text(k.fingerprint, style = Type.mono, color = t.text) }
            QRSquare(k.fingerprint, 160.dp)
            Text("Yours: ${model.me.fingerprint}", style = Type.mono, color = t.secondary)
            result?.let { Text(it, style = Type.small) }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Quiet("They match", {
                    model.attempt { result = if (model.core.verify(k.user, k.fingerprint)) "Verified." else "They don't match." }
                    model.refreshAll()
                })
                Spacer(Modifier.weight(1f))
                Quiet("Done", done, strong = true)
            }
        }
    }
}

// MARK: adding people

/// Friends not in it yet, by name in any case.
fun addable(contacts: List<Contact>, members: Collection<UserId>?): List<Contact> =
    contacts.filter { members != null && it.user !in members }.sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.name })

/// The ones whose name has what's typed in it, in any case; all of them while nothing is.
fun matching(candidates: List<Contact>, query: String): List<Contact> {
    val q = query.trim()
    return if (q.isEmpty()) candidates else candidates.filter { it.name.contains(q, ignoreCase = true) }
}

/// A search once there are more than six to choose from.
fun searchable(candidates: List<Contact>): Boolean = candidates.size > 6

/// The button: "Add", "Add 1 person", "Add 3 people".
fun addWord(picked: Int): String = if (picked == 0) "Add" else "Add ${if (picked == 1) "1 person" else "$picked people"}"

/// Adding people to a group chat or a space: every friend not in it yet, a tick each, a search once
/// there are many, and the button that adds them pinned at the bottom. Pushed in the chat's details.
@Composable
fun AddPeople(conv: ConversationId, back: () -> Unit) {
    val model = LocalModel.current
    val c = model.conversation(conv)
    var picked by remember(conv) { mutableStateOf(setOf<UserId>()) }
    var query by remember(conv) { mutableStateOf("") }
    Column(Modifier.fillMaxSize()) {
        PageBar("Add people", back = back)
        AddPeopleBody(
            title = c?.let { model.title(it) },
            space = c?.kind == ConvKind.Space,
            noFriends = model.contacts.isEmpty(),
            candidates = addable(model.contacts, c?.members),
            picked = picked,
            toggle = { u -> picked = if (u in picked) picked - u else picked + u },
            query = query,
            search = { query = it },
            add = {
                for (u in picked) model.addMember(conv, u)
                model.refreshAll(); back()
            },
        )
    }
}

/// The page itself, drawn from what it's told (a preview draws it too).
@Composable
fun AddPeopleBody(
    title: String?, space: Boolean, noFriends: Boolean, candidates: List<Contact>,
    picked: Set<UserId>, toggle: (UserId) -> Unit, query: String, search: (String) -> Unit, add: () -> Unit,
) {
    val t = LocalTones.current
    val shown = matching(candidates, query)
    Column(Modifier.fillMaxSize().imePadding()) {
        Column(
            Modifier.weight(1f).nestedScroll(rememberKeyboardTuck()).verticalScroll(rememberScrollState()).padding(horizontal = Parts.side, vertical = Parts.gap),
            verticalArrangement = Arrangement.spacedBy(Parts.gap),
        ) {
            if (candidates.isEmpty()) {
                Column(Modifier.fillMaxWidth().padding(top = 60.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Glyph(Glyphs.people, 38.dp, t.secondary)
                    Text(if (noFriends) "Add a friend first" else "Everyone's here", style = Type.heading, color = t.heading)
                    Text(
                        if (noFriends) "People join a group from your friends." else "All your friends are already in ${title ?: "it"}.",
                        style = Type.body, color = t.secondary, textAlign = TextAlign.Center,
                    )
                }
            } else {
                if (searchable(candidates)) SearchField(query, search, placeholder = "Search friends")
                ListCard(footer = if (space) "Joining a space makes them friends with everyone in it." else "Only friends can be added. Everyone in ${title ?: "the group"} will see who joined.") {
                    for (k in shown) {
                        val on = k.user in picked
                        RowSurface({ toggle(k.user) }, Modifier.semantics { selected = on }, selected = on, minHeight = Metrics.chatRow) {
                            val tt = LocalTones.current
                            Avatar(k.name, k.avatar, Metrics.face, presence = Mark.presence(k.devices))
                            WGap(10.dp)
                            Column(Modifier.weight(1f)) {
                                Text(k.name, style = Type.body, fontWeight = FontWeight.Medium, color = tt.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                Text(presenceWord(k.devices).capitalizedFirst, style = Type.small, color = tt.secondary, maxLines = 1)
                            }
                            WGap(8.dp)
                            TickCircle(on)
                        }
                    }
                    if (shown.isEmpty()) Box(Modifier.padding(horizontal = Metrics.inset + Metrics.pad).heightIn(min = Metrics.chatRow), contentAlignment = Alignment.CenterStart) {
                        Text("No friend called “${query.trim()}”.", style = Type.body, color = t.secondary)
                    }
                }
            }
        }
        if (candidates.isNotEmpty()) Column(Modifier.fillMaxWidth().background(t.surface).navigationBarsPadding()) {
            Hairline()
            Quiet(addWord(picked.size), add, Modifier.padding(horizontal = Parts.side, vertical = 12.dp).fillMaxWidth(), strong = true, large = true, enabled = picked.isNotEmpty())
        }
    }
}
