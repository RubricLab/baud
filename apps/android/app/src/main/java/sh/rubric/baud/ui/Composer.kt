// The composer (ComposerView.swift): multiline, a reply strip, photos (picked, shown before they
// go), drafts per conversation. No band behind it: the field floats on the same ground as the
// timeline, a solid step lifted off it, and the send button springs in, loud, once there is
// something to send.
package sh.rubric.baud.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import sh.rubric.baud.core.ConvKind
import sh.rubric.baud.core.Conversation
import sh.rubric.baud.core.Draft
import sh.rubric.baud.core.Event

@Composable
fun Composer(c: Conversation, reply: Event?, clearReply: () -> Unit) {
    val model = LocalModel.current
    val t = LocalTones.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var text by remember(c.id) { mutableStateOf(model.draft(c.id)) }
    val files = remember(c.id) { mutableStateListOf<String>() }
    var typingSent by remember { mutableLongStateOf(0L) }
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(20)) { uris ->
        scope.launch { for (u in uris) withContext(Dispatchers.IO) { Picked.copy(context, u) }?.let { files += it } }
    }
    val empty by remember { derivedStateOf { text.isBlank() && files.isEmpty() } }
    // The send button: in from small and clear with a bounce when there's something to send.
    val shown by animateFloatAsState(if (empty) 0f else 1f, spring(dampingRatio = 0.55f, stiffness = 440f), label = "send")
    fun send() {
        val s = text.trim()
        if (s.isEmpty() && files.isEmpty()) return
        model.send(c.id, Draft(s, files.toList(), reply = reply?.id))
        text = ""; files.clear(); clearReply()
    }
    Column(Modifier.fillMaxWidth().navigationBarsPadding()) {
        if (reply != null) Row(Modifier.padding(start = 16.dp, end = 8.dp, top = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.weight(1f)) { Quote(model.name(reply.user), reply.text ?: "attachment") }
            IconAction(Glyphs.xmark, "Cancel reply", 13.dp, t.secondary, clearReply)
        }
        if (files.isNotEmpty()) LazyRow(Modifier.padding(top = 8.dp), contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            items(files.toList(), key = { it }) { f -> Staged(f) { files.remove(f) } }
        }
        Row(
            Modifier.padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 14.dp).fillMaxWidth()
                .lifted(RoundedCornerShape(21.dp), t.field, t)
                .padding(horizontal = 10.dp, vertical = 7.dp),
            verticalAlignment = Alignment.Bottom,
        ) {
            Box(
                Modifier.size(30.dp).clip(CircleShape).clickable { pick.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }.semantics { contentDescription = "Attach" },
                contentAlignment = Alignment.Center,
            ) { Glyph(Glyphs.plus, 20.dp, t.secondary) }
            WGap(8.dp)
            BasicTextField(
                text,
                { new ->
                    text = new
                    model.setDraft(c.id, new)
                    // One typing frame every two seconds while the text keeps changing.
                    if (new.isNotEmpty() && System.currentTimeMillis() - typingSent > 2000) { typingSent = System.currentTimeMillis(); runCatching { model.core.typing(c.id) } }
                },
                Modifier.weight(1f).heightIn(min = 30.dp).semantics { contentDescription = "Message" },
                textStyle = Type.body.copy(color = t.text), cursorBrush = SolidColor(t.loud), maxLines = 8,
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
                // One line sits centred on the buttons beside it; more lines grow the field upward.
                decorationBox = { inner -> Box(Modifier.heightIn(min = 30.dp), contentAlignment = Alignment.CenterStart) { if (text.isEmpty()) Text(placeholder(model, c), style = Type.body, color = t.secondary, maxLines = 1, overflow = TextOverflow.Ellipsis); inner() } },
            )
            WGap(8.dp)
            Box(
                Modifier.size(30.dp).graphicsLayer { val s = 0.6f + 0.4f * shown; scaleX = s; scaleY = s; alpha = shown.coerceIn(0f, 1f) }
                    .clip(CircleShape).background(t.loud).clickable(enabled = !empty) { send() }.semantics { contentDescription = "Send" },
                contentAlignment = Alignment.Center,
            ) { Glyph(Glyphs.arrowUp, 22.dp, t.onLoud) }
        }
    }
}

private fun placeholder(model: sh.rubric.baud.AppModel, c: Conversation) = if (c.kind == ConvKind.Channel) "Message #${c.name ?: ""}" else "Message ${model.title(c)}"

/// A photo waiting in the composer: small; × takes it back.
@Composable
private fun Staged(path: String, remove: () -> Unit) {
    val t = LocalTones.current
    var thumb by remember(path) { mutableStateOf<androidx.compose.ui.graphics.ImageBitmap?>(null) }
    LaunchedEffect(path) { thumb = withContext(Dispatchers.IO) { Images.load(path, 200)?.asImageBitmap() } }
    Box(Modifier.padding(top = 6.dp, end = 6.dp)) {
        Box(Modifier.size(56.dp).clip(RoundedCornerShape(8.dp)).background(t.quiet).border(1.dp, t.hairline, RoundedCornerShape(8.dp))) {
            thumb?.let { Image(it, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop) }
        }
        Box(
            Modifier.align(Alignment.TopEnd).offset(6.dp, (-6).dp).size(18.dp).clip(CircleShape).background(t.surface).border(1.dp, t.hairline, CircleShape).clickable(onClick = remove)
                .semantics { contentDescription = "Remove" },
            contentAlignment = Alignment.Center,
        ) { Glyph(Glyphs.xmark, 9.dp, t.text) }
    }
}
