// The core baud's apps call and never implement: BaudCore/Surface.swift's `CoreSurface`, in Kotlin.
// The UI reads only this. Until baud-core's uniffi bindings land, `FakeCore` stands in (one device
// and demo people, in memory); then an adapter over the generated Kotlin conforms to it, and the
// screens don't change. Ids are opaque strings the core hands out; no protocol logic lives here.
package sh.rubric.baud.core

import java.time.Instant

typealias DeviceId = String
typealias UserId = String
typealias ConversationId = String
typealias EventId = String
typealias BlobHash = String

/// A kind this version doesn't know yet reads as a node, so a card listing one still reads.
enum class DeviceKind { Mac, Iphone, Android, Node }

/// How this device reaches another one right now.
sealed interface Path {
    data class Direct(val ms: Int?) : Path
    data class Relay(val via: DeviceId, val name: String) : Path
    data object Nearby : Path
    data object Waiting : Path
    data object Unreachable : Path
    data object None : Path
}

/// One install of someone's, with what this device knows about reaching it right now.
data class Device(
    val id: DeviceId,
    val name: String,
    val kind: DeviceKind,
    val user: UserId,
    val addedAt: Instant = Instant.now(),
    val online: Boolean = false,
    val lastOnline: Instant? = null,
    val path: Path = Path.None,
)

data class Person(
    val user: UserId,
    val name: String,
    val fingerprint: String,
    val devices: List<Device>,
    val thisDevice: DeviceId,
    /// The photo, as a blob hash on the card; null until one is set.
    val avatar: BlobHash? = null,
) {
    val otherDevices: List<Device> get() = devices.filter { it.id != thisDevice }
}

/// An invite (friend) or a device link: `baud://add#…` / `baud://link#…`.
data class Link(
    val url: String,
    val kind: Kind,
    val name: String,
    val expires: Instant,
    /// The same link as `https://baud.rubric.sh/add#…`, for people who don't have baud yet.
    val web: String = url.replace("baud://", "https://baud.rubric.sh/"),
    /// Everything after the `#`: what people copy and paste.
    val code: String = url.substringAfterLast("#"),
) {
    /// A reply answers my friend link, from someone who couldn't reach me: opening it meets them.
    enum class Kind { Friend, Device, Reply }
}

data class Contact(
    val user: UserId,
    val name: String,
    val verified: Boolean,
    val fingerprint: String,
    val devices: List<Device>,
    val metAt: Instant,
    val avatar: BlobHash? = null,
    /// Came by an identity redirect: their old key vouches for this one; not verified.
    val vouched: Boolean = false,
) {
    val online: Boolean get() = devices.any { it.online }
    val lastOnline: Instant? get() = devices.mapNotNull { it.lastOnline }.maxOrNull()
}

enum class ConvKind { Chat, Channel, Space, Home }

data class Conversation(
    val id: ConversationId,
    val kind: ConvKind,
    val name: String? = null,
    val topic: String? = null,
    val space: ConversationId? = null,
    val members: List<UserId>,
    val admins: List<UserId>,
    val createdAt: Instant,
    val lastAt: Instant,
    val lastText: String? = null,
    val lastUser: UserId? = null,
    val lastEvent: EventId? = null,
    val unread: Int = 0,
    val mentions: Int = 0,
    val eventCount: Int = 0,
    val isDefault: Boolean = false,
    val pinned: List<EventId> = emptyList(),
    /// Disappearing messages: how many seconds a message written now lasts after it's read; 0 is off.
    val disappear: Int = 0,
) {
    /// A DM is a chat with exactly two members and no name.
    val isDirect: Boolean get() = kind == ConvKind.Chat && name == null && members.size == 2
}

data class Attachment(
    val hash: BlobHash,
    val key: String = "",
    val mime: String,
    val size: Long,
    val name: String? = null,
    val width: Int? = null,
    val height: Int? = null,
    val duration: Double? = null,
) {
    val isImage: Boolean get() = mime.startsWith("image/")
    val isVideo: Boolean get() = mime.startsWith("video/")
}

data class Reaction(val key: String, val users: List<UserId>, val mine: Boolean)

enum class EventType { Message, Edit, Reaction, Redact, Receipt, Member, Card, State, Create }

/// How it travelled: straight between the two devices, through a helper, carried by a device
/// while the other was away, or still waiting (mine, not yet anywhere).
enum class Via { Direct, Relay, Carried, Waiting }

/// One resolved entry of a conversation: edits applied, reactions grouped, redactions gone.
data class Event(
    val id: EventId,
    val conv: ConversationId,
    val device: DeviceId,
    val seq: Long,
    val user: UserId,
    val at: Instant,
    val lamport: Long,
    val type: EventType,
    val text: String? = null,
    val attachments: List<Attachment> = emptyList(),
    val reply: EventId? = null,
    val thread: EventId? = null,
    val mentions: List<UserId> = emptyList(),
    val reactions: List<Reaction> = emptyList(),
    val edited: Boolean = false,
    val replies: Int = 0,
    val pinned: Boolean = false,
    /// For member, state, create: the line the timeline shows ("Ana added Jo").
    val system: String? = null,
    val mine: Boolean = false,
    /// On a received event: the device that held it for this one while it was away.
    val carriedBy: DeviceId? = null,
    val via: Via? = null,
)

/// What I'm sending: words, files (paths on this device), a reply, a thread.
data class Draft(
    val text: String,
    val attachments: List<String> = emptyList(),
    val reply: EventId? = null,
    val thread: EventId? = null,
    val mentions: List<UserId> = emptyList(),
)

sealed interface DeliveryState {
    data object Sent : DeliveryState
    data class Carried(val by: DeviceId) : DeliveryState
    data object Delivered : DeliveryState
    data object Read : DeliveryState
}

data class DeviceDelivery(
    val device: Device,
    val personName: String,
    val state: DeliveryState,
    /// Every device holding an envelope for this one, named: "Ana's Mac", "your Mac".
    val carriers: List<String> = emptyList(),
)

/// Per device: sent | carried by [device] | delivered | read. Real data, never a guess.
data class Delivery(val event: EventId, val devices: List<DeviceDelivery>)

data class Member(
    val user: UserId,
    val name: String,
    val admin: Boolean,
    val joinedAt: Instant,
    val devices: List<Device>,
    val verified: Boolean,
    val me: Boolean,
) {
    val online: Boolean get() = devices.any { it.online }
}

enum class FoundBy { Cache, Push, Exchange, Nearby, Invite }

data class Peer(
    val device: Device,
    val userName: String,
    val own: Boolean,
    val recordAgeSeconds: Double? = null,
    val foundBy: FoundBy? = null,
    val relaying: Boolean = false,
    val holdingForMe: Int = 0,
    val iHoldForIt: Int = 0,
)

data class Held(val device: DeviceId, val name: String, val count: Int, val bytes: Long)

data class Carrying(
    val envelopes: Int = 0,
    val bytes: Long = 0,
    val budgetBytes: Long = 200_000_000,
    val held: List<Held> = emptyList(),
)

data class Hit(val event: Event, val conversation: Conversation, val snippet: String)

/// This device's status, the same four on every device (apps/shared/NetStatus.swift): Online (the
/// internet reaches it), Through <device> (connected to the one that is), Not reachable, Offline.
sealed interface NetState {
    data object Offline : NetState
    data object Online : NetState
    data class Through(val name: String, val own: Boolean) : NetState
    data class NotReachable(val away: String?) : NetState
}

/// Flat errors, each with the sentence the UI shows.
sealed class CoreError(val sentence: String) : Exception(sentence) {
    data object NotFound : CoreError("That doesn't exist here.")
    data object Expired : CoreError("That link has expired. Ask for a new one.")
    data object Used : CoreError("That link was already used. Ask for a new one.")
    data object BadLink : CoreError("That isn't a baud link.")
    data object NotAdmin : CoreError("Only an admin can do that.")
    data object NotMember : CoreError("You're not in that conversation.")
    class Refused(s: String) : CoreError(s)
    class Failed(s: String) : CoreError(s)
    class Offline(s: String) : CoreError(s)
    class Unreachable(s: String) : CoreError(s)
    class Store(s: String) : CoreError(s)
}

/// Ids only, on the core's thread; the app re-reads what changed.
sealed interface Change {
    data object Me : Change
    data object Contacts : Change
    data object Conversations : Change
    data object Peers : Change
    data object Carrying : Change
    data object IncomingCall : Change
    data class Conversation(val id: ConversationId) : Change
    data class Delivery(val id: ConversationId) : Change
    data class Typing(val id: ConversationId) : Change
    /// A device asks to become mine: show its six digits, then `confirmLink(req, accept)`.
    data class LinkRequest(val req: ULong, val code: String, val device: String, val name: String, val kind: DeviceKind) : Change
    /// A link being redeemed here reached its meeting device.
    data class Reached(val device: DeviceId) : Change
    /// Another of my devices removed this one.
    data object Removed : Change
    /// Re-read `netState()`.
    data object Network : Change
    /// Someone's place in this chat changed, or my share in it did.
    data class Places(val id: ConversationId) : Change
    /// A reply I made was opened by its link's maker: we met.
    data class Replied(val user: UserId) : Change
    /// A reply I made stopped waiting unopened.
    data class ReplyLapsed(val user: UserId) : Change
    /// These disappearing messages went from this phone: their notification goes too.
    data class Expired(val conv: ConversationId, val events: List<EventId>) : Change
}

/// Where someone in a chat is while they share it (BaudCore/Places.swift).
data class Place(val user: UserId, val device: DeviceId, val lat: Double, val lon: Double, val accuracy: Double, val at: Instant, val until: Instant?)

/// A chat I share my location in; `until` null: until I stop.
data class Share(val conv: ConversationId, val until: Instant?)

fun interface Subscription { fun cancel() }

interface CoreSurface {
    // me and my devices
    fun me(): Person
    fun setName(name: String)
    /// A photo file on this device becomes my face, on my card.
    fun setAvatar(path: String)
    fun linkDevice(): Link
    suspend fun link(link: Link)
    /// The six digits this device shows while it waits to be let in by my other one.
    fun joiningCode(link: Link): String? = null
    fun confirmLink(req: ULong, accept: Boolean) {}
    fun revoke(device: DeviceId)
    /// Small settings that follow me to my other devices (the colour).
    fun profile(key: String): String? = null
    fun setProfile(key: String, value: String) {}
    // contacts
    fun invite(): Link
    suspend fun add(link: Link): Contact
    /// A friend link that isn't getting through from here: my answer, for them to open or scan.
    fun reply(link: Link): Link = throw CoreError.Failed("Replies need baud-core.")
    fun contacts(): List<Contact>
    fun verify(user: UserId, fingerprint: String): Boolean
    fun unfriend(user: UserId)
    /// Text from anywhere (a scan, a paste, an opened URL: dotted `peer1.f.…`, dotless, `baud://`,
    /// `https://baud.rubric.sh/add#…`) as a link, or null. The core owns the format.
    fun parse(text: String): Link?
    // conversations
    fun conversations(kind: ConvKind? = null): List<Conversation>
    fun conversation(id: ConversationId): Conversation?
    /// My chat with myself, synced across my devices.
    fun notes(): Conversation? = null
    fun events(conv: ConversationId, before: EventId? = null, limit: Int = 200): List<Event>
    fun send(conv: ConversationId, draft: Draft): Event
    fun react(conv: ConversationId, target: EventId, key: String, on: Boolean)
    fun edit(conv: ConversationId, target: EventId, text: String)
    fun redact(conv: ConversationId, target: EventId)
    fun markRead(conv: ConversationId, event: EventId)
    /// Messages written from now on disappear this many seconds after they're read; 0 turns it off.
    /// Anyone in a chat, only an admin in a channel.
    fun setDisappear(conv: ConversationId, seconds: Int)
    fun typing(conv: ConversationId)
    fun typingNow(conv: ConversationId): List<UserId>
    fun members(conv: ConversationId): List<Member>
    /// A friend into a group: anyone in it can, in a chat; only an admin in a channel.
    fun addMember(conv: ConversationId, user: UserId)
    /// Someone out of a group: only an admin can.
    fun removeMember(conv: ConversationId, user: UserId)
    /// Me out of a group: it leaves my list, and someone still in it can add me back.
    fun leave(conv: ConversationId)
    /// A group's name: anyone in it can, in a chat; only an admin in a channel.
    fun rename(conv: ConversationId, name: String)
    fun delivery(conv: ConversationId, event: EventId): Delivery
    fun createChat(users: List<UserId>): Conversation
    fun createGroup(name: String, users: List<UserId>): Conversation
    fun delete(conv: ConversationId)
    fun search(query: String): List<Hit>
    /// The file for a blob on this device, fetched from whoever has it; throws while nobody does.
    suspend fun blob(hash: BlobHash, key: String): String
    // the network, honestly
    fun peers(): List<Peer>
    fun carrying(): Carrying
    fun netState(): NetState
    fun setOnline(online: Boolean)
    /// The phone's network changed (Wi-Fi to cellular, back): dial again now.
    fun networkChanged() {}
    fun subscribe(listener: (Change) -> Unit): Subscription
    // places: where I am, for a chat I choose, while I share it
    fun sharePlace(conv: ConversationId, until: Instant?) {}
    fun stopSharing(conv: ConversationId) {}
    fun sharing(): List<Share> = emptyList()
    fun wantsPlace(): Boolean = false
    fun moved(lat: Double, lon: Double, accuracy: Double) {}
    fun places(conv: ConversationId): List<Place> = emptyList()
    /// Start over: the store and keys gone, the network let go.
    suspend fun reset() {}
}
