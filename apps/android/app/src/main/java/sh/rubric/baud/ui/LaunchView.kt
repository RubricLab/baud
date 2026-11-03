// What shows while baud can't show itself yet (apps/shared/LaunchView.swift): its mark on the
// colour, coming up gently after a moment, so a quick open never sees it flash.
package sh.rubric.baud.ui

import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay

@Composable
fun LaunchView() {
    val t = LocalTones.current
    var shown by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { delay(200); shown = true }
    val a by animateFloatAsState(if (shown) 1f else 0f, tween(350, easing = FastOutSlowInEasing), label = "launch")
    Box(
        Modifier.fillMaxSize().background(t.surface).clearAndSetSemantics { contentDescription = "baud is opening" },
        contentAlignment = Alignment.Center,
    ) {
        Box(Modifier.graphicsLayer { alpha = a; val s = 0.96f + 0.04f * a; scaleX = s; scaleY = s }) { BaudTile(80.dp) }
    }
}
