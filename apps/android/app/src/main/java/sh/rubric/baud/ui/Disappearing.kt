// Disappearing messages (apps/shared/Disappearing.swift): the timer in a conversation's header,
// with how long ("1d") while it's on, opens the choice: off, or how long a message stays after
// it's read. Anyone in a chat changes it; in a channel only an admin, and the others see it as
// it is. baud-core does the rest: the line in the timeline, each message going on its own time.
package sh.rubric.baud.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
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

/// The timer in the header: "1d" beside it while messages disappear; a tap opens the choice.
@Composable
fun DisappearSpot(c: Conversation) {
    val model = LocalModel.current
    val t = LocalTones.current
    var menu by remember { mutableStateOf(false) }
    val on = c.disappear > 0
    val can = c.kind != ConvKind.Channel || model.me.user in c.admins
    val says = if (on) "Messages disappear ${disappearAfter(c.disappear)} after they're read" else "Disappearing messages: off"
    Box {
        Row(
            Modifier.height(36.dp).clip(CircleShape).clickable { menu = true }.padding(horizontal = 8.dp).semantics { contentDescription = says },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Glyph(Glyphs.timer, 18.dp, t.secondary)
            if (on) { WGap(3.dp); Text(disappearShort(c.disappear), style = Type.small, fontWeight = FontWeight.SemiBold, color = t.secondary) }
        }
        DropdownMenu(menu, { menu = false }, containerColor = t.card) {
            Text(if (can) "Disappearing messages" else "Only an admin can change this", style = Type.small, color = t.secondary, modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
            for (s in DisappearChoices) {
                val picked = s == c.disappear
                DropdownMenuItem(
                    { Text(if (s == 0) "Off" else disappearAfter(s), style = Type.body, color = t.text, fontWeight = if (picked) FontWeight.SemiBold else FontWeight.Normal) },
                    { menu = false; if (!picked) model.setDisappear(c.id, s) },
                    enabled = can,
                    trailingIcon = if (picked) ({ Glyph(Glyphs.check, 16.dp, t.text) }) else null,
                )
            }
        }
    }
}
