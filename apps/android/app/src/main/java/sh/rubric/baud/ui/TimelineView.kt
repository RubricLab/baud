// The conversation's timeline (TimelineView.swift): a plain list of precomputed rows, anchored at
// the bottom, paging up. Mine are the loud fill, theirs a card, both lifted off the ground; the day
// is a bold word with no rules; under my newest message, its mark and a few words that spring as
// they change. Grouping, day lines and the delivery sentence come from Timeline; this only draws.
package sh.rubric.baud.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.SizeTransform
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withLink
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import sh.rubric.baud.Timeline
import sh.rubric.baud.whoReacted
import sh.rubric.baud.core.Attachment
import sh.rubric.baud.core.ConvKind
import sh.rubric.baud.core.DeliveryState
import sh.rubric.baud.core.Event
import sh.rubric.baud.core.EventType
import sh.rubric.baud.core.Via
import sh.rubric.baud.core.bytesText
import sh.rubric.baud.core.list
import sh.rubric.baud.core.sentence

/// The timeline: a plain list of precomputed rows, anchored at the bottom, paging up.
@Composable
fun TimelineList(timeline: Timeline, onReply: (Event) -> Unit, modifier: Modifier) {
    val state = rememberLazyListState()
    val rows = timeline.rows.asReversed()
    val status = timeline.status
    val typing = timeline.typing
    // Mine went out: back to the bottom to see it go.
    LaunchedEffect(timeline.events.lastOrNull()?.id) { if (timeline.events.lastOrNull()?.mine == true) state.animateScrollToItem(0) }
    // Near the top: the page before.
    LaunchedEffect(state) {
        snapshotFlow { state.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0 }.collect { last ->
            if (last >= state.layoutInfo.totalItemsCount - 6) timeline.loadMore()
        }
    }
    LazyColumn(modifier.fillMaxWidth(), state = state, reverseLayout = true) {
        item("bottom") { Gap(4.dp) }
        if (typing.isNotEmpty()) item("typing") { DeliveryRow("${list(typing)} ${if (typing.size == 1) "is" else "are"} typing", mine = false) }
        if (status != null) item("status") { DeliveryRow(status, timeline.statusMark) }
        items(rows, key = { it.key }) { row ->
            when (row) {
                is Timeline.Row.Day -> DayRow(row.date)
                is Timeline.Row.Item -> if (row.event.type == EventType.Message) MessageRow(row.event, row.first, row.last, timeline, onReply) else SystemRow(row.event)
            }
        }
    }
}

/// The mark beside the status (Timeline.swift's statusMark): the furthest every one of them has it.
private val Timeline.statusMark: Mark?
    get() {
        val s = status ?: return null
        val d = delivery ?: return null
        if (s == "Sending…") return Mark.Sending
        fun rank(x: DeliveryState) = when (x) { DeliveryState.Read -> 3; DeliveryState.Delivered -> 2; is DeliveryState.Carried -> 1; DeliveryState.Sent -> 0 }
        val byPerson = d.devices.groupBy { it.personName }.mapValues { (_, ds) -> ds.maxOf { rank(it.state) } }
        val floor = byPerson.values.minOrNull() ?: d.devices.minOfOrNull { rank(it.state) } ?: 0
        return listOf(Mark.Sending, Mark.Carried, Mark.Delivered, Mark.Read)[floor]
    }

/// The day, centred and set in bold small type: no rules, the gap is the divider.
@Composable
private fun DayRow(date: java.time.LocalDate) {
    val t = LocalTones.current
    Text(
        dayTitle(date), style = Type.small, fontWeight = FontWeight.Bold, color = t.secondary, textAlign = TextAlign.Center,
        modifier = Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 14.dp, bottom = 4.dp).semantics { heading() },
    )
}

@Composable
private fun SystemRow(e: Event) {
    val t = LocalTones.current
    Row(Modifier.padding(start = 48.dp, end = 16.dp, top = 2.dp, bottom = 2.dp)) {
        Text(e.system ?: "", style = Type.small, color = t.secondary)
        WGap(6.dp)
        Text(clock(e.at), style = Type.small.merge(Type.digits), color = t.secondary)
    }
}

/// Under my newest message, on my side: its mark and its few words ("Waiting for Ana", "Carried by
/// Jo's Mac", "Delivered", "Read"), read in ink, the rest a step under. The mark springs as it
/// changes and the words cross over. A typing line sits on theirs.
@Composable
private fun DeliveryRow(text: String, mark: Mark? = null, mine: Boolean = true) {
    val t = LocalTones.current
    val ink = if (mark == Mark.Read) t.text else t.secondary
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 22.dp).padding(top = 3.dp, bottom = 4.dp).semantics(mergeDescendants = true) {},
        horizontalArrangement = if (mine) Arrangement.End else Arrangement.Start,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        AnimatedContent(
            mark,
            transitionSpec = {
                (scaleIn(spring(dampingRatio = 0.6f, stiffness = 320f), initialScale = 0.4f) + fadeIn(tween(150))) togetherWith
                    (scaleOut(tween(120), targetScale = 0.4f) + fadeOut(tween(120))) using SizeTransform(clip = false)
            },
            label = "mark",
        ) { m -> if (m != null) Row { MarkView(m, 14.dp, if (m == Mark.Read) t.text else t.secondary); WGap(5.dp) } }
        AnimatedContent(text, transitionSpec = { fadeIn(tween(200)) togetherWith fadeOut(tween(200)) }, label = "delivery") {
            Text(it, style = Type.small, fontWeight = FontWeight.SemiBold, color = ink, maxLines = 1)
        }
    }
}

private val quick = listOf("👍", "❤️", "😂", "😮", "😢", "🔥", "🙌", "😍")

/// One message, in a bubble: mine the loud fill on my side, theirs a card on theirs, both lifted. A
/// run of one person's messages reads as one: its inner corners tighten. In a group the first of a
/// run carries their name and the last their face. A tap says how it travelled and when; a long
/// press opens the menu; a double tap is a thumbs up.
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun MessageRow(e: Event, first: Boolean, last: Boolean, timeline: Timeline, onReply: (Event) -> Unit) {
    val model = LocalModel.current
    val t = LocalTones.current
    val context = LocalContext.current
    var menu by remember { mutableStateOf(false) }
    var showPath by remember { mutableStateOf(false) }
    var picking by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf(false) }
    var who by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf(false) }
    fun react(k: String) {
        val on = !(e.reactions.firstOrNull { it.key == k }?.mine ?: false)
        model.attempt { model.core.react(e.conv, e.id, k, on) }
    }
    // Two people, or my chat with myself: no faces, no names, just the two sides.
    val direct = model.conversation(e.conv)?.let { it.isDirect || it.kind == ConvKind.Home } ?: true
    Box(
        Modifier.fillMaxWidth()
            .combinedClickable(remember { MutableInteractionSource() }, null, onLongClick = { menu = true }, onDoubleClick = { react("👍") }, onClick = { showPath = !showPath })
            .padding(start = 16.dp, end = 16.dp, top = if (first) Metrics.groupGap else Metrics.rowGap, bottom = if (last) Metrics.groupBottom else Metrics.rowGap),
    ) {
        Row(
            Modifier.fillMaxWidth().padding(start = if (e.mine) 64.dp else 0.dp, end = if (e.mine) 0.dp else 64.dp),
            horizontalArrangement = if (e.mine) Arrangement.End else Arrangement.Start,
            verticalAlignment = Alignment.Bottom,
        ) {
            if (!e.mine && !direct) {
                if (last) Avatar(model.name(e.user), model.contacts.firstOrNull { it.user == e.user }?.avatar, 28.dp) else Box(Modifier.width(28.dp))
                WGap(8.dp)
            }
            Column(horizontalAlignment = if (e.mine) Alignment.End else Alignment.Start, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                if (first && !e.mine && !direct) Text(model.name(e.user), style = Type.small, fontWeight = FontWeight.SemiBold, color = t.secondary, modifier = Modifier.padding(horizontal = 13.dp))
                Words(e, first, last, timeline)
                for (a in e.attachments) AttachmentBlock(a)
                if (e.reactions.isNotEmpty()) Reactions(e, ::react, { who = true }) { picking = true }
                // How it travelled, and when, a tap away; whether my newest got there is the one line under the chat.
                if (showPath) e.via?.let { v ->
                    Row(Modifier.padding(horizontal = 13.dp), verticalAlignment = Alignment.CenterVertically) {
                        MarkView(mark(v), 14.dp, t.secondary); WGap(5.dp)
                        Text(pathSentence(model, e, v) + " · " + clock(e.at), style = Type.small, color = t.secondary)
                    }
                }
            }
        }
        DropdownMenu(menu, { menu = false }, containerColor = t.card) {
            Row(Modifier.padding(horizontal = 8.dp)) {
                for (k in quick.take(6)) Box(Modifier.clip(CircleShape).clickable { react(k); menu = false }.padding(6.dp)) { Text(k, style = Type.heading) }
            }
            if (e.mine) timeline.delivery?.takeIf { it.event == e.id }?.let { d ->
                Text(d.sentence.capitalizedFirst, style = Type.small, color = t.secondary, modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp))
            }
            MenuItem("Reply") { onReply(e); menu = false }
            if (e.mine && e.text != null) MenuItem("Edit") { editing = true; menu = false }
            MenuItem("Copy") { copy(context, e.text ?: ""); menu = false }
            if (e.mine) MenuItem("Delete", danger = true) { deleting = true; menu = false }
        }
        if (picking) EmojiSheet({ picking = false }) { react(it); picking = false }
        if (editing) EditSheet(e) { editing = false }
        if (who) WhoReacted(e) { who = false }
        if (deleting) Confirm("Delete this message?", "It goes for everyone in this chat.", "Delete", { deleting = false }) {
            model.attempt { model.core.redact(e.conv, e.id) }
        }
    }
}

/// The words in their bubble, a reply's quote riding at the top; a mention of me edged in ink.
@Composable
private fun Words(e: Event, first: Boolean, last: Boolean, timeline: Timeline) {
    val model = LocalModel.current
    val t = LocalTones.current
    val quoted = e.reply?.let { timeline.byId[it] }
    val text = e.text
    if (text == null && quoted == null) return
    val big = 19.dp; val small = 6.dp
    val bubble = if (e.mine) RoundedCornerShape(topStart = big, bottomStart = big, bottomEnd = if (last) big else small, topEnd = if (first) big else small)
    else RoundedCornerShape(topStart = if (first) big else small, bottomStart = if (last) big else small, bottomEnd = big, topEnd = big)
    val mentioned = model.me.user in e.mentions && !e.mine
    Column(
        Modifier.lifted(bubble, if (e.mine) t.loud else t.card, t)
            .then(if (mentioned) Modifier.border(2.dp, t.text, bubble) else Modifier)
            .padding(horizontal = 14.dp, vertical = 9.dp),
        verticalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        quoted?.let { q -> Quote(model.name(q.user), q.text ?: if (q.attachments.isEmpty()) "" else "attachment", onMine = e.mine) }
        val uri = LocalUriHandler.current
        // Every link whole, as it was sent, underlined in the words' own ink; a baud link opens
        // here, on Add, any other in the browser.
        if (text != null) Text(buildAnnotatedString {
            var at = 0
            for (r in links(text)) {
                append(text.substring(at, r.first))
                val url = text.substring(r)
                withLink(LinkAnnotation.Clickable(url, TextLinkStyles(SpanStyle(textDecoration = TextDecoration.Underline))) {
                    if (model.core.parse(url) != null) model.open(url) else runCatching { uri.openUri(url) }
                }) { append(url) }
                at = r.last + 1
            }
            append(text.substring(at))
            if (e.edited) withStyle(SpanStyle(color = if (e.mine) t.onLoudSecondary else t.secondary, fontSize = Type.smallSize)) { append("  edited") }
        }, style = Type.message, color = if (e.mine) t.onLoud else t.text)
    }
}

/// The links in a message: `https://`, `http://` or `baud://` up to the next space, less what a
/// sentence puts after one (a closing bracket only when the link didn't open it).
internal fun links(s: String): List<IntRange> = Regex("(?i)(?:https?|baud)://\\S+").findAll(s).mapNotNull { m ->
    var end = m.range.last + 1
    while (end > m.range.first) {
        val c = s[end - 1]
        val part = s.substring(m.range.first, end)
        if (c in ".,;:!?'\"]}>*" || (c == ')' && part.count { it == ')' } > part.count { it == '(' })) end-- else break
    }
    if (s.substring(m.range.first, end).endsWith("://")) null else m.range.first until end
}.toList()

/// Each reaction on a capsule (mine on the loud fill), and one more to add another. A tap puts mine
/// on or takes it off; a long press says who reacted.
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun Reactions(e: Event, react: (String) -> Unit, who: () -> Unit, pick: () -> Unit) {
    val t = LocalTones.current
    Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
        for (r in e.reactions) Box(
            Modifier.clip(CircleShape).background(if (r.mine) t.loud else t.card)
                .combinedClickable(onClickLabel = if (r.mine) "Take yours off" else "React ${r.key}", onLongClickLabel = "Who reacted", onLongClick = who) { react(r.key) }
                .padding(horizontal = 7.dp, vertical = 3.dp),
        ) { Text("${r.key} ${r.users.size}", style = Type.small.merge(Type.digits), color = if (r.mine) t.onLoud else t.text) }
        Box(
            Modifier.clip(CircleShape).background(t.card).clickable(onClick = pick).defaultMinSize(minHeight = 23.dp)
                .padding(horizontal = 7.dp, vertical = 3.dp).semantics { contentDescription = "React" },
            contentAlignment = Alignment.Center,
        ) { Glyph(Glyphs.smile, 15.dp, t.secondary) }
    }
}

@Composable
private fun MenuItem(text: String, danger: Boolean = false, onClick: () -> Unit) {
    val t = LocalTones.current
    DropdownMenuItem({ Text(text, style = Type.body, color = if (danger) t.danger else t.text, fontWeight = if (danger) FontWeight.SemiBold else FontWeight.Normal) }, onClick)
}

/// Who reacted, in a sheet titled Reactions: each emoji, the most reactions first, and its people
/// by name ("You", the name I gave a friend, else the name they gave). In every chat.
@Composable
private fun WhoReacted(e: Event, dismiss: () -> Unit) {
    val model = LocalModel.current
    val t = LocalTones.current
    BaudSheet(dismiss) {
        Column(Modifier.fillMaxWidth().navigationBarsPadding().padding(bottom = 16.dp)) {
            Text("Reactions", style = Type.heading, color = t.heading, modifier = Modifier.padding(horizontal = Metrics.inset + Metrics.pad).padding(bottom = 8.dp).semantics { heading() })
            for ((key, names) in whoReacted(e.reactions, model.me.user, model::name)) {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = Metrics.inset + Metrics.pad, vertical = 8.dp).semantics(mergeDescendants = true) {},
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(key, style = Type.title, modifier = Modifier.width(40.dp))
                    WGap(8.dp)
                    Text(list(names), style = Type.body, color = t.text, modifier = Modifier.weight(1f))
                    WGap(8.dp)
                    Text("${names.size}", style = Type.small.merge(Type.digits), fontWeight = FontWeight.SemiBold, color = t.secondary)
                }
            }
        }
    }
}

private fun mark(v: Via): Mark = when (v) { Via.Direct -> Mark.Direct; Via.Relay -> Mark.Relayed; Via.Carried -> Mark.Held; Via.Waiting -> Mark.Waiting }

/// How this message travelled, in a few words.
private fun pathSentence(model: sh.rubric.baud.AppModel, e: Event, v: Via): String = when (v) {
    Via.Direct -> if (e.mine) "Went straight to them" else "Came straight from them"
    Via.Relay -> "Through a helper"
    Via.Waiting -> "Waiting for them to come online"
    Via.Carried -> e.carriedBy?.takeIf { !e.mine }?.let { c -> model.peers.firstOrNull { it.device.id == c } }
        ?.let { p -> "Carried by ${if (p.own) "your" else p.userName + "'s"} ${DeviceShape.of(p.device).word}" }
        ?: "Carried by a device while one of you was away"
}

/// A reply's quote: a bar and two lines. Inside my own bubble, in its ink.
@Composable
fun Quote(name: String, text: String, onMine: Boolean = false) {
    val t = LocalTones.current
    val ink = if (onMine) t.onLoudSecondary else t.secondary
    Row(Modifier.height(IntrinsicSize.Min)) {
        Box(Modifier.width(2.dp).fillMaxHeight().clip(RoundedCornerShape(1.dp)).background(ink))
        WGap(6.dp)
        Column {
            Text(name, style = Type.small, fontWeight = FontWeight.Medium, color = ink)
            Text(text, style = Type.small, color = ink, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
    }
}

/// Media as a tidy block: a photo at its own shape; any other file as its kind, name and size.
/// Until the bytes are here it says so, and looks again when someone comes online.
@Composable
private fun AttachmentBlock(a: Attachment) {
    val model = LocalModel.current
    val t = LocalTones.current
    val shape = RoundedCornerShape(10.dp)
    var open by remember { mutableStateOf(false) }
    val online = model.peers.count { it.device.online }
    var missing by remember(a.hash) { mutableStateOf(false) }
    var retry by remember { mutableLongStateOf(0L) }
    val img = if (a.isImage) model.image(a.hash) else null
    LaunchedEffect(a.hash, online, retry) {
        missing = runCatching { model.core.blob(a.hash, a.key) }.isFailure
    }
    val w = a.width ?: 0; val h = a.height ?: 0
    if (a.isImage && w > 0 && h > 0) {
        val ratio = w.toFloat() / h
        Box(
            (if (ratio >= 1f) Modifier.widthIn(max = 320.dp).fillMaxWidth().aspectRatio(ratio) else Modifier.height(320.dp).aspectRatio(ratio, matchHeightConstraintsFirst = true))
                .clip(shape).background(t.quiet).border(1.dp, t.hairline, shape).clickable { if (img != null) open = true else retry++ }
                .semantics { contentDescription = "Photo ${a.name ?: ""}, ${bytesText(a.size)}" },
            contentAlignment = Alignment.Center,
        ) {
            if (img != null) Image(img, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            else if (missing) Text("Waiting for a device that has it", style = Type.small, color = t.secondary, modifier = Modifier.padding(8.dp))
        }
        if (open && img != null) Dialog({ open = false }, DialogProperties(usePlatformDefaultWidth = false)) {
            Box(Modifier.fillMaxSize().background(Color.Black).clickable { open = false }, contentAlignment = Alignment.Center) {
                Image(model.image(a.hash, 2400) ?: img, a.name, Modifier.fillMaxWidth(), contentScale = ContentScale.Fit)
            }
        }
    } else {
        Row(
            Modifier.widthIn(max = 320.dp).clip(shape).background(t.raised).border(1.dp, t.hairline, shape).padding(horizontal = 10.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Glyph(if (a.isImage) Glyphs.photo else Glyphs.doc, 20.dp, t.secondary)
            WGap(10.dp)
            Column {
                Text(a.name ?: "File", style = Type.body, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(bytesText(a.size) + if (missing) " · waiting for a device that has it" else "", style = Type.small, color = t.secondary, maxLines = 1)
            }
        }
    }
}

/// Every emoji worth a tap, for a reaction.
@Composable
private fun EmojiSheet(dismiss: () -> Unit, pick: (String) -> Unit) {
    val all = quick + listOf("🎉", "👏", "🙏", "💯", "✨", "😅", "🤔", "👀", "😭", "🥹", "😎", "🤝", "✌️", "☕️", "🏔️", "🍕")
    BaudSheet(dismiss) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp).navigationBarsPadding().padding(bottom = 16.dp)) {
            for (row in all.chunked(8)) Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                for (k in row) Box(Modifier.size(42.dp).clip(CircleShape).clickable { pick(k) }, contentAlignment = Alignment.Center) { Text(k, style = Type.title) }
            }
        }
    }
}

/// My message, back to be changed.
@Composable
private fun EditSheet(e: Event, done: () -> Unit) {
    val model = LocalModel.current
    val t = LocalTones.current
    var text by remember { mutableStateOf(e.text ?: "") }
    BaudSheet(done) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp).navigationBarsPadding().imePadding().padding(bottom = 16.dp)) {
            Text("Editing", style = Type.small, color = t.secondary)
            Gap(8.dp)
            Field(text, { text = it }, "Message", Modifier.fillMaxWidth())
            Gap(12.dp)
            Quiet("Save", { model.attempt { model.core.edit(e.conv, e.id, text.trim()) }; done() }, strong = true, enabled = text.isNotBlank())
        }
    }
}

@Composable
private fun Field(text: String, onChange: (String) -> Unit, placeholder: String, modifier: Modifier) {
    val t = LocalTones.current
    BasicTextField(
        text, onChange, modifier.clip(RoundedCornerShape(Metrics.sheetCorner)).background(t.field).border(1.dp, t.hairline, RoundedCornerShape(Metrics.sheetCorner)).padding(12.dp),
        textStyle = Type.body.copy(color = t.text), cursorBrush = SolidColor(t.strong), maxLines = 8,
        decorationBox = { inner -> Box { if (text.isEmpty()) Text(placeholder, style = Type.body, color = t.secondary); inner() } },
    )
}

private fun copy(context: Context, s: String) {
    context.getSystemService(ClipboardManager::class.java)?.setPrimaryClip(ClipData.newPlainText("baud", s))
}
