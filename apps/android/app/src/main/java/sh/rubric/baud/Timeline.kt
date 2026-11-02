// One conversation's rows, ready to draw (apps/shared/Timeline.swift): pages of events from the
// core, grouped by sender and day, and the one status line under my newest message. Screens never
// compute any of this.
package sh.rubric.baud

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import sh.rubric.baud.core.ConversationId
import sh.rubric.baud.core.Delivery
import sh.rubric.baud.core.DeliveryState
import sh.rubric.baud.core.Event
import sh.rubric.baud.core.EventId
import sh.rubric.baud.core.EventType
import sh.rubric.baud.core.list
import java.time.Duration
import java.time.LocalDate
import java.time.ZoneId

class Timeline(val conv: ConversationId, private val model: AppModel) {
    sealed interface Row {
        val key: String
        data class Day(val date: LocalDate) : Row { override val key get() = "day-$date" }
        data class Item(val event: Event, val first: Boolean, val last: Boolean) : Row { override val key get() = event.id }
    }

    var events by mutableStateOf(listOf<Event>()); private set
    var rows by mutableStateOf(listOf<Row>()); private set
    var byId: Map<EventId, Event> = emptyMap(); private set
    var delivery by mutableStateOf<Delivery?>(null); private set
    var typing by mutableStateOf(listOf<String>()); private set
    var exhausted = false; private set
    private val page = 200

    init { reload() }

    fun reload() {
        val want = maxOf(page, events.size)
        events = model.core.events(conv, null, want)
        exhausted = events.size < want
        build()
        refreshDelivery()
    }

    fun loadMore() {
        if (exhausted) return
        val first = events.firstOrNull() ?: return
        val older = model.core.events(conv, first.id, page)
        exhausted = older.size < page
        if (older.isEmpty()) return
        events = older + events
        build()
    }

    fun refreshDelivery() {
        val last = events.lastOrNull { it.mine && it.type == EventType.Message }
        delivery = last?.let { runCatching { model.core.delivery(conv, it.id) }.getOrNull() }
    }

    /// Under my message while it is the newest, in a few quiet words: "Sending…", "Waiting for Ana",
    /// "Carried by Jo's Mac", "Delivered", "Read". Null when someone has answered since, or it's only me.
    val status: String?
        get() {
            val d = delivery ?: return null
            val last = events.lastOrNull() ?: return null
            if (last.id != d.event || d.devices.isEmpty()) return null
            fun level(s: DeliveryState) = when (s) { DeliveryState.Read -> 3; DeliveryState.Delivered -> 2; is DeliveryState.Carried -> 1; DeliveryState.Sent -> 0 }
            val people = d.devices.groupBy { it.personName }.mapValues { (_, ds) -> ds.maxOf { level(it.state) } }
            val one = people.size == 1
            if (people.values.all { it == 3 }) return if (one) "Read" else "Read by everyone"
            if (people.values.all { it >= 2 }) {
                val read = people.filter { it.value == 3 }.keys.sorted()
                return if (read.isEmpty()) "Delivered" else "Delivered · read by ${list(read)}"
            }
            val behind = people.filter { it.value < 2 }.keys.sorted()
            val online = d.devices.filter { it.device.online }.map { it.personName }.toSet()
            val carriers = d.devices.flatMap { it.carriers }.toSortedSet().toList()
            val who = if (behind.size <= 2) list(behind) else "${behind.size} people"
            if (behind.all { it in online }) return "Sending…"
            if (carriers.size == 1 && one) return "Carried by ${carriers[0]}"
            return "Waiting for $who"
        }

    private var typingTimer: Job? = null
    fun refreshTyping() {
        typing = model.core.typingNow(conv).map { model.name(it) }
        // The core forgets a typer five seconds after its last frame; look again just after that.
        typingTimer?.cancel()
        if (typing.isNotEmpty()) typingTimer = model.scope.launch { delay(5200); refreshTyping() }
    }

    /// Read only while it's in front of the person: the app in front and this chat on screen.
    fun markRead() {
        if (!model.front || model.onScreen != conv) return
        events.lastOrNull()?.let { runCatching { model.core.markRead(conv, it.id) } }
    }

    private fun build() {
        val out = ArrayList<Row>(events.size + 16)
        val zone = ZoneId.systemDefault()
        var lastDay: LocalDate? = null
        for ((i, e) in events.withIndex()) {
            val day = e.at.atZone(zone).toLocalDate()
            if (day != lastDay) { out += Row.Day(day); lastDay = day }
            val prev = events.getOrNull(i - 1)
            val next = events.getOrNull(i + 1)
            out += Row.Item(e, first = prev?.let { !same(it, e) } ?: true, last = next?.let { !same(e, it) } ?: true)
        }
        rows = out
        byId = events.associateBy { it.id }
    }

    /// Same sender, same day, within five minutes, both plain messages.
    private fun same(a: Event, b: Event): Boolean {
        val zone = ZoneId.systemDefault()
        return a.user == b.user && a.type == EventType.Message && b.type == EventType.Message &&
            Duration.between(a.at, b.at).seconds < 300 && a.at.atZone(zone).toLocalDate() == b.at.atZone(zone).toLocalDate()
    }
}
