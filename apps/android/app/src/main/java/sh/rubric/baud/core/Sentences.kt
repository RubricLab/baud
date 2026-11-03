// Status is a sentence: every word the app shows about reachability, delivery and devices, made
// once here, the same as BaudCore/Sentences.swift so the phones and the Mac say the same thing.
package sh.rubric.baud.core

import java.time.Duration
import java.time.Instant

val Path.sentence: String
    get() = when (this) {
        is Path.Direct -> ms?.let { "Direct, $it ms" } ?: "Direct"
        is Path.Relay -> "Relayed by $name"
        Path.Nearby -> "Nearby"
        Path.Waiting -> "Waiting"
        Path.Unreachable -> "Unreachable"
        Path.None -> "Not connected"
    }

val Path.isLive: Boolean get() = this is Path.Direct || this is Path.Relay || this == Path.Nearby

val Device.possessive: String
    get() = when (kind) {
        DeviceKind.Mac -> "Mac"
        DeviceKind.Iphone -> "iPhone"
        DeviceKind.Android -> "phone"
        DeviceKind.Node -> "device"
    }

/// "online, direct" · "last online 2 h ago" · "never online"
val Device.sentence: String
    get() {
        if (online) return if (path.isLive) "online, ${path.sentence.lowercase()}" else "online"
        lastOnline?.let { return "last online ${ago(it)}" }
        return "never online"
    }

val Contact.sentence: String
    get() {
        val on = devices.filter { it.online }
        on.firstOrNull()?.let { d -> return if (on.size > 1) "online on ${on.size} devices" else "online on their ${d.possessive}" }
        lastOnline?.let { return "last online ${ago(it)}" }
        return "never online"
    }

/// Under my last message: "read" · "delivered to Ana's iPhone" · "carried by Jo's Mac, waiting for Ana's iPhone".
val Delivery.sentence: String
    get() {
        if (devices.isEmpty()) return "only you"
        val read = mutableListOf<String>(); val readUsers = mutableSetOf<String>()
        val carried = mutableListOf<String>(); val carriers = mutableSetOf<String>()
        for (d in devices) {
            when (d.state) {
                DeliveryState.Read -> if (readUsers.add(d.personName)) read += d.personName
                is DeliveryState.Carried -> for (c in d.carriers) if (carriers.add(c)) carried += c
                else -> {}
            }
        }
        val people = devices.map { it.personName }.toSet().size
        val parts = mutableListOf<String>()
        if (read.isNotEmpty()) parts += if (people == 1) "read" else "read by ${list(read)}"
        val unread = devices.filter { it.personName !in readUsers }
        if (unread.isNotEmpty()) {
            val del = unread.filter { it.state == DeliveryState.Delivered }.map { "${it.personName}'s ${it.device.possessive}" }
            if (del.isNotEmpty()) parts += "delivered to ${list(del)}"
            if (carried.isNotEmpty()) parts += "carried by ${list(carried)}"
            val wait = unread.filter { it.state != DeliveryState.Delivered }.map { "${it.personName}'s ${it.device.possessive}" }
            if (wait.isNotEmpty()) parts += "waiting for ${list(wait)}"
        }
        if (parts.isEmpty()) return "sent"
        if (read.isEmpty() && devices.none { it.state == DeliveryState.Delivered } && carried.isEmpty()) return "sent, nobody online to carry it"
        return parts.joinToString(" · ")
    }

/// One word for the row: read > delivered > carried > sent.
val Delivery.best: DeliveryState
    get() {
        if (devices.any { it.state == DeliveryState.Read }) return DeliveryState.Read
        if (devices.any { it.state == DeliveryState.Delivered }) return DeliveryState.Delivered
        devices.firstOrNull { it.state is DeliveryState.Carried }?.let { return it.state }
        return DeliveryState.Sent
    }

/// How long a disappearing message lasts, in the largest unit that fits it whole: "5 minutes",
/// "1 hour", "1 day", "4 weeks" (baud-core's `disappear_after`).
fun disappearAfter(seconds: Int): String {
    val (n, unit) = disappearUnit(seconds)
    return "$n $unit" + if (n == 1) "" else "s"
}

/// The same, short, for a conversation's header: "5m", "1h", "8h", "1d", "1w", "4w".
fun disappearShort(seconds: Int): String {
    val (n, unit) = disappearUnit(seconds)
    return "$n${unit.first()}"
}

private fun disappearUnit(seconds: Int): Pair<Int, String> {
    for ((size, unit) in listOf(604_800 to "week", 86_400 to "day", 3600 to "hour", 60 to "minute")) if (seconds >= size && seconds % size == 0) return seconds / size to unit
    return seconds to "second"
}

/// The timeline's line when someone changes the setting: "Ana set messages to disappear 1 day
/// after they're read" · "You turned off disappearing messages" (baud-core's own, for the stand-in).
fun disappearLine(by: String, seconds: Int): String =
    if (seconds > 0) "$by set messages to disappear ${disappearAfter(seconds)} after they're read" else "$by turned off disappearing messages"

/// "a, b and c"
fun list(items: List<String>): String = when (items.size) {
    0 -> ""
    1 -> items[0]
    2 -> "${items[0]} and ${items[1]}"
    else -> items.dropLast(1).joinToString(", ") + " and ${items.last()}"
}

fun ago(date: Instant): String {
    val s = Duration.between(date, Instant.now()).seconds
    return when {
        s < 45 -> "just now"
        s < 5400 -> "${maxOf(1, s / 60)} min ago"
        s < 86_400 -> "${s / 3600} h ago"
        else -> "${s / 86_400} d ago"
    }
}

fun bytesText(n: Long): String = when {
    n < 1000 -> "$n B"
    n < 1_000_000 -> String.format("%.0f KB", n / 1000.0)
    n < 1_000_000_000 -> String.format("%.1f MB", n / 1_000_000.0)
    else -> String.format("%.2f GB", n / 1_000_000_000.0)
}
