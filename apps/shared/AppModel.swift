/// The one object the views read. Wraps the core, re-reads on every change it reports, keeps the
/// few bits of UI state that outlive a view: selection, drafts, the demo people. No protocol
/// logic: everything about devices, delivery and paths comes from the core as sentences.
import BaudCore
import CoreLocation
import Foundation
import Network
import Observation
import SwiftUI
#if os(iOS)
import PhotosUI
#endif

/// What the build carries. Spaces are behind `BAUD_SPACES` (off): chat first (Dexter, 0.2.0); the
/// code stays, nothing of it shows.
enum Features {
	#if BAUD_SPACES
	static let spaces = true
	#else
	static let spaces = false
	#endif
}

@MainActor
@Observable
final class AppModel {
	/// What the views talk to: the stub alone, or the crate-backed `Baud` over it.
	let core: any CoreSurface
	let local: LocalCore
	let keys: AppleKeychain
	let mesh = Mesh()
	private(set) var demo: Demo.People?
	private(set) var me: Person
	private(set) var contacts: [Contact] = [] { didSet { fetchFaces() } }
	private(set) var conversations: [Conversation] = [] { didSet { Notifier.shared.changed(conversations) } }
	/// The chat whose timeline is showing, for the notifications: none for the one in front of you.
	var onScreen: ConversationId?
	/// baud is the app in front: only then does a chat on screen count as read. A chat left open
	/// in the background (a locked iPhone, the Mac behind another app) keeps what arrives unread,
	/// and notifies, until the person is back.
	var front = false {
		didSet { if front, !oldValue, let c = onScreen { timelines[c]?.markRead() } }
	}
	private(set) var peers: [Peer] = []
	private(set) var carrying = Carrying()
	private(set) var timelines: [ConversationId: Timeline] = [:]
	/// Voice and video calls: the one under way, if any.
	let calls = CallCenter()
	var error: String?
	// MARK: linking, one state the sheets read
	/// What this device is showing: a link for a friend (once, an hour) or for my other device (once,
	/// ten minutes). The sheet (a window on the Mac) stays until the other side has arrived.
	enum Offer: String, Identifiable { case friend, device; var id: String { rawValue } }
	var offer: Offer?
	/// A link this device received: tapped, scanned, pasted (`link` nil: still to be pasted).
	struct Join: Identifiable, Equatable {
		let id = UUID(); var link: BaudCore.Link?
		/// Working: dialing the device the link names. Reached: it has the request (a device link now
		/// waits for the code to be confirmed there). Replying: nothing got through, and my reply
		/// waits for them to open it. Failed: why, in a sentence.
		enum Phase: Equatable { case ready, working(Date), reached(Date), replying, done, failed(String) }
		var phase: Phase = .ready
		var user: UserId?
		/// A friend link that isn't getting through: my answer, for them to open or scan.
		var reply: BaudCore.Link?
		/// Read by this device's camera: they're here, and can scan my reply back.
		var scanned = false
	}
	var join: Join?
	/// A device asking to become mine (the crate's link request): its name, its six digits.
	struct LinkAsk: Identifiable { let id: String; let code: String; let device: String; let name: String; let kind: String
		var what: String { kind == "mac" ? "Mac" : kind == "iphone" ? "iPhone" : kind == "ipad" ? "iPad" : "device" }
		var spaced: String { code.count == 6 ? String(code.prefix(3)) + " " + String(code.suffix(3)) : code } }
	var linkAsk: LinkAsk?
	/// A conversation the linking sheets ask the window to open (the new friend's chat).
	var reveal: ConversationId?
	/// The six digits this device shows while it waits to be let in.
	var joiningCode: String?
	/// The Add screen is up: showing my link, or reading one.
	var adding: Bool { offer != nil || join != nil }
	/// Where whoever opens my link meets me: here (this device is online), through one of mine or a
	/// friend's I am connected to, or nowhere, and then no link is shown: one that cannot be met is
	/// never handed out (Dexter: "if a device is not connected through anything, it shouldn't be
	/// able to show a QR code").
	/// Same Wi-Fi: nothing reaches this device from the internet, but it may use this network, so
	/// a device next to it on the same Wi-Fi can meet it at its local address (Dexter, 0.2.5:
	/// "Yes, labeled 'Same Wi-Fi'"). Without Local Network for baud here, not even that.
	enum Meeting: Equatable { case here, through(String), sameWiFi, none }
	/// The Add gate reads the same state as the status beside my face.
	var meeting: Meeting {
		switch netState {
		case .online: return .here
		case .through(let n, _): return .through(n)
		case .notReachable: return onLAN && !localNetworkOff ? .sameWiFi : .none
		case .offline: return .none
		}
	}
	/// What the router last said when this device asked it to open a port (the Mac's relay).
	var gateway: Crate.Node.Gate { _ = peers; return (core as? Baud)?.gateway() ?? .unknown }
	/// This device's status, the same words on every device: Online (anyone in my circle reaches
	/// this device), Through <device> (connected to the one of mine, or a friend's, that is),
	/// Not reachable (naming the meeting device I am not connected to, when there is one),
	/// Offline (no network). Recomputed whenever the network or a record changes.
	enum NetState: Equatable { case offline, online, through(String, own: Bool), notReachable(away: String?) }
	var netState: NetState { _ = peers; return (core as? Baud)?.netState(online: pathOnline) ?? (pathOnline ? .online : .offline) }
	/// The first seconds after launch, a wake or a network change, while the dials are out: a
	/// "Not reachable" then reads "Connecting". Not a spinner: it ends on its own. A stored flag the
	/// timer clears, so the status redraws when it ends: 0.2.5 compared the clock in a getter and
	/// nudged a redraw by writing the same date back, which Observation ignores, so a phone with
	/// nothing else changing said "Connecting" all morning.
	private(set) var connecting = true
	private var settling = 0
	/// Dials are out again (foreground, a new network): give them a moment before saying no.
	func settle() {
		connecting = true
		settling += 1
		let mine = settling
		Task { @MainActor in try? await Task.sleep(for: .seconds(6)); if settling == mine { connecting = false } }
	}
	/// The public address of the port this device's router holds for it, when it holds one.
	var mappedAddress: String? { _ = peers; return (core as? Baud)?.mapped() }
	/// baud may not use the local network (Settings → baud on the iPhone, Privacy & Security on the
	/// Mac): its dials to my devices' addresses on this network fail. Not a status but an issue
	/// beside it, on every network: at home it is the only way to my other devices when the router
	/// doesn't loop its public address back (Dexter: "if you haven't granted it, it needs to show as
	/// an issue and prompt you to fix it somewhere").
	var localNetworkOff = false
	/// The device this one is connected through (the meeting device), when it isn't this one.
	var carrier: Peer? { _ = peers; return (core as? Baud)?.meetingDevice().flatMap { id in peers.first { $0.device.id == id } } }
	/// Another of my devices removed this one; the root says so and starts over.
	var removedHere = false
	/// Whether this device has a network at all (the system's path).
	var pathOnline = true
	/// On Wi-Fi or Ethernet: a link can be met on the same network even when nothing else carries.
	var onLAN = true
	private let pathWatch = NWPathMonitor()
	/// Reachable from outside (the crate's reachability for this device, the address record for
	/// the others): a stable device, a home for messages when phones can't meet.
	func stable(_ device: DeviceId) -> Bool { _ = peers; return (core as? Baud)?.stable(device) ?? false }
	/// The devices that would carry for an away one (the crate's helpers), named.
	func carriers(of device: DeviceId) -> [Peer] { _ = peers; return ((core as? Baud)?.helpers(device) ?? []).compactMap { id in peers.first { $0.device.id == id } } }
	/// The stable-device picture has been seen once (onboarding); after that it lives in You.
	/// The chosen colour's hex, or nil: monochrome until they choose.
	var accentHex: String? = UserDefaults.standard.string(forKey: "accent") {
		didSet {
			UserDefaults.standard.set(accentHex, forKey: "accent")
			// The colour follows me to my other devices (not for a staged picture, not an echo).
			if !syncingAccent, ProcessInfo.processInfo.environment["BAUD_ACCENT"] == nil, oldValue != accentHex { local.setProfile("accent", accentHex ?? "none") }
			#if os(iOS)
			// Only for a colour picked here: one that came from another device of mine recolours the
			// app and leaves the icon. Never for a staged picture. iOS says so each time the icon
			// changes, so it changes once, for the colour kept, when You closes (iconPending).
			if !syncingAccent, ProcessInfo.processInfo.environment["BAUD_ACCENT"] == nil { iconPending = true }
			#else
			IconColour.apply(accentHex)
			#endif
		}
	}
	@ObservationIgnored private var syncingAccent = false
	/// A colour being dragged out in the picker: the app wears it while the finger moves; it's kept
	/// (and goes to my other devices, and to the icon) only when the drag ends.
	var previewHex: String?
	/// The colour to draw: the one being picked, else the one kept.
	var shownHex: String? { previewHex ?? accentHex }
	/// A colour picked on the iPhone whose icon hasn't been set yet.
	@ObservationIgnored var iconPending = false
	/// The iPhone: the Add screen asked for from inside You, opened once You has closed (two
	/// sheets can't stack, and one opened while the other is still closing is dropped at once).
	var afterYou: Offer?
	/// The icon in the colour kept, once the picking is over.
	func settleIcon() {
		// iOS says so in an alert, which would knock an Add sheet away: after it, then.
		guard iconPending, !adding, afterYou == nil else { return }
		iconPending = false
		IconColour.apply(accentHex)
	}
	/// Another of my devices picked a colour: take it, without sending it back. With none in my
	/// notes (0.2.5's wipe took the line, each device kept its own copy here), this device's goes
	/// in, so my devices settle on one rather than each keeping its own (Dexter: "the apps aren't
	/// synced including the color"); a line already there from another device outranks it.
	func syncAccent() {
		guard ProcessInfo.processInfo.environment["BAUD_ACCENT"] == nil else { return }
		guard let v = local.profile("accent") else {
			if let hex = accentHex, local.notes() != nil { local.setProfile("accent", hex) }
			return
		}
		let hex = v == "none" ? nil : v
		guard hex != accentHex else { return }
		Measure.log("accent: \(hex ?? "none") from my other devices, over \(accentHex ?? "none")")
		syncingAccent = true; accentHex = hex; syncingAccent = false
	}
	var accent: Color { Accent.color(accentHex) ?? .primary }
	var chosen: Color? { Accent.color(accentHex) }
	var chosenColour: Bool { accentHex != nil }
	private var images: [BlobHash: Image] = [:]
	private var loading: Set<BlobHash> = []
	/// The two modes with a wall between them: Home (chats, friends, devices) and Spaces (a list of
	/// spaces; hop into one and you are inside it). The sidebar never mixes them.
	enum Mode: String { case home, spaces }
	/// Switching mode brings back what was open on that side of the wall.
	var mode: Mode = Features.spaces ? Mode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .home : .home {
		didSet {
			UserDefaults.standard.set(mode.rawValue, forKey: "mode")
			guard !routing, mode != oldValue else { return }
			route { selectedConversation = mode == .home ? lastChat.flatMap { id in chats.contains { $0.id == id } ? id : nil } : selectedSpace.flatMap(channelToOpen(in:)) }
		}
	}
	/// The space I am inside, in Spaces; nil is the list of spaces. Hopping in opens its last channel.
	var selectedSpace: ConversationId? {
		didSet {
			UserDefaults.standard.set(selectedSpace, forKey: "space")
			guard !routing, selectedSpace != oldValue else { return }
			route { mode = .spaces; selectedConversation = selectedSpace.flatMap(channelToOpen(in:)) }
		}
	}
	/// What the main pane shows. Opening anything puts the app on its side of the wall: a chat is
	/// Home, a channel is Spaces inside its space, a space is that space.
	var selectedConversation: ConversationId? {
		didSet {
			UserDefaults.standard.set(selectedConversation, forKey: "conversation")
			guard let id = selectedConversation, let c = conversation(id) else { return }
			switch c.kind {
			case .chat, .home: lastChat = id
			case .channel: if let s = c.space { lastChannel[s] = id }
			default: break
			}
			guard !routing else { return }
			route {
				switch c.kind {
				case .chat: mode = .home
				case .channel: guard Features.spaces else { return }; mode = .spaces; selectedSpace = c.space
				case .space: mode = .spaces; selectedSpace = id; selectedConversation = channelToOpen(in: id)
				case .home: break
				}
			}
		}
	}
	private var routing = false
	private func route(_ f: () -> Void) { routing = true; f(); routing = false }
	private var lastChat: ConversationId? = UserDefaults.standard.string(forKey: "lastChat") { didSet { UserDefaults.standard.set(lastChat, forKey: "lastChat") } }
	private var lastChannel: [ConversationId: ConversationId] = UserDefaults.standard.dictionary(forKey: "lastChannel") as? [String: String] ?? [:] { didSet { UserDefaults.standard.set(lastChannel, forKey: "lastChannel") } }
	/// The channel a space opens on: the last one I had open there, else its default, else its first.
	func channelToOpen(in space: ConversationId) -> ConversationId? {
		let mine = channels(in: space)
		if let l = lastChannel[space], mine.contains(where: { $0.id == l }) { return l }
		return (mine.first { $0.isDefault } ?? mine.first)?.id
	}
	/// No longer friends: the crate tells them, our chat leaves the list.
	func unfriend(_ u: UserId) {
		attempt { if let b = core as? Baud { try b.unfriend(u) } else { local.unfriend(u) } }
		if let s = selectedConversation, conversation(s)?.isDirect == true, conversation(s)?.members.contains(u) == true { selectedConversation = nil }
		refreshAll()
	}
	/// The chat a delete is being confirmed for.
	var deleting: Conversation?
	/// Delete a chat here (a group is left first); my chat with myself is only cleared.
	func delete(_ c: Conversation) {
		attempt { try local.delete(c.id) }
		if selectedConversation == c.id && c.kind != .home { selectedConversation = nil }
		conversations = core.conversations(nil)
	}
	/// The chat with a friend, made if there is none yet, opened (in Home).
	func message(_ user: UserId) {
		attempt { if let c = chat(with: user) { open(c.id) } else { open(try core.createChat([user]).id) } }
		#if os(iOS)
		reveal = selectedConversation
		#endif
	}
	/// A chat read to its newest message (the list's menu, a swipe, ⇧⌘U).
	func markRead(_ c: Conversation) { try? core.markRead(c.id, c.lastEvent ?? "") }
	/// A call to a friend, in our chat (made if there is none yet).
	func call(_ user: UserId, video: Bool) {
		guard let id = chat(with: user)?.id ?? startChat(with: user) else { return }
		calls.start(id, video: video)
	}
	/// Open anything: a chat, a channel, a space. A chat marked unread is read once it's opened.
	func open(_ id: ConversationId?) {
		selectedConversation = id
		if let id { pane = nil; opened(id) }
	}
	/// A chat on screen: the mark I put on it (unread) goes, here and on my other devices.
	func opened(_ id: ConversationId) { if markedUnread.contains(id) { setUnread(id, false) } }
	/// The Mac's main pane, when it isn't a conversation: Settings (me at the sidebar's foot, ⌘,)
	/// or Friends (the sidebar's people button, ⇧⌘1, ⌘K). A chat clicked, or ⎋, goes back.
	enum Pane { case settings, friends }
	var pane: Pane?
	func showFriends() { mode = .home; selectedConversation = nil; pane = .friends }
	func showSettings(_ section: String? = nil) { selectedConversation = nil; pane = .settings; if let section { settingsSection = section } }

	// MARK: a chat's marks: unread, muted

	/// Chats I marked unread (a dot and a bold name until opened), kept in my profile so the mark
	/// follows me to my other devices.
	private(set) var markedUnread: Set<ConversationId> = []
	/// Chats muted, until when (`.distantFuture`: always): no notifications for their messages.
	private(set) var mutes: [ConversationId: Date] = [:]
	/// Pinned chats, when each was pinned (their order at the top); five at most.
	private(set) var pins: [ConversationId: Date] = [:]
	static let maxPins = 5
	/// Archived chats, when each was archived.
	private(set) var archives: [ConversationId: Date] = [:]
	func isPinned(_ id: ConversationId) -> Bool { pins[id] != nil }
	func pin(_ id: ConversationId, _ on: Bool) {
		guard !on || pins.count < Self.maxPins else { return }
		let at = Date()
		if on { pins[id] = at } else { pins[id] = nil }
		local.setProfile("pin." + id, on ? String(at.timeIntervalSince1970) : "0")
	}
	/// Archived: out of the list, kept, until a new message from someone else (a muted chat stays).
	func isArchived(_ c: Conversation) -> Bool {
		guard let at = archives[c.id] else { return false }
		return c.lastAt <= at || c.lastUser == me.user || muted(c.id) != nil
	}
	func archive(_ c: Conversation, _ on: Bool) {
		let at = Date()
		if on { archives[c.id] = at } else { archives[c.id] = nil }
		local.setProfile("archive." + c.id, on ? String(at.timeIntervalSince1970) : "0")
		if on, selectedConversation == c.id { selectedConversation = nil }
	}
	func isUnread(_ c: Conversation) -> Bool { c.unread > 0 || markedUnread.contains(c.id) }
	func muted(_ id: ConversationId) -> Date? { mutes[id].flatMap { $0 > Date() ? $0 : nil } }
	/// Read or unread, the chat menu's and ⇧⌘U's one toggle.
	func toggleUnread(_ c: Conversation) {
		if isUnread(c) { markRead(c); setUnread(c.id, false) } else { setUnread(c.id, true) }
	}
	func setUnread(_ id: ConversationId, _ on: Bool) {
		if on { markedUnread.insert(id) } else { markedUnread.remove(id) }
		local.setProfile("unread." + id, on ? "1" : "0")
	}
	/// Muted for a while, always (nil), or unmuted (`until` in the past).
	func mute(_ id: ConversationId, for seconds: TimeInterval?) {
		let until = seconds.map { Date().addingTimeInterval($0) } ?? .distantFuture
		mutes[id] = until
		local.setProfile("mute." + id, seconds == nil ? "always" : String(Int(until.timeIntervalSince1970)))
	}
	func unmute(_ id: ConversationId) { mutes[id] = nil; local.setProfile("mute." + id, "0") }
	/// The marks as my profile has them now (another device of mine may have changed them).
	private func readMarks() {
		var unread = Set<ConversationId>(), muted: [ConversationId: Date] = [:], pinned: [ConversationId: Date] = [:], archived: [ConversationId: Date] = [:]
		for c in conversations where c.kind == .chat || c.kind == .home {
			if local.profile("unread." + c.id) == "1" { unread.insert(c.id) }
			if let p = local.profile("pin." + c.id).flatMap(Double.init), p > 0 { pinned[c.id] = Date(timeIntervalSince1970: p) }
			if let a = local.profile("archive." + c.id).flatMap(Double.init), a > 0 { archived[c.id] = Date(timeIntervalSince1970: a) }
			if let m = local.profile("mute." + c.id) {
				if m == "always" { muted[c.id] = .distantFuture } else if let t = Double(m), t > Date().timeIntervalSince1970 { muted[c.id] = Date(timeIntervalSince1970: t) }
			}
		}
		if unread != markedUnread { markedUnread = unread }
		if muted != mutes { mutes = muted }
		if pinned != pins { pins = pinned }
		if archived != archives { archives = archived }
	}
	/// My reaction on a message, given or taken back, and the reaction remembered as a recent one.
	func toggleReaction(_ e: Event, _ key: String) {
		let on = !(e.reactions.first { $0.key == key }?.mine ?? false)
		if on { EmojiPicker.used(key) }
		attempt { try core.react(e.conv, e.id, key, on: on) }
	}
	/// A message's actions asked for from outside its row (the iPhone's hold menu): the row opens
	/// its own editor, info or delete question.
	enum MessageAsk: Equatable { case edit, info, delete, forward, react }
	var messageAsk: (event: EventId, ask: MessageAsk)?
	/// Where this device keeps baud: the store, its files, what it carries for others.
	@ObservationIgnored private(set) var storeDir: URL?
	/// How much that is, counted off the main thread.
	func storeSize() async -> Int64? {
		guard let dir = storeDir else { return nil }
		return await Task.detached(priority: .utility) {
			guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) else { return nil }
			var total: Int64 = 0
			while let u = e.nextObject() as? URL {
				let v = try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
				total += Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
			}
			return total
		}.value
	}
	/// Everyone sharing where they are with me, from any chat: the newest place of each.
	var livePlaces: [Place] {
		_ = placesTick
		let all = conversations.flatMap { local.places($0.id) }.filter { $0.user != me.user }
		return Dictionary(grouping: all, by: \.user).compactMap { $0.value.max { $0.date < $1.date } }.sorted { $0.date > $1.date }
	}
	/// Out of the space, back to the list of spaces.
	func leaveSpace() { route { mode = .spaces; selectedSpace = nil; selectedConversation = nil } }
	/// Home, or Spaces where I left it.
	func show(_ m: Mode) { mode = m }
	var openThread: EventId?
	/// Files dropped anywhere on a conversation, waiting for its composer to take them, and the
	/// conversation a drag is over now (it says "Drop to send").
	var dropped: [ConversationId: [URL]] = [:]
	var dropOver: ConversationId?
	private var drafts: [ConversationId: String] = UserDefaults.standard.dictionary(forKey: "drafts") as? [String: String] ?? [:]
	private var sub: Subscription?
	static let launched = Date()
	/// The chats I share my location in, until when; a tick for the maps when anyone's place moves.
	var sharingPlaces: [ConversationId: Date] = [:]
	var placesTick = 0
	func placesChanged() { sharingPlaces = local.sharing(); placesTick &+= 1; Whereabouts.shared.follow() }
	/// The one the app runs on, for what arrives before any view does (a push that launched us).
	nonisolated(unsafe) static weak var current: AppModel?

	init() {
		// A dev build (bundle id ending in .dev) keeps its own store and keychain service, so local
		// runs never touch the shipped app's data or fight it for the bundle id.
		// The design beta (`.beta`) is a dev build too, and more: its keys are only ever in its own
		// folder, and with no `BAUD_DIR` that folder is its own, never the shipped app's or a dev build's.
		let beta = Bundle.main.bundleIdentifier?.hasSuffix(".beta") == true
		let dev = beta || Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true
		if dev { AppleKeychain.service = beta ? "sh.rubric.baud.beta" : "sh.rubric.baud.dev" }
		let dir = ProcessInfo.processInfo.environment["BAUD_DIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(beta ? "baud-beta" : dev ? "baud-dev" : "baud")
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		// Lab copies (a Debug build given its own `BAUD_DIR`) keep their keys in that folder: in the
		// one dev keychain service, each copy's launch overwrote the others' and a relaunch was locked out.
		#if DEBUG
		let lab = dev && ProcessInfo.processInfo.environment["BAUD_DIR"] != nil
		#else
		let lab = false
		#endif
		// Never the keychain for a beta copy, whatever it was built as.
		keys = AppleKeychain(fallbackDir: dir, fileOnly: lab || beta)
		storeDir = dir
		// Before the first unlock after a restart (a background wake, a call coming in), neither the
		// keychain nor the store can be read. Opening anyway made a nameless stand-in, and baud asked
		// for a name; it waits instead, on an empty store in memory that touches neither, and the app
		// makes a new model once the iPhone is unlocked. (Only when a read actually fails: whether
		// protected data is available reads false while the app is still starting.)
		var wait = false
		#if DEBUG
		// `BAUD_LOCKED=1`: as if not unlocked since a restart, for a picture of the wait.
		if ProcessInfo.processInfo.environment["BAUD_LOCKED"] == "1" { wait = true }
		#endif
		let opened: LocalCore
		if wait { opened = try! LocalCore(dir: nil, keys: MemoryKeys(), deviceName: AppModel.deviceName, kind: AppModel.deviceKind) }
		else { do { opened = try LocalCore(dir: dir, keys: keys, deviceName: AppModel.deviceName, kind: AppModel.deviceKind) }
		catch is KeysLocked {
			wait = true
			opened = try! LocalCore(dir: nil, keys: MemoryKeys(), deviceName: AppModel.deviceName, kind: AppModel.deviceKind)
		}
		catch where AppModel.locked {
			wait = true
			opened = try! LocalCore(dir: nil, keys: MemoryKeys(), deviceName: AppModel.deviceName, kind: AppModel.deviceKind)
		}
		catch {
			// A store that won't open at its home opens in memory, and the screen says so.
			opened = try! LocalCore(dir: nil, keys: keys, deviceName: AppModel.deviceName, kind: AppModel.deviceKind)
			openFailure = "Couldn't open baud's store at \(dir.path): \(error). Running in memory for now; nothing you do here will be kept."
		} }
		waiting = wait
		local = opened
		mesh.join(local)
		// The demo people live on the in-process mesh alone: the crate adopting its identity while
		// they are seeded left them half made ("demo failed: notAdmin").
		let demoOn = ProcessInfo.processInfo.environment["BAUD_DEMO"].map { $0 != "0" } ?? UserDefaults.standard.bool(forKey: "demo")
		core = Crate.wanted && !demoOn && !wait ? Baud(local: local, dir: dir, keys: keys) : local
		me = core.me()
		(core as? Baud)?.onLinkRequest = { [weak self] id, code, device, name, kind in Task { @MainActor in self?.linkAsk = LinkAsk(id: id, code: code, device: device, name: name, kind: kind) } }
		// `BAUD_ACCENT=0090FF|none` sets the colour for a smoke or a picture.
		if let a = ProcessInfo.processInfo.environment["BAUD_ACCENT"] { accentHex = a == "none" ? nil : a }
		selectedSpace = UserDefaults.standard.string(forKey: "space")
		selectedConversation = UserDefaults.standard.string(forKey: "conversation")
		sub = core.subscribe { [weak self] c in Task { @MainActor in self?.changed(c) } }
		refreshAll()
		if !named, !wait, let n = ProcessInfo.processInfo.environment["BAUD_NAME"] { try? core.setName(n); me = core.me(); onboarded = true; Measure.log("staged name \(n), named=\(named), keys in \(keys.usingFile ? "file" : "keychain")") }
		if named, demoWanted { startDemo() }
		// `BAUD_OPEN_LINK=baud://…` is a launch from a scanned or tapped link, for the smoke on the simulator.
		if let u = ProcessInfo.processInfo.environment["BAUD_OPEN_LINK"] { join = Join(link: Code.parse(u)) }
		#if DEBUG
		// `BAUD_OPEN_LATER=<file>` (the lab): a link opened here once it appears in that file.
		if let f = ProcessInfo.processInfo.environment["BAUD_OPEN_LATER"] {
			Task { @MainActor [weak self] in
				for _ in 0..<180 {
					if let u = try? String(contentsOfFile: f, encoding: .utf8), let l = Code.parse(u) { Measure.log("opening \(l.kind) link from \(l.name)"); self?.offer = nil; self?.join = Join(link: l); return }
					try? await Task.sleep(for: .milliseconds(500))
				}
			}
		}
		#endif
		Journey.run(self)
		carryHooks()
		// `BAUD_DOOR=friend|device|paste` on an already-named launch opens that door after two seconds.
		if named, let d = ProcessInfo.processInfo.environment["BAUD_DOOR"] { Task { @MainActor in try? await Task.sleep(for: .seconds(2)); if offer == nil, join == nil { door(d) } } }
		settleSelection()
		pathWatch.pathUpdateHandler = { [weak self] p in Task { @MainActor in
			guard let self else { return }
			let was = (self.pathOnline, self.onLAN)
			self.pathOnline = p.status == .satisfied
			self.onLAN = p.status == .satisfied && (p.usesInterfaceType(.wifi) || p.usesInterfaceType(.wiredEthernet))
			if was != (self.pathOnline, self.onLAN) { self.settle() }
			(self.core as? Baud)?.networkChanged()
		} }
		(core as? Baud)?.onRemoved = { [weak self] in Task { @MainActor in self?.removedHere = true } }
		calls.attach(self, core as? Baud)
		AppModel.current = self
		Whereabouts.shared.attach(self)
		sharingPlaces = local.sharing()
		// A share's time running out, and a friend's pin ageing, show without anything else happening.
		Task { @MainActor [weak self] in
			while let self {
				try? await Task.sleep(for: .seconds(30))
				if !self.sharingPlaces.isEmpty || self.placesTick > 0 { self.placesChanged() }
			}
		}
		(core as? Baud)?.onReached = { [weak self] _ in Task { @MainActor in if case .working(let t)? = self?.join?.phase { self?.join?.phase = .reached(t) } } }
		// My reply met them: the add the Add screen shows is done.
		(core as? Baud)?.onReplied = { [weak self] user in Task { @MainActor in
			guard let self, self.join?.reply != nil, self.join?.phase != .done else { return }
			Measure.log("join: my answer met \(user.prefix(8))")
			self.join?.user = user; self.join?.phase = .done; self.onboarded = true; self.refreshAll()
		} }
		(core as? Baud)?.onReplyLapsed = { [weak self] _ in Task { @MainActor in
			guard let self, let j = self.join, j.reply != nil, j.phase != .done, let name = j.link?.name else { return }
			self.join?.phase = .failed("\(name) didn't open your answer in time. Ask \(name) for a fresh link.")
		} }
		#if DEBUG
		// `BAUD_PICK=<hex|none>`: the colour picked by hand three seconds in (synced, icon and all).
		if let p = ProcessInfo.processInfo.environment["BAUD_PICK"] { Task { @MainActor in try? await Task.sleep(for: .seconds(3)); self.accentHex = p == "none" ? nil : p } }
		#endif
		#if os(macOS)
		// The Dock icon in the colour from launch (iOS keeps its alternate between launches).
		let hex = accentHex
		Task { @MainActor in IconColour.apply(hex) }
		#endif
		// Ask for the local network now, on its own, before any link is redeemed: the dial that
		// would otherwise raise the prompt is lost, and a refusal fails without a word.
		LocalNetwork.shared.onChange = { [weak self] granted in
			guard let self else { return }
			let was = self.localNetworkOff
			self.localNetworkOff = !granted
			// Turned on in Settings: dial my devices' local addresses now, not at the next loop.
			if was, granted { (self.core as? Baud)?.networkChanged(); self.settle() }
		}
		LocalNetwork.shared.probe()
		pathWatch.start(queue: .global(qos: .utility))
		settle()
		Notifier.shared.attach(self)
		Measure.log("model ready: named=\(named) convs=\(conversations.count)")
	}

	/// What was open last time, on the right side of the wall: a chat is Home, a channel is its space.
	private func settleSelection() {
		route {
			if let id = selectedConversation, let c = conversation(id) {
				if c.kind == .chat { mode = .home } else if c.kind == .channel { mode = .spaces; selectedSpace = c.space }
			} else { selectedConversation = nil }
			if let s = selectedSpace, conversation(s) == nil { selectedSpace = nil }
		}
	}

	/// Smoke hooks for the carry proof across real networks, any build: `BAUD_SAY_TO=Ana BAUD_SAY=hi
	/// BAUD_SAY_AT=30` sends into the chat with that contact; `BAUD_OFFLINE_AT=20 BAUD_ONLINE_AT=60`
	/// drops the connection and comes back; `BAUD_REPORT_AT=90` logs the last message of every chat
	/// with who carried it and its delivery sentence.
	private func carryHooks() {
		let env = ProcessInfo.processInfo.environment
		if let to = env["BAUD_SAY_TO"], let say = env["BAUD_SAY"] {
			Task { @MainActor in
				try? await Task.sleep(for: .seconds(Double(env["BAUD_SAY_AT"] ?? "20") ?? 20))
				for _ in 0..<60 {
					if let c = contacts.first(where: { $0.name == to }) {
						let chat = chat(with: c.user) ?? (try? core.createChat([c.user]))
						if let chat { refreshAll(); send(chat.id, Draft(text: say)); Measure.log("say: '\(say)' to \(to) in \(chat.id)"); return }
					}
					try? await Task.sleep(for: .seconds(1))
				}
				Measure.log("say: no chat with \(to); contacts: \(contacts.map(\.name)) chats: \(chats.count)")
			}
		}
		if let off = env["BAUD_OFFLINE_AT"].flatMap(Double.init) {
			Task { @MainActor in
				try? await Task.sleep(for: .seconds(off)); core.setOnline(false); Measure.log("hook: offline")
				if let on = env["BAUD_ONLINE_AT"].flatMap(Double.init) {
					try? await Task.sleep(for: .seconds(max(0, on - off))); core.setOnline(true); Measure.log("hook: back online")
				}
			}
		}
		if let at = env["BAUD_REPORT_AT"].flatMap(Double.init) {
			Task { @MainActor in
				try? await Task.sleep(for: .seconds(at))
				Measure.log("report: me \(me.name) contacts \(contacts.map(\.name)) chats \(chats.count) peers \(peers.map { "\($0.userName)/\($0.device.name):\($0.device.online ? "on" : "off")" })")
				for c in chats {
					for e in core.events(c.id, before: nil, limit: 2) where e.type == .message {
						let carrier = e.carriedBy.map { id in peers.first { $0.device.id == id }.map { "\($0.userName)'s \($0.device.possessive)" } ?? String(id.prefix(8)) }
						Measure.log("report \(c.name ?? "chat"): \(name(of: e.user)): \(e.text ?? "") · \(carrier.map { "carried by \($0)" } ?? "direct") · \(core.delivery(c.id, e.id).sentence)")
					}
				}
			}
		}
	}

	/// Observed, not computed from the core: the first-run screen must re-render the moment the
	/// name lands (it didn't, on the real iPhone: `core.me()` is not something SwiftUI watches).
	/// Keys outlive the store (the keychain survives a reinstall), so a user with keys but no name
	/// is still asked for one; the keys are kept, the name is written next to them.
	var named: Bool { !me.user.isEmpty && !me.name.isEmpty }
	var onboarded: Bool = UserDefaults.standard.bool(forKey: "onboarded") { didSet { UserDefaults.standard.set(onboarded, forKey: "onboarded") } }
	/// Why the core couldn't open, shown on the first screen instead of nothing.
	private(set) var openFailure: String?
	/// The iPhone hasn't been unlocked since it restarted: nothing of mine can be read yet, and the
	/// launch screen shows until it can (never the name screen, which is for a first run).
	private(set) var waiting = false
	/// The iPhone's files are still locked (not unlocked since a restart).
	static var locked: Bool {
		#if os(iOS)
		return !UIApplication.shared.isProtectedDataAvailable
		#else
		return false
		#endif
	}
	var demoWanted: Bool {
		if let v = ProcessInfo.processInfo.environment["BAUD_DEMO"] { return v != "0" }
		return UserDefaults.standard.bool(forKey: "demo")
	}
	var demoEvents: Int { Int(ProcessInfo.processInfo.environment["BAUD_DEMO_EVENTS"] ?? "") ?? 1200 }

	/// Three demo people on the mesh, so the product can be used alone and every state is real.
	func startDemo() {
		guard demo == nil else { return }
		UserDefaults.standard.set(true, forKey: "demo")
		// `BAUD_DEMO_TALK=everyday`: friends' talk instead of the build team's, for pictures of the app.
		// `everyday-mirror` is the friend's side of the same chat; `-before` holds back the newest
		// line; `-away` sends it while Sam is offline; `-sending` leaves it on its way.
		let said = ProcessInfo.processInfo.environment["BAUD_DEMO_TALK"] ?? ""
		let talk: Demo.Talk = said.hasPrefix("everyday") ? .everyday(mirror: said.contains("mirror"), holdLast: said.contains("before"), away: said.contains("away"), sending: said.contains("sending")) : .work
		do { demo = try Demo.seed(around: local, on: mesh, events: demoEvents, image: DemoImage.make, talk: talk) } catch { self.error = "\(error)"; Measure.log("demo failed: \(error)") }
		// `BAUD_DEMO_PLACES=1`: Ana and Jo share where they are in their chats with me, for pictures.
		if ProcessInfo.processInfo.environment["BAUD_DEMO_PLACES"] == "1", let d = demo {
			for (who, lat, lon) in [(d.ana, 40.7359, -73.9911), (d.jo, 40.7308, -73.9973)] {
				guard let chat = who.conversations(.chat).first(where: { $0.isDirect && $0.members.contains(me.user) }) else { continue }
				who.moved(lat: lat, lon: lon, accuracy: 15)
				who.share(place: chat.id, until: Date().addingTimeInterval(3600))
			}
			// And Jo sends where she is once, a place in the chat.
			if let chat = d.jo.conversations(.chat).first(where: { $0.isDirect && $0.members.contains(me.user) }), PlaceText.parse(chat.lastText) == nil {
				_ = try? d.jo.send(chat.id, Draft(text: PlaceText.make(CLLocationCoordinate2D(latitude: 40.7412, longitude: -73.9897))))
			}
		}
		// `BAUD_DEMO_DISAPPEAR=<seconds>`: disappearing messages on in my chat with Sam (I turned it
		// on) and in Ana's with me (she did), with a line written in each after, for pictures. Once
		// per store: a relaunch finds it set.
		if let s = ProcessInfo.processInfo.environment["BAUD_DEMO_DISAPPEAR"].flatMap(Int.init), let d = demo {
			for (who, other, line) in [(local, d.sam.me().user, "the gate code is 4471, see you at 8"), (d.ana, me.user, "the spare key is under the blue pot")] {
				guard let chat = who.conversations(.chat).first(where: { $0.isDirect && $0.members.contains(other) }), chat.disappear != s else { continue }
				attempt { try who.setDisappear(chat.id, s); _ = try who.send(chat.id, Draft(text: line)) }
			}
		}
		#if DEBUG
		// `BAUD_DEMO_THREAD=1`: Ana and Jo answer "who's in for saturday?" in a thread in weekend, as
		// older versions could, to show thread replies inline. Once per store.
		if ProcessInfo.processInfo.environment["BAUD_DEMO_THREAD"] == "1", let d = demo,
			let weekend = d.ana.conversations(.chat).first(where: { $0.name == "weekend" }),
			let root = d.ana.events(weekend.id, before: nil, limit: 50).last(where: { $0.type == .message && $0.text != nil }),
			d.ana.thread(weekend.id, root.id, before: nil, limit: 5).count < 2 {
			attempt {
				_ = try d.ana.send(weekend.id, Draft(text: "count me in", thread: root.id))
				_ = try d.jo.send(weekend.id, Draft(text: "same, if it isn't raining", thread: root.id))
			}
		}
		#endif
		refreshAll()
	}

	// MARK: reading

	/// Every chat in the list: my chat with myself ("You") first, then the pinned ones in the order
	/// they were pinned, then the rest; archived ones aren't here (`archivedChats`).
	var chats: [Conversation] {
		let all = conversations.filter { $0.kind == .chat && !isArchived($0) }
		let pinned = all.filter { pins[$0.id] != nil }.sorted { pins[$0.id]! < pins[$1.id]! }
		return (notes.map { [$0] } ?? []) + pinned + all.filter { pins[$0.id] == nil }
	}
	/// Chats I archived, until someone else writes in one (unless it's muted).
	var archivedChats: [Conversation] { conversations.filter { $0.kind == .chat && isArchived($0) } }
	/// Friends I have no chat with yet: listed under the chats, so anyone can be written to.
	var quiet: [Contact] {
		let talked = Set(conversations.filter { $0.kind == .chat && $0.isDirect }.flatMap(\.members))
		return contacts.filter { !talked.contains($0.user) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
	}
	/// Our chat, made the first time it's opened; nil if it couldn't be.
	func startChat(with friend: UserId) -> ConversationId? {
		var id: ConversationId?
		attempt { id = try core.createChat([friend]).id; refreshAll() }
		return id
	}
	/// My chat with myself, synced across my devices; it can be cleared, never deleted.
	var notes: Conversation? { _ = conversations; return local.notes() }
	var spaces: [Conversation] { Features.spaces ? conversations.filter { $0.kind == .space }.sorted { ($0.name ?? "") < ($1.name ?? "") } : [] }
	func channels(in space: ConversationId) -> [Conversation] { core.channels(space: space).filter { $0.members.contains(me.user) } }
	func browsable(in space: ConversationId) -> [Conversation] { core.channels(space: space).filter { !$0.members.contains(me.user) } }
	func conversation(_ id: ConversationId?) -> Conversation? { id.flatMap { i in conversations.first { $0.id == i } } ?? id.flatMap(core.conversation) }
	/// Contacts by petname; co-members by the name on their card, learned from any conversation we share.
	private var names: [UserId: String] = [:]
	func name(of user: UserId) -> String {
		if user == me.user { return "You" }
		if let n = nickname(user) { return n }
		if let c = contacts.first(where: { $0.user == user }) { return c.name }
		if let n = names[user] { return n }
		for c in conversations { if let m = core.members(c.id).first(where: { $0.user == user }) { names[user] = m.name; return m.name } }
		return "Someone"
	}

	/// What the row and the header call it: the other person's name for a DM, else its name.
	func title(_ c: Conversation) -> String {
		if c.kind == .home { return "You" }
		if c.isDirect, let other = c.members.first(where: { $0 != me.user }) { return nickname(other) ?? contacts.first { $0.user == other }?.name ?? name(of: other) }
		return c.kind == .channel ? "#\(c.name ?? "channel")" : (c.name ?? "Chat")
	}

	/// The header's status: what a person needs to know, "Online", "Last seen 2 h ago", "3 people ·
	/// 2 online". How they're reached (the path, how fast) is a tap away: the person page's devices
	/// and the Connection sheet.
	func status(_ c: Conversation) -> String {
		if c.kind == .home { return "Your devices" }
		let members = core.members(c.id)
		let others = members.filter { !$0.me }
		if others.isEmpty { return "Just you" }
		if c.isDirect, let o = others.first {
			if o.devices.contains(where: \.online) { return "Online" }
			if let last = o.devices.compactMap(\.lastOnline).max() {
				let ago = agoShort(last)
				return ago == "now" ? "Last seen just now" : "Last seen \(ago) ago"
			}
			return "Never online"
		}
		let online = others.filter(\.online).count
		return "\(members.count) people" + (online > 0 ? " · \(online) online" : "")
	}

	func timeline(_ conv: ConversationId) -> Timeline {
		if let t = timelines[conv] { return t }
		let t = Timeline(conv: conv, model: self)
		timelines[conv] = t
		return t
	}

	/// Photos in messages, drawn small once and kept for the session.
	@ObservationIgnored private var thumbs: [BlobHash: Image] = [:]
	func thumbnail(_ hash: BlobHash, _ url: URL) async -> Image? {
		if let t = thumbs[hash] { return t }
		guard let cg = await Task.detached(priority: .userInitiated, operation: { downscaled(url, maxPixels: 1000) }).value else { return nil }
		let img = Image(decorative: cg, scale: 2)
		thumbs[hash] = img
		return img
	}

	/// Friends' photos are fetched while they're online, not when a face first scrolls into view:
	/// a face looked at later, with its owner away, is already here.
	private func fetchFaces() { for c in contacts where c.online { if let h = c.avatar { _ = image(h) } } }

	/// A blob as an image, fetched once; nil until it is here (the view redraws when it lands).
	func image(_ hash: BlobHash) -> Image? {
		if let i = images[hash] { return i }
		if !loading.contains(hash) {
			loading.insert(hash)
			Task { if let url = try? await core.blob(hash, key: ""), let img = loadImage(url) { images[hash] = img }; loading.remove(hash) }
		}
		return nil
	}
	/// Every unread message, for the dock and the home screen.
	var unread: Int { conversations.reduce(0) { $0 + $1.unread } }

	/// ⌥⌘↓ / ⌥⌘↑ and the sidebar's arrows: the next thing on this side of the wall. Home walks the
	/// chats; inside a space, its channels; the list of spaces, the spaces.
	func step(_ by: Int) {
		if mode == .spaces, selectedSpace == nil {
			let order = spaces.map(\.id)
			guard !order.isEmpty else { return }
			let i = order.firstIndex { $0 == stepCursor } ?? (by > 0 ? -1 : order.count)
			stepCursor = order[max(0, min(order.count - 1, i + by))]
			return
		}
		let order = mode == .home ? chats.map(\.id) : selectedSpace.map { channels(in: $0).map(\.id) } ?? []
		guard !order.isEmpty else { return }
		let i = order.firstIndex { $0 == selectedConversation } ?? (by > 0 ? -1 : order.count)
		selectedConversation = order[max(0, min(order.count - 1, i + by))]
	}
	/// In the list of spaces, the one the arrows are on (⏎ hops in).
	var stepCursor: ConversationId?
	/// The sidebar holds the keyboard: opening a conversation from it leaves the composer alone.
	var sidebarFocused = false
	/// ⌘0 bumps this; the sidebar takes the keyboard.
	var focusSidebar = 0
	/// The Mac's details pane beside the open chat (⌘I).
	var details = false
	/// ⌘F bumps this; the sidebar's search takes the keyboard.
	var focusSearch = 0
	/// ⏎ in the sidebar bumps this; the open chat's composer takes the keyboard.
	var focusComposer = 0
	/// The conversation whose "add someone" sheet is up.
	var addingTo: ConversationId?
	/// Settings scrolls to this section when it opens (friends, devices, network).
	/// The You section to scroll to (`BAUD_SECTION` for the pictures).
	var settingsSection: String? = ProcessInfo.processInfo.environment["BAUD_SECTION"]

	// MARK: Home and Spaces, read

	/// Unread on the other side of the wall shows on its switch.
	var unreadHome: Bool { chats.contains { $0.unread > 0 } }
	var unreadSpaces: Bool { spaces.contains { s in channels(in: s.id).contains { $0.unread > 0 } } }
	func unread(space: ConversationId) -> Int { channels(in: space).reduce(0) { $0 + $1.unread } }
	/// The people of a space (the space's own members), me first.
	func people(in space: ConversationId) -> [Member] { core.members(space).sorted { a, b in a.me != b.me ? a.me : (a.online != b.online ? a.online : a.name < b.name) } }
	/// "4 people · 2 online"
	func peopleLine(_ members: [Member]) -> String {
		let others = members.filter { !$0.me }
		let on = others.filter(\.online).count
		return "\(members.count) \(members.count == 1 ? "person" : "people")" + (others.isEmpty ? "" : " · \(on == 0 ? "nobody else" : "\(on)") online")
	}
	/// For a member who is not my friend: the friends we share in this conversation, who carry for us.
	func through(_ m: Member, in conv: ConversationId) -> [String] {
		guard !m.me, !contacts.contains(where: { $0.user == m.user }) else { return [] }
		let members = Set(core.members(conv).map(\.user))
		return contacts.filter { members.contains($0.user) }.map(\.name)
	}
	func isFriend(_ user: UserId) -> Bool { contacts.contains { $0.user == user } }

	func draft(_ conv: ConversationId) -> String { drafts[conv] ?? "" }
	func setDraft(_ conv: ConversationId, _ text: String) {
		if text.isEmpty { drafts.removeValue(forKey: conv) } else { drafts[conv] = text }
		UserDefaults.standard.set(drafts, forKey: "drafts")
	}

	// MARK: writing

	func attempt(_ what: () throws -> Void) {
		do { try what() } catch let e as CoreError { error = e.sentence } catch { self.error = "\(error)" }
	}
	func attempt(_ what: () async throws -> Void) async {
		do { try await what() } catch let e as CoreError { error = e.sentence } catch { self.error = "\(error)" }
	}

	/// A photo from the picker: written to a file, then onto the card as a blob.
	func setPhoto(_ item: Any?) async {
		#if os(iOS)
		guard let item = item as? PhotosPickerItem, let data = try? await item.loadTransferable(type: Data.self) else { return }
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("photo-\(UUID().uuidString).jpg")
		try? data.write(to: url)
		attempt { try core.setAvatar(url) }
		refreshAll()
		#endif
	}

	func setName(_ name: String) {
		attempt { try core.setName(name) }
		me = core.me()
		if !named, error == nil { error = "The name didn't stick: the keys couldn't be written. \(keys.usingFile ? "Keys are in a file next to the store." : "Keys are in the keychain.")" }
		if named, demoWanted { startDemo() }
	}

	func send(_ conv: ConversationId, _ draft: Draft) {
		if draft.thread == nil { setDraft(conv, "") }
		guard !draft.attachments.isEmpty else { attempt { _ = try core.send(conv, draft) }; return }
		// Files are hashed and copied into the store first: off the main thread, so a big one
		// doesn't hold the window.
		let surface = core
		Task {
			do { _ = try await Task.detached(priority: .userInitiated) { try surface.send(conv, draft) }.value }
			catch let e as CoreError { error = e.sentence } catch { self.error = "\(error)" }
		}
	}

	func answerLink(_ ask: LinkAsk, accept: Bool) { (core as? Baud)?.confirmLink(ask.id, accept: accept); linkAsk = nil; if accept { refreshAll() } }
	/// Become that person's device: show the digits while the other side decides.
	func link(_ link: BaudCore.Link) async throws {
		joiningCode = (core as? Baud)?.joiningCode(link)
		defer { joiningCode = nil }
		try await core.link(link)
		refreshAll()
	}

	/// Start over on this device: the network let go, the store and the keys gone, the app's
	/// settings cleared. The app then makes a fresh model (`restart`), as on first run.
	func wipe() async {
		await (core as? Baud)?.reset()
		await (core as? Baud)?.close()
		sub?.cancel()
		try? FileManager.default.removeItem(at: local.dir)
		keys.wipe()
		if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
		Measure.log("wiped: store, keys and settings")
	}

	/// `BAUD_DOOR` for the smoke: the same assignments a tap makes.
	func door(_ d: String) {
		switch d {
		case "friend", "invite": offer = .friend
		case "device": offer = .device
		case "paste": if join == nil { join = Join(link: nil) }
		#if DEBUG
		// `joined:Maya` (pictures of the app): the card a scan ends on, Maya just added.
		case let d where d.hasPrefix("joined:"):
			let name = String(d.dropFirst(7))
			join = Join(link: Link(url: "baud://add#demo", kind: .friend, name: name, expires: .distantFuture), phase: .done, user: contacts.first { $0.name == name }?.user)
		// `answer:Maya` / `answer-scanned:Maya`: the answer to Maya's link that isn't getting through.
		case let d where d.hasPrefix("answer"):
			let name = String(d.split(separator: ":").last ?? "Maya")
			join = Join(link: Link(url: "baud://add#demo", kind: .friend, name: name, expires: .distantFuture), phase: .replying,
				reply: Link(url: "baud://add#AXIEU2FtIFNoYXJtYQABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4fAAAAAGrAi9BcXFxc", kind: .reply, name: me.name, expires: Date().addingTimeInterval(14 * 60 + 30)), scanned: d.hasPrefix("answer-scanned"))
		#endif
		default: break
		}
	}
	/// A tapped or scanned link: the join sheet takes it from here.
	func open(url: URL) {
		if let l = Code.parse(url.absoluteString) { join = Join(link: l) } else { error = "That link was cut short on its way. Ask for a new one." }
	}
	/// The chat with a person, if one exists yet (the inviter makes it; the invited side receives it).
	func chat(with user: UserId) -> Conversation? { chats.first { $0.isDirect && $0.members.contains(user) } }
	/// "iPhone" or "Mac": what this device is, for sentences about it.
	static var thisKind: String { deviceKind == .iphone ? "iPhone" : "Mac" }

	func scene(active: Bool) { front = active; core.setOnline(active || calls.holdsOnline); if active { settle() } }

	// MARK: changes

	private func changed(_ c: Change) {
		switch c {
		case .me: me = core.me()
		case .contacts: contacts = core.contacts()
		case .conversations: conversations = core.conversations(nil); contacts = core.contacts()
		case .peers: peers = core.peers(); contacts = core.contacts(); conversations = core.conversations(nil); timelines.values.forEach { $0.refreshDelivery() }
		case .carrying: carrying = core.carrying(); peers = core.peers()
		case .conversation(let id): timelines[id]?.reload(); conversations = core.conversations(nil); if id == local.notesID { syncAccent(); readMarks() }
		case .delivery(let id): timelines[id]?.refreshDelivery()
		case .typing(let id): timelines[id]?.refreshTyping()
		case .places: placesChanged()
		case .expired(let id, let events): Notifier.shared.expired(id, events)
		case .incomingCall: break
		}
	}

	// MARK: nicknames

	/// My own names for people: seen only by me, on all my devices (a profile setting, as the colour
	/// is, so it rides my chat with myself). Used everywhere I see their name.
	@ObservationIgnored private var nicknames: [UserId: String] = [:]
	/// Bumped when a nickname changes here or arrives from another device of mine.
	private(set) var nicknameTick = 0
	func nickname(_ user: UserId) -> String? {
		_ = nicknameTick
		if let n = nicknames[user] { return n.isEmpty ? nil : n }
		let n = local.profile("nick." + user) ?? ""
		nicknames[user] = n
		return n.isEmpty ? nil : n
	}
	/// nil or empty takes it away, and their own name shows again.
	func setNickname(_ user: UserId, _ name: String?) {
		let n = String((name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
		local.setProfile("nick." + user, n)
		nicknames[user] = n
		nicknameTick &+= 1
	}
	/// A member's label in a group, seen by everyone in it.
	func setLabel(_ conv: ConversationId, _ user: UserId, _ text: String?) {
		attempt { try core.setLabel(conv, user, text) }
		refreshAll()
	}

	func refreshAll() {
		if !nicknames.isEmpty { nicknames = [:]; nicknameTick &+= 1 }
		syncAccent()
		me = core.me()
		contacts = core.contacts()
		conversations = core.conversations(nil); readMarks()
		peers = core.peers()
		carrying = core.carrying()
		timelines.values.forEach { $0.reload() }
	}

	static var deviceName: String {
		#if os(iOS)
		UIDevice.current.name
		#else
		Host.current().localizedName ?? "Mac"
		#endif
	}
	static var deviceKind: DeviceKind {
		#if os(iOS)
		.iphone
		#else
		.mac
		#endif
	}
}

#if os(iOS)
import UIKit
#endif
