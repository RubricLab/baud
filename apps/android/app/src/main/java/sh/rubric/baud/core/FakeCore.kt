// The stand-in until baud-core's bindings land: one device in memory, and (on Demo) the people
// around it from BaudCore/Demo.swift's everyday talk. Ana on her Mac (her iPhone away), Jo through
// Ana's Mac, Sam direct, Maya a friend with no chat yet, Lee a friend of Ana's met in a group.
// Delivery moves as it would (Sending… → Delivered → Read), friends answer a question, and a
// debug broadcast makes one of them write, so notifications can be seen with the app closed.
package sh.rubric.baud.core

import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Shader
import android.util.Base64
import kotlinx.coroutines.delay
import java.io.File
import java.security.MessageDigest
import java.security.SecureRandom
import java.time.Instant
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import android.graphics.Path as GPath

class FakeCore(private val dir: File, private val prefs: SharedPreferences, deviceName: String) : CoreSurface {
    private val lock = Any()
    private val listeners = CopyOnWriteArrayList<(Change) -> Unit>()
    private val clock = Executors.newSingleThreadScheduledExecutor { Thread(it, "fake-core").apply { isDaemon = true } }
    private val random = SecureRandom()

    private val user: UserId = prefs.getString("user", null) ?: hex(16).also { prefs.edit().putString("user", it).apply() }
    private val thisDevice: DeviceId = "phone-" + user.take(8)
    private var name: String = prefs.getString("name", "") ?: ""
    private var avatar: BlobHash? = prefs.getString("avatar", null)
    private val mine = mutableListOf(Device(thisDevice, deviceName, DeviceKind.Android, user, online = true))
    private val friends = LinkedHashMap<UserId, Contact>()
    /// People met through a shared conversation, not friends: their names and devices.
    private val strangers = LinkedHashMap<UserId, Pair<String, List<Device>>>()
    private val convs = LinkedHashMap<ConversationId, Conv>()
    private val blobs = HashMap<BlobHash, File>()
    private val typers = HashMap<ConversationId, MutableMap<UserId, Long>>()
    private var lamport = 1000L
    private var online = true
    var demo = false
        private set

    private class Conv(
        var c: Conversation,
        val events: MutableList<Event> = mutableListOf(),
        /// For each of my messages: each other device's state, and who carries for it.
        val receipts: MutableMap<EventId, MutableMap<DeviceId, Pair<DeliveryState, List<String>>>> = HashMap(),
        var read: Long = 0,
    )

    init {
        File(dir, "blobs").mkdirs()
        avatar?.let { h -> File(dir, "blobs/$h").takeIf { it.exists() }?.let { blobs[h] = it } }
        if (prefs.getBoolean("demo", false) && name.isNotEmpty()) seedDemo()
    }

    // MARK: listeners

    private fun emit(vararg changes: Change) {
        clock.execute { for (c in changes) for (l in listeners) l(c) }
    }
    private fun later(ms: Long, f: () -> Unit) { clock.schedule({ synchronized(lock) { f() } }, ms, TimeUnit.MILLISECONDS) }

    override fun subscribe(listener: (Change) -> Unit): Subscription {
        listeners += listener
        return Subscription { listeners -= listener }
    }

    // MARK: me and my devices

    override fun me(): Person = synchronized(lock) { Person(user, name, fingerprint(user), mine.toList(), thisDevice, avatar) }

    override fun setName(name: String) {
        synchronized(lock) { this.name = name.trim(); prefs.edit().putString("name", this.name).apply() }
        emit(Change.Me)
    }

    override fun setAvatar(path: String) {
        val h = putBlob(File(path))
        synchronized(lock) { avatar = h; prefs.edit().putString("avatar", h).apply() }
        emit(Change.Me, Change.Conversations)
    }

    override fun linkDevice(): Link = token('m', "baud://link#", 600)
    override fun invite(): Link = token('f', "baud://add#", 3600)

    override suspend fun link(link: Link) {
        delay(1500)
        if (link.expires.isBefore(Instant.now())) throw CoreError.Expired
        synchronized(lock) { mine += Device("dev-" + hex(4), "${link.name}'s Mac", DeviceKind.Mac, user, online = true, lastOnline = Instant.now(), path = Path.Direct(12)) }
        emit(Change.Me, Change.Peers)
    }

    override fun revoke(device: DeviceId) {
        synchronized(lock) { mine.removeAll { it.id == device && it.id != thisDevice } }
        emit(Change.Me, Change.Peers)
    }

    // MARK: contacts

    override suspend fun add(link: Link): Contact {
        delay(1600)
        if (link.expires.isBefore(Instant.now())) throw CoreError.Expired
        val c = synchronized(lock) {
            friends.values.firstOrNull { it.name == link.name } ?: run {
                val u = hex(16)
                Contact(u, link.name, false, fingerprint(u), listOf(Device("dev-" + hex(4), "${link.name}'s phone", DeviceKind.Android, u, online = true, lastOnline = Instant.now(), path = Path.Direct(22))), Instant.now())
                    .also { friends[u] = it }
            }
        }
        emit(Change.Contacts, Change.Peers, Change.Conversations)
        return c
    }

    override fun contacts(): List<Contact> = synchronized(lock) { friends.values.toList() }
    override fun verify(user: UserId, fingerprint: String): Boolean = synchronized(lock) {
        val c = friends[user] ?: return false
        val ok = c.fingerprint.replace(" ", "") == fingerprint.replace(" ", "")
        if (ok) friends[user] = c.copy(verified = true)
        ok
    }.also { emit(Change.Contacts) }

    override fun unfriend(user: UserId) {
        synchronized(lock) {
            friends.remove(user)
            convs.values.removeAll { it.c.isDirect && user in it.c.members }
        }
        emit(Change.Contacts, Change.Conversations, Change.Peers)
    }

    override fun parse(text: String): Link? = Links.parse(text)

    // MARK: conversations

    override fun conversations(kind: ConvKind?): List<Conversation> = synchronized(lock) {
        convs.values.map { summary(it) }.filter { kind == null || it.kind == kind }.sortedByDescending { it.lastAt }
    }

    override fun conversation(id: ConversationId): Conversation? = synchronized(lock) { convs[id]?.let { summary(it) } }

    private fun summary(v: Conv): Conversation {
        val msgs = v.events.filter { it.type == EventType.Message }
        val last = msgs.lastOrNull()
        return v.c.copy(
            lastAt = last?.at ?: v.c.createdAt,
            lastText = last?.let { it.text ?: if (it.attachments.isNotEmpty()) "Photo" else null },
            lastUser = last?.user, lastEvent = last?.id,
            unread = msgs.count { !it.mine && it.lamport > v.read },
            mentions = msgs.count { !it.mine && it.lamport > v.read && user in it.mentions },
            eventCount = v.events.size,
        )
    }

    override fun events(conv: ConversationId, before: EventId?, limit: Int): List<Event> = synchronized(lock) {
        val all = convs[conv]?.events ?: return emptyList()
        val end = before?.let { b -> all.indexOfFirst { it.id == b }.takeIf { it >= 0 } } ?: all.size
        all.subList(maxOf(0, end - limit), end).toList()
    }

    override fun send(conv: ConversationId, draft: Draft): Event {
        val files = draft.attachments.map { File(it) }.map { f -> attachment(f) }
        val e = synchronized(lock) {
            val v = convs[conv] ?: throw CoreError.NotFound
            val e = Event(
                id = "e-" + hex(8), conv = conv, device = thisDevice, seq = ++lamport, user = user, at = Instant.now(), lamport = lamport,
                type = EventType.Message, text = draft.text.ifBlank { null }, attachments = files, reply = draft.reply, thread = draft.thread,
                mentions = draft.mentions, mine = true, via = Via.Waiting,
            )
            v.events += e
            v.read = e.lamport
            v.receipts[e.id] = others(v.c).associate { it.id to (DeliveryState.Sent to emptyList<String>()) }.toMutableMap()
            if (online) progress(v, e)
            e
        }
        emit(Change.Conversation(conv), Change.Conversations, Change.Delivery(conv))
        return e
    }

    /// What happens to a message of mine once it leaves: each online device has it a moment later;
    /// an away one is held by an online device of theirs or a friend's; the person reads it soon
    /// after if they're on; a question gets an answer.
    private fun progress(v: Conv, e: Event) {
        later(700) {
            val r = v.receipts[e.id] ?: return@later
            val devices = others(v.c)
            val carrier = devices.firstOrNull { it.online }
            for (d in devices) {
                r[d.id] = when {
                    d.online -> DeliveryState.Delivered to emptyList()
                    carrier != null -> DeliveryState.Carried(carrier.id) to listOf("${nameOf(carrier.user)}'s ${carrier.possessive}")
                    else -> DeliveryState.Sent to emptyList()
                }
            }
            val path = devices.firstOrNull { it.online }?.path
            replace(v, e.id) { it.copy(via = when { path is Path.Relay -> Via.Relay; path != null -> Via.Direct; else -> Via.Waiting }) }
            emit(Change.Delivery(v.c.id), Change.Conversation(v.c.id), Change.Conversations)
        }
        val readers = devices(v.c).filter { it.online && it.user in friends }
        if (readers.isEmpty()) return
        later(3200) {
            val r = v.receipts[e.id] ?: return@later
            for (d in readers) r[d.id] = DeliveryState.Read to emptyList()
            emit(Change.Delivery(v.c.id), Change.Conversations)
        }
        if (e.text?.trim()?.endsWith("?") == true) {
            val who = readers.first().user
            later(4200) { typers.getOrPut(v.c.id) { HashMap() }[who] = System.currentTimeMillis() + 5000; emit(Change.Typing(v.c.id)) }
            later(7200) {
                typers[v.c.id]?.remove(who)
                incoming(v, who, answers[(lamport % answers.size).toInt()])
                emit(Change.Typing(v.c.id), Change.Conversation(v.c.id), Change.Conversations)
            }
        }
    }

    private val answers = listOf("yes!!", "sounds good", "haha yes", "on my way", "can't wait", "ok!", "love it", "let me check and get back to you")

    private fun incoming(v: Conv, from: UserId, text: String?, at: Instant = Instant.now(), photo: Attachment? = null): Event {
        val d = (friends[from]?.devices ?: strangers[from]?.second.orEmpty()).let { ds -> ds.firstOrNull { it.online } ?: ds.firstOrNull() }
        val e = Event(
            id = "e-" + hex(8), conv = v.c.id, device = d?.id ?: "", seq = ++lamport, user = from, at = at, lamport = lamport,
            type = EventType.Message, text = text, attachments = listOfNotNull(photo),
            via = if (d?.path is Path.Relay) Via.Relay else Via.Direct,
        )
        v.events += e
        return e
    }

    /// A friend writes: the debug broadcast `sh.rubric.baud.DEMO_SAY` (`--es from Ana --es text …`).
    fun say(fromName: String, text: String) {
        val conv = synchronized(lock) {
            val u = friends.values.firstOrNull { it.name.equals(fromName, true) }?.user ?: return
            val v = convs.values.firstOrNull { it.c.isDirect && u in it.c.members } ?: Conv(newChat(listOf(user, u))).also { convs[it.c.id] = it }
            incoming(v, u, text)
            v.c.id
        }
        emit(Change.Conversation(conv), Change.Conversations)
    }

    override fun react(conv: ConversationId, target: EventId, key: String, on: Boolean) {
        synchronized(lock) {
            val v = convs[conv] ?: throw CoreError.NotFound
            replace(v, target) { e ->
                val others = e.reactions.filter { it.key != key }
                val r = e.reactions.firstOrNull { it.key == key }
                val users = (r?.users.orEmpty() - user).let { if (on) it + user else it }
                e.copy(reactions = if (users.isEmpty()) others else (e.reactions.map { if (it.key == key) Reaction(key, users, on) else it }.takeIf { r != null } ?: (e.reactions + Reaction(key, users, on))))
            }
        }
        emit(Change.Conversation(conv))
    }

    override fun edit(conv: ConversationId, target: EventId, text: String) {
        synchronized(lock) { convs[conv]?.let { v -> replace(v, target) { it.copy(text = text, edited = true) } } }
        emit(Change.Conversation(conv), Change.Conversations)
    }

    override fun redact(conv: ConversationId, target: EventId) {
        synchronized(lock) { convs[conv]?.events?.removeAll { it.id == target } }
        emit(Change.Conversation(conv), Change.Conversations)
    }

    override fun markRead(conv: ConversationId, event: EventId) {
        val changed = synchronized(lock) {
            val v = convs[conv] ?: return
            val l = v.events.firstOrNull { it.id == event }?.lamport ?: return
            if (l > v.read) { v.read = l; true } else false
        }
        if (changed) emit(Change.Conversations)
    }

    override fun typing(conv: ConversationId) {}
    override fun typingNow(conv: ConversationId): List<UserId> = synchronized(lock) {
        val now = System.currentTimeMillis()
        typers[conv]?.filterValues { it > now }?.keys?.toList().orEmpty()
    }

    override fun members(conv: ConversationId): List<Member> = synchronized(lock) {
        val v = convs[conv] ?: return emptyList()
        v.c.members.map { u ->
            when {
                u == user -> Member(u, name, u in v.c.admins, v.c.createdAt, mine.toList(), true, true)
                friends[u] != null -> friends.getValue(u).let { Member(u, it.name, u in v.c.admins, v.c.createdAt, it.devices, it.verified, false) }
                else -> strangers[u].let { Member(u, it?.first ?: "Someone", u in v.c.admins, v.c.createdAt, it?.second.orEmpty(), false, false) }
            }
        }
    }

    override fun delivery(conv: ConversationId, event: EventId): Delivery = synchronized(lock) {
        val v = convs[conv] ?: return Delivery(event, emptyList())
        val r = v.receipts[event] ?: return Delivery(event, emptyList())
        Delivery(event, others(v.c).map { d -> r[d.id].let { DeviceDelivery(d, nameOf(d.user), it?.first ?: DeliveryState.Sent, it?.second.orEmpty()) } })
    }

    override fun createChat(users: List<UserId>): Conversation {
        val c = synchronized(lock) {
            if (users.size == 1) convs.values.firstOrNull { it.c.isDirect && users[0] in it.c.members }?.let { return@synchronized summary(it) }
            Conv(newChat(listOf(user) + users)).also { convs[it.c.id] = it }.let { summary(it) }
        }
        emit(Change.Conversations)
        return c
    }

    override fun createGroup(name: String, users: List<UserId>): Conversation {
        val c = synchronized(lock) { Conv(newChat(listOf(user) + users, name)).also { convs[it.c.id] = it }.let { summary(it) } }
        emit(Change.Conversations)
        return c
    }

    override fun delete(conv: ConversationId) {
        synchronized(lock) { convs.remove(conv) }
        emit(Change.Conversations)
    }

    override fun search(query: String): List<Hit> = synchronized(lock) {
        val q = query.trim().lowercase()
        if (q.length < 2) return emptyList()
        convs.values.flatMap { v -> v.events.filter { it.text?.lowercase()?.contains(q) == true }.map { Hit(it, summary(v), it.text!!) } }
            .sortedByDescending { it.event.at }.take(40)
    }

    override suspend fun blob(hash: BlobHash, key: String): String =
        synchronized(lock) { blobs[hash] }?.path ?: throw CoreError.NotFound

    // MARK: the network

    override fun peers(): List<Peer> = synchronized(lock) {
        mine.filter { it.id != thisDevice }.map { Peer(it, name, true, 3.0, FoundBy.Exchange) } +
            friends.values.flatMap { c -> c.devices.map { Peer(it, c.name, false, 8.0, FoundBy.Invite) } }
    }

    override fun carrying(): Carrying = Carrying()
    override fun netState(): NetState = if (online) NetState.Online else NetState.Offline
    override fun setOnline(online: Boolean) { synchronized(lock) { this.online = online } }

    // MARK: inside

    private fun devices(c: Conversation): List<Device> = c.members.filter { it != user }.flatMap { u -> friends[u]?.devices ?: strangers[u]?.second.orEmpty() }
    private fun others(c: Conversation): List<Device> = devices(c)
    private fun nameOf(u: UserId): String = if (u == user) name else friends[u]?.name ?: strangers[u]?.first ?: "Someone"

    private fun replace(v: Conv, id: EventId, f: (Event) -> Event) {
        val i = v.events.indexOfFirst { it.id == id }
        if (i >= 0) v.events[i] = f(v.events[i])
    }

    private fun newChat(members: List<UserId>, name: String? = null): Conversation {
        val now = Instant.now()
        return Conversation("c-" + hex(8), ConvKind.Chat, name = name, members = members, admins = listOf(members.first()), createdAt = now, lastAt = now)
    }

    private fun putBlob(f: File): BlobHash {
        val bytes = f.readBytes()
        val h = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        val to = File(dir, "blobs/$h")
        if (!to.exists()) to.writeBytes(bytes)
        synchronized(lock) { blobs[h] = to }
        return h
    }

    private fun attachment(f: File): Attachment {
        val h = putBlob(f)
        val o = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(f.path, o)
        val image = o.outWidth > 0
        val ext = f.extension.lowercase()
        val mime = if (image) o.outMimeType ?: "image/jpeg" else when (ext) { "mp4", "mov" -> "video/mp4"; "pdf" -> "application/pdf"; else -> "application/octet-stream" }
        // A photo turned the way it was taken: its box is the turned one.
        val rotated = image && runCatching { androidx.exifinterface.media.ExifInterface(f.path).rotationDegrees % 180 != 0 }.getOrDefault(false)
        return Attachment(h, "", mime, f.length(), f.name, if (!image) null else if (rotated) o.outHeight else o.outWidth, if (!image) null else if (rotated) o.outWidth else o.outHeight)
    }

    private fun token(kind: Char, prefix: String, seconds: Long): Link {
        val n = name.toByteArray().take(255)
        val expires = Instant.now().plusSeconds(seconds)
        val b = ArrayList<Byte>()
        b += 1; b += kind.code.toByte(); b += n.size.toByte(); b += n
        b += ByteArray(32).also { random.nextBytes(it) }.toList()
        for (i in 7 downTo 0) b += ((expires.epochSecond shr (i * 8)) and 0xFF).toByte()
        b += ByteArray(32).also { random.nextBytes(it) }.toList()
        b += ByteArray(18).also { random.nextBytes(it) }.toList()
        val t = Base64.encodeToString(b.toByteArray(), Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
        return Link(prefix + t, if (kind == 'm') Link.Kind.Device else Link.Kind.Friend, name, expires)
    }

    private fun hex(n: Int): String = ByteArray(n).also { random.nextBytes(it) }.joinToString("") { "%02x".format(it) }
    private fun fingerprint(u: UserId): String = u.take(20).chunked(4).joinToString(" ").uppercase()

    // MARK: demo

    /// Starts over: my name, face and the people around me gone (You → Start over).
    fun wipe() {
        synchronized(lock) {
            prefs.edit().clear().apply()
            friends.clear(); strangers.clear(); convs.clear(); typers.clear()
            name = ""; avatar = null; demo = false
            mine.retainAll { it.id == thisDevice }
            File(dir, "blobs").listFiles()?.forEach { it.delete() }
            blobs.clear()
        }
        emit(Change.Me, Change.Contacts, Change.Conversations, Change.Peers)
    }

    fun startDemo() {
        synchronized(lock) { if (demo) return; prefs.edit().putBoolean("demo", true).apply(); seedDemo() }
        emit(Change.Me, Change.Contacts, Change.Conversations, Change.Peers)
    }

    private fun seedDemo() {
        demo = true
        val now = Instant.now()
        fun ago(min: Long) = now.minusSeconds(min * 60)
        fun dev(id: String, name: String, kind: DeviceKind, u: UserId, on: Boolean, path: Path = Path.None, last: Instant? = now) = Device(id, name, kind, u, ago(60 * 24 * 30), on, last, path)
        val ana = "u-ana"; val jo = "u-jo"; val sam = "u-sam"; val maya = "u-maya"; val lee = "u-lee"
        val anaMac = dev("d-ana-mac", "Ana's Mac", DeviceKind.Mac, ana, true, Path.Direct(14))
        friends[ana] = Contact(ana, "Ana", true, fingerprint(ana + "a1b2c3d4e5f6"), listOf(anaMac, dev("d-ana-iphone", "Ana's iPhone", DeviceKind.Iphone, ana, false, last = ago(120))), ago(60 * 24 * 40))
        friends[jo] = Contact(jo, "Jo", false, fingerprint(jo + "b2c3d4e5f6a1"), listOf(dev("d-jo-iphone", "Jo's iPhone", DeviceKind.Iphone, jo, true, Path.Relay(anaMac.id, "Ana's Mac"))), ago(60 * 24 * 20))
        friends[sam] = Contact(sam, "Sam", false, fingerprint(sam + "c3d4e5f6a1b2"), listOf(dev("d-sam-mac", "Sam's Mac", DeviceKind.Mac, sam, true, Path.Direct(31))), ago(60 * 24 * 12))
        friends[maya] = Contact(maya, "Maya", false, fingerprint(maya + "d4e5f6a1b2c3"), listOf(dev("d-maya-iphone", "Maya's iPhone", DeviceKind.Iphone, maya, false, last = ago(180))), ago(60 * 24 * 2))
        strangers[lee] = "Lee" to listOf(dev("d-lee-mini", "Lee's Mac mini", DeviceKind.Mac, lee, true, Path.Relay(anaMac.id, "Ana's Mac")))
        if (mine.size == 1) mine += dev("d-my-mac", "${name.split(" ").first()}'s MacBook Air", DeviceKind.Mac, user, true, Path.Direct(9))

        val photo = runCatching {
            val f = File(dir, "demo-dusk.jpg")
            if (!f.exists()) f.outputStream().use { DemoImage.make(1200, 900).compress(Bitmap.CompressFormat.JPEG, 88, it) }
            Attachment(putBlob(f), "", "image/jpeg", f.length(), "IMG_4103.jpg", 1200, 900)
        }.getOrNull()

        /// One conversation as written: (who, words, a photo, a reaction someone puts on it), my
        /// lines read by everyone but the newest, which is delivered.
        fun script(v: Conv, from: Long, gap: Long, lines: List<Line>) {
            var at = now.minusSeconds(from * 60)
            val steps = longArrayOf(7, 12, 5, 9, 14, 6, 10, 8, 11, 4)
            for ((i, l) in lines.withIndex()) {
                at = at.plusSeconds(gap * 60 * steps[i % steps.size] / 10)
                val e = if (l.who == user) Event("e-" + hex(8), v.c.id, thisDevice, ++lamport, user, at, lamport, EventType.Message, l.text, listOfNotNull(if (l.photo) photo else null), mine = true, via = Via.Direct)
                    .also { v.events += it }
                else incoming(v, l.who, l.text, at, if (l.photo) photo else null)
                l.reaction?.let { (by, key) -> replace(v, e.id) { it.copy(reactions = listOf(Reaction(key, listOf(by), by == user))) } }
                if (e.mine) v.receipts[e.id] = others(v.c).associate { d -> d.id to ((if (d.online) DeliveryState.Read else DeliveryState.Sent) to emptyList<String>()) }.toMutableMap()
            }
            v.read = v.events.lastOrNull()?.lamport ?: 0
            v.events.lastOrNull { it.mine }?.let { last -> v.receipts[last.id]?.replaceAll { _, s -> if (s.first == DeliveryState.Read) DeliveryState.Delivered to emptyList() else s } }
        }
        fun conv(members: List<UserId>, name: String? = null, created: Long): Conv =
            Conv(newChat(listOf(user) + members, name).copy(createdAt = ago(created))).also { convs[it.c.id] = it }

        val weekend = conv(listOf(ana, jo), "weekend", 60 * 50)
        script(weekend, 30 * 60, 30, listOf(Line(ana, "cabin is booked 🏡", reaction = jo to "🙌"), Line(jo, "who's driving?"), Line(user, "I can drive"), Line(ana, "I'll do groceries"), Line(jo, "bringing the speaker")))
        val hike = conv(listOf(ana, lee), "hike", 60 * 60)
        script(hike, 50 * 60, 40, listOf(Line(ana, "trail map is in the group"), Line(lee, "I'll bring snacks"), Line(user, "see you at the station")))
        val dmAna = conv(listOf(ana), created = 60 * 30)
        script(dmAna, 20 * 60, 15, listOf(Line(ana, "landed 🛬"), Line(user, "welcome back!! how was lisbon?"), Line(ana, "unreal. the light there"), Line(ana, null, photo = true, reaction = user to "😍"), Line(user, "ok that's not fair"), Line(ana, "I'll tell you everything")))
        val dmJo = conv(listOf(jo), created = 60 * 5)
        script(dmJo, 2 * 60, 15, listOf(Line(jo, "did you get the tickets?"), Line(user, "two, row F", reaction = jo to "🔥"), Line(jo, "you're the best")))
        val dmSam = conv(listOf(sam), created = 60 * 3)
        script(dmSam, 80, 7, listOf(Line(sam, "you around this weekend?"), Line(user, "yes! what's up"), Line(sam, "hike saturday, then dinner?"), Line(sam, null, photo = true, reaction = user to "😍"), Line(user, "that view"), Line(sam, "leaves at 8 from the station", reaction = user to "👍"), Line(user, "I'll bring coffee ☕️"), Line(sam, "legend"), Line(user, "dinner after at mine?"), Line(sam, "yes!! I'll bring dessert"), Line(user, "see you saturday ✌️")))
        // The newest lines: Ana's and Jo's, not read yet.
        incoming(dmAna, ana, "dinner thursday?", now.minusSeconds(4 * 60))
        incoming(weekend, jo, "who's in for saturday?", now.minusSeconds(11 * 60))
    }

    private data class Line(val who: UserId, val text: String?, val photo: Boolean = false, val reaction: Pair<UserId, String>? = null)
}

/// Links in both forms: dotted `peer1.f.<name>.<user>.<expires>.<device>.<meet>` and the dotless
/// one-token form, bare or after `baud://add#`, `baud://link#`, `https://baud.rubric.sh/add#`.
/// (BaudCore's Code.parse and parseLink; the real core parses them once its bindings land.)
object Links {
    fun parse(text: String): Link? {
        val t = text.trim().replace(" ", "").replace("\n", "")
        if (t.isEmpty()) return null
        if ("#" in t) return parseLink(t)
        if ("." !in t) parseLink(t)?.let { l -> return parseLink("baud://${if (l.kind == Link.Kind.Device) "link" else "add"}#$t") }
        val parts = t.split(".")
        if (parts.size != 7 || parts[0] != "peer1") return null
        return parseLink("baud://${if (parts[1] == "m") "link" else "add"}#$t")
    }

    private fun parseLink(url: String): Link? {
        val frag = url.substringAfterLast("#")
        if (frag.isNotEmpty() && "." !in frag) return dotless(frag, url)
        val parts = frag.split(".")
        if (parts.size != 7 || parts[0] != "peer1") return null
        val kind = when (parts[1]) { "f" -> Link.Kind.Friend; "m" -> Link.Kind.Device; else -> return null }
        val t = parts[4].toDoubleOrNull() ?: return null
        val name = runCatching { String(Base64.decode(parts[2], Base64.URL_SAFE or Base64.NO_PADDING)) }.getOrNull()
            ?.takeIf { s -> s.isNotEmpty() && s.none { it == '\n' || it == '\u0000' } && s.all { !it.isISOControl() } } ?: parts[2]
        return Link(url.replace("https://baud.rubric.sh/", "baud://"), kind, name, Instant.ofEpochSecond(t.toLong()))
    }

    /// `1 | kind | name length, name | user (32) | expires (8, big-endian seconds) | secret (32) | meet`.
    private fun dotless(token: String, url: String): Link? {
        val d = runCatching { Base64.decode(token, Base64.URL_SAFE or Base64.NO_PADDING) }.getOrNull() ?: return null
        if (d.size <= 3 || d[0].toInt() != 1) return null
        val kind = when (d[1].toInt().toChar()) { 'f' -> Link.Kind.Friend; 'm' -> Link.Kind.Device; else -> return null }
        val n = d[2].toInt() and 0xFF
        val at = 3 + n + 32
        if (d.size < at + 8 + 32) return null
        val name = runCatching { String(d, 3, n, Charsets.UTF_8) }.getOrNull() ?: return null
        var t = 0L
        for (i in 0 until 8) t = (t shl 8) or (d[at + i].toLong() and 0xFF)
        return Link(url.replace("https://baud.rubric.sh/", "baud://"), kind, name, Instant.ofEpochSecond(t))
    }
}

/// A dusk over water (apps/shared/QRCode.swift's DemoImage): something that reads as a photo.
object DemoImage {
    fun make(w: Int, h: Int): Bitmap {
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val c = Canvas(bmp)
        val W = w.toFloat(); val H = h.toFloat(); val horizon = H * 0.60f   // from the top
        fun rgb(r: Int, g: Int, b: Int, a: Int = 255) = android.graphics.Color.argb(a, r, g, b)
        val p = Paint(Paint.ANTI_ALIAS_FLAG)
        p.shader = LinearGradient(0f, horizon, 0f, 0f, intArrayOf(rgb(245, 166, 98), rgb(214, 108, 112), rgb(62, 58, 112), rgb(26, 32, 70)), floatArrayOf(0f, 0.25f, 0.7f, 1f), Shader.TileMode.CLAMP)
        c.drawRect(0f, 0f, W, horizon, p)
        p.shader = null; p.color = rgb(255, 214, 140)
        val sunTop = horizon + W * 0.05f - W * 0.13f
        c.drawOval(RectF(W * 0.58f, sunTop, W * 0.58f + W * 0.13f, sunTop + W * 0.13f), p)
        p.shader = LinearGradient(0f, H, 0f, horizon, rgb(18, 26, 56), rgb(70, 62, 104), Shader.TileMode.CLAMP)
        c.drawRect(0f, horizon, W, H, p)
        p.shader = null; p.color = rgb(255, 200, 130, 140)
        for (i in 0 until 9) {
            val y = horizon + (i + 1) * H * 0.035f; val wd = W * (0.12f - i * 0.01f); val hh = maxOf(1f, H * 0.008f)
            c.drawRect(W * 0.645f - wd / 2, y - hh, W * 0.645f + wd / 2, y, p)
        }
        p.color = rgb(20, 22, 44)
        val land = GPath().apply { moveTo(0f, horizon); cubicTo(W * 0.12f, horizon - H * 0.16f, W * 0.26f, horizon - H * 0.05f, W * 0.42f, horizon); close() }
        c.drawPath(land, p)
        return bmp
    }
}
