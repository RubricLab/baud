// The root (apps/ios/IOSApp.swift): first run until there is a name, then Chats, one scroll, with
// my face at the left (You) and New at the right; a chat pushed over it. One Add sheet for a
// friend, my own device and any link I'm given; You is a sheet from the face.
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
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.BottomSheetDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import sh.rubric.baud.AppModel

@Composable
fun Root(model: AppModel) {
    CompositionLocalProvider(LocalModel provides model) {
        val t = LocalTones.current
        Box(Modifier.fillMaxSize().background(t.surface)) {
            if (!model.named || (!model.onboarded && model.conversations.isEmpty())) Onboarding() else Home()
            if (model.removedHere) Removed()
        }
        if (model.adding && model.named && model.onboarded) {
            // Keyed on the link, so one opened while another is up gets its own sheet.
            androidx.compose.runtime.key(model.join?.link?.url) {
                // Full height while my answer to a link (its code and why) is up.
                BaudSheet(onDismiss = { model.offer = null; model.join = null }, full = model.join?.reply != null) { AddView() }
            }
        }
        val ask = model.linkAsk
        if (ask != null && !model.adding) BaudSheet(onDismiss = { model.linkAsk = null }) { AskBody(ask) }
        model.error?.let { e ->
            AlertDialog(
                onDismissRequest = { model.error = null },
                confirmButton = { TextButton({ model.error = null }) { Text("OK", color = t.text, fontWeight = FontWeight.SemiBold) } },
                title = { Text("baud", style = Type.heading) },
                text = { Text(e, style = Type.body, color = t.secondary) },
                containerColor = t.card, titleContentColor = t.text, textContentColor = t.secondary,
            )
        }
    }
}

/// A sheet in the hue: its surface, a handle, the drag to close.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BaudSheet(onDismiss: () -> Unit, full: Boolean = false, content: @Composable ColumnScope.() -> Unit) {
    val t = LocalTones.current
    val state = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = state,
        containerColor = t.surface,
        contentColor = t.text,
        scrimColor = androidx.compose.ui.graphics.Color.Black.copy(alpha = if (t.dark) 0.5f else 0.32f),
        dragHandle = { BottomSheetDefaults.DragHandle(color = t.tertiary) },
        shape = RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp),
        // Below the status bar, a breath of the screen showing above it, as the iPhone's sheets.
        modifier = Modifier.windowInsetsPadding(androidx.compose.foundation.layout.WindowInsets.statusBars).padding(top = if (full) 10.dp else 0.dp),
    ) { content() }
}

/// Asked before anything that can't be undone, always in the same shape: "Leave hike?", what will
/// happen in a sentence, then the one answer in red ("Leave") beside Cancel.
@Composable
fun Confirm(title: String, body: String, action: String, onDismiss: () -> Unit, onConfirm: () -> Unit) {
    val t = LocalTones.current
    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = { TextButton({ onConfirm(); onDismiss() }) { Text(action, color = t.danger, fontWeight = FontWeight.Bold) } },
        dismissButton = { TextButton(onDismiss) { Text("Cancel", color = t.text, fontWeight = FontWeight.SemiBold) } },
        title = { Text(title, style = Type.heading) },
        text = { Text(body, style = Type.body, color = t.secondary) },
        containerColor = t.card, titleContentColor = t.text, textContentColor = t.secondary,
    )
}

/// Starting over on this phone, asked first: the same words from You and from Removed.
@Composable
fun ConfirmErase(onDismiss: () -> Unit, onConfirm: () -> Unit) =
    Confirm("Erase this phone?", "Its chats, friends and keys go for good. Your other devices keep theirs.", "Erase", onDismiss, onConfirm)

/// Chats, and a chat over it (the stack is conversation ids, kept across a rotation or a theme
/// change). A notification tapped or a new friend's Message opens one (`reveal`).
@Composable
private fun Home() {
    val model = LocalModel.current
    var stack by rememberSaveable { mutableStateOf(listOf<String>()) }
    var you by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(model.reveal) {
        val id = model.reveal ?: return@LaunchedEffect
        you = false; model.offer = null
        stack = listOf(id); model.reveal = null
    }
    BackHandler(stack.isNotEmpty()) { stack = stack.dropLast(1) }
    AnimatedContent(
        targetState = stack.lastOrNull(),
        transitionSpec = {
            val push = targetState != null
            (slideInHorizontally(tween(260)) { w -> if (push) w else -w / 4 } + fadeIn(tween(200))) togetherWith
                (slideOutHorizontally(tween(260)) { w -> if (push) -w / 4 else w } + fadeOut(tween(200)))
        },
        label = "nav",
    ) { top ->
        if (top == null) Chats(open = { stack = stack + it }, you = { you = true })
        else ConversationScreen(top, back = { stack = stack.dropLast(1) })
    }
    if (you) BaudSheet(onDismiss = { you = false }, full = true) { You(close = { you = false }) }
}

/// This device was removed by another of mine: the picture, a word, Start over (asked first).
@Composable
private fun Removed() {
    val model = LocalModel.current
    val t = LocalTones.current
    val scope = rememberCoroutineScope()
    var confirm by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxSize().background(t.surface), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = androidx.compose.foundation.layout.Arrangement.Center) {
        DeviceGlyph(DeviceShape.Phone, 72.dp, lit = false)
        Gap(16.dp)
        Text("Removed", style = Type.title)
        Gap(16.dp)
        DangerRow("Start over", { confirm = true }, Modifier.width(200.dp), centred = true)
    }
    if (confirm) ConfirmErase({ confirm = false }) { scope.launch { model.wipe() } }
}

/// A device asking to become mine: its picture, its name, the six digits, Not mine or Add.
@Composable
fun AskBody(ask: AppModel.LinkAsk) {
    val model = LocalModel.current
    Column(Modifier.fillMaxWidth().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        DeviceGlyph(when (ask.kind) { sh.rubric.baud.core.DeviceKind.Iphone -> DeviceShape.Iphone; sh.rubric.baud.core.DeviceKind.Android -> DeviceShape.Phone; else -> DeviceShape.Macbook }, 64.dp)
        Gap(16.dp)
        Text(ask.name.ifEmpty { ask.device }, style = Type.title)
        Gap(16.dp)
        Text(ask.spaced, style = Type.display.copy(fontSize = androidx.compose.ui.unit.TextUnit(40f, androidx.compose.ui.unit.TextUnitType.Sp), fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace))
        Gap(16.dp)
        Row {
            Quiet("Not mine", { model.answerLink(ask, false) }, large = true)
            WGap(10.dp)
            Quiet("Add", { model.answerLink(ask, true) }, strong = true, large = true)
        }
        Gap(24.dp)
    }
}

@Suppress("unused") private val keepWidth = Modifier.width(0.dp)
