// The one object the screens read (apps/shared/AppModel.swift). Wraps the core, re-reads on every
// change it reports, keeps the few bits of UI state that outlive a screen: drafts, the colour, the
// Add screen's state. No protocol logic: devices, delivery and paths come from the core.
package sh.rubric.baud

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import sh.rubric.baud.core.Change
import sh.rubric.baud.core.Contact
import sh.rubric.baud.core.ConvKind
import sh.rubric.baud.core.Conversation
import sh.rubric.baud.core.ConversationId
import sh.rubric.baud.core.CoreError
import sh.rubric.baud.core.CoreSurface
import sh.rubric.baud.core.Draft
import sh.rubric.baud.core.FakeCore
import sh.rubric.baud.core.Link
import sh.rubric.baud.core.NetState
import sh.rubric.baud.core.Path
import sh.rubric.baud.core.Peer
import sh.rubric.baud.core.Person
import sh.rubric.baud.core.UserId
import sh.rubric.baud.core.BlobHash
import sh.rubric.baud.ui.Images

class AppModel(val context: Context, val core: CoreSurface) {
    private val main = Handler(Looper.getMainLooper())
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val prefs = context.getSharedPreferences("app", Context.MODE_PRIVATE)

    var me by mutableStateOf(core.me()); private set
    var contacts by mutableStateOf(core.contacts()); private set
    var conversations by mutableStateOf(core.conversations()); private set
    var notes by mutableStateOf(core.notes()); private set
    var peers by mutableStateOf(core.peers()); private set
    var netState by mutableStateOf(core.netState()); private set
    private val timelines = HashMap<ConversationId, Timeline>()

    /// The chat whose timeline is showing, for the notifications: none for the one in front of you.
    var onScreen by mutableStateOf<ConversationId?>(null)
    /// baud is the app in front: only then does a chat on screen count as read. A chat left open in
    /// the background keeps what arrives unread, and notifies, until the person is back.
    var front by mutableStateOf(false)
        private set
    var error by mutableStateOf<String?>(null)

    // MARK: the Add screen, one state the sheets read
    enum class Offer { Friend, Device }
    /// What this device is showing: a link for a friend or for my other device.
    var offer by mutableStateOf<Offer?>(null)
    /// A link this device received: tapped, scanned, pasted (`link` null: still to be pasted).
    /// `reply`: a friend link that isn't getting through, and my answer to it for them to open or
    /// scan; `scanned`: read by this phone's camera, so they're here to scan mine back.
    data class Join(val link: Link?, val phase: Phase = Phase.Ready, val user: UserId? = null, val reply: Link? = null, val scanned: Boolean = false) {
        /// Ready: one button. Working: dialing. Reached: the other side has the request. Replying:
        /// nothing got through, and my reply waits for them to open it. Failed: why, in a sentence.
        sealed interface Phase {
            data object Ready : Phase
            data class Working(val since: Long) : Phase
            data class Reached(val since: Long) : Phase
            data object Replying : Phase
            data object Done : Phase
            data class Failed(val why: String) : Phase
        }
    }
    var join by mutableStateOf<Join?>(null)
    val adding: Boolean get() = offer != null || join != null
    /// A device asking to become mine: its name, its six digits.
    data class LinkAsk(val req: ULong, val code: String, val device: String, val name: String, val kind: sh.rubric.baud.core.DeviceKind) {
        val spaced: String get() = if (code.length == 6) code.take(3) + " " + code.takeLast(3) else code
    }
    var linkAsk by mutableStateOf<LinkAsk?>(null)
    /// The six digits this device shows while it waits to be let in.
    var joiningCode by mutableStateOf<String?>(null)
    /// A conversation to open (a notification tapped, a new friend's Message).
    var reveal by mutableStateOf<ConversationId?>(null)
    /// You asked for, from a notification or a link (the screen opens it).
    var removedHere by mutableStateOf(false)
    /// The first seconds after launch or a network change, while the dials are out: a "Not
    /// reachable" then reads "Connecting". It ends on its own.
    var connecting by mutableStateOf(true); private set
    private var settling = 0

    /// The chosen colour's hex, or null: monochrome until they choose. It follows me to my devices.
    var accentHex by mutableStateOf(prefs.getString("accent", null))
        private set
    fun pickAccent(hex: String?) {
        if (hex == accentHex) return
        accentHex = hex
        prefs.edit().putString("accent", hex).apply()
        runCatching { core.setProfile("accent", hex ?: "none") }
    }
    /// Another of my devices picked a colour: take it, without sending it back.
    private fun syncAccent() {
        val v = runCatching { core.profile("accent") }.getOrNull() ?: return
        val hex = if (v == "none") null else v
        if (hex != accentHex) { accentHex = hex; prefs.edit().putString("accent", hex).apply() }
    }

    var onboarded by mutableStateOf(prefs.getBoolean("onboarded", false))
        private set
    fun markOnboarded(v: Boolean) { onboarded = v; prefs.edit().putBoolean("onboarded", v).apply() }
    /// Observed, so the first-run screen moves on the moment the name lands.
    val named: Boolean get() = me.user.isNotEmpty() && me.name.isNotEmpty()

    /// Staying reachable with baud closed: the connection service. On after first run, unless turned off in You.
    var staying by mutableStateOf(prefs.getBoolean("staying", true))
        private set
    fun stay(on: Boolean) {
        staying = on
        prefs.edit().putBoolean("staying", on).apply()
        if (on) Reachable.start(context) else Reachable.stop(context)
        online(front || on)
    }

    // MARK: places

    /// The chats I share my location in, and until when (null: until I stop).
    var sharing by mutableStateOf(runCatching { core.sharing().associate { it.conv to it.until } }.getOrDefault(emptyMap())); private set
    /// Bumped when anyone's place changes: the cards re-read.
    var placesTick by mutableStateOf(0); private set
    val whereabouts = Whereabouts(context, this)
    fun share(conv: ConversationId, until: java.time.Instant?) { attempt { core.sharePlace(conv, until) }; refreshPlaces() }
    fun stopSharing(conv: ConversationId) { attempt { core.stopSharing(conv) }; refreshPlaces() }
    /// Disappearing messages in this conversation: seconds after they're read, 0 off.
    fun setDisappear(conv: ConversationId, seconds: Int) { attempt { core.setDisappear(conv, seconds) } }
    /// Shares that ran out drop here too; the location service follows.
    fun refreshPlaces() {
        sharing = runCatching { core.sharing().associate { it.conv to it.until } }.getOrDefault(emptyMap())
        placesTick++
        whereabouts.follow()
    }

    private val drafts = HashMap<String, String>()
    val images = mutableStateMapOf<BlobHash, ImageBitmap>()
    private val loading = HashSet<BlobHash>()

    init {
        core.subscribe { c -> main.post { changed(c) } }
        syncAccent()
        // After construction: the callbacks fire on their own thread at once, and may not touch
        // properties declared below this block before they are set.
        main.post { watchNetwork() }
        settle()
        Notifier.attach(context, this)
        // A share until I stop outlives a restart: the location service comes back for it.
        main.post { whereabouts.follow() }
        Log.i("baud", "model ready: named=$named convs=${conversations.size}")
    }

    // MARK: reading

    /// Every chat, with my chat with myself first when the core has one.
    val chats: List<Conversation>
        get() = (notes?.let { listOf(it) } ?: emptyList()) + conversations.filter { it.kind == ConvKind.Chat }
    /// Friends I have no chat with yet: listed under the chats, so anyone can be written to.
    val quiet: List<Contact>
        get() {
            val talked = conversations.filter { it.kind == ConvKind.Chat && it.isDirect }.flatMap { it.members }.toSet()
            return contacts.filter { it.user !in talked }.sortedBy { it.name.lowercase() }
        }
    val unread: Int get() = conversations.sumOf { it.unread }

    fun conversation(id: ConversationId?): Conversation? = id?.let { i -> conversations.firstOrNull { it.id == i } ?: notes?.takeIf { it.id == i } ?: core.conversation(i) }

    private val names = HashMap<UserId, String>()
    /// Contacts by petname; co-members by the name on their card, learned from a shared conversation.
    fun name(of: UserId): String {
        if (of == me.user) return "You"
        contacts.firstOrNull { it.user == of }?.let { return it.name }
        names[of]?.let { return it }
        for (c in conversations) core.members(c.id).firstOrNull { it.user == of }?.let { names[of] = it.name; return it.name }
        return "Someone"
    }

    /// What the row and the header call it: the other person's name for a DM, else its name.
    fun title(c: Conversation): String {
        if (c.kind == ConvKind.Home) return "You"
        if (c.isDirect) c.members.firstOrNull { it != me.user }?.let { o -> return contacts.firstOrNull { it.user == o }?.name ?: name(o) }
        return if (c.kind == ConvKind.Channel) "#${c.name ?: "channel"}" else c.name ?: "Chat"
    }

    /// The header's status, in at most two words: "Online", "Offline", "3 online".
    fun status(c: Conversation): String {
        if (c.kind == ConvKind.Home) return "Your devices"
        val others = core.members(c.id).filter { !it.me }
        if (others.isEmpty()) return "Just you"
        if (c.isDirect) {
            val o = others.first()
            // How I reach them, in two or three words: the way, and how quick it is when it's direct.
            val on = o.devices.filter { it.online }
            if (on.isNotEmpty()) {
                val paths = on.map { it.path }
                val direct = paths.filterIsInstance<Path.Direct>()
                if (direct.isNotEmpty()) return direct.mapNotNull { it.ms }.minOrNull()?.let { "Online · direct, $it ms" } ?: "Online · direct"
                if (Path.Nearby in paths) return "Online · nearby"
                paths.filterIsInstance<Path.Relay>().firstOrNull()?.let { return "Online · through ${it.name}" }
                return "Online"
            }
            o.devices.mapNotNull { it.lastOnline }.maxOrNull()?.let { last ->
                val ago = sh.rubric.baud.ui.agoShort(last)
                return if (ago == "now") "Online moments ago" else "Last online $ago ago"
            }
            return "Never online"
        }
        val online = others.count { it.online }
        return when (online) { 0 -> "Nobody online"; others.size -> "All online"; else -> "$online online" }
    }

    fun timeline(conv: ConversationId): Timeline = timelines.getOrPut(conv) { Timeline(conv, this) }

    /// A blob as an image, fetched once; null until it is here (the screen redraws when it lands).
    fun image(hash: BlobHash, maxPixels: Int = 1000): ImageBitmap? {
        val k = if (maxPixels == 1000) hash else "$hash@$maxPixels"
        images[k]?.let { return it }
        if (loading.add(k)) scope.launch {
            val bmp = runCatching { core.blob(hash, "") }.getOrNull()?.let { path -> withContext(Dispatchers.IO) { Images.load(path, maxPixels) } }
            if (bmp != null) images[k] = bmp.asImageBitmap()
            loading.remove(k)
        }
        return null
    }

    fun draft(key: String): String = drafts[key] ?: ""
    fun setDraft(key: String, text: String) { if (text.isEmpty()) drafts.remove(key) else drafts[key] = text }

    // MARK: writing

    fun attempt(f: () -> Unit) {
        try { f() } catch (e: CoreError) { error = e.sentence } catch (e: Exception) { error = e.message ?: "$e" }
    }

    fun setName(name: String) {
        attempt { core.setName(name) }
        me = core.me()
        if (named) firstRun()
    }

    /// After the name: the connection service, so friends reach this phone with baud closed.
    private fun firstRun() {
        prefs.edit().putBoolean("named", true).apply()
        if (staying) Reachable.start(context)
    }

    fun setPhoto(path: String) { attempt { core.setAvatar(path) }; refreshAll() }

    fun send(conv: ConversationId, draft: Draft) {
        if (draft.thread == null) setDraft(conv, "")
        if (draft.attachments.isEmpty()) { attempt { core.send(conv, draft) }; return }
        // Files are hashed and copied into the store first: off the main thread.
        scope.launch {
            try { withContext(Dispatchers.IO) { core.send(conv, draft) } } catch (e: CoreError) { error = e.sentence } catch (e: Exception) { error = e.message }
        }
    }

    /// The chat with a person, if one exists yet.
    fun chat(with: UserId): Conversation? = chats.firstOrNull { it.isDirect && with in it.members }
    /// Our chat, made the first time it's opened; null if it couldn't be.
    fun startChat(with: UserId): ConversationId? {
        var id: ConversationId? = null
        attempt { id = core.createChat(listOf(with)).id; refreshAll() }
        return id
    }
    /// The chat with a friend, made if there is none yet, opened.
    fun message(user: UserId) { reveal = chat(user)?.id ?: startChat(user) }

    fun unfriend(u: UserId) { attempt { core.unfriend(u) }; refreshAll() }
    fun delete(c: Conversation) { attempt { core.delete(c.id) }; conversations = core.conversations() }

    /// A tapped or scanned link: the Add sheet takes it from here.
    fun open(url: String) {
        val l = core.parse(url)
        if (l != null) join = Join(l) else error = "That link was cut short on its way. Ask for a new one."
    }

    /// Become that person's device: show the digits while the other side decides.
    suspend fun link(link: Link) {
        joiningCode = runCatching { core.joiningCode(link) }.getOrNull()
        try { core.link(link) } finally { joiningCode = null }
        refreshAll()
    }
    fun answerLink(ask: LinkAsk, accept: Boolean) { attempt { core.confirmLink(ask.req, accept) }; linkAsk = null; if (accept) refreshAll() }

    /// Start over on this device: keys, store, friends here, everything.
    suspend fun wipe() {
        Reachable.stop(context)
        runCatching { core.reset() }
        (core as? FakeCore)?.wipe()
        prefs.edit().clear().apply()
        context.getSharedPreferences("keychain", Context.MODE_PRIVATE).edit().clear().commit()
        accentHex = null; onboarded = false; staying = true; removedHere = false
        offer = null; join = null
        timelines.clear(); images.clear()
        refreshAll()
    }

    /// In front: online and reading. Leaving: online still while the connection service runs.
    fun scene(active: Boolean) {
        front = active
        // In front: online. Behind: online still while the connection service runs (that is its
        // point on Android, unlike the iPhone's background); offline only when it's turned off.
        online(active || (staying && named) || Reachable.running)
        if (active) { settle(); onScreen?.let { timelines[it]?.markRead() }; Notifier.clearShown(context, onScreen); refreshPlaces() }
    }

    /// Dials are out again (foreground, a new network): give them a moment before saying no.
    private fun settle() {
        connecting = true
        val mine = ++settling
        scope.launch { delay(6000); if (settling == mine) connecting = false }
    }

    /// Capabilities change often (signal strength): one call a second at most.
    private val tellCore by lazy { Runnable { runCatching { core.networkChanged() }; netState = core.netState() } }
    private fun changedSoon() { main.removeCallbacks(tellCore); main.postDelayed(tellCore, 1000) }

    /// Same-Wi-Fi discovery needs multicast, which Android filters unless an app holds this lock:
    /// held while the node is online, let go when it isn't.
    private val multicast by lazy { runCatching {
        context.applicationContext.getSystemService(android.net.wifi.WifiManager::class.java)?.createMulticastLock("baud")?.apply { setReferenceCounted(false) }
    }.getOrNull() }
    private fun online(on: Boolean) {
        runCatching { core.setOnline(on) }
        runCatching { if (on) multicast?.acquire() else multicast?.release() }
    }

    private fun watchNetwork() {
        val cm = context.getSystemService(ConnectivityManager::class.java) ?: return
        runCatching {
            cm.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) { main.post { runCatching { core.networkChanged() }; settle(); netState = core.netState() } }
                override fun onLost(network: Network) { main.post { runCatching { core.networkChanged() }; netState = core.netState() } }
                // A new address on the same network (DHCP, IPv6 privacy addresses, a VPN): the core
                // can't watch netlink from the app's sandbox, so it is told.
                override fun onLinkPropertiesChanged(network: Network, lp: android.net.LinkProperties) = changedSoon()
                override fun onCapabilitiesChanged(network: Network, caps: android.net.NetworkCapabilities) = changedSoon()
            })
        }
    }

    // MARK: changes

    private fun changed(c: Change) {
        when (c) {
            Change.Me -> { me = core.me() }
            Change.Contacts -> { contacts = core.contacts(); fetchFaces() }
            Change.Conversations -> { setConversations(); contacts = core.contacts() }
            Change.Peers -> { peers = core.peers(); contacts = core.contacts(); netState = core.netState(); setConversations(); timelines.values.forEach { it.refreshDelivery() } }
            Change.Carrying -> peers = core.peers()
            is Change.Conversation -> { timelines[c.id]?.reload(); setConversations(); if (c.id == notes?.id) syncAccent() }
            is Change.Delivery -> timelines[c.id]?.refreshDelivery()
            is Change.Typing -> timelines[c.id]?.refreshTyping()
            is Change.LinkRequest -> linkAsk = LinkAsk(c.req, c.code, c.device, c.name, c.kind)
            is Change.Reached -> join?.let { j -> (j.phase as? Join.Phase.Working)?.let { join = j.copy(phase = Join.Phase.Reached(it.since)) } }
            Change.Removed -> removedHere = true
            Change.Network -> netState = core.netState()
            is Change.Places -> refreshPlaces()
            is Change.Expired -> sh.rubric.baud.Notifier.expired(context, c.conv)
            // My reply met them: the add the Add screen shows is done.
            is Change.Replied -> join?.takeIf { it.reply != null && it.phase != Join.Phase.Done }?.let {
                join = it.copy(user = c.user, phase = Join.Phase.Done); markOnboarded(true); refreshAll()
            }
            is Change.ReplyLapsed -> join?.takeIf { it.reply != null && it.phase != Join.Phase.Done }?.let {
                val first = it.link?.name?.split(" ")?.first() ?: "They"
                join = it.copy(phase = Join.Phase.Failed("$first didn't open your answer in time. Ask $first for a fresh link."))
            }
            Change.IncomingCall -> {}
        }
    }

    private fun setConversations() {
        conversations = core.conversations()
        notes = core.notes()
        Notifier.changed(context, this, conversations)
    }

    /// Friends' photos are fetched while they're online, so a face looked at later is already here.
    private fun fetchFaces() { for (c in contacts) if (c.online) c.avatar?.let { image(it, 200) } }

    fun refreshAll() {
        syncAccent()
        me = core.me()
        contacts = core.contacts()
        setConversations()
        peers = core.peers()
        netState = core.netState()
        timelines.values.forEach { it.reload() }
        fetchFaces()
    }

    /// The demo people (the fake core only): on from first run's Demo, or `adb … --ez demo true`.
    fun startDemo() { (core as? FakeCore)?.startDemo(); markOnboarded(true); refreshAll() }
    val debug: Boolean = context.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0
    val demoAvailable: Boolean get() = core is FakeCore && !(core as FakeCore).demo
    fun peersOnline(): List<Peer> = peers.filter { it.device.online }
    val thisKind: String get() = "phone"
    fun person(): Person = me
    fun isOnline(s: NetState) = s is NetState.Online || s is NetState.Through
    /// The connection service started or stopped.
    fun serviceRunning(on: Boolean) = online(on || front)
}
