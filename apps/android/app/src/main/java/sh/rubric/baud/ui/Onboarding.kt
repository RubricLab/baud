// First run (apps/shared/OnboardingView.swift): a face and a name, then the Add screen. Nothing else.
package sh.rubric.baud.ui

import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import sh.rubric.baud.AppModel
import java.io.File
import java.util.UUID

@Composable
fun Onboarding() {
    val model = LocalModel.current
    val t = LocalTones.current
    var name by rememberSaveable { mutableStateOf("") }
    /// The photo picked before there is a card to put it on: set with the name.
    var face by rememberSaveable { mutableStateOf<String?>(null) }
    val focus = remember { FocusRequester() }
    fun go() {
        val n = name.trim()
        if (n.isEmpty()) return
        model.setName(n)
        face?.let { if (model.named) model.setPhoto(it) }
    }
    Box(Modifier.fillMaxSize().background(t.surface).systemBarsPadding().imePadding()) {
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(20.dp, Alignment.CenterVertically),
        ) {
            if (model.join != null || model.named) {
                // A link opened on first run asks for the name itself; once named, the Add screen.
                AddView()
                if (model.demoAvailable && model.debug) Quiet("Demo", { model.startDemo() })
            } else {
                FaceSlot(name, face) { face = it }
                Spacer(Modifier.size(0.dp))
                NameField(name, { name = it }, focus, ::go)
                Quiet("Continue", ::go, strong = true, large = true, enabled = name.isNotBlank())
                // baud on another device already: scan its link, no name needed.
                Quiet("Scan", { model.join = AppModel.Join(null) }, icon = Glyphs.scan)
            }
        }
        if (model.named) {
            Box(Modifier.align(Alignment.TopEnd).padding(16.dp)) {
                Quiet("Later", { model.markOnboarded(true); model.join = null; model.offer = null; model.refreshAll() })
            }
        }
    }
    LaunchedEffect(Unit) { if (model.join == null && !model.named) runCatching { focus.requestFocus() } }
}

/// The name, large and centred, on its field.
@Composable
private fun NameField(value: String, onChange: (String) -> Unit, focus: FocusRequester, done: () -> Unit) {
    val t = LocalTones.current
    BasicTextField(
        value, onChange,
        modifier = Modifier.widthIn(max = 300.dp).fillMaxWidth().focusRequester(focus).semantics { contentDescription = "Your name" },
        textStyle = Type.title.copy(fontWeight = FontWeight.SemiBold, color = t.text, textAlign = TextAlign.Center),
        singleLine = true,
        cursorBrush = SolidColor(t.strong),
        keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words, imeAction = ImeAction.Done),
        keyboardActions = KeyboardActions(onDone = { done() }),
        decorationBox = { inner ->
            Box(Modifier.clip(RoundedCornerShape(10.dp)).background(t.field).padding(12.dp), contentAlignment = Alignment.Center) {
                if (value.isEmpty()) Text("Your name", style = Type.title.copy(fontWeight = FontWeight.SemiBold), color = t.secondary, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
                inner()
            }
        },
    )
}

/// Your face on first run: your initials as you type, your photo once you pick one (a tap).
@Composable
private fun FaceSlot(name: String, face: String?, picked: (String) -> Unit) {
    val t = LocalTones.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var shown by remember { mutableStateOf<ImageBitmap?>(null) }
    LaunchedEffect(face) { if (face != null && shown == null) shown = withContext(Dispatchers.IO) { Images.load(face, 400)?.asImageBitmap() } }
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        uri ?: return@rememberLauncherForActivityResult
        scope.launch {
            val path = withContext(Dispatchers.IO) { Picked.face(context, uri) } ?: return@launch
            shown = withContext(Dispatchers.IO) { Images.load(path, 400)?.asImageBitmap() }
            picked(path)
        }
    }
    val size = 104.dp
    val i = initials(name)
    Box(
        Modifier.size(size).clickable(remember { MutableInteractionSource() }, null) { pick.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }
            .semantics { contentDescription = if (shown == null) "Add a photo" else "Change photo" },
    ) {
        val img = shown
        if (img != null) Image(img, null, Modifier.size(size).clip(CircleShape), contentScale = ContentScale.Crop)
        else Box(Modifier.size(size).clip(CircleShape).background(t.face), contentAlignment = Alignment.Center) {
            if (i.isEmpty()) Glyph(Glyphs.person, size * 0.4f, t.onFace)
            else Text(i, fontSize = (size.value * 0.38f).sp, fontWeight = FontWeight.Bold, color = t.onFace)
        }
        Box(
            Modifier.align(Alignment.BottomEnd).offset(0.dp, 0.dp).size(32.dp).clip(CircleShape).background(t.raised).border(1.dp, t.hairline, CircleShape),
            contentAlignment = Alignment.Center,
        ) { Glyph(Glyphs.camera, 15.dp, t.text) }
    }
}

/// Photos from the picker, copied out to files of our own (the picker's grant ends with the screen).
object Picked {
    /// A face: small and square enough for a card, turned upright, as a JPEG.
    fun face(context: Context, uri: Uri): String? {
        val raw = copy(context, uri) ?: return null
        val bmp = Images.load(raw, 800) ?: return null
        val out = File(context.cacheDir, "face-${UUID.randomUUID()}.jpg")
        out.outputStream().use { bmp.compress(Bitmap.CompressFormat.JPEG, 90, it) }
        File(raw).delete()
        return out.path
    }

    /// A photo or file as it is, under its own name.
    fun copy(context: Context, uri: Uri): String? = runCatching {
        val name = context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) c.getString(0) else null
        } ?: "photo-${UUID.randomUUID()}.jpg"
        val dir = File(context.cacheDir, "picked-${UUID.randomUUID()}").apply { mkdirs() }
        val out = File(dir, name.replace("/", "-"))
        context.contentResolver.openInputStream(uri)!!.use { input -> out.outputStream().use { input.copyTo(it) } }
        out.path
    }.getOrNull()
}
