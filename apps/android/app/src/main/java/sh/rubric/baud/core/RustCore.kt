// The real core: baud-core over Rust (uniffi's `sh.rubric.baud.ffi.Baud`, core/API.md), as this
// app's CoreSurface. Only types are translated here (unix ms to Instant, unsigned to signed, the
// error classes to CoreError with the core's own sentence); every decision is the core's.
package sh.rubric.baud.core

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import java.time.Instant
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import sh.rubric.baud.ffi.Baud as Ffi
import sh.rubric.baud.ffi.BaudException as FfiError
import sh.rubric.baud.ffi.Change as FfiChange
import sh.rubric.baud.ffi.Config as FfiConfig
import sh.rubric.baud.ffi.DeliveryState as FfiDeliveryState
import sh.rubric.baud.ffi.DeviceKind as FfiDeviceKind
import sh.rubric.baud.ffi.Draft as FfiDraft
import sh.rubric.baud.ffi.EventType as FfiEventType
import sh.rubric.baud.ffi.FoundBy as FfiFoundBy
import sh.rubric.baud.ffi.Keychain as FfiKeychain
import sh.rubric.baud.ffi.Kind as FfiKind
import sh.rubric.baud.ffi.LinkKind as FfiLinkKind
import sh.rubric.baud.ffi.Listener as FfiListener
import sh.rubric.baud.ffi.NetState as FfiNetState
import sh.rubric.baud.ffi.Path as FfiPath
import sh.rubric.baud.ffi.Via as FfiVia

class RustCore private constructor(private val b: Ffi) : CoreSurface {
    companion object {
        /// Opens (or makes) this phone's device in the app's files: under a second, the network
        /// coming up behind it.
        suspend fun open(context: Context, deviceName: String): RustCore {
            val dir = context.filesDir.resolve("baud").apply { mkdirs() }.path
            return RustCore(call { Ffi.open(dir, AppKeys(context), FfiConfig(name = "", deviceName = deviceName, deviceKind = FfiDeviceKind.ANDROID)) })
        }
        fun version(): String = sh.rubric.baud.ffi.version()

        private inline fun <T> call(f: () -> T): T = try { f() } catch (e: FfiError) { throw e.toCore() }
    }

    private inline fun <T> call(f: () -> T): T = try { f() } catch (e: FfiError) { throw e.toCore() }

    // me and my devices
    override fun me() = call { b.me().toCore() }
    override fun setName(name: String) = call { b.setName(name) }
    override fun setAvatar(path: String) = call { b.setAvatar(path) }
    override fun linkDevice() = call { b.linkDevice().toCore() }
    override suspend fun link(link: Link) = call { b.link(link.url) }
    override fun joiningCode(link: Link) = call { b.joiningCode(link.url) }
    override fun confirmLink(req: ULong, accept: Boolean) = call { b.confirmLink(req, accept) }
    override fun revoke(device: DeviceId) = call { b.revoke(device) }
    override fun profile(key: String) = call { b.profile(key) }
    override fun setProfile(key: String, value: String) = call { b.setProfile(key, value) }
    // contacts
    override fun invite() = call { b.invite().toCore() }
    override suspend fun add(link: Link) = call { b.add(link.url).toCore() }
    override fun reply(link: Link) = call { b.reply(link.url).toCore() }
    override fun contacts() = call { b.contacts().map { it.toCore() } }
    override fun verify(user: UserId, fingerprint: String) = call { b.verify(user, fingerprint) }
    override fun unfriend(user: UserId) = call { b.unfriend(user) }
    override fun parse(text: String): Link? = runCatching { sh.rubric.baud.ffi.parseLink(text)?.toCore() }.getOrNull()
    // conversations
    override fun conversations(kind: ConvKind?) = call { b.conversations(kind?.toFfi()).map { it.toCore() } }
    override fun conversation(id: ConversationId) = call { b.conversation(id)?.toCore() }
    override fun notes() = call { b.notes()?.toCore() }
    override fun events(conv: ConversationId, before: EventId?, limit: Int) = call { b.events(conv, before, limit.toUInt()).map { it.toCore() } }
    override fun send(conv: ConversationId, draft: Draft) = call { b.send(conv, FfiDraft(draft.text, draft.attachments, draft.reply, draft.thread, draft.mentions)).toCore() }
    override fun react(conv: ConversationId, target: EventId, key: String, on: Boolean) = call { b.react(conv, target, key, on) }
    override fun edit(conv: ConversationId, target: EventId, text: String) = call { b.edit(conv, target, text) }
    override fun redact(conv: ConversationId, target: EventId) = call { b.redact(conv, target) }
    override fun markRead(conv: ConversationId, event: EventId) = call { b.markRead(conv, event) }
    override fun setDisappear(conv: ConversationId, seconds: Int) = call { b.setDisappear(conv, seconds.coerceAtLeast(0).toUInt()) }
    override fun typing(conv: ConversationId) = call { b.typing(conv) }
    override fun typingNow(conv: ConversationId) = call { b.typingNow(conv) }
    override fun members(conv: ConversationId) = call { b.members(conv).map { it.toCore() } }
    override fun delivery(conv: ConversationId, event: EventId) = call { b.delivery(conv, event).toCore() }
    override fun createChat(users: List<UserId>) = call { b.createChat(users).toCore() }
    override fun createGroup(name: String, users: List<UserId>) = call { b.createGroup(name, users).toCore() }
    override fun delete(conv: ConversationId) = call { b.delete(conv) }
    override fun search(query: String) = call { b.search(query, null).map { Hit(it.event.toCore(), it.conversation.toCore(), it.snippet) } }
    override suspend fun blob(hash: BlobHash, key: String) = call { b.blob(hash, key) }
    // the network
    override fun peers() = call { b.peers().map { it.toCore() } }
    override fun carrying() = call { b.carrying().let { c -> Carrying(c.envelopes.toInt(), c.bytes.toLong(), c.budgetBytes.toLong(), c.held.map { Held(it.device, it.name, it.count.toInt(), it.bytes.toLong()) }) } }
    override fun netState() = call {
        when (val n = b.netState()) {
            is FfiNetState.Offline -> NetState.Offline
            is FfiNetState.Online -> NetState.Online
            is FfiNetState.Through -> NetState.Through(n.name, n.own)
            is FfiNetState.NotReachable -> NetState.NotReachable(n.away)
        }
    }
    override fun setOnline(online: Boolean) = call { b.setOnline(online) }
    override fun networkChanged() = call { b.networkChanged() }
    override suspend fun reset() = call { b.reset() }
    /// The core's own account of itself (interfaces, addresses, dials), for the log.
    fun trace(): List<String> = runCatching { b.trace() }.getOrDefault(emptyList())

    // places
    override fun sharePlace(conv: ConversationId, until: Instant?) = call { b.sharePlace(conv, until?.toEpochMilli()) }
    override fun stopSharing(conv: ConversationId) = call { b.stopSharing(conv) }
    override fun sharing() = call { b.sharing().map { Share(it.conv, it.until?.let(::ms)) } }
    override fun wantsPlace() = call { b.wantsPlace() }
    override fun moved(lat: Double, lon: Double, accuracy: Double) = call { b.moved(lat, lon, accuracy) }
    override fun places(conv: ConversationId) = call { b.places(conv).map { Place(it.user, it.device, it.lat, it.lon, it.accuracy, ms(it.at), it.until?.let(::ms)) } }

    override fun subscribe(listener: (Change) -> Unit): Subscription {
        val s = b.subscribe(object : FfiListener {
            override fun onChange(change: FfiChange) { change.toCore()?.let(listener) }
        })
        return Subscription { s.cancel() }
    }
}

// MARK: types

private fun ms(t: Long): Instant = Instant.ofEpochMilli(t)

private fun FfiError.toCore(): CoreError = when (this) {
    is FfiError.NotFound -> CoreError.NotFound
    is FfiError.Expired -> CoreError.Expired
    is FfiError.Used -> CoreError.Used
    is FfiError.BadLink -> CoreError.BadLink
    is FfiError.NotAdmin -> CoreError.NotAdmin
    is FfiError.NotMember -> CoreError.NotMember
    is FfiError.Refused -> CoreError.Refused(message ?: "Refused.")
    is FfiError.Offline -> CoreError.Offline(message ?: "Offline.")
    is FfiError.Unreachable -> CoreError.Unreachable(message ?: "Couldn't reach them.")
    is FfiError.Store -> CoreError.Store(message ?: "The store failed.")
    else -> CoreError.Failed(message ?: "Something failed.")
}

private fun FfiChange.toCore(): Change? = when (this) {
    is FfiChange.Me -> Change.Me
    is FfiChange.Contacts -> Change.Contacts
    is FfiChange.Conversations -> Change.Conversations
    is FfiChange.Peers -> Change.Peers
    is FfiChange.Carrying -> Change.Carrying
    is FfiChange.Conversation -> Change.Conversation(id)
    is FfiChange.Delivery -> Change.Delivery(conv)
    is FfiChange.Typing -> Change.Typing(conv)
    is FfiChange.LinkRequest -> Change.LinkRequest(req, code, device, name, kind.toCore())
    is FfiChange.Reached -> Change.Reached(device)
    is FfiChange.Removed -> Change.Removed
    is FfiChange.Network -> Change.Network
    is FfiChange.Places -> Change.Places(conv)
    is FfiChange.Replied -> Change.Replied(user)
    is FfiChange.ReplyLapsed -> Change.ReplyLapsed(user)
    is FfiChange.Expired -> Change.Expired(conv, events)
    else -> null
}

private fun FfiDeviceKind.toCore() = when (this) {
    FfiDeviceKind.MAC -> DeviceKind.Mac
    FfiDeviceKind.IPHONE -> DeviceKind.Iphone
    FfiDeviceKind.ANDROID -> DeviceKind.Android
    else -> DeviceKind.Node
}

private fun FfiPath.toCore(): Path = when (this) {
    is FfiPath.Direct -> Path.Direct(ms?.toInt())
    is FfiPath.Relay -> Path.Relay(device, name)
    is FfiPath.Nearby -> Path.Nearby
    is FfiPath.Waiting -> Path.Waiting
    is FfiPath.Unreachable -> Path.Unreachable
    else -> Path.None
}

private fun sh.rubric.baud.ffi.Device.toCore() = Device(id, name, kind.toCore(), user, ms(addedAt), online, lastOnline?.let(::ms), path.toCore())
private fun sh.rubric.baud.ffi.Person.toCore() = Person(user, name, fingerprint, devices.map { it.toCore() }, thisDevice, avatar)
private fun sh.rubric.baud.ffi.Contact.toCore() = Contact(user, name, verified, fingerprint, devices.map { it.toCore() }, ms(metAt), avatar, vouched)
private fun sh.rubric.baud.ffi.Link.toCore() = Link(url, when (kind) { FfiLinkKind.DEVICE -> Link.Kind.Device; FfiLinkKind.REPLY -> Link.Kind.Reply; else -> Link.Kind.Friend }, name, ms(expires), web, code)

private fun ConvKind.toFfi() = when (this) { ConvKind.Chat -> FfiKind.CHAT; ConvKind.Channel -> FfiKind.CHANNEL; ConvKind.Space -> FfiKind.SPACE; ConvKind.Home -> FfiKind.HOME }
private fun FfiKind.toCore() = when (this) { FfiKind.CHAT -> ConvKind.Chat; FfiKind.CHANNEL -> ConvKind.Channel; FfiKind.SPACE -> ConvKind.Space; FfiKind.HOME -> ConvKind.Home }

private fun sh.rubric.baud.ffi.Conversation.toCore() = Conversation(
    id, kind.toCore(), name, topic, space, members, admins, ms(createdAt), ms(lastAt), lastText, lastUser, lastEvent,
    unread.toInt(), mentions.toInt(), eventCount.toInt(), isDefault, pinned, disappear.toInt(),
)

private fun FfiEventType.toCore() = when (this) {
    FfiEventType.MESSAGE -> EventType.Message
    FfiEventType.EDIT -> EventType.Edit
    FfiEventType.REACTION -> EventType.Reaction
    FfiEventType.REDACT -> EventType.Redact
    FfiEventType.RECEIPT -> EventType.Receipt
    FfiEventType.MEMBER -> EventType.Member
    FfiEventType.CARD -> EventType.Card
    FfiEventType.STATE -> EventType.State
    FfiEventType.CREATE -> EventType.Create
}

private fun FfiVia.toCore() = when (this) { FfiVia.DIRECT -> Via.Direct; FfiVia.RELAY -> Via.Relay; FfiVia.CARRIED -> Via.Carried; FfiVia.WAITING -> Via.Waiting }

private fun sh.rubric.baud.ffi.Event.toCore() = Event(
    id = id, conv = conv, device = device, seq = seq.toLong(), user = user, at = ms(at), lamport = lamport.toLong(), type = kind.toCore(),
    text = text, attachments = attachments.map { Attachment(it.hash, it.key, it.mime, it.size.toLong(), it.name, it.width?.toInt(), it.height?.toInt(), it.duration) },
    reply = reply, thread = thread, mentions = mentions, reactions = reactions.map { Reaction(it.key, it.users, it.mine) },
    edited = edited, replies = replies.toInt(), pinned = pinned, system = system, mine = mine, carriedBy = carriedBy, via = via?.toCore(),
)

private fun FfiDeliveryState.toCore(): DeliveryState = when (this) {
    is FfiDeliveryState.Sent -> DeliveryState.Sent
    is FfiDeliveryState.Carried -> DeliveryState.Carried(by)
    is FfiDeliveryState.Delivered -> DeliveryState.Delivered
    is FfiDeliveryState.Read -> DeliveryState.Read
}

private fun sh.rubric.baud.ffi.Delivery.toCore() = Delivery(event, devices.map { DeviceDelivery(it.device.toCore(), it.personName, it.state.toCore(), it.carriers) })
private fun sh.rubric.baud.ffi.Member.toCore() = Member(user, name, admin, ms(joinedAt), devices.map { it.toCore() }, verified, me)

private fun FfiFoundBy.toCore() = when (this) { FfiFoundBy.CACHE -> FoundBy.Cache; FfiFoundBy.PUSH -> FoundBy.Push; FfiFoundBy.EXCHANGE -> FoundBy.Exchange; FfiFoundBy.NEARBY -> FoundBy.Nearby; FfiFoundBy.INVITE -> FoundBy.Invite }
private fun sh.rubric.baud.ffi.Peer.toCore() = Peer(device.toCore(), userName, own, recordAge?.let { it / 1000.0 }, foundBy?.toCore(), relaying, holdingForMe.toInt(), iHoldForIt.toInt())

/// The core's keystore: small secrets by name, each sealed with an AES key that never leaves the
/// Android Keystore, kept in this app's own preferences. Readable after the phone's first unlock,
/// so the service can open the core at boot.
class AppKeys(context: Context) : FfiKeychain {
    private val prefs: SharedPreferences = context.getSharedPreferences("keychain", Context.MODE_PRIVATE)
    private val alias = "baud-keychain"

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(alias, null) as? SecretKey)?.let { return it }
        val g = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        g.init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).setKeySize(256).build())
        return g.generateKey()
    }

    override fun get(item: String): ByteArray? {
        val sealed = prefs.getString(item, null) ?: return null
        val raw = Base64.decode(sealed, Base64.NO_WRAP)
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, raw, 0, 12))
        return c.doFinal(raw, 12, raw.size - 12)
    }

    override fun put(item: String, bytes: ByteArray) {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, key())
        val out = c.iv + c.doFinal(bytes)
        // commit, not apply: a key the core was told is kept must be on disk before it goes on.
        prefs.edit().putString(item, Base64.encodeToString(out, Base64.NO_WRAP)).commit()
    }

    override fun delete(item: String) { prefs.edit().remove(item).commit() }
}
