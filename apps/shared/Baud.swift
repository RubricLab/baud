/// `Baud`: the crate-backed core. Identity, cards, invites, device links and presence come from
/// the peer crate; conversations, feeds and delivery stay in `LocalCore`, which keeps talking
/// over the in-process mesh until the crate's streams and inbox land and replace it. Every call
/// the views make goes through here; none of them changes when that happens.
import BaudCore
import Foundation

final class Baud: CoreSurface, @unchecked Sendable {
	let local: LocalCore
	let dir: URL
	let keys: Crate.KeyStore
	private let lock = NSLock()
	private var node: Crate.Node?
	private var listeners: [UUID: @Sendable (Change) -> Void] = [:]
	private var sub: Subscription?

	init(local: LocalCore, dir: URL, keys: AppleKeychain) {
		self.local = local; self.dir = dir
		self.keys = Crate.KeyStore(get: { keys.get($0) }, put: { keys.put($0, $1) }, delete: { keys.delete($0) })
		sub = local.subscribe { [weak self] c in self?.emit(c) }
		Task { await self.open() }
	}

	/// The crate opens in the background; until then the stub answers, and the moment it is up
	/// the stub takes the crate's identity and cards.
	private func open() async {
		Measure.log("crate opening")
		do {
			let n = try await Crate.open(dir: dir, name: local.me().name, deviceName: local.deviceName, deviceKind: local.deviceKind.rawValue, keys: keys) { [weak self] e in self?.on(e) }
			lock.withLock { node = n }
			// The name typed before the crate was up goes onto its card now.
			if n.me().name.isEmpty, !local.me().name.isEmpty { try? n.setName(local.me().name) }
			adoptIdentity(); adoptContacts()
			lock.withLock { if greeted == nil { greeted = Set(local.contacts().map(\.user)) } }
			// Redirects that came while the app was closed.
			for r in n.redirects() { local.redirect(from: r.from, to: r.to) }
			n.onFrame = { [weak self] bytes, from in self?.local.receive(bytes: bytes, from: from, carriedBy: nil) }
			local.setMyPeerCard(n.myCard())
			local.onMember = { [weak self] conv, user in self?.admit(conv, user) }
			LocalCore.log = { Measure.log($0) }
			local.transport = CrateTransport(node: n) { [weak local] d in local?.user(of: d) }
			n.setOnline(true)
			drainInbox()
			Measure.log("crate \(Crate.version) open: \(n.me().user.prefix(8))… on \(n.me().thisDevice.prefix(8))…")
			resync(n)
			if ProcessInfo.processInfo.environment["BAUD_TRACE"] != nil { trace(n) }
		} catch {
			Measure.log("crate failed to open: \(error); the stub carries on alone")
		}
	}

	/// Every minute, my clocks to every device I hold a live connection to: a frame that was sent
	/// and never opened (a key not there yet, a stream cut short) is sent again. A sync with
	/// nothing missing reads two small indexes on each side.
	private func resync(_ n: Crate.Node) {
		Task { [weak self] in
			while !Task.isCancelled {
				try? await Task.sleep(for: .seconds(60))
				guard let self else { return }
				for d in n.peers() where d.online { self.local.connected(d.id) }
			}
		}
	}

	/// `BAUD_TRACE=1`: the crate's trace into the log as it grows, and this device's status every
	/// ten seconds (what it says, the meeting device, who is connected and how).
	private func trace(_ n: Crate.Node) {
		Task { [weak self] in
			var last: String?
			var tick = 0
			while !Task.isCancelled {
				let lines = n.trace()
				let from = last.flatMap { l in lines.lastIndex(of: l).map { $0 + 1 } } ?? 0
				for l in lines[from...] { Measure.log("trace \(l)") }
				last = lines.last ?? last
				if tick % 5 == 0, let self {
					let m = n.meeting()
					let live = n.peers().filter(\.online).map { "\($0.name.isEmpty ? String($0.id.prefix(8)) : $0.name) \($0.path)" }
					Measure.log("status \(self.netState(online: true)) · meeting \(m.kind) \(m.device.map { String($0.prefix(8)) } ?? "-") \(m.deviceName) · probe \(n.reachable()) · router \(n.gateway()) · port \(n.mapped() ?? "-") · connected \(live)")
				}
				tick += 1
				try? await Task.sleep(for: .seconds(2))
			}
		}
	}

	private func adoptIdentity() {
		guard let n = lock.withLock({ node }) else { return }
		let m = n.me()
		guard !m.user.isEmpty else { return }
		let devices = m.devices.map { (id: $0.id, name: $0.name, kind: $0.id == m.thisDevice ? local.deviceKind : DeviceKind(rawValue: $0.kind) ?? kind(of: $0.name)) }
		local.adoptIdentity(user: m.user, name: m.name.isEmpty ? local.me().name : m.name, thisDevice: m.thisDevice, devices: devices)
	}
	private func adoptContacts() {
		guard let n = lock.withLock({ node }) else { return }
		// The crate's book is the book, on every device of mine: anyone it no longer lists (removed
		// on another device, a demo person, a leftover) leaves the friends list here too.
		let book = n.contacts()
		local.keepContacts(Set(book.map(\.user)))
		for c in book {
			local.saveContact(user: c.user, name: c.name, fingerprint: c.fingerprint, verified: c.verified, vouched: c.redirectedFrom != nil,
				devices: c.devices.map { (id: $0.id, name: $0.name.isEmpty ? "device" : $0.name, kind: DeviceKind(rawValue: $0.kind) ?? kind(of: $0.name), online: $0.online, path: path($0.path)) })
		}
	}
	/// Catching a device up after its connection was replaced: at most once per `settle`.
	private var resynced: [DeviceId: Date] = [:]
	private static let settle: TimeInterval = 10
	private func resync(_ d: DeviceId) -> Bool {
		lock.withLock {
			if let t = resynced[d], Date().timeIntervalSince(t) < Self.settle { return false }
			resynced[d] = Date()
			return true
		}
	}
	private func kind(of name: String) -> DeviceKind { name.lowercased().contains("iphone") || name.lowercased().contains("phone") ? .iphone : .mac }
	private func path(_ p: Crate.BaudPath) -> Path {
		switch p {
		case .direct(let ms): return .direct(ms: ms)
		case .relay(let d): return .relay(d, name: local.peers().first { $0.device.id == d }.map { "\($0.userName)'s \($0.device.possessive)" } ?? "a friend's device")
		case .nearby: return .nearby
		case .waiting: return .waiting
		case .unreachable: return .unreachable
		}
	}

	private func on(_ e: Crate.Event) {
		switch e {
		case .dialing(let d):
			// A dial began to a device not connected: it is being reached, not away.
			if node?.isOnline(d) != true { local.setDialing(device: d) }
		case .reached(let d):
			// A link being redeemed reached its meeting device: the other side has the request.
			Measure.log("reached \(d.prefix(8))"); onReached?(d)
		case .online(let d), .offline(let d), .pathChanged(let d):
			if let s = node?.peers().first(where: { $0.id == d }) { local.setLive(device: d, online: s.online, path: path(s.path)) }
			if case .online = e { Measure.log("online \(d.prefix(8))"); local.connected(d) }
			if case .offline = e { Measure.log("offline \(d.prefix(8))"); node?.forget(d) }
			// A new connection replaced the held one (the other side relaunched, woke, moved): no
			// "online", but the old one and every stream on it are gone, and what went down them in
			// the gap may never have arrived. A fresh connection for the next frame, and the clocks.
			// The crate also says this before refusing a send its path can't carry: then nothing
			// was replaced, and catching up would only send more down it (1,370 refusals in three
			// minutes once). So: only while it is online, and at most once per settle per device.
			if case .pathChanged = e {
				node?.forget(d)
				if node?.isOnline(d) == true, resync(d) { Measure.log("reconnected \(d.prefix(8))"); local.connected(d) }
			}
		case .pathMoved(let d):
			// The same connection, a new path (a punch landed, or a failover kept it): only how
			// they're reached changes; nothing was lost, so no fresh connection and no resync.
			if let s = node?.peers().first(where: { $0.id == d }) { local.setLive(device: d, online: s.online, path: path(s.path)) }
		case .contactsChanged:
			adoptContacts(); emit(.contacts)
			// New since this handler last looked, not since anyone adopted the book: `add` adopts
			// the contact it made too, and when their dial met us first it got there before this
			// ran, and the contact never counted as new (no chat, no card).
			let now = local.contacts()
			let fresh: [Contact] = lock.withLock {
				defer { greeted = Set(now.map(\.user)) }
				guard let g = greeted else { return [] }
				return now.filter { !g.contains($0.user) }
			}
			// The inviter opens the chat; the other side receives it.
			// A new contact gets my card with the crate's card inside (and sends theirs), so either
			// of us can later admit the other into a group for a third person.
			for new in fresh { local.announce(to: new.user) }
			if let new = fresh.first {
				let answer = lock.withLock { answered.remove(new.user) != nil }
				if answer || invited {
					if !answer { invited = false }
					Measure.log("inviter opens a chat with \(new.name), devices \(new.devices.map { $0.id.prefix(8) })"); _ = try? local.createChat([new.user])
				}
			}
		case .meChanged:
			let before = Set(local.me().devices.map(\.id))
			adoptIdentity(); emit(.me)
			// A device just became mine: offer it my clocks now (it came online before it was mine,
			// so my chat with myself, and the colour in it, wasn't offered then).
			for d in local.me().devices where !before.contains(d.id) && d.id != local.me().thisDevice && node?.isOnline(d.id) == true { local.connected(d.id) }
		case .inbound(let c): node?.accept(c)
		case .callInbound(let c): onCall?(c)
		case .inbox: drainInbox()
		case .delivered: emit(.peers)
		case .linkRequest(let r):
			if let id = UInt64(r), let ask = node?.linkAsk(id) { onLinkRequest?(r, ask.code, ask.device, ask.name, ask.kind) }
		case .network:
			if let m = node?.meeting() { Measure.log("meeting: \(m.kind) \(m.device.map { $0 == local.me().thisDevice ? "this device" : String($0.prefix(8)) } ?? "none") · reachable \(node?.reachable() ?? .unknown)") }
			emit(.peers)
		case .recordChanged, .other: emit(.peers)
		case .removed: Measure.log("removed by another of my devices"); onRemoved?()
		case .unfriended(let user):
			// They removed me: they and our chat are simply gone here, no line about it.
			Measure.log("unfriended by \(user.prefix(8))")
			local.unfriend(user); emit(.contacts); emit(.conversations)
		case .redirected(let from, let to):
			// A friend's two identities are one: one contact, one chat, their name kept.
			Measure.log("redirect \(from.prefix(8)) → \(to.prefix(8))")
			adoptContacts(); local.redirect(from: from, to: to); emit(.contacts); emit(.conversations)
		case .replied(let user):
			// The maker of a link I answered opened my reply: we met (the contact came with contactsChanged).
			Measure.log("replied: met \(user.prefix(8))"); onReplied?(user)
		case .replyLapsed(let user):
			Measure.log("reply lapsed for \(user.prefix(8))"); onReplyLapsed?(user)
		}
	}
	private var invited = false
	/// The people whose answers to my links I opened: the chat with each is mine to make.
	private var answered: Set<UserId> = []
	/// The contacts the contactsChanged handler has already welcomed (nil until the crate is up).
	private var greeted: Set<UserId>?
	/// Calls: the crate to dial with, and each call connection as it arrives (CallCenter).
	var callNode: Crate.Node? { lock.withLock { node } }
	var onCall: (@Sendable (UInt64) -> Void)?
	/// Another of my devices removed this one: the app says so and starts over.
	var onRemoved: (@Sendable () -> Void)?
	/// A link being redeemed here reached the device it names (`Crate.Event.reached`).
	var onReached: (@Sendable (String) -> Void)?
	/// A reply I made met its link's maker (their user), or stopped waiting unopened.
	var onReplied: (@Sendable (String) -> Void)?
	var onReplyLapsed: (@Sendable (String) -> Void)?
	/// A device asking to become mine: id, the six digits, its device id, its name and kind. The app shows it; `confirmLink` answers.
	var onLinkRequest: (@Sendable (String, String, String, String, String) -> Void)?
	func confirmLink(_ id: String, accept: Bool) { if let r = UInt64(id) { node?.confirmLink(r, accept: accept) } }
	func joiningCode(_ link: BaudCore.Link) -> String? { node?.joiningCode(link.url) }
	/// Envelopes that arrived while away: open each, name its carrier, acknowledge.
	private func drainInbox() {
		guard let n = node else { return }
		for e in n.inbox() {
			local.receive(bytes: e.bytes, from: e.from ?? "", carriedBy: e.carriedBy.first)
			n.ack(e.id)
		}
	}
	private func emit(_ c: Change) { lock.withLock { Array(listeners.values) }.forEach { $0(c) } }

	// MARK: identity, contacts, presence: the crate when it is open, the stub before that

	/// Mine, with the safety number the network gives me: the one my friends see for me (peer's),
	/// not the stub's, or the two numbers a pair compares in person would never match.
	func me() -> Person {
		var p = local.me()
		if let f = node?.me().fingerprint, !f.isEmpty { p.fingerprint = f }
		return p
	}
	func setName(_ name: String) throws { try local.setName(name); try node?.setName(name) }
	func setAvatar(_ path: URL) throws { try local.setAvatar(path) }
	func linkDevice() throws -> BaudCore.Link {
		guard let n = node else { return try local.linkDevice() }
		let url = try n.linkDevice()
		return parseLink(url: url) ?? BaudCore.Link(url: url, kind: .device, name: local.me().name, expires: Date().addingTimeInterval(600))
	}
	func link(_ link: BaudCore.Link) async throws {
		guard let n = node else { return try await local.link(link) }
		try await n.link(link.url, deviceName: local.deviceName)
		adoptIdentity(); adoptContacts()
	}
	func unfriend(_ user: UserId) throws { try node?.remove(user); local.unfriend(user) }
	func revoke(_ device: DeviceId) throws { try node?.removeDevice(device); try local.revoke(device) }
	func networkChanged() { node?.networkChanged() }
	/// This device on the network. Online: the internet reaches it, because its router holds a
	/// port for it or it runs a relay others reach; any device, a phone as much as a Mac (Dexter,
	/// 0.2.6: "devices open a port and then say online"; 0.2.5 gave the relay to Macs only, and a
	/// phone its router had opened a port for said Not reachable). Else Through the meeting device,
	/// one of mine or a friend's that runs a relay, while I hold a live connection to it; else Not
	/// reachable, naming the one I am not connected to. The UDP probe's verdict says a punch could
	/// work, not that anyone can reach me, so it is no part of this: the home Mac said "Reachable" with
	/// nothing able to reach it (0.2.4).
	func netState(online: Bool) -> AppModel.NetState {
		guard online else { return .offline }
		guard let n = node else { return .notReachable(away: nil) }
		let m = n.meeting()
		// Reached from outside: it runs the relay, its router holds a port, or the network lets a
		// punch through (IPv6 seen untranslated, or a NAT that keeps one port).
		if m.device == local.me().thisDevice || n.mapped() != nil || n.reachable() == .yes { return .online }
		guard m.kind != .none, let d = m.device else { return .notReachable(away: nil) }
		let name = m.kind == .own ? Names.device(m.deviceName) : "\(Names.first(m.userName))'s \(Names.device(m.deviceName))"
		return n.isOnline(d) ? .through(name, own: m.kind == .own) : .notReachable(away: m.kind == .own ? "your " + name : name)
	}
	/// Why this device runs no relay anyone can reach: what the router said when asked to open a port.
	func gateway() -> Crate.Node.Gate { node?.gateway() ?? .unknown }
	/// The public address a port the router holds for this device opens.
	func mapped() -> String? { node?.mapped() }
	/// The device the next link names to meet at, when it isn't this one.
	func meetingDevice() -> DeviceId? { node?.meeting().device.flatMap { $0 == local.me().thisDevice ? nil : $0 } }
	/// A device that runs a relay others can reach: the house.
	func stable(_ device: DeviceId) -> Bool {
		guard let n = node else { return false }
		if device == local.me().thisDevice { let m = n.meeting(); return m.kind == .own && m.device == device }
		return n.records().first { $0.device == device }.map { $0.relay == device && $0.reachable } ?? false
	}
	func helpers(_ device: DeviceId) -> [DeviceId] { node?.helpers(device) ?? [] }
	/// Let go of the network and the store's files, before this device starts over.
	func close() async { await node?.close() }
	func reset() async { await node?.reset() }
	func invite() throws -> BaudCore.Link {
		guard let n = node else { return try local.invite() }
		let url = try n.invite()
		invited = true
		return parseLink(url: url) ?? BaudCore.Link(url: url, kind: .friend, name: local.me().name, expires: Date().addingTimeInterval(3600))
	}
	func add(_ link: BaudCore.Link) async throws -> Contact {
		guard let n = node, !local.knowsInProcess(parsedDevice(link) ?? "") else { return try await local.add(link) }
		// A reply answers my link: I'm the inviter, and the inviter opens the chat with them.
		if link.kind == .reply, let u = n.linkUser(link.url) { lock.withLock { _ = answered.insert(u) } }
		let c = try await n.add(link.url)
		adoptContacts()
		guard let k = local.contacts().first(where: { $0.user == c.user }) else { throw CoreError.notFound }
		return k
	}
	/// A reply to a friend link whose maker can't be reached from here: a link to send back the way
	/// theirs came, or to show them to scan. This device keeps dialing theirs until they open it.
	func reply(_ link: BaudCore.Link) throws -> BaudCore.Link {
		guard let n = node else { throw CoreError.notFound }
		let url = try n.reply(link.url)
		return parseLink(url: url) ?? BaudCore.Link(url: url, kind: .reply, name: local.me().name, expires: Date().addingTimeInterval(900))
	}
	private func parsedDevice(_ link: BaudCore.Link) -> DeviceId? { let p = link.url.components(separatedBy: "#").last?.components(separatedBy: "."); return p?.count == 7 ? p?[5] : nil }
	func contacts() -> [Contact] { local.contacts() }
	func verify(_ user: UserId, fingerprint: String) throws -> Bool {
		if let n = node, try n.verify(user, fingerprint) { adoptContacts(); return true }
		return try local.verify(user, fingerprint: fingerprint)
	}
	/// The stub's peers with the crate's facts on top: the record's age, how it was found, when it
	/// was last connected (the network loop's own numbers, crate 94e9812).
	func peers() -> [Peer] {
		let base = local.peers()
		guard let n = node else { return base }
		let live = Dictionary(n.peers().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
		return base.map { p in
			guard let d = live[p.device.id] else { return p }
			var p = p
			if let age = d.recordAge { p.recordAge = age }
			if let f = d.foundBy.flatMap(FoundBy.init(rawValue:)) { p.foundBy = f }
			if !d.online, let seen = d.lastSeen { p.device.lastOnline = seen }
			return p
		}
	}
	func carrying() -> Carrying { local.carrying() }
	func setOnline(_ online: Bool) { local.setOnline(online); node?.setOnline(online) }
	func subscribe(_ listener: @escaping @Sendable (Change) -> Void) -> Subscription {
		let id = UUID(); lock.withLock { listeners[id] = listener }
		return Cancel { [weak self] in self?.lock.withLock { _ = self?.listeners.removeValue(forKey: id) } }
	}

	// MARK: conversations: the stub, over the mesh, until the crate carries bytes

	func conversations(_ kind: Kind?) -> [Conversation] { local.conversations(kind) }
	func conversation(_ id: ConversationId) -> Conversation? { local.conversation(id) }
	func events(_ conv: ConversationId, before: EventId?, limit: Int) -> [Event] { local.events(conv, before: before, limit: limit) }
	func thread(_ conv: ConversationId, _ root: EventId, before: EventId?, limit: Int) -> [Event] { local.thread(conv, root, before: before, limit: limit) }
	func send(_ conv: ConversationId, _ draft: Draft) throws -> Event { try local.send(conv, draft) }
	func react(_ conv: ConversationId, _ target: EventId, _ key: String, on: Bool) throws { try local.react(conv, target, key, on: on) }
	func edit(_ conv: ConversationId, _ target: EventId, text: String) throws { try local.edit(conv, target, text: text) }
	func redact(_ conv: ConversationId, _ target: EventId) throws { try local.redact(conv, target) }
	func pin(_ conv: ConversationId, _ target: EventId, on: Bool) throws { try local.pin(conv, target, on: on) }
	func markRead(_ conv: ConversationId, _ event: EventId) throws { try local.markRead(conv, event) }
	func typing(_ conv: ConversationId) { local.typing(conv) }
	func typingNow(_ conv: ConversationId) -> [UserId] { local.typingNow(conv) }
	func members(_ conv: ConversationId) -> [Member] { local.members(conv) }
	/// Membership in the stub, then the crate: a co-member's devices get admitted and carried for
	/// once the groups bindings land (`addMember(group:card:)` at crate 16aa249); until then the
	/// crate only carries for contacts, so a non-contact co-member's first message waits.
	func addMember(_ conv: ConversationId, _ user: UserId) throws {
		try local.addMember(conv, user)
		admit(conv, user)
	}
	/// The crate admits and carries for a co-member's devices once it holds their card.
	private func admit(_ conv: ConversationId, _ user: UserId) {
		guard let n = node, let card = n.cardOf(user) ?? local.peerCard(of: user) else { Measure.log("no card for \(user.prefix(8)) to admit into \(conv.prefix(8))"); return }
		makeGroup(conv, n)
		n.addMember(group: conv, card: card)
	}
	/// Each conversation's group gets its tier before its first member: a space and its channels
	/// are `space` (everyone a mutual), any chat is `chat` (non-contacts reached through mutuals).
	private var made: Set<ConversationId> = []
	private func makeGroup(_ conv: ConversationId, _ n: Crate.Node) {
		guard lock.withLock({ made.insert(conv).inserted }), let c = local.conversation(conv) else { return }
		n.makeGroup(conv, space: c.kind == .space || c.kind == .channel)
	}
	func removeMember(_ conv: ConversationId, _ user: UserId) throws { try local.removeMember(conv, user) }
	func leave(_ conv: ConversationId) throws { try local.leave(conv) }
	func setName(_ conv: ConversationId, _ name: String) throws { try local.setName(conv, name) }
	func setTopic(_ conv: ConversationId, _ topic: String) throws { try local.setTopic(conv, topic) }
	func delivery(_ conv: ConversationId, _ event: EventId) -> Delivery { local.delivery(conv, event) }
	func createChat(_ users: [UserId]) throws -> Conversation { try local.createChat(users) }
	func createGroup(_ name: String, users: [UserId]) throws -> Conversation { try local.createGroup(name, users: users) }
	func createSpace(_ name: String) throws -> Conversation { try local.createSpace(name) }
	func createChannel(space: ConversationId, name: String) throws -> Conversation { try local.createChannel(space: space, name: name) }
	func join(space: ConversationId, channel: ConversationId) throws { try local.join(space: space, channel: channel) }
	func channels(space: ConversationId) -> [Conversation] { local.channels(space: space) }
	func search(_ query: String, scope: SearchScope?) -> [Hit] { local.search(query, scope: scope) }
	func blob(_ hash: BlobHash, key: String) async throws -> URL { try await local.blob(hash, key: key) }
	func transfers(_ conv: ConversationId) -> [Transfer] { local.transfers(conv) }
	func call(_ conv: ConversationId, video: Bool) throws -> Call { try local.call(conv, video: video) }
	func incoming() -> Call? { nil }
}

final class Cancel: Subscription, @unchecked Sendable {
	let f: () -> Void
	init(_ f: @escaping () -> Void) { self.f = f }
	func cancel() { f() }
}

/// The crate as the core's transport: bytes to a device now, or to carriers.
final class CrateTransport: Transport, @unchecked Sendable {
	let node: Crate.Node
	let userOf: @Sendable (DeviceId) -> UserId?
	init(node: Crate.Node, userOf: @escaping @Sendable (DeviceId) -> UserId?) { self.node = node; self.userOf = userOf }
	/// Ask the crate for the member's current card (a device linked after we first held it).
	private func refresh(_ device: DeviceId) -> Bool {
		guard let u = userOf(device), node.cardOf(u) != nil else { return false }
		return node.holdsCard(for: device)
	}
	func reaches(_ device: DeviceId) -> Bool { node.holdsCard(for: device) || refresh(device) }
	func isOnline(_ device: DeviceId) -> Bool { node.isOnline(device) }
	func rtt(_ device: DeviceId) -> Int? { node.rtt(device) }
	func send(_ bytes: Data, to device: DeviceId) async -> Bool { await node.send(bytes, to: device) }
	func post(_ bytes: Data, to device: DeviceId, ttl: TimeInterval) async -> [DeviceId] {
		// Only to a device whose card we hold; a member seen online before its card arrived waits
		// here, and the feed sync on the next connection carries what it missed.
		guard node.holdsCard(for: device) || refresh(device) else { Measure.log("holding post to \(device.prefix(8)): no card yet"); return [] }
		let carriers = await node.post(bytes, to: device, ttl: ttl)
		Measure.log("posted to \(device.prefix(8)): carriers \(carriers.map { $0.prefix(8) })")
		return carriers
	}
	/// The file into the crate's blob store, by reference where it can: its blake3 is the id.
	func provide(_ file: URL) async -> String? {
		do { return try await node.p.blobs().addPath(path: file.path) } catch { Measure.log("provide failed: \(error)"); return nil }
	}
	/// The crate fetches, verifies as it goes, retries on its own budget, and exports to `file`.
	func fetch(_ id: String, from device: DeviceId, to file: URL) async -> Bool {
		do {
			let t = try await node.p.blobs().fetch(from: device, hash: id, to: file.path, rangeStart: 0, rangeEnd: 0)
			while true {
				switch t.state() {
				case .done: Measure.log("fetched \(id.prefix(8)) from \(device.prefix(8))"); return FileManager.default.fileExists(atPath: file.path)
				case .cancelled, .failed: Measure.log("fetch \(id.prefix(8)) from \(device.prefix(8)) \(t.state()): \(t.error() ?? "-")"); return false
				default: try await Task.sleep(for: .milliseconds(150))
				}
			}
		} catch { Measure.log("fetch \(id.prefix(8)) from \(device.prefix(8)) failed: \(error)"); return false }
	}
}
