// Disappearing messages (apps/shared/Disappearing.swift): the choice lives in a chat's info, in a
// card of its own, a row that says how it's set ("Off", "1 day") and opens the choice: off, or how
// long a message stays after it's read. While it's on, a small timer with how long ("1d") sits in the header and opens
// the info. Anyone in a chat changes it; in a channel only an admin, and the others see it as it
// is. baud-core does the rest: the line in the timeline, each message going on its own time.
package sh.rubric.baud.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import sh.rubric.baud.core.ConvKind
import sh.rubric.baud.core.Conversation
import sh.rubric.baud.core.disappearAfter
import sh.rubric.baud.core.disappearShort

/// Off, 5 minutes, 1 hour, 8 hours, 1 day, 1 week, 4 weeks: the seconds each one is.
val DisappearChoices = listOf(0, 300, 3600, 28_800, 86_400, 604_800, 2_419_200)

/// How it's set, in words: "Off", "5 minutes", "1 day".
fun disappearWord(seconds: Int): String = if (seconds <= 0) "Off" else disappearAfter(seconds)

/// The header's timer while messages disappear, with how long ("1d"); a tap opens the chat's info,
/// where it's changed. Nothing while it's off.
@Composable
fun DisappearMark(c: Conversation, onClick: () -> Unit) {
    val t = LocalTones.current
    if (c.disappear <= 0) return
    Row(
        Modifier.heightIn(min = 48.dp).widthIn(min = 48.dp).clip(CircleShape).clickable(role = Role.Button, onClick = onClick).padding(horizontal = 8.dp)
            .semantics { contentDescription = "Messages disappear ${disappearAfter(c.disappear)} after they're read" },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = androidx.compose.foundation.layout.Arrangement.Center,
    ) {
        Glyph(Glyphs.timer, 18.dp, t.secondary)
        WGap(3.dp)
        Text(disappearShort(c.disappear), style = Type.small, fontWeight = FontWeight.SemiBold, color = t.secondary)
    }
}

/// The choice in a chat's info, in its card ("Disappearing messages"): the timer and how it's set,
/// a tap for the choices; under it, while it's on, what that means, or that only an admin changes it.
@Composable
fun DisappearRow(c: Conversation) {
    val model = LocalModel.current
    val t = LocalTones.current
    var menu by remember { mutableStateOf(false) }
    val can = c.kind != ConvKind.Channel || model.me.user in c.admins
    val words = disappearWord(c.disappear)
    Box {
        RowSurface({ menu = true }, Modifier.semantics { contentDescription = "Disappearing messages: $words" }, minHeight = Metrics.compactRow, enabled = can) {
            Glyph(Glyphs.timer, 17.dp, t.secondary)
            WGap(8.dp)
            Text(words, style = Type.body, color = if (can) t.text else t.secondary, maxLines = 1, modifier = Modifier.weight(1f))
            if (can) { WGap(8.dp); Glyph(Glyphs.chevronUpDown, 14.dp, t.secondary) }
        }
        DropdownMenu(menu, { menu = false }, containerColor = t.card) {
            for (s in DisappearChoices) {
                val picked = s == c.disappear
                DropdownMenuItem(
                    { Text(disappearWord(s), style = Type.body, color = t.text, fontWeight = if (picked) FontWeight.SemiBold else FontWeight.Normal) },
                    { menu = false; if (!picked) model.setDisappear(c.id, s) },
                    enabled = can,
                    trailingIcon = if (picked) ({ Glyph(Glyphs.check, 16.dp, t.text) }) else null,
                )
            }
        }
    }
    if (c.disappear > 0 || !can) Text(
        if (!can) "Only an admin can change this." else "New messages go ${disappearAfter(c.disappear)} after they're read.",
        style = Type.small, color = t.secondary, modifier = Modifier.padding(start = Metrics.inset + Metrics.pad, end = Metrics.inset + Metrics.pad, bottom = 8.dp),
    )
}
