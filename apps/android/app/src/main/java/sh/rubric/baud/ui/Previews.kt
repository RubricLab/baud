// The new pages drawn on made-up people, for Android Studio's preview pane: the person page, Add
// people, the Location sheet and a place in a chat, in a colour, light and dark. Nothing here runs
// in the app; each page is drawn from what it's told, so no model or core is needed.
package sh.rubric.baud.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import sh.rubric.baud.core.Contact
import sh.rubric.baud.core.Device
import sh.rubric.baud.core.DeviceKind
import sh.rubric.baud.core.Path
import java.time.Instant

private val now: Instant = Instant.now()
private fun device(id: String, name: String, kind: DeviceKind, user: String, on: Boolean, path: Path = Path.None) =
    Device(id, name, kind, user, now.minusSeconds(86_400 * 30), on, if (on) now else now.minusSeconds(7200), path)
private fun friend(name: String, on: Boolean = false) =
    Contact(name.lowercase(), name, false, "", listOf(device(name.lowercase() + "1", "$name's phone", DeviceKind.Android, name.lowercase(), on, if (on) Path.Direct(18) else Path.None)), now)

private val ana = PersonFacts(
    name = "Ana",
    face = Face("Ana"),
    presence = Mark.Online,
    verified = false,
    subtitle = personSubtitle(false, "Ana", "Ana", "online", emptyList()),
    me = false,
    friend = true,
    devices = listOf(
        device("a1", "Ana's iPhone", DeviceKind.Iphone, "ana", true, Path.Direct(14)),
        device("a2", "Ana's MacBook", DeviceKind.Mac, "ana", false),
    ),
    thisDevice = "me1",
    groups = listOf(
        SharedGroup("g1", "hike", listOf(Face("Jo"), Face("Lee"), Face("Sam")), 5),
        SharedGroup("g2", "weekend", listOf(Face("Jo"), Face("Maya")), 3),
    ),
    removeFrom = "hike",
)

private val lee = ana.copy(
    name = "Lee", face = Face("Lee"), presence = null, friend = false, devices = emptyList(), groups = emptyList(), removeFrom = null,
    subtitle = personSubtitle(false, null, "Lee", "never seen", listOf("Ana", "Jo")),
)

@Composable
private fun Shown(dark: Boolean = false, content: @Composable () -> Unit) =
    BaudTheme(Tones.make("0090FF", dark)) { Box(Modifier.fillMaxSize().background(LocalTones.current.surface)) { content() } }

@Preview(name = "Person page", widthDp = 390, heightDp = 1100)
@Composable
private fun PersonPagePreview() = Shown {
    Column { PageBar(back = {}); PersonBody(ana, {}, {}, {}, {}, {}) }
}

@Preview(name = "Person page, dark", widthDp = 390, heightDp = 1100)
@Composable
private fun PersonPageDarkPreview() = Shown(dark = true) {
    Column { PageBar(back = {}); PersonBody(ana.copy(verified = true, subtitle = personSubtitle(false, "Ana", "Ana", "online on 2", emptyList())), {}, {}, {}, {}, {}) }
}

@Preview(name = "Person page, not a friend", widthDp = 390, heightDp = 700)
@Composable
private fun StrangerPreview() = Shown {
    Column { PageBar(back = {}); PersonBody(lee, {}, {}, {}, {}, {}) }
}

@Preview(name = "Add people", widthDp = 390, heightDp = 844)
@Composable
private fun AddPeoplePreview() = Shown {
    val candidates = addable(listOf(friend("Ana", true), friend("Bea"), friend("Dana", true), friend("Jo"), friend("Maya"), friend("Sam", true), friend("Theo")), listOf("lee"))
    Column {
        PageBar("Add people", back = {})
        AddPeopleBody("hike", space = false, noFriends = false, candidates = candidates, picked = setOf("bea", "sam"), toggle = {}, query = "", search = {}, add = {})
    }
}

@Preview(name = "Add people, everyone's here", widthDp = 390, heightDp = 600)
@Composable
private fun EveryoneHerePreview() = Shown(dark = true) {
    Column {
        PageBar("Add people", back = {})
        AddPeopleBody("hike", space = false, noFriends = false, candidates = emptyList(), picked = emptySet(), toggle = {}, query = "", search = {}, add = {})
    }
}

@Preview(name = "Location", widthDp = 390, heightDp = 800)
@Composable
private fun LocationPreview() = Shown {
    LocationBody(Face("Kit"), Fix(finding = false, found = true, accuracy = 9.6), sharing = false, until = null, who = "Only Ana sees it.", {}, {}, {}, {}, {})
}

@Preview(name = "Location, sharing live", widthDp = 390, heightDp = 800)
@Composable
private fun LocationSharingPreview() = Shown(dark = true) {
    LocationBody(Face("Kit"), Fix(finding = true), sharing = true, until = now.plusSeconds(3600), who = "Everyone in hike sees it, and nobody else.", {}, {}, {}, {}, {})
}

@Preview(name = "Location, turned off", widthDp = 390, heightDp = 600)
@Composable
private fun LocationOffPreview() = Shown {
    LocationBody(Face("Kit"), Fix(denied = true, finding = false), sharing = false, until = null, who = "Only Ana sees it.", {}, {}, {}, {}, {})
}

/// A place in a chat, mine and theirs, in their bubbles.
@Preview(name = "Place bubbles", widthDp = 390, heightDp = 520)
@Composable
private fun PlaceBubblePreview() = Shown {
    val t = LocalTones.current
    Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Start) {
            Box(Modifier.lifted(RoundedCornerShape(19.dp), t.card, t).padding(horizontal = 14.dp, vertical = 9.dp)) { PlaceBubble(Face("Jo"), mine = false, open = {}, longPress = {}) }
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            Box(Modifier.lifted(RoundedCornerShape(19.dp), t.loud, t).padding(horizontal = 14.dp, vertical = 9.dp)) { PlaceBubble(Face("Kit"), mine = true, open = {}, longPress = {}) }
        }
    }
}

@Preview(name = "Group faces", widthDp = 240, heightDp = 100)
@Composable
private fun GroupFacesPreview() = Shown {
    Row(Modifier.padding(16.dp), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
        GroupFace(listOf(Face("Ana"), Face("Jo")), "weekend", 44.dp)
        GroupFace(listOf(Face("Ana"), Face("Jo"), Face("Lee")), "hike", 44.dp)
        GroupFace(listOf(Face("Ana"), Face("Jo"), Face("Lee")), "hike", 72.dp)
    }
}

/// The update bar at the top of Chats: offered, coming down, ready.
@Preview(name = "Update bar", widthDp = 390, heightDp = 260)
@Composable
private fun UpdateBarPreview() = Shown {
    val r = sh.rubric.baud.Updates.Release("0.2.22", "https://example.invalid/baud.apk", "")
    Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        UpdateBarBody(r.version, sh.rubric.baud.Updates.State.Available(r)) {}
        UpdateBarBody(r.version, sh.rubric.baud.Updates.State.Downloading(r, 0.4f)) {}
        UpdateBarBody(r.version, sh.rubric.baud.Updates.State.Ready(r)) {}
    }
}
