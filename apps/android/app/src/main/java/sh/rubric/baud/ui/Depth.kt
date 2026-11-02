// Depth, made of the colour itself and nothing else (apps/shared/Depth.swift). The ground is one
// solid step of it, with no gradient and no glow; raised things (their messages, fields, cards)
// are solid steps lifted off it by a shadow in the hue's own deep ink: a tight contact shadow where
// they touch, a soft one under them. Mine are the loud fill. Contrast and shadow make the depth,
// never a veil.
package sh.rubric.baud.ui

import android.graphics.Paint
import android.os.Build
import androidx.compose.foundation.background
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.asAndroidPath
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/// A solid fill in `shape`, lifted off the ground: a contact shadow where it touches (0.5 blur,
/// 0.5 down) and a soft one under it (7 blur, 3.5 down, at 0.7 of the shade), both scaled by
/// `depth`. The blurs are SwiftUI's shadow radii taken as the Gaussian's sigma.
fun Modifier.lifted(shape: Shape, fill: Color, tones: Tones, depth: Float = 1f): Modifier {
    // Shadow layers on shapes are drawn by the GPU from Android 9; before it, the platform's own
    // elevation shadow in the hue's ink stands in.
    if (Build.VERSION.SDK_INT < 28) return this.shadow((2 * depth).dp, shape, clip = false, ambientColor = tones.shade, spotColor = tones.shade).background(fill, shape)
    return this.drawWithCache {
        val path = Path().apply {
            when (val o = shape.createOutline(size, layoutDirection, this@drawWithCache)) {
                is Outline.Rectangle -> addRect(o.rect)
                is Outline.Rounded -> addRoundRect(o.roundRect)
                is Outline.Generic -> addPath(o.path)
            }
        }.asAndroidPath()
        // Skia's blur radius for a sigma (its sigma is 0.57735 r + 0.5).
        fun blur(sigma: Dp): Float = maxOf(0.01f, (sigma.toPx() - 0.5f) / 0.57735f)
        val soft = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = fill.toArgb()
            setShadowLayer(blur((7 * depth).dp), 0f, (3.5f * depth).dp.toPx(), tones.shade.copy(alpha = tones.shade.alpha * 0.7f).toArgb())
        }
        val contact = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = fill.toArgb()
            setShadowLayer(blur((0.5f * depth).dp), 0f, (0.5f * depth).dp.toPx(), tones.shade.toArgb())
        }
        onDrawBehind {
            drawIntoCanvas { c ->
                c.nativeCanvas.drawPath(path, soft)
                c.nativeCanvas.drawPath(path, contact)
            }
        }
    }
}

/// Raised: a solid card, lifted by the hue's shadow (or set flat on the ground).
fun Modifier.glass(shape: Shape, tones: Tones, lifted: Boolean = true): Modifier =
    if (lifted) lifted(shape, tones.card, tones) else background(tones.card, shape)

fun Modifier.glass(corner: Dp, tones: Tones, lifted: Boolean = true): Modifier = glass(RoundedCornerShape(corner), tones, lifted)
