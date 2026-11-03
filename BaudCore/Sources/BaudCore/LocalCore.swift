/// One device, standing in for the crate: feeds in SQLite, FTS for search, cards in events,
/// delivery as real rows. Alone it is a node with nobody to talk to; on a `Mesh` it talks to the
/// other cores in the process exactly the way the crate will talk to other devices (Carry.swift).
/// Every method answers truthfully for what this device knows.
import CryptoKit
import Foundation

public final class LocalCore: CoreSurface, @unchecked Sendable {
	let store: Store
	let keys: Keys
	let lock = NSRecursiveLock()
	/// This device's id: from the keys here, or the crate's once it has adopted one.
	public private(set) var device: DeviceId
	public let deviceName: String
	public let deviceKind: DeviceKind
	public let dir: URL
	var user: UserId = ""
	var name: String = ""
	/// Strong both ways: a mesh and its cores live as long as the process that made them.
	var mesh: Mesh?
	/// The crate's transport when it is here; frames then leave the process sealed, and the mesh is only the demo's.
	public var transport: Transport?
	var online = false
	var listeners: [UUID: @Sendable (Change) -> Void] = [:]
	var typingSeen: [ConversationId: [UserId: Date]] = [:]
	var pendingTransfers: [ConversationId: [Transfer]] = [:]
	/// Files being asked for from other devices (Files.swift).
	var blobWaits: [BlobHash: BlobWait] = [:]
	/// Devices that asked for a file I didn't have yet but may give them (Files.swift).
	var wantedBy: [BlobHash: Set<DeviceId>] = [:]
	/// Sealed packets for a conversation whose key hasn't arrived yet (Transport.swift).
	var waitingForKey: [(conv: ConversationId, bytes: Data, from: DeviceId, carriedBy: DeviceId?)] = []
	/// Where the core says what it did on the wire, when the app wants to know (its log).
	nonisolated(unsafe) public static var log: ((String) -> Void)?
	func trace(_ s: @autoclosure () -> String) { Self.log?(s()) }
	/// Online state and path per device as the crate reports it (the adapter fills this; the mesh otherwise).
	var liveState: [DeviceId: (online: Bool, path: Path)] = [:]
	/// This iPhone's push addresses, for wake tickets (Wake.swift); nil elsewhere.
	var wakeTokens: WakeTokens?
	/// When I last asked the relay to wake a device, by device and kind (Wake.swift).
	var lastWake: [String: Date] = [:]
	/// Where the people sharing with me are, by chat and person; my own latest fix (Places.swift).
	var heldPlaces: [ConversationId: [UserId: Place]] = [:]
	var lastFix: (lat: Double, lon: Double, accuracy: Double, at: Double)?
	/// The sweep that waits for the next disappearing message due to go, and when that is (Disappear.swift).
	var expiryTimer: Task<Void, Never>?
	var expiryDue: Double?
	public var isDemo = false

	/// `dir` nil keeps everything in memory (tests, demo people).
	public init(dir: URL?, keys: Keys, deviceName: String, kind: DeviceKind) throws {
		self.keys = keys
		self.deviceName = deviceName
		self.deviceKind = kind
		self.dir = dir ?? FileManager.default.temporaryDirectory.appendingPathComponent("baud-\(UUID().uuidString)")
		try? FileManager.default.createDirectory(at: self.dir.appendingPathComponent("blobs"), withIntermediateDirectories: true)
		store = try Store(path: dir.map { $0.appendingPathComponent("baud.sqlite").path } ?? ":memory:")
		let read = keys.get("device-key")
		if read == nil, keys.locked { throw KeysLocked() }
		let dk = read ?? { let k = randomBytes(32); keys.put("device-key", k); return k }()
		// Who I am is the network's identity once it has been adopted (a device linked into a person
		// has no user key of its own): kept here, so a launch knows me at once instead of showing
		// the name screen until the network is up.
		let adopted = (user: store.one("select v from me where k='user'")?.string("v") ?? "", device: store.one("select v from me where k='device'")?.string("v") ?? "")
		device = adopted.device.isEmpty ? stableId("device:" + hex(dk)) : adopted.device
		if dir != nil { wipeLegacy() }
		if !adopted.user.isEmpty {
			user = adopted.user
			name = store.one("select v from me where k='name'")?.string("v") ?? ""
		} else if let uk = keys.get("user-key") {
			user = stableId("user:" + hex(uk))
			name = store.one("select v from me where k='name'")?.string("v") ?? ""
			store.run("insert or ignore into people(user,name,fingerprint) values(?,?,?)", [user, name, fingerprint(user)])
			store.run("insert or ignore into devices(id,user,name,kind,added_at) values(?,?,?,?,?)", [device, user, deviceName, kind.rawValue, Date()])
		}
		// What came due while baud was closed goes now; the rest waits for its time.
		expire()
	}

	public var named: Bool { !user.isEmpty }

	/// Once per store, before wire 2: every message goes, unread (0.2.4 and before left each device
	/// with different ones). Identity, contacts and devices stay; demo people, attachments and the
	/// demo's stores go. Older packets are refused on the wire, so nothing brings them back.
	func wipeLegacy() {
		guard store.one("select v from me where k='epoch'")?.string("v") != String(wireVersion) else { return }
		store.wipeMessages()
		let avatars = Set(store.query("select avatar from people where avatar is not null").compactMap { $0.string("avatar") })
		let blobs = dir.appendingPathComponent("blobs")
		for f in (try? FileManager.default.contentsOfDirectory(atPath: blobs.path)) ?? [] where !avatars.contains(f) { try? FileManager.default.removeItem(at: blobs.appendingPathComponent(f)) }
		try? FileManager.default.removeItem(at: dir.appendingPathComponent("demo"))
		store.run("insert or replace into me(k,v) values('epoch',?)", [String(wireVersion)])
	}

	// MARK: me and my devices

	public func me() -> Person {
		lock.withLock {
			Person(user: user, name: name, fingerprint: user.isEmpty ? "" : fingerprint(user), devices: devices(of: user), thisDevice: device, avatar: store.one("select avatar from people where user=?", [user])?.string("avatar"))
		}
	}

	/// First run: a name makes the user key. Later: a new name, told to everyone who knows me.
	public func setName(_ new: String) throws {
		let n = new.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !n.isEmpty else { return }
		lock.withLock {
			if user.isEmpty {
				let uk = randomBytes(32); keys.put("user-key", uk)
				user = stableId("user:" + hex(uk))
				store.run("insert or replace into devices(id,user,name,kind,added_at) values(?,?,?,?,?)", [device, user, deviceName, deviceKind.rawValue, Date()])
				ensure(conv: stableId("home:" + user) + stableId("home2:" + user), kind: .home, name: nil, space: nil, creator: user)
			}
			name = n
			store.run("insert or replace into me(k,v) values('name',?)", [n])
			store.run("insert or replace into people(user,name,fingerprint,verified,contact,met_at) values(?,?,?,1,0,coalesce((select met_at from people where user=?),?))", [user, n, fingerprint(user), user, Date()])
		}
		tell(.card(card()))
		emit(.me); emit(.contacts); emit(.conversations)
	}

	/// A photo onto my card: stored as a blob, its hash on the card, told to everyone who knows me.
	public func setAvatar(_ path: URL) throws {
		let a = try addBlob(path)
		lock.withLock { store.run("update people set avatar=? where user=?", [a.hash, user]) }
		tell(.card(card()))
		emit(.me); emit(.contacts)
	}

	public func linkDevice() throws -> Link { try makeLink(kind: .device, ttl: 600) }

	/// This device becomes that person's: identity copied, then everything synced over.
	public func link(_ link: Link) async throws {
		let (dev, secret) = try parse(link, kind: .device)
		guard let mesh, let old = mesh.core(dev) else { throw CoreError.unreachable("No device answered at that link. Until the peer crate lands, baud can only meet devices in this process.") }
		guard mesh.isOnline(dev) else { throw CoreError.offline("That device isn't online. Linking needs both devices online at once.") }
		try old.admit(secret: secret, device: WireDevice(id: device, name: deviceName, kind: deviceKind, addedAt: Date().timeIntervalSince1970))
		let p = old.me()
		lock.withLock {
			user = p.user; name = p.name
			keys.put("user-key", old.keys.get("user-key") ?? randomBytes(32))
			store.run("insert or replace into me(k,v) values('name',?)", [name])
			store.run("insert or replace into people(user,name,fingerprint,verified,contact,met_at) values(?,?,?,1,0,?)", [user, name, fingerprint(user), Date()])
			ensure(conv: stableId("home:" + user) + stableId("home2:" + user), kind: .home, name: nil, space: nil, creator: user)
		}
		old.handOver(to: self)
		emit(.me); emit(.contacts); emit(.conversations); emit(.peers)
	}

	public func revoke(_ dev: DeviceId) throws {
		guard dev != device else { throw CoreError.notFound }
		lock.withLock { store.run("delete from devices where id=? and user=?", [dev, user]) }
		tell(.card(card()))
		emit(.me); emit(.peers)
	}

	// MARK: contacts

	public func invite() throws -> Link { try makeLink(kind: .friend, ttl: 3600) }

	public func add(_ link: Link) async throws -> Contact {
		let (dev, secret) = try parse(link, kind: .friend)
		guard let mesh, let other = mesh.core(dev) else { throw CoreError.unreachable("Nobody answered at that link. Until the peer crate lands, baud can only meet devices in this process.") }
		guard mesh.isOnline(dev), online else { throw CoreError.offline("\(link.name) isn't online right now. An invite is a meeting: both of you have to be online at once.") }
		try other.hello(secret: secret, card: card(), from: self)
		guard let c = contacts().first(where: { $0.user == other.me().user }) else { throw CoreError.notFound }
		return c
	}

	public func contacts() -> [Contact] {
		lock.withLock {
			store.query("select * from people where contact=1 and user<>? order by name collate nocase", [user]).map { r in
				let u = r.string("user")!
				return Contact(user: u, name: r.string("name") ?? "", verified: r.bool("verified"), fingerprint: r.string("fingerprint") ?? "", devices: devices(of: u), metAt: r.date("met_at") ?? Date(), avatar: r.string("avatar"), vouched: r.bool("vouched"))
			}
		}
	}

	public func verify(_ u: UserId, fingerprint fp: String) throws -> Bool {
		let ok = lock.withLock { (store.one("select fingerprint from people where user=?", [u])?.string("fingerprint") ?? "") == fp.trimmingCharacters(in: .whitespaces) }
		if ok { lock.withLock { store.run("update people set verified=1 where user=?", [u]) }; emit(.contacts) }
		return ok
	}

	// MARK: conversations

	public func conversations(_ kind: Kind?) -> [Conversation] {
		lock.withLock {
			let rows = kind.map { store.query("select c.* from conversations c join members m on m.conv=c.id where m.user=? and c.kind=?", [user, $0.rawValue]) }
				?? store.query("select c.* from conversations c join members m on m.conv=c.id where m.user=? and c.kind<>'home'", [user])
			let shown = rows.filter { r in
				guard let id = r.string("id"), let cut = cutoff("hidden:", id) else { return true }
				return store.int("select coalesce(max(lamport),0) as n from events where conv=? and type='message' and body<>'{}'", [id]) > cut
			}
			return collapse(shown.map(conversation(row:))).sorted { $0.lastAt > $1.lastAt }
		}
	}

	/// Deleting a chat here: it leaves the list until a message newer than the deletion arrives (the
	/// friend stays a friend). A group is left first, which tells its members.
	public func delete(_ conv: ConversationId) throws {
		guard let c = conversation(conv) else { throw CoreError.notFound }
		if c.kind == .home { return clear(conv) }
		if !c.isDirect { try? leave(conv) }
		lock.withLock { hide(conv) }
		emit(.conversations)
	}
	/// Hidden here and on every other device of mine: the cutoff travels as a state line in my
	/// chat with myself, like the colour.
	func hide(_ conv: ConversationId) {
		let l = store.int("select coalesce(max(lamport),0) as n from events where conv=?", [conv])
		store.run("insert or replace into me(k,v) values(?,?)", ["hidden:" + conv, String(l)])
		setProfile("hidden." + conv, String(l))
	}
	/// No longer friends: they leave the friends list and our chat leaves this device's list (every
	/// copy of it). A link adds them again.
	public func unfriend(_ u: UserId) {
		lock.withLock {
			store.run("update people set contact=0 where user=?", [u])
			let direct = store.query("select c.id from conversations c where c.kind='chat' and c.name is null and (select count(*) from members m where m.conv=c.id)=2 and exists(select 1 from members m where m.conv=c.id and m.user=?)", [u])
			for r in direct { if let id = r.string("id") { hide(id) } }
		}
		emit(.contacts); emit(.peers); emit(.conversations)
	}
	/// Clearing my own chat with myself: its lines before now leave this device's view.
	public func clear(_ conv: ConversationId) {
		lock.withLock {
			let l = store.int("select coalesce(max(lamport),0) as n from events where conv=?", [conv])
			store.run("insert or replace into me(k,v) values(?,?)", ["cleared:" + conv, String(l)])
			setProfile("cleared." + conv, String(l))
		}
		emit(.conversation(conv)); emit(.conversations)
	}
	/// A cutoff from another device of mine: the later of the two wins.
	func raise(_ key: String, _ conv: ConversationId, to l: Int) {
		guard (cutoff(key, conv) ?? -1) < l else { return }
		store.run("insert or replace into me(k,v) values(?,?)", [key + conv, String(l)])
	}
	func cutoff(_ key: String, _ conv: ConversationId) -> Int? { store.one("select v from me where k=?", [key + conv])?.string("v").flatMap(Int.init) }
	/// My settings that follow me to my other devices (the colour): a state line in my chat with
	/// myself, never shown in it; the latest one wins everywhere.
	public func setProfile(_ key: String, _ value: String) {
		guard let home = notes()?.id else { return }
		_ = try? write(home, .state, body: encode(StateBody(key: "profile." + key, value: value)))
	}
	public func profile(_ key: String) -> String? {
		lock.withLock {
			guard !user.isEmpty else { return nil }
			let home = stableId("home:" + user) + stableId("home2:" + user)
			// The last one set, by when: a device that picks before it has caught up with my others
			// writes below their clock, and by clock alone their older pick took it back at once.
			return store.one("select body from events where conv=? and type='state' and body like ? order by at desc, lamport desc, id desc limit 1", [home, "%\"profile.\(key)\"%"])?.string("body").flatMap { decode(StateBody.self, $0)?.value }
		}
	}
	/// The id of my chat with myself.
	public var notesID: ConversationId? { lock.withLock { user.isEmpty ? nil : stableId("home:" + user) + stableId("home2:" + user) } }

	/// My chat with myself: the home conversation every device of mine holds, shown at the top as "You".
	public func notes() -> Conversation? {
		lock.withLock {
			guard !user.isEmpty else { return nil }
			// Made here too: a user that came back from the keychain was never named again.
			let id = stableId("home:" + user) + stableId("home2:" + user)
			ensure(conv: id, kind: .home, name: nil, space: nil, creator: user)
			return store.one("select * from conversations where id=?", [id]).map(conversation(row:))
		}
	}

	/// A direct chat is keyed by the other person's key, never by a name. When two exist for the same
	/// pair (both sides opened one before seeing the other's), the one with the smaller id is the chat
	/// on both sides, and the other's messages, unread and last line show inside it.
	func collapse(_ cs: [Conversation]) -> [Conversation] {
		var direct: [UserId: [Conversation]] = [:]
		var out: [Conversation] = []
		for c in cs {
			if c.isDirect, let other = c.members.first(where: { $0 != user }) { direct[other, default: []].append(c) } else { out.append(c) }
		}
		for (_, group) in direct {
			guard group.count > 1 else { out += group; continue }
			var keep = group.min { $0.id < $1.id }!
			let latest = group.max { $0.lastAt < $1.lastAt }!
			keep.lastAt = latest.lastAt; keep.lastText = latest.lastText; keep.lastUser = latest.lastUser; keep.lastEvent = latest.lastEvent
			keep.unread = group.reduce(0) { $0 + $1.unread }; keep.mentions = group.reduce(0) { $0 + $1.mentions }; keep.eventCount = group.reduce(0) { $0 + $1.eventCount }
			out.append(keep)
		}
		return out
	}
	/// For the journey: a second direct chat with someone, as a race between two devices makes one.
	public func forceDirectChat(with u: UserId) { _ = try? create(kind: .chat, name: nil, space: nil, users: [u]) }
	/// Every direct chat with someone in the store, shown or not.
	public func directChatCount(with u: UserId) -> Int {
		lock.withLock { store.query("select c.* from conversations c join members m on m.conv=c.id where m.user=? and c.kind='chat' and c.name is null", [u]).map(conversation(row:)).filter { $0.isDirect && $0.members.contains(user) }.count }
	}
	/// The other direct chats with the same person as this one, when it is the one shown.
	func aliases(of conv: ConversationId) -> [ConversationId] {
		guard let c = store.one("select * from conversations where id=?", [conv]).map(conversation(row:)), c.isDirect, let other = c.members.first(where: { $0 != user }) else { return [] }
		let all = store.query("select c.* from conversations c join members m on m.conv=c.id where m.user=? and c.kind='chat' and c.name is null", [other]).map(conversation(row:)).filter { $0.isDirect && $0.members.contains(user) }
		guard all.count > 1, all.map(\.id).min() == conv else { return [] }
		return all.map(\.id).filter { $0 != conv }
	}

	public func conversation(_ id: ConversationId) -> Conversation? {
		lock.withLock { store.one("select * from conversations where id=?", [id]).map(conversation(row:)) }
	}

	public func events(_ conv: ConversationId, before: EventId?, limit: Int) -> [Event] {
		let others = lock.withLock { aliases(of: conv) }
		if !others.isEmpty {
			// A merged direct chat: each conversation's page, resolved on its own, interleaved by time.
			let cut = before.flatMap { b in lock.withLock { store.one("select at from events where id=?", [b])?.date("at") } }
			let all = ([conv] + others).flatMap { c in pageByTime(c, before: cut, limit: limit) }
			return Array(all.sorted { ($0.at, $0.id) < ($1.at, $1.id) }.suffix(limit))
		}
		return lock.withLock {
			var sql = "select * from events where conv=? and type in ('message','member','state','create') and thread is null and id not in (select target from events where conv=? and type='redact') and not (type='state' and body like '%\"key\":\"profile.%') and not (type='message' and body='{}')"
			var args: [Bindable?] = [conv, conv]
			if let cut = cutoff("cleared:", conv) { sql += " and lamport > ?"; args.append(cut) }
			if let before, let b = store.one("select lamport from events where id=?", [before]) {
				sql += " and (lamport < ? or (lamport = ? and id < ?))"; args += [b.int("lamport")!, b.int("lamport")!, before]
			}
			sql += " order by lamport desc, id desc limit ?"; args.append(limit)
			return resolve(store.query(sql, args).reversed(), conv: conv)
		}
	}

	private func pageByTime(_ conv: ConversationId, before: Date?, limit: Int) -> [Event] {
		lock.withLock {
			var sql = "select * from events where conv=? and type in ('message','member','state','create') and thread is null and id not in (select target from events where conv=? and type='redact') and not (type='state' and body like '%\"key\":\"profile.%') and not (type='message' and body='{}')"
			var args: [Bindable?] = [conv, conv]
			if let before { sql += " and at < ?"; args.append(before) }
			sql += " order by at desc, id desc limit ?"; args.append(limit)
			return resolve(store.query(sql, args).reversed(), conv: conv)
		}
	}

	public func thread(_ conv: ConversationId, _ root: EventId, before: EventId?, limit: Int) -> [Event] {
		lock.withLock {
			let rows = store.query("select * from events where conv=? and (id=? or thread=?) and id not in (select target from events where conv=? and type='redact') and not (type='message' and body='{}') order by lamport, id", [conv, root, root, conv])
			return resolve(rows, conv: conv)
		}
	}

	public func send(_ conv: ConversationId, _ draft: Draft) throws -> Event {
		guard isMember(conv) else { throw CoreError.notMember }
		var attachments: [Attachment] = []
		for url in draft.attachments { attachments.append(try addBlob(url)) }
		let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
		// While the conversation's messages disappear, this one carries its own time.
		let ttl = lock.withLock { store.one("select disappear from conversations where id=?", [conv])?.int("disappear") ?? 0 }
		let body = MessageBody(text: text.isEmpty ? nil : text, attachments: attachments.isEmpty ? nil : attachments, reply: draft.reply, thread: draft.thread, mentions: draft.mentions.isEmpty ? nil : draft.mentions, ttl: ttl > 0 ? ttl : nil)
		let e = try write(conv, .message, body: encode(body), text: body.text, reply: draft.reply, thread: draft.thread)
		queueBigTransfers(conv, attachments)
		return event(e.id)!
	}

	public func react(_ conv: ConversationId, _ target: EventId, _ key: String, on: Bool) throws {
		_ = try write(conv, .reaction, body: encode(ReactionBody(target: target, key: key, on: on)), target: target)
	}
	public func edit(_ conv: ConversationId, _ target: EventId, text: String) throws {
		guard event(target)?.mine == true else { throw CoreError.notFound }
		_ = try write(conv, .edit, body: encode(EditBody(target: target, text: text)), text: text, target: target)
	}
	public func redact(_ conv: ConversationId, _ target: EventId) throws {
		guard let e = event(target), e.mine || isAdmin(conv) else { throw CoreError.notAdmin }
		_ = try write(conv, .redact, body: encode(RedactBody(target: target)), target: target)
	}
	public func pin(_ conv: ConversationId, _ target: EventId, on: Bool) throws {
		guard isAdmin(conv) || conversation(conv)?.kind == .chat else { throw CoreError.notAdmin }
		_ = try write(conv, .state, body: encode(StateBody(key: "pin", value: on ? target : "-" + target)), text: "pin", target: target)
	}

	public func markRead(_ conv: ConversationId, _ ev: EventId) throws {
		// A merged direct chat is read as one: the other conversations' last lines too.
		for a in lock.withLock({ aliases(of: conv) }) {
			if let last = lock.withLock({ store.one("select id from events where conv=? and type='message' order by lamport desc limit 1", [a])?.string("id") }), last != ev { try markRead(a, last) }
		}
		guard let e = lock.withLock({ store.one("select lamport, conv from events where id=?", [ev]) }) else { return }
		let conv = e.string("conv") ?? conv
		let l = e.int("lamport")!
		let already = lock.withLock { (store.one("select lamport from reads where conv=?", [conv])?.int("lamport") ?? -1) >= l }
		if already { return }
		lock.withLock { store.run("insert or replace into reads(conv,event,lamport) values(?,?,?)", [conv, ev, l]) }
		let r = WireReceipt(conv: conv, device: device, user: user, event: ev, lamport: l, kind: "read", at: Date().timeIntervalSince1970)
		apply(receipt: r)
		for d in memberDevices(conv) where d != device { post(.receipt(r), to: d, conv: conv) }
		emit(.conversations)
	}

	public func typing(_ conv: ConversationId) {
		guard online else { return }
		for d in memberDevices(conv) where d != device {
			if let t = transport, t.isOnline(d) { let bytes = seal(.typing(conv, user), conv: conv); Task { _ = await t.send(bytes, to: d) } }
			else { mesh?.send(.typing(conv, user), from: device, to: d) }
		}
	}
	/// A call in this chat, to its members' online devices (direct only: it's news now or never).
	public func announceCall(_ conv: ConversationId, _ p: CallPresence) {
		guard online else { return }
		for d in memberDevices(conv) where d != device {
			if let t = transport, t.isOnline(d) { let bytes = seal(.inCall(conv, p), conv: conv); Task { _ = await t.send(bytes, to: d) } }
		}
	}
	/// Someone's word that a call is going on in a chat (or that it's over).
	public var onCallPresence: (@Sendable (ConversationId, CallPresence) -> Void)?

	public func typingNow(_ conv: ConversationId) -> [UserId] {
		lock.withLock { (typingSeen[conv] ?? [:]).filter { $0.value > Date().addingTimeInterval(-5) }.map(\.key).sorted() }
	}

	public func members(_ conv: ConversationId) -> [Member] {
		lock.withLock {
			store.query("select m.*, p.name, p.verified from members m left join people p on p.user=m.user where m.conv=? order by m.joined_at", [conv]).map { r in
				let u = r.string("user")!
				return Member(user: u, name: u == user ? "You" : (r.string("name") ?? "?"), admin: r.bool("admin"), joinedAt: r.date("joined_at") ?? Date(), devices: devices(of: u), verified: r.bool("verified"), me: u == user, label: r.string("label").flatMap { $0.isEmpty ? nil : $0 })
			}
		}
	}

	public func addMember(_ conv: ConversationId, _ u: UserId) throws {
		guard let c = conversation(conv) else { throw CoreError.notFound }
		guard c.kind == .chat || isAdmin(conv) || (u == user && c.kind == .channel && c.space.map(isMember) == true) else { throw CoreError.notAdmin }
		guard let cd = cardOf(u) else { throw CoreError.notFound }
		_ = try write(conv, .member, body: encode(MemberBody(user: u, card: cd, action: "add", admin: false)), text: "add")
		if c.kind == .space {
			for ch in channels(space: conv) where ch.isDefault && !ch.members.contains(u) { try? addMember(ch.id, u) }
		}
	}
	public func removeMember(_ conv: ConversationId, _ u: UserId) throws {
		guard isAdmin(conv) else { throw CoreError.notAdmin }
		_ = try write(conv, .member, body: encode(MemberBody(user: u, card: nil, action: "remove", admin: nil)), text: "remove")
	}
	public func leave(_ conv: ConversationId) throws {
		guard let c = conversation(conv) else { throw CoreError.notFound }
		_ = try write(conv, .member, body: encode(MemberBody(user: user, card: nil, action: "leave", admin: nil)), text: "leave")
		if c.kind == .space { for ch in channels(space: conv) where ch.members.contains(user) { try? leave(ch.id) } }
		emit(.conversations)
	}
	public func setName(_ conv: ConversationId, _ n: String) throws {
		guard isAdmin(conv) || conversation(conv)?.kind == .chat else { throw CoreError.notAdmin }
		_ = try write(conv, .state, body: encode(StateBody(key: "name", value: n)), text: "name")
	}
	/// A call, as a quiet line in its conversation: written once, by the caller's device, when the
	/// call is over. `outcome` is "talked" (for `seconds`), "missed", "declined" or "busy". A state
	/// event, so a device from before calls skips the line instead of failing on it.
	public func recordCall(_ conv: ConversationId, video: Bool, outcome: String, seconds: Int) throws {
		_ = try write(conv, .state, body: encode(StateBody(key: "call", value: encode(CallRecord(video: video, outcome: outcome, seconds: seconds)))), text: "call")
	}
	/// Labels are short (24 characters) and say something about someone in this group, to everyone
	/// in it. A member sets their own; an admin sets anyone's. A quiet change: no line in the chat.
	public func setLabel(_ conv: ConversationId, _ u: UserId, _ text: String?) throws {
		guard u == user || isAdmin(conv) else { throw CoreError.notAdmin }
		let t = String((text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
		_ = try write(conv, .state, body: encode(StateBody(key: "label", value: encode(LabelBody(user: u, text: t)))), text: "label")
	}
	public func setTopic(_ conv: ConversationId, _ t: String) throws {
		guard isAdmin(conv) || conversation(conv)?.kind == .chat else { throw CoreError.notAdmin }
		_ = try write(conv, .state, body: encode(StateBody(key: "topic", value: t)), text: "topic")
	}
	/// Disappearing messages: each message written from now on carries this many seconds and goes
	/// that long after it is read (its writer's copies, after it is sent); 0 turns it off. Anyone in
	/// a chat changes it, only an admin in a channel. A state line, resolved like the name.
	public func setDisappear(_ conv: ConversationId, _ seconds: Int) throws {
		guard isAdmin(conv) || conversation(conv)?.kind == .chat else { throw CoreError.notAdmin }
		_ = try write(conv, .state, body: encode(StateBody(key: "disappear", value: String(max(0, seconds)))), text: "disappear")
	}

	public func createChat(_ users: [UserId]) throws -> Conversation {
		let all = Set(users + [user])
		if all.count == 2, let u = users.first(where: { $0 != user }), let existing = conversations(.chat).first(where: { $0.isDirect && $0.members.contains(u) }) { return existing }
		return try create(kind: .chat, name: nil, space: nil, users: users)
	}
	public func createGroup(_ name: String, users: [UserId]) throws -> Conversation { try create(kind: .chat, name: name, space: nil, users: users) }
	public func createSpace(_ name: String) throws -> Conversation { try create(kind: .space, name: name, space: nil, users: []) }
	public func createChannel(space: ConversationId, name: String) throws -> Conversation {
		guard isAdmin(space) else { throw CoreError.notAdmin }
		let isDefault = channels(space: space).isEmpty
		let c = try create(kind: .channel, name: name, space: space, users: [], isDefault: isDefault)
		var list = channelList(space)
		list.append(ChannelRef(conv: c.id, name: name, isDefault: isDefault))
		_ = try write(space, .state, body: encode(StateBody(key: "channels", value: encode(list))), text: "channels")
		if isDefault { for m in members(space) where !m.me { try? addMember(c.id, m.user) } }
		return conversation(c.id)!
	}
	public func join(space: ConversationId, channel: ConversationId) throws { try addMember(channel, user) }
	public func channels(space: ConversationId) -> [Conversation] {
		lock.withLock { store.query("select * from conversations where space=? order by is_default desc, name collate nocase", [space]).map(conversation(row:)) }
	}

	public func search(_ query: String, scope: SearchScope?) -> [Hit] {
		let terms = query.split(whereSeparator: { $0.isWhitespace }).map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }
		guard !terms.isEmpty else { return [] }
		return lock.withLock {
			var sql = "select event, conv, snippet(fts, 0, '', '', '…', 14) as s from fts where fts match ?"
			var args: [Bindable?] = [terms.joined(separator: " ")]
			if let c = scope?.conversation { sql += " and conv=?"; args.append(c) }
			if let u = scope?.user { sql += " and user=?"; args.append(u) }
			if let s = scope?.space { sql += " and conv in (select id from conversations where space=? or id=?)"; args += [s, s] }
			sql += " order by rowid desc limit 60"
			var convs: [ConversationId: Conversation] = [:]
			return store.query(sql, args).compactMap { r in
				guard let e = event(r.string("event")!, paths: false) else { return nil }
				let cid = r.string("conv")!
				if convs[cid] == nil { convs[cid] = conversation(cid) }
				guard let c = convs[cid], c.members.contains(user) else { return nil }
				return Hit(event: e, conversation: c, snippet: r.string("s") ?? "")
			}
		}
	}

	public func blob(_ hash: BlobHash, key: String) async throws -> URL {
		let mine = blobPath(hash)
		if FileManager.default.fileExists(atPath: mine.path) { return mine }
		for d in mesh?.devices ?? [] {
			if let c = mesh?.core(d), c.device != device, FileManager.default.fileExists(atPath: c.blobPath(hash).path) {
				try FileManager.default.copyItem(at: c.blobPath(hash), to: mine); return mine
			}
		}
		if let url = await fetchBlob(hash) { return url }
		throw CoreError.unreachable("Nobody who has it is online.")
	}

	// MARK: the network

	public func peers() -> [Peer] {
		lock.withLock {
			store.query("select d.*, p.name as pname from devices d left join people p on p.user=d.user where d.id<>? order by d.user=? desc, pname collate nocase, d.name", [device, user]).map { r in
				let d = device(row: r)
				let own = r.string("user") == user
				let contact = store.int("select count(*) as n from people where user=? and contact=1", [d.user]) > 0
				return Peer(device: d, userName: own ? "You" : (r.string("pname") ?? "?"), own: own,
					recordAge: d.online ? 0 : d.lastOnline.map { Date().timeIntervalSince($0) },
					foundBy: own ? .exchange : contact ? .invite : .exchange,
					relaying: false,
					holdingForMe: mesh?.core(d.id)?.heldCount(for: device) ?? 0,
					iHoldForIt: store.int("select count(*) as n from envelopes where to_device=?", [d.id]))
			}
		}
	}

	public func carrying() -> Carrying {
		lock.withLock {
			let held = store.query("select e.to_device, count(*) as n, sum(size) as b, d.kind, d.user, p.name as pname from envelopes e left join devices d on d.id=e.to_device left join people p on p.user=d.user group by e.to_device").map {
				Held(device: $0.string("to_device")!, name: "\($0.string("user") == user ? "your" : ($0.string("pname") ?? "?") + "'s") \(kindWord($0.string("kind")))", count: $0.int("n") ?? 0, bytes: $0.int("b") ?? 0)
			}
			return Carrying(envelopes: held.reduce(0) { $0 + $1.count }, bytes: held.reduce(0) { $0 + $1.bytes }, held: held)
		}
	}

	public func transfers(_ conv: ConversationId) -> [Transfer] { lock.withLock { pendingTransfers[conv] ?? [] } }

	public func call(_ conv: ConversationId, video: Bool) throws -> Call {
		let on = members(conv).filter { !$0.me }.filter(\.online)
		guard !on.isEmpty else { throw CoreError.offline("\(list(members(conv).filter { !$0.me }.map(\.name))) \(members(conv).count > 2 ? "aren't" : "isn't") online.") }
		throw CoreError.offline("The direct path is here; calls over it come in release 2.")
	}
	public func incoming() -> Call? { nil }

	public func setOnline(_ on: Bool) {
		let changed = lock.withLock { let c = online != on; online = on; return c }
		guard changed else { return }
		mesh?.setOnline(self, on)
		// Devices the crate connected before the app said it was active (a relaunch connects in
		// ~70 ms, the window comes later): their "online" found this core offline and offered
		// nothing, so offer now.
		if on, let t = transport {
			let all = lock.withLock { store.query("select id from devices where id<>?", [device]).compactMap { $0.string("id") } }
			for d in all where t.isOnline(d) { connected(d) }
		}
		emit(.peers); emit(.contacts); emit(.conversations)
	}

	public func subscribe(_ listener: @escaping @Sendable (Change) -> Void) -> Subscription {
		let id = UUID()
		lock.withLock { listeners[id] = listener }
		return Sub { [weak self] in self?.lock.withLock { _ = self?.listeners.removeValue(forKey: id) } }
	}
	func emit(_ c: Change) { lock.withLock { Array(listeners.values) }.forEach { $0(c) } }

	// MARK: reading rows

	func conversation(row r: Row) -> Conversation {
		let id = r.string("id")!
		let members = store.query("select user, admin from members where conv=?", [id])
		// A message gone (body '{}') is not a last line, unread, or counted.
		let last = store.one("select id, text, user, at from events where conv=? and type='message' and thread is null and body<>'{}' order by lamport desc, id desc limit 1", [id])
		let created = r.date("created_at") ?? Date()
		let readL = store.one("select lamport from reads where conv=?", [id])?.int("lamport") ?? -1
		let unread = store.int("select count(*) as n from events where conv=? and type='message' and thread is null and user<>? and lamport>? and body<>'{}'", [id, user, readL])
		let mentions = unread == 0 ? 0 : store.int("select count(*) as n from events where conv=? and type='message' and user<>? and lamport>? and body like ?", [id, user, readL, "%\"\(user)\"%"])
		let count = store.int("select count(*) as n from events where conv=? and type='message' and body<>'{}'", [id])
		return Conversation(id: id, kind: Kind(rawValue: r.string("kind") ?? "chat") ?? .chat, name: r.string("name"), topic: r.string("topic"), space: r.string("space"),
			members: members.map { $0.string("user")! }, admins: members.filter { $0.bool("admin") }.map { $0.string("user")! }, createdAt: created,
			lastAt: last?.date("at") ?? created, lastText: last?.string("text"), lastUser: last?.string("user"), lastEvent: last?.string("id"), unread: unread, mentions: mentions, eventCount: count,
			isDefault: r.bool("is_default"), pinned: store.query("select event from pins where conv=?", [id]).compactMap { $0.string("event") }, disappear: r.int("disappear") ?? 0)
	}

	func device(row r: Row) -> Device {
		let id = r.string("id")!
		let live = liveState[id]
		// Demo people live on the mesh; everyone else is the crate's to know about.
		let inProcess = mesh?.core(id) != nil
		let on = live?.online ?? (inProcess ? mesh?.isOnline(id) : transport?.isOnline(id)) ?? mesh?.isOnline(id) ?? false
		let path: Path = live?.path ?? (on && online ? .direct(ms: (inProcess ? nil : transport?.rtt(id)) ?? mesh?.rtt(id)) : on ? .waiting : .none)
		return Device(id: id, name: r.string("name") ?? "device", kind: DeviceKind(rawValue: r.string("kind") ?? "mac") ?? .mac, user: r.string("user") ?? "", addedAt: r.date("added_at") ?? Date(), online: on, lastOnline: r.date("last_online"), path: path)
	}

	func devices(of u: UserId) -> [Device] { store.query("select * from devices where user=? order by added_at", [u]).map(device(row:)) }

	func event(_ id: EventId, paths: Bool = true) -> Event? {
		lock.withLock { store.one("select * from events where id=?", [id]).flatMap { resolve([$0], conv: $0.string("conv")!, paths: paths).first } }
	}

	/// Edits applied, reactions grouped, thread counts, pins, the system line for non-messages.
	func resolve(_ rows: [Row], conv: ConversationId, paths: Bool = true) -> [Event] {
		guard !rows.isEmpty else { return [] }
		// Small pages name their ids; big ones (the whole timeline for a measurement) use the lamport range.
		let lo = rows.map { $0.int("lamport") ?? 0 }.min()!, hi = rows.map { $0.int("lamport") ?? 0 }.max()!
		let ids = rows.map { $0.string("id")! }
		let small = ids.count <= 400
		let inPage = small ? "(\(ids.map { _ in "?" }.joined(separator: ",")))" : "(select id from events where conv=? and lamport between ? and ?)"
		let pageArgs: [Bindable?] = small ? ids : [conv, lo, hi]
		// The planner prefers the conversation index, which is a scan of the whole conversation; name the right one.
		let byTarget = small ? "indexed by events_target" : "", byThread = small ? "indexed by events_thread" : ""
		var edits: [EventId: String] = [:]
		for e in store.query("select target, text from events \(byTarget) where target in \(inPage) and conv=? and type='edit' order by lamport, id", pageArgs + [conv]) { edits[e.string("target")!] = e.string("text") }
		var reacts: [EventId: [String: [UserId]]] = [:]
		for r in store.query("select target, user, body from events \(byTarget) where target in \(inPage) and conv=? and type='reaction' order by lamport, id", pageArgs + [conv]) {
			guard let b = decode(ReactionBody.self, r.string("body")), let u = r.string("user") else { continue }
			var byKey = reacts[b.target] ?? [:]
			var users = byKey[b.key] ?? []
			users.removeAll { $0 == u }
			if b.on { users.append(u) }
			byKey[b.key] = users
			reacts[b.target] = byKey
		}
		var threads: [EventId: (Int, [UserId])] = [:]
		for t in store.query("select thread, count(*) as n, group_concat(user) as users from (select thread, user from events \(byThread) where thread in \(inPage) and conv=? and type='message' and body<>'{}' order by lamport) group by thread", pageArgs + [conv]) {
			let users = (t.string("users") ?? "").split(separator: ",").map(String.init)
			var seen: [UserId] = []
			for u in users.reversed() where !seen.contains(u) { seen.append(u); if seen.count == 3 { break } }
			threads[t.string("thread")!] = (t.int("n") ?? 0, seen)
		}
		let pinned = Set(store.query("select event from pins where conv=?", [conv]).compactMap { $0.string("event") })
		var names: [UserId: String] = [:]
		func nameOf(_ u: UserId) -> String {
			if let n = names[u] { return n }
			let n = u == user ? "You" : (store.one("select name from people where user=?", [u])?.string("name") ?? "Someone")
			names[u] = n; return n
		}
		// How my messages on this page travelled: three queries for the page, not three per line.
		let mineIDs = paths ? rows.filter { $0.string("user") == user }.compactMap { $0.string("id") } : []
		let marks = mineIDs.map { _ in "?" }.joined(separator: ",")
		let delivered: Set<String> = mineIDs.isEmpty ? [] : Set(store.query("select distinct event from receipts where conv=? and user<>? and kind='delivered' and event in (\(marks))", [conv, user] + mineIDs).compactMap { $0.string("event") })
		let handedOver: Set<String> = mineIDs.isEmpty ? [] : Set(store.query("select distinct event from handed where event in (\(marks))", mineIDs).compactMap { $0.string("event") })
		let readUpTo = mineIDs.isEmpty ? -1 : store.one("select max(lamport) as l from receipts where conv=? and user<>? and kind='read'", [conv, user])?.int("l") ?? -1
		return rows.map { r in
			let id = r.string("id")!, type = EventType(rawValue: r.string("type") ?? "message") ?? .message, u = r.string("user") ?? ""
			var e = Event(id: id, conv: conv, device: r.string("device") ?? "", seq: r.int("seq") ?? 0, user: u, at: r.date("at") ?? Date(), lamport: r.int("lamport") ?? 0, type: type, mine: u == user, carriedBy: r.string("carried_by"))
			switch type {
			case .message:
				let stored = r.string("via").flatMap(Event.Via.init(rawValue:))
				if u == user {
					// Mine: waiting until another device has it, carried while one holds it for them.
					let arrived = delivered.contains(id) || (r.int("lamport") ?? 0) <= readUpTo
					e.via = handedOver.contains(id) ? .carried : arrived ? (stored ?? .direct) : .waiting
				} else { e.via = stored ?? .direct }
				let b = decode(MessageBody.self, r.string("body"))
				e.text = edits[id] ?? b?.text
				e.edited = edits[id] != nil
				e.attachments = b?.attachments ?? []
				e.reply = b?.reply; e.thread = b?.thread; e.mentions = b?.mentions ?? []
				e.reactions = (reacts[id] ?? [:]).filter { !$0.value.isEmpty }.map { Reaction(key: $0.key, users: $0.value, mine: $0.value.contains(user)) }.sorted { $0.key < $1.key }
				if let t = threads[id] { e.replies = t.0; e.lastRepliers = t.1 }
				e.pinned = pinned.contains(id)
			case .member:
				let b = decode(MemberBody.self, r.string("body"))
				let who = b.map { nameOf($0.user) } ?? "someone"
				switch b?.action {
				case "add": e.system = b?.user == u ? "\(nameOf(u)) joined" : "\(nameOf(u)) added \(who)"
				case "remove": e.system = "\(nameOf(u)) removed \(who)"
				default: e.system = "\(nameOf(u)) left"
				}
			case .state:
				let b = decode(StateBody.self, r.string("body"))
				switch b?.key {
				case "name": e.system = "\(nameOf(u)) named it \(b?.value ?? "")"
				case "topic": e.system = "\(nameOf(u)) set the topic: \(b?.value ?? "")"
				case "pin": e.system = (b?.value.hasPrefix("-") == true) ? "\(nameOf(u)) unpinned a message" : "\(nameOf(u)) pinned a message"
				case "call": e.system = decode(CallRecord.self, b?.value).map { $0.line(mine: u == user, caller: nameOf(u)) }
				case "disappear": if let s = b.flatMap({ Int($0.value) }), s >= 0 { e.system = disappearLine(by: nameOf(u), seconds: s) }
				default: e.system = nil
				}
			case .create:
				let b = decode(CreateBody.self, r.string("body"))
				e.system = b?.kind == .channel ? "\(nameOf(u)) created #\(b?.name ?? "")" : b?.kind == .space ? "\(nameOf(u)) created the space \(b?.name ?? "")" : b?.name != nil ? "\(nameOf(u)) made the group \(b!.name!)" : nil
			default: break
			}
			return e
		}.filter { $0.type == .message || $0.system != nil }
	}

	// MARK: writing

	/// Every event this device writes: its own id, its own next seq, then told to every member device.
	@discardableResult
	func write(_ conv: ConversationId, _ type: EventType, body: String, text: String? = nil, reply: EventId? = nil, thread: EventId? = nil, target: EventId? = nil, at: Date = Date()) throws -> WireEvent {
		guard named else { throw CoreError.notMember }
		let e: WireEvent = lock.withLock {
			let seq = store.int("select coalesce(max(seq),0) as n from events where conv=? and device=?", [conv, device]) + 1
			let lamport = store.int("select coalesce(max(lamport),0) as n from events where conv=?", [conv]) + 1
			return WireEvent(id: stableId("\(conv)/\(device)/\(seq)"), conv: conv, device: device, seq: seq, user: user, at: at.timeIntervalSince1970, lamport: lamport, type: type, text: text, reply: reply, thread: thread, target: target, body: body)
		}
		apply(e, carriedBy: nil)
		if type == .message, let l = Optional(e.lamport) { lock.withLock { store.run("insert or replace into reads(conv,event,lamport) values(?,?,?)", [conv, e.id, l]) } }
		// A join announces itself to the space too: its members hold the channel's history.
		var to = Set(memberDevices(conv))
		if type == .member, let space = conversation(conv)?.space { to.formUnion(memberDevices(space)) }
		// A joiner's devices get the conversation so far (a chat from its creation; a channel all of
		// it) with the key; the mesh does the same by syncing, the crate by what travels here.
		let joiner: Set<DeviceId> = type == .member && decode(MemberBody.self, body)?.action == "add" ? Set(decode(MemberBody.self, body).map { devices(of: $0.user).map(\.id) } ?? []) : []
		let history: [WireEvent] = joiner.isEmpty ? [] : lock.withLock { store.query("select * from events where conv=? order by lamport, id", [conv]).map(wire(row:)) }
		for d in to where d != device { post(.events(joiner.contains(d) ? history : [e]), to: d, conv: conv, joiner: joiner.contains(d)) }
		return e
	}

	/// The path from a device that just sent me something: relayed, or direct.
	func viaFrom(_ d: DeviceId) -> String {
		if case .relay = liveState[d]?.path { return "relay" }
		return "direct"
	}
	/// The path my message is leaving by: direct when any other member's device is, else relayed
	/// when one is reached through a helper, else nothing yet (it waits).
	func viaTo(_ conv: ConversationId) -> String? {
		let others = store.query("select d.id from devices d join members m on m.user=d.user where m.conv=? and m.user<>?", [conv, user]).compactMap { $0.string("id") }
		let paths = others.compactMap { liveState[$0] }.filter(\.online).map(\.path)
		if paths.contains(where: { if case .direct = $0 { return true }; if case .nearby = $0 { return true }; return false }) { return "direct" }
		if paths.contains(where: { if case .relay = $0 { return true }; return false }) { return "relay" }
		return nil
	}

	/// Insert a feed entry (idempotent by (conv, device, seq)) and its effect on state.
	@discardableResult
	func apply(_ e: WireEvent, carriedBy: DeviceId?) -> Bool {
		var joined: [(ConversationId, UserId)] = []
		var expires: Double?
		let fresh: Bool = lock.withLock {
			if store.int("select count(*) as n from events where id=?", [e.id]) > 0 { return false }
			// How it came (theirs) or how it is leaving (mine), as the paths are right now.
			let via: String? = carriedBy != nil ? "carried" : e.device != device ? viaFrom(e.device) : viaTo(e.conv)
			store.run("insert into events(id,conv,device,seq,user,at,lamport,type,text,reply,thread,target,body,carried_by,via) values(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
				[e.id, e.conv, e.device, e.seq, e.user, e.at, e.lamport, e.type.rawValue, e.text, e.reply, e.thread, e.target, e.body, carriedBy, via])
			switch e.type {
			case .message:
				if let t = e.text { store.run("insert into fts(text,event,conv,user) values(?,?,?,?)", [t, e.id, e.conv, e.user]) }
				// A disappearing message: when it goes here, if that is known yet.
				expires = expiry(of: e)
				if let x = expires { store.run("update events set expires_at=? where id=?", [x, e.id]) }
			case .edit:
				// An edit of a message already gone from here goes with it: it carries the words too.
				if let target = e.target, gone(target) { store.run("update events set text=null, body='{}' where id=?", [e.id]) }
				else if let t = e.text, let target = e.target { store.run("delete from fts where event=?", [target]); store.run("insert into fts(text,event,conv,user) values(?,?,?,?)", [t, target, e.conv, e.user]) }
			case .redact:
				if let target = e.target { store.run("delete from fts where event=?", [target]); store.run("update events set text=null, body='{}' where id=?", [target]) }
			case .create:
				if let b = decode(CreateBody.self, e.body) {
					ensure(conv: e.conv, kind: b.kind, name: b.name, space: b.space, creator: b.creator.user, isDefault: b.isDefault ?? false, at: Date(timeIntervalSince1970: e.at))
					save(card: b.creator, contact: false)
				}
			case .member:
				if let b = decode(MemberBody.self, e.body) {
					if b.action == "add" {
						if let c = b.card { save(card: c, contact: false) }
						store.run("insert or ignore into members(conv,user,admin,joined_at) values(?,?,?,?)", [e.conv, b.user, b.admin ?? false, e.at])
						if b.user != user { joined.append((e.conv, b.user)) }
					} else {
						store.run("delete from members where conv=? and user=?", [e.conv, b.user])
					}
				}
			case .state:
				if let b = decode(StateBody.self, e.body) {
					switch b.key {
					case "name": store.run("update conversations set name=? where id=?", [b.value, e.conv])
					case "topic": store.run("update conversations set topic=? where id=?", [b.value, e.conv])
					case "disappear": if let s = Int(b.value), s >= 0 { store.run("update conversations set disappear=? where id=?", [s, e.conv]) }
					case "label":
						// Only their own, or an admin's word on anyone's.
						if let l = decode(LabelBody.self, b.value), l.user == e.user || store.one("select admin from members where conv=? and user=?", [e.conv, e.user])?.bool("admin") == true {
							store.run("update members set label=? where conv=? and user=?", [String(l.text.prefix(24)), e.conv, l.user])
						}
					case "pin":
						if b.value.hasPrefix("-") { store.run("delete from pins where conv=? and event=?", [e.conv, String(b.value.dropFirst())]) }
						else if !gone(b.value) { store.run("insert or ignore into pins(conv,event) values(?,?)", [e.conv, b.value]) }
					case "channels":
						for ch in decode([ChannelRef].self, b.value) ?? [] {
							store.run("insert or ignore into conversations(id,kind,name,space,created_at,is_default) values(?,?,?,?,?,?)", [ch.conv, Kind.channel.rawValue, ch.name, e.conv, e.at, ch.isDefault])
						}
					default:
						// A chat deleted or cleared on another device of mine.
						guard e.user == user, e.conv == notesID, let l = Int(b.value) else { break }
						if b.key.hasPrefix("profile.hidden.") { raise("hidden:", String(b.key.dropFirst(15)), to: l) }
						if b.key.hasPrefix("profile.cleared.") { raise("cleared:", String(b.key.dropFirst(16)), to: l) }
					}
				}
			case .card:
				if let c = decode(WireCard.self, e.body) { save(card: c, contact: false) }
			default: break
			}
			return true
		}
		guard fresh else { return false }
		// Past its time already (it was read on another device of mine, or written long ago): it
		// goes now, before anyone sees it; else the sweep waits for it.
		if let x = expires { if x <= Date().timeIntervalSince1970 { expire() } else { scheduleExpiry() } }
		for (c, u) in joined { onMember?(c, u) }
		if e.type == .create || e.type == .member || e.type == .state && (e.text == "channels" || e.text == "disappear") { emit(.conversations) }
		// A cutoff from another device of mine: the list and that chat redraw.
		if e.type == .state, e.user == user, let b = decode(StateBody.self, e.body), b.key.hasPrefix("profile.hidden.") || b.key.hasPrefix("profile.cleared.") {
			emit(.conversations); emit(.conversation(String(b.key.split(separator: ".", maxSplits: 2).last ?? "")))
		}
		emit(.conversation(e.conv))
		if e.type == .member, let b = decode(MemberBody.self, e.body), b.action == "add", b.user != user, e.user == user || isMember(e.conv) {
			// A joiner gets history from whoever has it (chats from their join, channels everything).
			for d in devices(of: b.user) where (mesh?.isOnline(d.id) ?? false) && online { if let c = mesh?.core(d.id) { sync(with: c, only: e.conv) } }
		}
		return true
	}

	func ensure(conv: ConversationId, kind: Kind, name: String?, space: ConversationId?, creator: UserId, isDefault: Bool = false, at: Date = Date()) {
		store.run("insert or ignore into conversations(id,kind,name,space,created_at,is_default) values(?,?,?,?,?,?)", [conv, kind.rawValue, name, space, at, isDefault])
		store.run("update conversations set is_default=? where id=? and is_default=0", [isDefault, conv])
		store.run("insert or ignore into members(conv,user,admin,joined_at) values(?,?,1,?)", [conv, creator, at])
	}

	func create(kind: Kind, name: String?, space: ConversationId?, users: [UserId], isDefault: Bool = false) throws -> Conversation {
		guard named else { throw CoreError.notMember }
		// 32 bytes, as the crate's group ids are.
		let seed = "conv:\(device):\(UUID().uuidString)"
		let id = stableId(seed) + stableId("2:" + seed)
		let body = CreateBody(kind: kind, name: name, space: space, history: kind == .channel ? "shared" : "members", creator: card(), isDefault: isDefault)
		_ = try write(id, .create, body: encode(body), text: name)
		for u in users where u != user { try addMember(id, u) }
		emit(.conversations)
		return conversation(id)!
	}

	/// The crate's cards, mine and everyone's I have met or share a conversation with.
	var myPeerCard: Data?
	var peerCards: [UserId: Data] = [:]
	/// A hook for the adapter: someone joined a conversation I'm in, with this card.
	public var onMember: ((ConversationId, UserId) -> Void)?
	public func setMyPeerCard(_ d: Data) { lock.withLock { myPeerCard = d } }
	/// My card, with the crate's card inside, to one person's devices: after meeting on the
	/// crate, so each side can later vouch for the other to co-members.
	public func announce(to u: UserId) { for d in devices(of: u) { post(.card(card()), to: d.id, conv: "") } }
	public func peerCard(of u: UserId) -> Data? { lock.withLock { peerCards[u] ?? store.one("select peer_card from people where user=?", [u]).flatMap { $0.d["peer_card"] as? Data } } }

	func save(card c: WireCard, contact: Bool) {
		if let pc = c.peerCard { peerCards[c.user] = pc; store.run("update people set peer_card=? where user=?", [pc, c.user]) }
		store.run("insert into people(user,name,fingerprint,verified,contact,met_at,demo,avatar) values(?,?,?,0,?,?,?,?) on conflict(user) do update set name=excluded.name, contact=max(people.contact, excluded.contact), avatar=coalesce(excluded.avatar, people.avatar)", [c.user, c.name, c.fingerprint, contact, Date(), isDemo, c.avatar])
		if let pc = c.peerCard { store.run("update people set peer_card=? where user=?", [pc, c.user]) }
		// A specific kind on the card (an Android phone) replaces the network's plain "node", never the other way.
		for d in c.devices { store.run("insert into devices(id,user,name,kind,added_at) values(?,?,?,?,?) on conflict(id) do update set kind=excluded.kind where devices.kind='node' and excluded.kind!='node'", [d.id, c.user, d.name, d.kind.rawValue, d.addedAt]) }
		let listed = c.devices.map(\.id)
		if !listed.isEmpty { store.run("delete from devices where user=? and id not in (\(listed.map { _ in "?" }.joined(separator: ",")))", [c.user] + listed) }
	}

	func card() -> WireCard {
		lock.withLock { WireCard(user: user, name: name, fingerprint: fingerprint(user), devices: store.query("select * from devices where user=?", [user]).map { WireDevice(id: $0.string("id")!, name: $0.string("name") ?? "", kind: DeviceKind(rawValue: $0.string("kind") ?? "mac") ?? .mac, addedAt: $0.double("added_at") ?? 0) }, avatar: store.one("select avatar from people where user=?", [user])?.string("avatar"), peerCard: myPeerCard) }
	}
	func cardOf(_ u: UserId) -> WireCard? {
		lock.withLock {
			guard let p = store.one("select * from people where user=?", [u]) else { return nil }
			return WireCard(user: u, name: p.string("name") ?? "", fingerprint: p.string("fingerprint") ?? "", devices: store.query("select * from devices where user=?", [u]).map { WireDevice(id: $0.string("id")!, name: $0.string("name") ?? "", kind: DeviceKind(rawValue: $0.string("kind") ?? "mac") ?? .mac, addedAt: $0.double("added_at") ?? 0) }, avatar: p.string("avatar"), peerCard: peerCards[u])
		}
	}

	func isMember(_ conv: ConversationId) -> Bool { lock.withLock { store.int("select count(*) as n from members where conv=? and user=?", [conv, user]) > 0 } }
	func isAdmin(_ conv: ConversationId) -> Bool { lock.withLock { store.int("select count(*) as n from members where conv=? and user=? and admin=1", [conv, user]) > 0 } }
	func memberDevices(_ conv: ConversationId) -> [DeviceId] {
		lock.withLock { store.query("select d.id from devices d join members m on m.user=d.user where m.conv=?", [conv]).compactMap { $0.string("id") } }
	}
	func channelList(_ space: ConversationId) -> [ChannelRef] {
		lock.withLock { store.one("select body from events where conv=? and type='state' and text='channels' order by lamport desc limit 1", [space]).flatMap { decode(StateBody.self, $0.string("body")) }.flatMap { decode([ChannelRef].self, $0.value) } ?? [] }
	}

	// MARK: links and blobs

	func makeLink(kind: Link.Kind, ttl: TimeInterval) throws -> Link {
		guard named else { throw CoreError.notMember }
		let secret = hex(randomBytes(16)), expires = Date().addingTimeInterval(ttl)
		lock.withLock { store.run("insert into links(secret,kind,expires) values(?,?,?)", [secret, kind.rawValue, expires]) }
		let safe = name.replacingOccurrences(of: ".", with: " ")
		return Link(url: "baud://\(kind == .friend ? "add" : "link")#peer1.\(kind.rawValue).\(safe).\(user).\(Int(expires.timeIntervalSince1970)).\(device).\(secret)", kind: kind, name: name, expires: expires)
	}

	/// Whether a device is a core in this process (the demo people), so a link for it meets here.
	public func knowsInProcess(_ device: DeviceId) -> Bool { mesh?.core(device) != nil }

	/// A dial to the device began: it is being reached, which says nothing about when it was last online.
	public func setDialing(device: DeviceId) {
		lock.withLock { liveState[device] = (false, .waiting) }
		emit(.peers)
	}
	public func setLive(device: DeviceId, online: Bool, path: Path) {
		let came = lock.withLock { () -> Bool in
			let was = liveState[device]?.online ?? false
			liveState[device] = (online, path)
			if !online { store.run("update devices set last_online=? where id=?", [Date(), device]) }
			return online && !was
		}
		// Connected: it holds a ticket to wake this iPhone, if it hasn't one fresh enough.
		if came { offerWake(to: device); placesOnConnect(device) }
		emit(.peers); emit(.contacts); emit(.conversations)
	}

	func parse(_ link: Link, kind: Link.Kind) throws -> (DeviceId, String) {
		let parts = link.url.components(separatedBy: "#").last?.components(separatedBy: ".") ?? []
		guard parts.count == 7, parts[0] == "peer1", parts[1] == kind.rawValue else { throw CoreError.badLink }
		guard Double(parts[4]).map({ Date(timeIntervalSince1970: $0) > Date() }) == true else { throw CoreError.expired }
		return (parts[5], parts[6])
	}

	public static func parse(url: String) -> Link? { parseLink(url: url) }

	// MARK: the seams an adapter uses when identity and cards come from the peer crate

	/// Take the crate's identity: this device is that person's, with those devices.
	public func adoptIdentity(user u: UserId, name n: String, thisDevice: DeviceId, devices: [(id: DeviceId, name: String, kind: DeviceKind)]) {
		lock.withLock {
			if !user.isEmpty, u != user {
				// Everything written as the stub's user before the crate was up is mine under the crate's id.
				for t in ["events", "members", "receipts", "devices"] { store.run("update \(t) set user=? where user=?", [u, user]) }
				store.run("update people set user=? where user=?", [u, user])
				store.run("update conversations set id=id where 0")
				let oldHome = stableId("home:" + user) + stableId("home2:" + user), newHome = stableId("home:" + u) + stableId("home2:" + u)
				store.run("update conversations set id=? where id=?", [newHome, oldHome])
				store.run("update members set conv=? where conv=?", [newHome, oldHome])
				store.run("update events set conv=? where conv=?", [newHome, oldHome])
				store.run("update reads set conv=? where conv=?", [newHome, oldHome])
			}
			if thisDevice != device {
				// The crate's device id is the one other devices dial and sign for; take it over.
				store.run("update events set device=? where device=?", [thisDevice, device])
				store.run("update receipts set device=? where device=?", [thisDevice, device])
				store.run("delete from devices where id=?", [device])
				device = thisDevice
			}
			user = u; name = n
			store.run("insert or replace into me(k,v) values('name',?)", [n])
			store.run("insert or replace into me(k,v) values('user',?)", [u])
			store.run("insert or replace into me(k,v) values('device',?)", [thisDevice])
			store.run("insert or replace into people(user,name,fingerprint,verified,contact,met_at) values(?,?,?,1,0,coalesce((select met_at from people where user=?),?))", [u, n, fingerprint(u), u, Date()])
			for d in devices { store.run("insert or ignore into devices(id,user,name,kind,added_at) values(?,?,?,?,?)", [d.id, u, d.name, d.kind.rawValue, Date()]) }
			let ids = devices.map(\.id)
			if !ids.isEmpty { store.run("delete from devices where user=? and id not in (\(ids.map { _ in "?" }.joined(separator: ",")))", [u] + ids) }
			ensure(conv: stableId("home:" + u) + stableId("home2:" + u), kind: .home, name: nil, space: nil, creator: u)
		}
		emit(.me)
	}

	/// The crate's book is the book: anyone else marked a contact here is not one.
	public func keepContacts(_ users: Set<UserId>) {
		let dropped: Int = lock.withLock {
			let extra = store.query("select user from people where contact=1 and user<>?", [user]).compactMap { $0.string("user") }.filter { !users.contains($0) }
			for u in extra { store.run("update people set contact=0 where user=?", [u]) }
			return extra.count
		}
		if dropped > 0 { emit(.contacts); emit(.peers) }
	}

	/// A contact's card as the crate holds it, with the online state the crate reports per device.
	public func saveContact(user u: UserId, name n: String, fingerprint fp: String, verified: Bool, vouched: Bool = false, devices: [(id: DeviceId, name: String, kind: DeviceKind, online: Bool, path: Path)]) {
		lock.withLock {
			if vouched, !verified { store.run("update people set vouched=1 where user=?", [u]) }
			store.run("insert into people(user,name,fingerprint,verified,contact,met_at) values(?,?,?,?,1,?) on conflict(user) do update set name=excluded.name, fingerprint=excluded.fingerprint, verified=excluded.verified, contact=1, vouched=case when excluded.verified=1 then 0 else people.vouched end", [u, n, fp, verified, Date()])
			if vouched, !verified { store.run("update people set vouched=1 where user=?", [u]) }
			for d in devices { store.run("insert or ignore into devices(id,user,name,kind,added_at) values(?,?,?,?,?)", [d.id, u, d.name, d.kind.rawValue, Date()]) }
			let ids = devices.map(\.id)
			if !ids.isEmpty { store.run("delete from devices where user=? and id not in (\(ids.map { _ in "?" }.joined(separator: ",")))", [u] + ids) }
			for d in devices { liveState[d.id] = (d.online, d.path) }
		}
		emit(.contacts); emit(.peers)
	}

	/// A friend who had two identities is one now (the crate's redirect): everything the old key
	/// wrote, joined or received is the new key's, so our two chats become one (`collapse`) and one
	/// contact remains, the old name kept when the new one has none. Vouched for, not verified.
	public func redirect(from old: UserId, to new: UserId) {
		guard old != new, !old.isEmpty, !new.isEmpty else { return }
		lock.withLock {
			// My own redirect (this device joined another person) is `adoptIdentity`'s, not a friend's.
			guard new != user, old != user else { return }
			let was = store.one("select * from people where user=?", [old])
			for t in ["events", "receipts", "devices"] { store.run("update \(t) set user=? where user=?", [new, old]) }
			store.run("update or ignore members set user=? where user=?", [new, old])
			store.run("delete from members where user=?", [old])
			store.run("insert into people(user,name,fingerprint,verified,contact,met_at,vouched) values(?,?,'',0,1,?,1) on conflict(user) do update set contact=1, vouched=case when people.verified=1 then 0 else 1 end, name=case when people.name is null or people.name='' then excluded.name else people.name end",
				[new, was?.string("name") ?? "", was?.date("met_at") ?? Date()])
			store.run("delete from people where user=?", [old])
		}
		emit(.contacts); emit(.peers); emit(.conversations)
	}

	func burn(secret: String, kind: Link.Kind) throws {
		try lock.withLock {
			guard let r = store.one("select * from links where secret=? and kind=?", [secret, kind.rawValue]) else { throw CoreError.badLink }
			guard !r.bool("used") else { throw CoreError.used }
			guard (r.date("expires") ?? .distantPast) > Date() else { throw CoreError.expired }
			store.run("update links set used=1 where secret=?", [secret])
		}
	}

	func blobPath(_ hash: BlobHash) -> URL { dir.appendingPathComponent("blobs").appendingPathComponent(hash) }

	/// Over 50 MB never goes to carriers: it waits for the other side.
	func queueBigTransfers(_ conv: ConversationId, _ atts: [Attachment]) {
		let big = atts.filter { $0.size > 50 << 20 }
		guard !big.isEmpty else { return }
		let anyOnline = members(conv).contains { !$0.me && $0.online }
		lock.withLock {
			pendingTransfers[conv, default: []] += big.map { Transfer(id: $0.hash, blob: $0.hash, name: $0.name ?? "file", direction: .up, done: anyOnline ? $0.size : 0, total: $0.size, rate: 0, paused: false, waiting: !anyOnline) }
		}
	}
}

struct ChannelRef: Codable, Hashable { var conv: ConversationId; var name: String; var isDefault: Bool }

final class Sub: Subscription, @unchecked Sendable {
	let onCancel: () -> Void
	init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
	func cancel() { onCancel() }
}

/// `baud://add#…`, `baud://link#…` or the https form: the grouped form peer writes (0.2.19), the
/// seven fields after the hash, or the dotless form, one base64url token of the same.
public func parseLink(url: String) -> Link? {
	let frag = url.components(separatedBy: "#").last ?? ""
	if let l = groupedLink(frag, url: url) { return l }
	if !frag.isEmpty, !frag.contains(".") { return dotlessLink(frag, url: url) }
	let parts = frag.components(separatedBy: ".")
	guard parts.count == 7, parts[0] == "peer1", let k = Link.Kind(rawValue: parts[1]), let t = Double(parts[4]) else { return nil }
	// The crate writes the inviter's name base64url (utf-8); the stub wrote it plain. Read both.
	var b64 = parts[2].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
	while b64.count % 4 != 0 { b64 += "=" }
	let name = Data(base64Encoded: b64).flatMap { String(data: $0, encoding: .utf8) }.flatMap { $0.allSatisfy { !$0.isNewline && $0 != "\0" } && !$0.isEmpty ? $0 : nil } ?? parts[2]
	return Link(url: canonical(url), kind: k, name: name, expires: Date(timeIntervalSince1970: t))
}

/// A link's address as the app keeps it: before the `#` in lower case (a copy may have shouted
/// it), the web form as `baud://`.
private func canonical(_ url: String) -> String {
	guard let i = url.firstIndex(of: "#") else { return url }
	return (url[..<i].lowercased() + url[i...]).replacingOccurrences(of: "https://baud.rubric.sh/", with: "baud://")
}

/// peer's `Link::grouped`: base32 in one case, in groups joined by dashes, of
/// `2 | kind | name length, name | user (32) | expires (8, big-endian seconds) | secret (32) | meet`.
/// Dashes, spaces and line breaks a copy picked up don't matter.
private func groupedLink(_ token: String, url: String) -> Link? {
	let t = token.filter { $0 != "-" && !$0.isWhitespace }
	let lower = t.allSatisfy { ("a"..."z").contains($0) || ("2"..."7").contains($0) }, upper = t.allSatisfy { ("A"..."Z").contains($0) || ("2"..."7").contains($0) }
	guard !t.isEmpty, lower || upper, ![1, 3, 6].contains(t.count % 8) else { return nil }
	var d: [UInt8] = [], acc = 0, bits = 0
	for c in t.uppercased().unicodeScalars {
		acc = (acc << 5 | Int(c.value >= 65 ? c.value - 65 : c.value - 24)) & 0xFFFF
		bits += 5
		if bits >= 8 { bits -= 8; d.append(UInt8(acc >> bits & 0xFF)) }
	}
	guard d.count > 3, d[0] == 2, let k = Link.Kind(rawValue: String(UnicodeScalar(d[1]))) else { return nil }
	let n = Int(d[2]), at = 3 + n + 32
	guard n <= 64, d.count >= at + 8 + 32 + 33, let name = String(bytes: d[3..<(3 + n)], encoding: .utf8) else { return nil }
	let e = d[at..<(at + 8)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
	return Link(url: canonical(url), kind: k, name: name, expires: Date(timeIntervalSince1970: TimeInterval(e)))
}

/// `1 | kind | name length, name | user (32) | expires (8, big-endian seconds) | secret (32) | meet`.
private func dotlessLink(_ token: String, url: String) -> Link? {
	var b64 = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
	while b64.count % 4 != 0 { b64 += "=" }
	guard let d = Data(base64Encoded: b64).map(Array.init), d.count > 3, d[0] == 1, let k = Link.Kind(rawValue: String(UnicodeScalar(d[1]))) else { return nil }
	let n = Int(d[2]), at = 3 + n + 32
	guard d.count >= at + 8 + 32, let name = String(bytes: d[3..<(3 + n)], encoding: .utf8) else { return nil }
	let t = d[at..<(at + 8)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
	return Link(url: canonical(url), kind: k, name: name, expires: Date(timeIntervalSince1970: TimeInterval(t)))
}
