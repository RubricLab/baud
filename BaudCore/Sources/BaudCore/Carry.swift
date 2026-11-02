/// The transport side of `LocalCore`: posting a frame to a device now or to a carrier, receiving
/// frames, syncing feeds on connect, and the delivery rows that make "carried by Jo's Mac" true.
/// On the crate this is `Peer.connect/post/inbox`; the shapes here are the ones it will fill.
import Foundation

extension LocalCore {
	/// Direct if the device is online; otherwise sealed and handed to every online device that
	/// holds its card (own devices first); otherwise it waits here for the next connection.
	func post(_ frame: Frame, to d: DeviceId, conv: ConversationId, joiner: Bool = false) {
		if let t = transport, mesh?.core(d) == nil {
			// The crate: live if it can, else sealed to carriers; the answer comes back later. A frame
			// to another device of mine carries the conversation's key too (it is me, over the
			// crate's device-to-device encryption): a device that just became mine can open my chats,
			// my chat with myself and the colour in it.
			let own = lock.withLock { store.int("select count(*) as n from devices where id=? and user=?", [d, user]) > 0 }
			let bytes = seal(frame, conv: conv.isEmpty ? nil : conv, joiner: joiner || own)
			let events: [EventId] = { if case .events(let es) = frame { return es.map(\.id) }; return [] }()
			Task { [weak self] in
				guard let self else { return }
				if t.isOnline(d), await t.send(bytes, to: d) { return }
				// A co-member who isn't a friend: no card, so no connection and no carriers. Someone
				// in the conversation who holds both cards passes it on, now.
				if !conv.isEmpty, !t.reaches(d), await self.relay(bytes, to: d, conv: conv, t) { return }
				let carriers = await t.post(bytes, to: d, ttl: 14 * 86_400)
				// Asleep: wake it for a message someone else wrote (never for my own, syncing to my phone).
				if case .events(let es) = frame, let theirs = self.user(of: d), es.contains(where: { $0.type == .message && $0.user != theirs }) {
					Task { await self.wake(d, .message) }
				}
				for c in carriers { for e in events { self.lock.withLock { self.store.run("insert or ignore into handed(event,to_device,carrier,at) values(?,?,?,?)", [e, d, c, Date()]) } } }
				if !conv.isEmpty { emit(.delivery(conv)) }
			}
			return
		}
		guard let mesh else { return }
		if online, mesh.send(frame, from: device, to: d) { return }
		let size = encode(frame).utf8.count
		for carrier in carriers(for: d) {
			let env = WireEnvelope(id: hex(randomBytes(8)), to: d, from: device, conv: conv, frame: frame, size: size, expires: Date().addingTimeInterval(14 * 86_400).timeIntervalSince1970, hops: 1)
			guard mesh.send(.envelope(env), from: device, to: carrier) else { continue }
			if case .events(let es) = frame { for e in es { lock.withLock { store.run("insert or ignore into handed(event,to_device,carrier,at) values(?,?,?,?)", [e.id, d, carrier, Date()]) } } }
		}
		emit(.delivery(conv))
	}

	/// Sealed bytes for a co-member I hold no card for, handed to members I'm connected to (at most
	/// two, not mine: my devices hold the same book) to pass on. True when one took it.
	func relay(_ bytes: Data, to d: DeviceId, conv: ConversationId, _ t: Transport) async -> Bool {
		let theirs = user(of: d)
		let via: [DeviceId] = lock.withLock {
			store.query("select d.id from devices d join members m on m.user=d.user where m.conv=? and d.user<>? and d.user<>?", [conv, user, theirs ?? ""]).compactMap { $0.string("id") }
		}.filter { t.isOnline($0) }
		var took = false
		for v in via.prefix(2) where await t.send(seal(.relay(d, bytes), conv: nil), to: v) { took = true }
		trace("relay to \(d.prefix(8)) in \(conv.prefix(8)) via \(via.prefix(2).map { $0.prefix(8) }): \(took ? "taken" : "nobody")")
		return took
	}

	/// A member asks me to pass sealed bytes to another: only within a conversation all three of us
	/// are in, and only to a device whose card I hold.
	func relayed(_ bytes: Data, to d: DeviceId, from: DeviceId) {
		guard let t = transport, t.reaches(d), let conv = (try? unjson.decode(Packet.self, from: bytes))?.conv,
			  let a = user(of: from), let b = user(of: d) else { return }
		let members = lock.withLock { Set(store.query("select user from members where conv=?", [conv]).compactMap { $0.string("user") }) }
		guard members.contains(user), members.contains(a), members.contains(b) else { trace("relay refused: \(from.prefix(8)) to \(d.prefix(8)) outside \(conv.prefix(8))"); return }
		Task {
			if t.isOnline(d), await t.send(bytes, to: d) { return }
			_ = await t.post(bytes, to: d, ttl: 14 * 86_400)
		}
	}

	/// Online devices, not mine and not the recipient, that list the recipient in a card they hold.
	func carriers(for d: DeviceId) -> [DeviceId] {
		guard let mesh, online else { return [] }
		let own = lock.withLock { Set(store.query("select id from devices where user=?", [user]).compactMap { $0.string("id") }) }
		return mesh.devices.filter { $0 != device && $0 != d && mesh.isOnline($0) && (mesh.core($0)?.knows(d) ?? false) }
			.sorted { own.contains($0) && !own.contains($1) }
	}

	public func user(of d: DeviceId) -> UserId? { lock.withLock { store.one("select user from devices where id=?", [d])?.string("user") } }
	func knows(_ d: DeviceId) -> Bool { lock.withLock { store.int("select count(*) as n from devices where id=?", [d]) > 0 } }
	func heldCount(for d: DeviceId) -> Int { lock.withLock { store.int("select count(*) as n from envelopes where to_device=?", [d]) } }

	/// Tell every device I know (my own, my contacts', my co-members') something small.
	func tell(_ frame: Frame) {
		let all = lock.withLock { store.query("select id from devices where id<>?", [device]).compactMap { $0.string("id") } }
		for d in all { post(frame, to: d, conv: "") }
	}

	func receive(_ frame: Frame, from: DeviceId, carriedBy: DeviceId?) {
		lock.withLock { store.run("update devices set last_online=? where id=?", [Date(), from]) }
		switch frame {
		case .events(let es):
			var touched = Set<ConversationId>()
			var stoppedTyping = Set<ConversationId>()
			// An event that reached me from a device other than its writer was carried by that device.
			for e in es where apply(e, carriedBy: carriedBy ?? (from != e.device ? from : nil)) {
				touched.insert(e.conv)
				// Their message is here: they are no longer typing it.
				if e.type == .message, lock.withLock({ typingSeen[e.conv]?.removeValue(forKey: e.user) }) != nil { stoppedTyping.insert(e.conv) }
				guard e.type == .message, e.user != user else { continue }
				let r = WireReceipt(conv: e.conv, device: device, user: user, event: e.id, lamport: e.lamport, kind: "delivered", at: Date().timeIntervalSince1970)
				apply(receipt: r)
				for d in lock.withLock({ store.query("select id from devices where user=(select user from devices where id=?)", [e.device]).compactMap { $0.string("id") } }) where d != device { post(.receipt(r), to: d, conv: e.conv) }
			}
			if !touched.isEmpty { emit(.conversations) }
			for c in stoppedTyping { emit(.typing(c)) }
			prefetch(es)
		case .receipt(let r):
			apply(receipt: r)
		case .typing(let conv, let u):
			lock.withLock { typingSeen[conv, default: [:]][u] = Date() }
			emit(.typing(conv))
		case .envelope(let env):
			if env.to == device { receive(env.frame, from: env.from, carriedBy: from); mesh?.send(.ack(env.id), from: device, to: from) }
			else {
				lock.withLock { store.run("insert or ignore into envelopes(id,to_device,from_device,conv,frame,size,expires,hops,held_at) values(?,?,?,?,?,?,?,?,?)", [env.id, env.to, env.from, env.conv, encode(env.frame), env.size, env.expires, env.hops, Date()]) }
				emit(.carrying)
			}
		case .ack(let id):
			lock.withLock { store.run("delete from envelopes where id=?", [id]) }
			emit(.carrying)
		case .card(let c):
			let contact = lock.withLock { store.int("select count(*) as n from people where user=? and contact=1", [c.user]) > 0 }
			lock.withLock { save(card: c, contact: contact) }
			emit(.contacts); emit(.peers)
		case .welcome(let c):
			lock.withLock { save(card: c, contact: true) }
			emit(.contacts); emit(.peers)
		case .clock(let conv, let theirs), .clockReply(let conv, let theirs):
			// They told me what they hold: send what they lack from every feed I have, and my
			// receipts. If they hold anything I lack (a conversation I have never seen included),
			// my clock goes back once so they send it; a reply is never answered, so it ends there.
			let mine = clock(conv)
			let missing: [WireEvent] = lock.withLock {
				mine.filter { $0.value > (theirs[$0.key] ?? 0) }.flatMap { d, _ in store.query("select * from events where conv=? and device=? and seq>? order by seq", [conv, d, theirs[d] ?? 0]) }
					.sorted { ($0.int("lamport") ?? 0, $0.string("id")!) < ($1.int("lamport") ?? 0, $1.string("id")!) }.map(wire(row:))
			}
			if !missing.isEmpty { post(.events(missing), to: from, conv: conv) }
			let receipts = lock.withLock { store.query("select * from receipts where conv=? and device=?", [conv, device]) }
			for r in receipts { post(.receipt(WireReceipt(conv: conv, device: device, user: user, event: r.string("event")!, lamport: r.int("lamport") ?? 0, kind: r.string("kind") ?? "delivered", at: r.double("at") ?? 0)), to: from, conv: conv) }
			if case .clock = frame, theirs.contains(where: { $0.value > (mine[$0.key] ?? 0) }) { post(.clockReply(conv, mine), to: from, conv: conv) }
		case .relay(let to, let bytes):
			relayed(bytes, to: to, from: from)
		case .inCall(let conv, let p):
			onCallPresence?(conv, p)
		case .wake(let ticket, let expires):
			keepWake(ticket, expires: expires, from: from)
		case .place(let conv, let p):
			keep(place: p, conv: conv, from: from)
		case .want(let hash):
			wanted(hash, by: from)
		case .offer(let hash, let id):
			offered(hash, id: id, by: from)
		case .hello, .link:
			break // handled synchronously by hello(…) and admit(…)
		}
	}

	func apply(receipt r: WireReceipt) {
		// Read on another device of mine is read here: the chat's unread follows me.
		let readHere: Bool = lock.withLock {
			store.run("insert or ignore into receipts(conv,device,user,event,lamport,kind,at) values(?,?,?,?,?,?,?)", [r.conv, r.device, r.user, r.event, r.lamport, r.kind, r.at])
			guard r.kind == "read", r.user == user, r.device != device, (store.one("select lamport from reads where conv=?", [r.conv])?.int("lamport") ?? -1) < r.lamport else { return false }
			store.run("insert or replace into reads(conv,event,lamport) values(?,?,?)", [r.conv, r.event, r.lamport])
			return true
		}
		// Read by me, here or on another device of mine: disappearing messages start their clocks.
		if r.kind == "read", r.user == user { startClocks(r.conv, upTo: r.lamport, at: r.at) }
		emit(.delivery(r.conv))
		if readHere { emit(.conversations) }
	}

	/// On connect: everything the other device is missing in every conversation we share, my
	/// receipts for it, and every envelope I hold for it.
	func sync(with other: LocalCore, only: ConversationId? = nil) {
		guard online, mesh?.isOnline(other.device) == true else { return }
		// Shared as this device sees it: a conversation I'm in whose member list names their user.
		let shared: [(ConversationId, Double)] = lock.withLock {
			store.query("select a.conv, b.joined_at, c.kind from members a join members b on b.conv=a.conv join conversations c on c.id=a.conv where a.user=? and b.user=?", [user, other.user])
				.filter { only == nil || $0.string("conv") == only }
				.map { ($0.string("conv")!, $0.string("kind") == "chat" ? ($0.double("joined_at") ?? 0) : 0) }
		}
		for (conv, fromJoin) in shared {
			// Their clock against mine, per feed: a no-op sync reads nothing but two small indexes.
			let theirs = other.clock(conv), mine = clock(conv)
			let missing: [WireEvent] = lock.withLock {
				mine.filter { $0.value > (theirs[$0.key] ?? 0) }.sorted { $0.key < $1.key }.flatMap { d, _ in
					store.query("select * from events where conv=? and device=? and seq>? order by seq", [conv, d, theirs[d] ?? 0])
				}
				.filter { ($0.double("at") ?? 0) >= fromJoin - 1 || $0.string("type") != "message" }
				.sorted { ($0.int("lamport") ?? 0, $0.string("id")!) < ($1.int("lamport") ?? 0, $1.string("id")!) }
				.map(wire(row:))
			}
			if !missing.isEmpty { other.receive(.events(missing), from: device, carriedBy: nil) }
			// Receipts of mine they don't have yet: compare counts first so steady state costs one query.
			let n = lock.withLock { store.int("select count(*) as n from receipts where conv=? and device=?", [conv, device]) }
			if n > other.lock.withLock({ other.store.int("select count(*) as n from receipts where conv=? and device=?", [conv, device]) }) {
				let receipts = lock.withLock { store.query("select * from receipts where conv=? and device=?", [conv, device]) }
				for r in receipts {
					other.apply(receipt: WireReceipt(conv: conv, device: device, user: user, event: r.string("event")!, lamport: r.int("lamport") ?? 0, kind: r.string("kind") ?? "delivered", at: r.double("at") ?? 0))
				}
			}
		}
		let held = lock.withLock { store.query("select * from envelopes where to_device=?", [other.device]) }
		for h in held {
			guard let f = decode(Frame.self, h.string("frame")) else { continue }
			other.receive(f, from: h.string("from_device") ?? device, carriedBy: device)
			lock.withLock { store.run("delete from envelopes where id=?", [h.string("id")!]) }
		}
		if !held.isEmpty { emit(.carrying); emit(.peers) }
	}

	func clock(_ conv: ConversationId) -> [DeviceId: Int] {
		lock.withLock { Dictionary(uniqueKeysWithValues: store.query("select device, max(seq) as s from events where conv=? group by device", [conv]).map { ($0.string("device")!, $0.int("s") ?? 0) }) }
	}
	func wire(row r: Row) -> WireEvent {
		WireEvent(id: r.string("id")!, conv: r.string("conv")!, device: r.string("device")!, seq: r.int("seq") ?? 0, user: r.string("user") ?? "", at: r.double("at") ?? 0, lamport: r.int("lamport") ?? 0, type: EventType(rawValue: r.string("type") ?? "message") ?? .message, text: r.string("text"), reply: r.string("reply"), thread: r.string("thread"), target: r.string("target"), body: r.string("body") ?? "{}")
	}

	func peerChanged(_ d: DeviceId, online on: Bool) {
		let known = knows(d)
		if !on, known { lock.withLock { store.run("update devices set last_online=? where id=?", [Date(), d]) } }
		if known { emit(.peers); emit(.contacts); emit(.conversations) }
	}

	// MARK: meeting

	/// The inviter's side of the handshake: check and burn the secret, save their card, make the chat, answer with mine.
	func hello(secret: String, card: WireCard, from other: LocalCore) throws {
		try burn(secret: secret, kind: .friend)
		lock.withLock { save(card: card, contact: true) }
		emit(.contacts); emit(.peers)
		mesh?.send(.welcome(card: self.card()), from: device, to: other.device)
		_ = try createChat([card.user])
	}

	/// The old device's side of linking: burn the secret, list the new device in my card, tell everyone.
	func admit(secret: String, device d: WireDevice) throws {
		try burn(secret: secret, kind: .device)
		lock.withLock { store.run("insert or replace into devices(id,user,name,kind,added_at) values(?,?,?,?,?)", [d.id, user, d.name, d.kind.rawValue, d.addedAt]) }
		tell(.card(card()))
		emit(.me); emit(.peers)
	}

	/// After linking: contacts, then every conversation from its start (the new device is mine, so it gets everything).
	func handOver(to new: LocalCore) {
		let cards = lock.withLock { store.query("select user from people where contact=1 and user<>?", [user]).compactMap { $0.string("user") }.compactMap(cardOf) }
		for c in cards { new.receive(.welcome(card: c), from: device, carriedBy: nil) }
		let convs = lock.withLock { store.query("select distinct conv from members where user=?", [user]).compactMap { $0.string("conv") } }
		for conv in convs {
			let all = lock.withLock { store.query("select * from events where conv=? order by lamport, id", [conv]).map(wire(row:)) }
			new.receive(.events(all), from: device, carriedBy: nil)
			let reads = lock.withLock { store.one("select * from reads where conv=?", [conv]) }
			if let r = reads { new.lock.withLock { new.store.run("insert or replace into reads(conv,event,lamport) values(?,?,?)", [conv, r.string("event"), r.int("lamport") ?? 0]) } }
		}
	}

	// MARK: delivery

	public func delivery(_ conv: ConversationId, _ ev: EventId) -> Delivery {
		lock.withLock {
			guard let e = store.one("select lamport, user from events where id=?", [ev]) else { return Delivery(event: ev, devices: []) }
			let l = e.int("lamport") ?? 0
			let names = Dictionary(uniqueKeysWithValues: store.query("select user, name from people").map { ($0.string("user")!, $0.string("name") ?? "?") })
			let members = store.query("select user from members where conv=? and user<>?", [conv, user]).compactMap { $0.string("user") }
			var out: [DeviceDelivery] = []
			for u in members {
				let readL = store.one("select max(lamport) as l from receipts where conv=? and user=? and kind='read'", [conv, u])?.int("l") ?? -1
				for d in devices(of: u) {
					let state: DeliveryState
					var carriers: [String] = []
					if readL >= l { state = .read }
					else if store.int("select count(*) as n from receipts where conv=? and device=? and event=? and kind='delivered'", [conv, d.id, ev]) > 0 { state = .delivered }
					else if let hs = Optional(store.query("select h.carrier, d.kind, d.user from handed h left join devices d on d.id=h.carrier where h.event=? and h.to_device=?", [ev, d.id])), !hs.isEmpty {
						carriers = hs.map { "\($0.string("user") == user ? "your" : (names[$0.string("user") ?? ""] ?? "someone") + "'s") \(kindWord($0.string("kind")))" }.sorted { ($0.hasPrefix("your") ? "" : $0) < ($1.hasPrefix("your") ? "" : $1) }
						state = .carried(by: hs[0].string("carrier") ?? "")
					} else { state = .sent }
					out.append(DeviceDelivery(device: d, personName: names[u] ?? "?", state: state, carriers: carriers))
				}
			}
			return Delivery(event: ev, devices: out)
		}
	}
}

func kindWord(_ kind: String?) -> String {
	switch kind {
	case "iphone": "iPhone"
	case "android": "phone"
	case "node": "device"
	default: "Mac"
	}
}
