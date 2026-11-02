// This phone's status (apps/shared/NetStatus.swift): one mark and at most three words, the same
// four on every device: Online, Through <device>, Not reachable, Offline. A tap opens one calm
// sheet: this phone, a fine line to each device and friend it is connected to right now, and the
// state in a word and a sentence.
package sh.rubric.baud.ui

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathMeasure
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import sh.rubric.baud.AppModel
import sh.rubric.baud.core.NetState
import sh.rubric.baud.core.Path as CorePath

val NetState.mark: Mark get() = when (this) { NetState.Offline -> Mark.NeverSeen; NetState.Online -> Mark.Direct; is NetState.Through -> Mark.Stable; is NetState.NotReachable -> Mark.Waiting }
fun NetState.words(connecting: Boolean): String = when (this) {
    NetState.Offline -> "Offline"
    NetState.Online -> "Online"
    is NetState.Through -> "Through $name"
    is NetState.NotReachable -> if (connecting) "Connecting" else "Not reachable"
}
val NetState.lit: Boolean get() = this == NetState.Online || this is NetState.Through
/// Under the state, and under this phone in the picture.
fun NetState.line(connecting: Boolean): String = when (this) {
    NetState.Offline -> "No network."
    NetState.Online -> "Your devices and friends reach this phone from anywhere."
    is NetState.Through -> "Your devices and friends reach this phone through ${if (own) "your " else ""}$name."
    is NetState.NotReachable -> if (connecting) "Reaching your devices." else "Nothing outside reaches this phone yet."
}

/// The status chip: the mark and the words; a tap opens the sheet. Past its room, the mark alone.
@Composable
fun NetStatusChip() {
    val model = LocalModel.current
    val t = LocalTones.current
    var open by remember { mutableStateOf(false) }
    val s = model.netState
    Pill({ open = true }) {
        Row(Modifier.height(24.dp).padding(horizontal = 5.dp), verticalAlignment = Alignment.CenterVertically) {
            MarkView(s.mark, 12.dp, if (s.lit) t.strong else t.secondary)
            WGap(4.dp)
            Text(s.words(model.connecting), style = Type.small, fontWeight = FontWeight.SemiBold, color = if (s.lit) t.text else t.secondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
    if (open) BaudSheet({ open = false }) { NetStatusSheet() }
}

/// This phone and what it is connected to, the state in a word and a sentence.
@Composable
fun NetStatusSheet() {
    val model = LocalModel.current
    val t = LocalTones.current
    val s = model.netState
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 28.dp).padding(top = 16.dp, bottom = 24.dp).navigationBarsPadding(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(22.dp),
    ) {
        Constellation(model, s)
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                MarkView(s.mark, 15.dp, if (s.lit) t.strong else t.secondary); WGap(7.dp)
                Text(s.words(model.connecting), style = Type.heading)
            }
            Text(s.line(model.connecting), style = Type.body, color = t.secondary, textAlign = TextAlign.Center)
        }
        if (s is NetState.NotReachable && !model.connecting) NotReachable(compact = false)
    }
}

/// This phone, and a fine line down to each device and friend it is connected to, with its name
/// and how fast. Nothing connected: a dotted line ending in the state's mark.
@Composable
private fun Constellation(model: AppModel, state: NetState) {
    val t = LocalTones.current
    class Node(val id: String, val name: String, val detail: String, val shape: DeviceShape?)
    val live = model.peers.filter { it.device.online }.sortedWith(compareBy({ if (it.own) 0 else 1 }, { it.userName }))
    val links = live.take(4).map { p ->
        Node(p.device.id, if (p.own) Names.device(p.device.name) else Names.first(p.userName), when (val path = p.device.path) {
            is CorePath.Direct -> path.ms?.let { "$it ms" } ?: "Direct"
            is CorePath.Relay -> "Relayed"
            CorePath.Nearby -> "Nearby"
            else -> ""
        }, if (p.own) DeviceShape.of(p.device) else null)
    } + if (live.size > 4) listOf(Node("more", "${live.size - 4} more", "", null)) else emptyList()
    val drawn = remember { Animatable(0f) }
    LaunchedEffect(Unit) { drawn.animateTo(1f, tween(500, 100)) }
    Column(Modifier.widthIn(max = (maxOf(1, links.size) * 104).dp), horizontalAlignment = Alignment.CenterHorizontally) {
        DeviceGlyph(DeviceShape.Phone, 64.dp, lit = state != NetState.Offline)
        if (links.isEmpty()) {
            Canvas(Modifier.padding(top = 6.dp).size(2.dp, 34.dp)) {
                var y = 0f
                while (y < size.height) { drawRect(t.tertiary, Offset(0f, y), androidx.compose.ui.geometry.Size(1.2.dp.toPx(), 3.dp.toPx())); y += 7.dp.toPx() }
            }
            Box(Modifier.padding(top = 6.dp)) { MarkView(state.mark, 20.dp, t.secondary) }
        } else {
            Canvas(Modifier.fillMaxWidth().height(40.dp).padding(top = 2.dp)) {
                val n = links.size
                for ((i, _) in links.withIndex()) {
                    val x = size.width * (i + 0.5f) / n
                    val p = Path().apply { moveTo(size.width / 2, 0f); cubicTo(size.width / 2, size.height * 0.55f, x, size.height * 0.45f, x, size.height) }
                    val m = PathMeasure().apply { setPath(p, false) }
                    val part = Path().also { m.getSegment(0f, m.length * drawn.value, it, true) }
                    drawPath(part, t.tertiary, style = Stroke(1.dp.toPx()))
                }
            }
            Row(Modifier.fillMaxWidth().padding(top = 4.dp)) {
                for (l in links) {
                    Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(5.dp)) {
                        Box(Modifier.height(32.dp), contentAlignment = Alignment.Center) {
                            when {
                                l.shape != null -> DeviceGlyph(l.shape, 30.dp)
                                l.id == "more" -> Glyph(Glyphs.ellipsis, 20.dp, t.secondary)
                                else -> Avatar(l.name, null, 28.dp)
                            }
                        }
                        Text(l.name, style = Type.small, fontWeight = FontWeight.Medium, maxLines = 1)
                        if (l.detail.isNotEmpty()) Text(l.detail, style = Type.small, color = t.secondary, maxLines = 1)
                    }
                }
            }
        }
    }
    @Suppress("UNUSED_VARIABLE") val w = Modifier.width(0.dp)
}
