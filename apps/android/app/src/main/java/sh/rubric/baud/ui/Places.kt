// A place, drawn (apps/shared/Places.swift's PinFace and HueMap). No map here: no tiles, no SDK,
// nobody else told. A place is a tile in the chat's own colour with the person's face at its
// middle, ringed as a pin; a tap hands the spot to the phone's own maps app (a geo: link), the only
// time it leaves baud.
package sh.rubric.baud.ui

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import java.util.Locale

/// A face as a pin: ringed in the chat's strongest colour, lifted off the ground.
@Composable
fun PinFace(face: Face, size: Dp = 32.dp) {
    val t = LocalTones.current
    Box(Modifier.lifted(CircleShape, t.mine, t).padding(2.5.dp)) { Avatar(face.name, face.hash, size) }
}

/// Where a place is, without a map: a tile of the chat's ground, two faint rings around the middle,
/// and whose it is there, as a pin. `fill` is the tile (a step off whatever it sits on).
@Composable
fun PlaceTile(face: Face?, modifier: Modifier = Modifier, fill: Color = LocalTones.current.surface, pin: Dp = 28.dp) {
    val t = LocalTones.current
    Box(modifier.background(fill), contentAlignment = Alignment.Center) {
        Canvas(Modifier.fillMaxSize()) {
            val w = 1.dp.toPx()
            drawCircle(t.hairline, radius = 34.dp.toPx(), style = Stroke(w))
            drawCircle(t.hairline, radius = 62.dp.toPx(), style = Stroke(w))
        }
        if (face != null) PinFace(face, pin)
    }
}

/// The phone's own maps app at a spot, with whose it is; a sentence when there is none.
fun openInMaps(context: Context, lat: Double, lon: Double, label: String, failed: (String) -> Unit) {
    val at = String.format(Locale.US, "%.6f,%.6f", lat, lon)
    val uri = Uri.parse("geo:$at?q=$at(${Uri.encode(label)})")
    try { context.startActivity(Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
    catch (e: ActivityNotFoundException) { failed("There's no maps app on this phone to show it in.") }
}
