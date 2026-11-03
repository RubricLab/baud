// A newer baud, where it's seen (apps/mac/Updates.swift's UpdateBar): a slim bar at the top of Chats
// while one is waiting, with what it is and the one press; and, the first time, the sentence that
// sends the person to Android's "allow from this source".
package sh.rubric.baud.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import sh.rubric.baud.Updates

/// The bar, while a newer version is waiting: "baud 0.2.22", where it's at, and Update or Install
/// (or how far the download has come).
@Composable
fun UpdateBar(modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val s = Updates.state
    val r = Updates.waiting ?: return
    UpdateBarBody(r.version, s, modifier) { Updates.update(context) }
}

/// The bar itself, drawn from what it's told (a preview draws it too).
@Composable
fun UpdateBarBody(version: String, s: Updates.State, modifier: Modifier = Modifier, press: () -> Unit) {
    val t = LocalTones.current
    Row(
        modifier.fillMaxWidth().glass(12.dp, t).padding(start = 10.dp, end = 8.dp, top = 8.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        UpdateMark(20.dp)
        WGap(9.dp)
        Column(Modifier.weight(1f)) {
            Text("baud $version", style = Type.small, fontWeight = FontWeight.SemiBold, color = t.text, maxLines = 1)
            Text(
                when (s) { is Updates.State.Ready -> "Ready to install"; is Updates.State.Available -> "A new version is out"; else -> "Updating…" },
                style = Type.small, color = t.secondary, maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
        }
        WGap(6.dp)
        when (s) {
            is Updates.State.Available -> Quiet("Update", press, strong = true)
            is Updates.State.Ready -> Quiet("Install", press, strong = true)
            is Updates.State.Downloading -> Box(Modifier.widthIn(min = 40.dp).semantics { contentDescription = "Downloading, ${(s.progress * 100).toInt()}%" }, contentAlignment = Alignment.Center) {
                CircularProgressIndicator({ s.progress }, Modifier.size(22.dp), color = t.strong, trackColor = t.quiet, strokeWidth = 2.5.dp)
            }
            else -> Box(Modifier.widthIn(min = 40.dp), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(Modifier.size(22.dp), color = t.strong, trackColor = t.quiet, strokeWidth = 2.5.dp)
            }
        }
    }
}

/// An arrow down, knocked out of a solid disc in the loud colour.
@Composable
fun UpdateMark(size: Dp) {
    val t = LocalTones.current
    Canvas(Modifier.size(size).graphicsLayer(compositingStrategy = CompositingStrategy.Offscreen)) {
        val s = this.size.minDimension / 24f
        drawCircle(t.strong, this.size.minDimension / 2)
        val arrow = Path().apply { moveTo(12f * s, 6.5f * s); lineTo(12f * s, 16.5f * s); moveTo(7.8f * s, 12.6f * s); lineTo(12f * s, 16.8f * s); lineTo(16.2f * s, 12.6f * s) }
        drawPath(arrow, Color.Black, style = Stroke(2.4f * s, cap = StrokeCap.Round, join = StrokeJoin.Round), blendMode = BlendMode.Clear)
    }
}

/// The first update: Android asks once whether baud may install apps. One sentence why, then its
/// own screen; back from it, the install carries on.
@Composable
fun AllowUpdates() {
    if (!Updates.asking) return
    val t = LocalTones.current
    val context = LocalContext.current
    AlertDialog(
        onDismissRequest = { Updates.notNow() },
        confirmButton = { TextButton({ Updates.allow(context) }) { Text("Continue", color = t.text, fontWeight = FontWeight.Bold) } },
        dismissButton = { TextButton({ Updates.notNow() }) { Text("Not now", color = t.secondary) } },
        title = { Text("Let baud update itself", style = Type.heading) },
        text = { Text("To install its own updates, baud needs you to turn on “Allow from this source” once, then come back.", style = Type.body, color = t.secondary) },
        containerColor = t.card, titleContentColor = t.text, textContentColor = t.secondary,
    )
}
