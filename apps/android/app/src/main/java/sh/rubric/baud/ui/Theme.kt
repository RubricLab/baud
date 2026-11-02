// One type scale: small, body, heading, title, display, and messages a step over body. Nothing else
// is set in another size. The sizes are the iPhone's (Theme.swift), in sp so the person's text size
// scales them. Material 3 is underneath (sheets, fields, menus, dialogs, ripples) and wears the
// tones: never its own purple, never a tonal tint over a surface.
package sh.rubric.baud.ui

import android.app.Activity
import androidx.compose.foundation.text.selection.LocalTextSelectionColors
import androidx.compose.foundation.text.selection.TextSelectionColors
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.view.WindowCompat

object Type {
    val bodySize = 16.sp
    val smallSize = 13.sp
    val headingSize = 19.sp   // body + 3: Chats, Friends, a card's title
    val titleSize = 22.sp     // body + 6: the conversation's name
    val displaySize = 30.sp
    /// What people say is set a step larger than the chrome around it.
    val messageSize = 17.sp

    val body = TextStyle(fontSize = bodySize, lineHeight = 21.sp)
    val message = TextStyle(fontSize = messageSize, lineHeight = 22.sp)
    val small = TextStyle(fontSize = smallSize, lineHeight = 17.sp)
    val heading = TextStyle(fontSize = headingSize, lineHeight = 24.sp, fontWeight = FontWeight.Bold)
    val title = TextStyle(fontSize = titleSize, lineHeight = 27.sp, fontWeight = FontWeight.Bold)
    val display = TextStyle(fontSize = displaySize, lineHeight = 36.sp, fontWeight = FontWeight.Bold)
    val mono = TextStyle(fontSize = smallSize, lineHeight = 17.sp, fontFamily = FontFamily.Monospace)
    /// Figures of one width, so times and counts don't shift as they change.
    val digits = TextStyle(fontFeatureSettings = "tnum")
}

/// The few numbers every screen uses.
object Metrics {
    val corner = 6.dp
    val sheetCorner = 10.dp
    /// A card (You, a tile): rounder than a row.
    val cardCorner = 18.dp
    /// Between message groups; within one; under the last of one.
    val groupGap = 14.dp
    val rowGap = 2.dp
    val groupBottom = 2.dp
    val sectionGap = 28.dp
    // Rows (Rows.swift, iPhone)
    val chatRow = 66.dp
    val compactRow = 46.dp
    val face = 44.dp
    val smallFace = 30.dp
    val inset = 8.dp
    val pad = 10.dp
}

@Composable
fun BaudTheme(tones: Tones, content: @Composable () -> Unit) {
    val scheme = remember(tones) {
        val base = if (tones.chromeDark) darkColorScheme() else lightColorScheme()
        base.copy(
            primary = tones.loud, onPrimary = tones.onLoud,
            primaryContainer = tones.loud, onPrimaryContainer = tones.onLoud,
            secondary = tones.loud, onSecondary = tones.onLoud,
            secondaryContainer = tones.quiet, onSecondaryContainer = tones.text,
            tertiary = tones.loud, onTertiary = tones.onLoud,
            background = tones.surface, onBackground = tones.text,
            surface = tones.surface, onSurface = tones.text,
            surfaceVariant = tones.raised, onSurfaceVariant = tones.secondary,
            surfaceTint = tones.surface,
            surfaceContainerLowest = tones.surface, surfaceContainerLow = tones.raised,
            surfaceContainer = tones.card, surfaceContainerHigh = tones.card, surfaceContainerHighest = tones.field,
            surfaceBright = tones.card, surfaceDim = tones.raised,
            inverseSurface = tones.loud, inverseOnSurface = tones.onLoud, inversePrimary = tones.surface,
            outline = tones.hairline, outlineVariant = tones.hairline,
            error = tones.text, onError = tones.surface,
            scrim = androidx.compose.ui.graphics.Color.Black.copy(alpha = 0.4f),
        )
    }
    val typography = remember {
        Typography(
            bodyLarge = Type.body, bodyMedium = Type.body, bodySmall = Type.small,
            labelLarge = Type.body.copy(fontWeight = FontWeight.SemiBold), labelMedium = Type.small, labelSmall = Type.small,
            titleLarge = Type.title, titleMedium = Type.heading, titleSmall = Type.body.copy(fontWeight = FontWeight.SemiBold),
            headlineSmall = Type.title, headlineMedium = Type.display, headlineLarge = Type.display,
        )
    }
    // The bars around the content take the surface and follow it: light icons over a ground that
    // wears white words, dark over one that wears near-black.
    val view = LocalView.current
    if (!view.isInEditMode) {
        SideEffect {
            val window = (view.context as? Activity)?.window ?: return@SideEffect
            WindowCompat.getInsetsController(window, view).apply {
                isAppearanceLightStatusBars = !tones.chromeDark
                isAppearanceLightNavigationBars = !tones.chromeDark
            }
            window.decorView.setBackgroundColor(tones.surface.toArgb())
        }
    }
    MaterialTheme(colorScheme = scheme, typography = typography) {
        CompositionLocalProvider(
            LocalTones provides tones,
            LocalContentColor provides tones.text,
            // A selection is a solid step behind the words, not the loud colour turned down.
            LocalTextSelectionColors provides TextSelectionColors(handleColor = tones.loud, backgroundColor = tones.quiet),
            content = content,
        )
    }
}
