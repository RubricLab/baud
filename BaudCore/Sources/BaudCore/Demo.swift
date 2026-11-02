/// Demo people on the mesh around me: three contacts with devices in different states, a space
/// with channels, groups, DMs, and enough events to measure scrolling. Lee is Ana's friend, not
/// mine: Ana's "hike" group puts us together, so a stranger reached through a shared friend is on
/// screen too. They are real cores, so
/// every delivery state and path on screen is computed, not painted. `BAUD_DEMO=1` turns it on;
/// `BAUD_DEMO_EVENTS` sizes #general (default 1,200; 10,000 for the numbers).
import Foundation

public enum Demo {
	public struct People { public let ana: LocalCore, anaPhone: LocalCore, jo: LocalCore, sam: LocalCore, lee: LocalCore
		public var all: [LocalCore] { [ana, anaPhone, jo, sam, lee] } }

	/// Builds the demo once per store (skipped when demo contacts exist) and returns the people
	/// either way, so the app can toggle them online and offline from Network.
	/// What the demo people say: `.work` is the build-team chatter the app was made with; `.everyday`
	/// is friends' talk, one coherent conversation per chat and everyone online, for pictures of the
	/// app (the site's screenshots).
	public enum Talk: Sendable, Equatable {
		case work
		/// `mirror`: the same chat from the friend's side (my lines and Sam's swapped, Sam named
		/// Maya); `holdLast`: the newest line not yet sent (a "before" picture); `away`: Sam is
		/// offline when it is sent, so someone carries it; `sending`: Sam is online but hasn't
		/// got it yet (the moment between Send and Delivered).
		case everyday(mirror: Bool = false, holdLast: Bool = false, away: Bool = false, sending: Bool = false)
		var isWork: Bool { self == .work }
	}

	public static func seed(around me: LocalCore, on mesh: Mesh, events: Int, image: ((Int, Int) -> Data)? = nil, talk: Talk = .work) throws -> People {
		if me.mesh == nil { mesh.join(me) }
		me.setOnline(true)
		// Fixed keys and their own stores next to mine, so the same people come back with the
		// same ids and their own copies on every launch, like devices that were just asleep.
		func keys(_ n: UInt8) -> Keys { let k = MemoryKeys(); k.put("device-key", Data(repeating: n, count: 32)); k.put("user-key", Data(repeating: n == 4 ? 1 : n, count: 32)); return k }
		func dir(_ n: String) -> URL { let d = me.dir.appendingPathComponent("demo/\(n)"); try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true); return d }
		func make(_ n: UInt8, _ name: String, _ device: String, _ kind: DeviceKind) throws -> LocalCore {
			let c = try LocalCore(dir: dir(device), keys: keys(n), deviceName: device, kind: kind)
			mesh.join(c); c.isDemo = true
			if c.me().name.isEmpty { try c.setName(name) }
			return c
		}
		let ana = try make(1, "Ana", "Ana's Mac", .mac)
		let jo = try make(2, "Jo", "Jo's iPhone", .iphone)
		let mirrored: Bool = { if case .everyday(let m, _, _, _) = talk { return m }; return false }()
		let sam = try make(3, mirrored ? "Maya" : "Sam", mirrored ? "Maya's iPhone" : "Sam's Mac", mirrored ? .iphone : .mac)
		let lee = try make(5, "Lee", "Lee's Mac mini", .mac)
		let fresh = !me.lock.withLock { me.store.int("select count(*) as n from people where demo=1", []) > 0 }
		let anaPhone: LocalCore
		if fresh {
			for c in [ana, jo, sam] { try PairCore.meet(me, c) }
			try PairCore.meet(ana, lee)
			anaPhone = try PairCore.linkDevice(of: ana, deviceName: "Ana's iPhone", kind: .iphone, on: mesh, keys: keys(4), dir: dir("Ana's iPhone"))
			anaPhone.isDemo = true
			try fill(me: me, ana: ana, anaPhone: anaPhone, jo: jo, sam: sam, lee: lee, events: events, image: image, talk: talk)
			me.lock.withLock { me.store.run("update people set demo=1 where user in (?,?,?)", [ana.user, jo.user, sam.user]) }
		} else {
			anaPhone = try LocalCore(dir: dir("Ana's iPhone"), keys: keys(4), deviceName: "Ana's iPhone", kind: .iphone)
			mesh.join(anaPhone); anaPhone.isDemo = true
			for c in [ana, jo, sam, anaPhone, lee] { c.setOnline(true) }
		}
		// Two worlds, visibly: Ana's Mac and Jo's iPhone are online; Ana's iPhone and Sam's Mac are not.
		// (Everyday talk: all of them online, as in a picture of a good day.)
		anaPhone.setOnline(false)
		if talk.isWork { sam.setOnline(false) }
		if talk.isWork { me.lock.withLock {
			me.store.run("update devices set last_online=? where id=?", [Date().addingTimeInterval(-2 * 3600), anaPhone.device])
			me.store.run("update devices set last_online=? where id=?", [Date().addingTimeInterval(-26 * 3600), sam.device])
		} }
		me.emit(.contacts); me.emit(.peers); me.emit(.conversations)
		return People(ana: ana, anaPhone: anaPhone, jo: jo, sam: sam, lee: lee)
	}

	static func fill(me: LocalCore, ana: LocalCore, anaPhone: LocalCore, jo: LocalCore, sam: LocalCore, lee: LocalCore, events: Int, image: ((Int, Int) -> Data)?, talk: Talk = .work) throws {
		var rng = LCG(seed: 7)
		let space = try me.createSpace("rubric")
		let general = try me.createChannel(space: space.id, name: "general")
		let random = try me.createChannel(space: space.id, name: "random")
		let design = try me.createChannel(space: space.id, name: "design")
		try me.setTopic(general.id, "what we're shipping this week")
		for u in [ana, jo, sam] { try me.addMember(space.id, u.user) }
		for u in [ana, jo] { try u.join(space: space.id, channel: random.id) }
		try ana.join(space: space.id, channel: design.id)
		let weekend = try me.createGroup("weekend", users: [ana.user, jo.user])
		// Ana's group: she is friends with Lee and with me; Lee and I are not friends.
		let hike = try ana.createGroup("hike", users: [me.user, lee.user])
		let dmAna = try me.createChat([ana.user]), dmJo = try me.createChat([jo.user]), dmSam = try me.createChat([sam.user])

		// Lines read like a team talking; the pool is small on purpose so search finds things.
		let pool = ["shipping the sidebar today", "can someone look at the delivery sentence under the last message", "the subway test passed on the 6 train", "cold open is 180 ms on the M1 now", "who has the mini", "carried by Jo's Mac is my favourite line in the app", "lunch?", "pushed the icon generator", "the three-pane layout feels right", "typing indicators only when both online, as spec'd", "let's keep rows at 32 pt", "no shadows, hairlines", "what does the network screen say when a record goes grey", "I'd drop the badge there", "⌘K is fast", "reading the peer spec again", "the invite link is seven fields, everything after the hash", "we should measure keypress to screen", "10k events at 60 fps on the phone", "the carrier budget is 200 MB per device", "fourteen days and three hops", "nothing in the cloud, nothing on strangers' machines", "the Mac at home is what makes it fast", "who's online right now", "I'll be on the train in ten", "sent it, waiting for your phone", "the thread pane on the Mac is nice", "pin that", "topic updated", "can we drop the second accent colour", "monochrome everywhere now", "the composer keeps drafts per conversation", "search spans every channel", "the home conversation holds read markers", "receipts are batched, one per device per 30 s", "a group adds people by card", "a late joiner cannot ask for more", "every device owns its feed", "corrections are new events", "state resolves the same everywhere", "creator is admin", "the direct path is the product", "big files wait until you're both online", "calls ring only online devices", "there is no voicemail", "ok", "yes", "agreed", "👍", "on it", "done", "merged", "looks good", "ship it", "thanks", "nice", "tomorrow", "see you at the office", "the mini is online all day", "address records are never logged", "petnames are the UI", "groups are the only namespaces", "honest status everywhere"]
		let people = [me, ana, jo, sam]
		let start = Date().addingTimeInterval(-TimeInterval(events) * 90 * 1.1 - 3600)
		var at = start
		var lamport = 10
		var seqs: [String: Int] = [:]
		var ids: [EventId] = []
		var threadRoots: [EventId] = []
		func put(_ conv: ConversationId, by: LocalCore, _ body: MessageBody, at: Date, to cores: [LocalCore]) -> WireEvent {
			let key = conv + by.device
			let seq = (seqs[key] ?? 1000) + 1; seqs[key] = seq
			lamport += 1
			let e = WireEvent(id: stableId("\(conv)/\(by.device)/\(seq)"), conv: conv, device: by.device, seq: seq, user: by.user, at: at.timeIntervalSince1970, lamport: lamport, type: .message, text: body.text, reply: body.reply, thread: body.thread, target: nil, body: encode(body))
			for c in cores { c.applyQuietly(e) }
			if cores.contains(where: { $0 === ana }) { anaPhone.applyQuietly(e) }
			return e
		}
		func fillConv(_ conv: ConversationId, cores: [LocalCore], count: Int, step: TimeInterval, threads: Bool) {
			// Each conversation runs back from ten minutes ago, so nothing is dated in the future.
			at = Date().addingTimeInterval(-Double(count) * step * 1.1 - 600)
			for i in 0..<count {
				at = at.addingTimeInterval(step * Double(rng.next(1...20)) / 10)
				let by = cores[rng.next(0..<cores.count)]
				var body = MessageBody(text: pool[rng.next(0..<pool.count)], attachments: nil, reply: nil, thread: nil, mentions: nil)
				let roll = rng.next(0..<100)
				if roll < 4, let image, cores.count > 2 {
					let w = [1200, 800, 1600][rng.next(0..<3)], h = [800, 1000, 900][rng.next(0..<3)]
					let data = image(w, h)
					let url = FileManager.default.temporaryDirectory.appendingPathComponent("demo-\(i).png")
					try? data.write(to: url)
					if let a = try? by.addBlob(url) { body.attachments = [Attachment(hash: a.hash, key: a.key, mime: "image/png", size: a.size, name: "photo-\(i).png", width: w, height: h)]; body.text = roll < 2 ? nil : body.text }
				} else if roll < 7, let r = ids.last { body.reply = r }
				else if roll < 10 { body.mentions = [me.user]; body.text = "@\(me.name) " + (body.text ?? "") }
				else if threads, roll < 22, let root = threadRoots.last, i > 3 { body.thread = root }
				let e = put(conv, by: by, body, at: at, to: cores)
				if body.thread == nil { ids.append(e.id) }
				if threads, roll >= 90, body.thread == nil { threadRoots.append(e.id) }
				if roll >= 85, body.thread == nil, let reactor = cores.randomElement(using: &rng), reactor !== by {
					let key = ["👍", "❤️", "😂", "🔥"][rng.next(0..<4)]
					let rk = conv + reactor.device
					let seq = (seqs[rk] ?? 1000) + 1; seqs[rk] = seq
					lamport += 1
					let r = WireEvent(id: stableId("\(conv)/\(reactor.device)/\(seq)"), conv: conv, device: reactor.device, seq: seq, user: reactor.user, at: at.timeIntervalSince1970, lamport: lamport, type: .reaction, text: nil, reply: nil, thread: nil, target: e.id, body: encode(ReactionBody(target: e.id, key: key, on: true)))
					for c in cores { c.applyQuietly(r) }
					if cores.contains(where: { $0 === ana }) { anaPhone.applyQuietly(r) }
				}
			}
		}
		/// One conversation as written: (who, words or nil, a photo, a reaction someone puts on it).
		func script(_ conv: ConversationId, _ cores: [LocalCore], from ago: TimeInterval, gap: TimeInterval, _ lines: [(LocalCore, String?, Bool, (LocalCore, String)?)]) {
			at = Date().addingTimeInterval(-ago)
			for (i, line) in lines.enumerated() {
				at = at.addingTimeInterval(gap * Double(rng.next(4...14)) / 10)
				var body = MessageBody(text: line.1, attachments: nil, reply: nil, thread: nil, mentions: nil)
				if line.2, let image {
					let url = FileManager.default.temporaryDirectory.appendingPathComponent("demo-everyday-\(i).png")
					try? image(1200, 900).write(to: url)
					if let a = try? line.0.addBlob(url) { body.attachments = [Attachment(hash: a.hash, key: a.key, mime: "image/png", size: a.size, name: "IMG_\(4100 + i).png", width: 1200, height: 900)] }
				}
				let e = put(conv, by: line.0, body, at: at, to: cores)
				if let (reactor, key) = line.3 {
					let rk = conv + reactor.device
					let seq = (seqs[rk] ?? 1000) + 1; seqs[rk] = seq
					lamport += 1
					let r = WireEvent(id: stableId("\(conv)/\(reactor.device)/\(seq)"), conv: conv, device: reactor.device, seq: seq, user: reactor.user, at: at.timeIntervalSince1970, lamport: lamport, type: .reaction, text: nil, reply: nil, thread: nil, target: e.id, body: encode(ReactionBody(target: e.id, key: key, on: true)))
					for c in cores { c.applyQuietly(r) }
					if cores.contains(where: { $0 === ana }) { anaPhone.applyQuietly(r) }
				}
			}
		}
		let all = [me, ana, jo, sam], everyone = [me, ana, anaPhone, jo, sam, lee]
		for c in everyone { c.store.exec("begin") }
		fillConv(general.id, cores: all, count: events, step: 90, threads: true)
		fillConv(random.id, cores: [me, ana, jo], count: max(12, events / 40), step: 600, threads: true)
		fillConv(design.id, cores: [me, ana], count: max(8, events / 80), step: 900, threads: false)
		if case .everyday(let mirror, _, _, _) = talk {
			// The friend's side: Sam's lines are mine and mine are Sam's.
			let (I, S) = mirror ? (sam, me) : (me, sam)
			script(weekend.id, [me, ana, jo], from: 30 * 3600, gap: 1800, [(ana, "cabin is booked 🏡", false, (jo, "🙌")), (jo, "who's driving?", false, nil), (me, "I can drive", false, nil), (ana, "I'll do groceries", false, nil), (jo, "bringing the speaker", false, nil)])
			script(hike.id, [me, ana, lee], from: 50 * 3600, gap: 2400, [(ana, "trail map is in the group", false, nil), (lee, "I'll bring snacks", false, nil), (me, "see you at the station", false, nil)])
			script(dmAna.id, [me, ana], from: 20 * 3600, gap: 900, [(ana, "landed 🛬", false, nil), (me, "welcome back!! how was lisbon?", false, nil), (ana, "unreal. the light there", false, nil), (ana, nil, true, (me, "😍")), (me, "ok that's not fair", false, nil), (ana, "I'll tell you everything", false, nil)])
			script(dmJo.id, [me, jo], from: 2 * 3600, gap: 900, [(jo, "did you get the tickets?", false, nil), (me, "two, row F", false, (jo, "🔥")), (jo, "you're the best", false, nil)])
			script(dmSam.id, [me, sam], from: 80 * 60, gap: 400, [(S, "you around this weekend?", false, nil), (I, "yes! what's up", false, nil), (S, "hike saturday, then dinner?", false, nil), (S, nil, true, (I, "😍")), (I, "that view", false, nil), (S, "leaves at 8 from the station", false, (I, "👍")), (I, "I'll bring coffee ☕️", false, nil), (S, "legend", false, nil), (I, "dinner after at mine?", false, nil), (S, "yes!! I'll bring dessert", false, nil)])
		} else {
			fillConv(weekend.id, cores: [me, ana, jo], count: max(10, events / 50), step: 1200, threads: false)
			fillConv(hike.id, cores: [me, ana, lee], count: max(8, events / 80), step: 1500, threads: false)
			fillConv(dmAna.id, cores: [me, ana], count: max(14, events / 30), step: 500, threads: false)
			fillConv(dmJo.id, cores: [me, jo], count: max(8, events / 60), step: 800, threads: false)
			fillConv(dmSam.id, cores: [me, sam], count: max(6, events / 100), step: 2000, threads: false)
		}
		_ = all
		// The conversations were made just now but their messages run back days: date the
		// creation and membership lines before the first message so the day lines read true.
		let convs = [space.id, general.id, random.id, design.id, weekend.id, hike.id, dmAna.id, dmJo.id, dmSam.id]
		for c in everyone {
			c.store.run("update events set at=? where type in ('create','member','state') and conv in (\(convs.map { _ in "?" }.joined(separator: ",")))", [start.addingTimeInterval(-60)] + convs)
			c.store.exec("commit")
		}
		// Everyone has read everything but my last few lines; the online devices have those.
		for (conv, cores) in [(general.id, all), (random.id, [me, ana, jo]), (design.id, [me, ana]), (weekend.id, [me, ana, jo]), (hike.id, [me, ana, lee]), (dmAna.id, [me, ana]), (dmJo.id, [me, jo]), (dmSam.id, [me, sam])] {
			let mine = me.lock.withLock { me.store.query("select id, lamport from events where conv=? and type='message' order by lamport desc limit 3", [conv]) }
			guard let cut = mine.last?.int("lamport") else { continue }
			for c in cores where c !== me {
				me.apply(receipt: WireReceipt(conv: conv, device: c.device, user: c.user, event: mine.last!.string("id")!, lamport: cut - 1, kind: "read", at: Date().timeIntervalSince1970))
				for r in mine.dropLast() where c.mesh?.isOnline(c.device) == true {
					me.apply(receipt: WireReceipt(conv: conv, device: c.device, user: c.user, event: r.string("id")!, lamport: r.int("lamport") ?? 0, kind: "delivered", at: Date().timeIntervalSince1970))
				}
			}
			me.lock.withLock { me.store.run("insert or replace into reads(conv,event,lamport) values(?,?,?)", [conv, mine.first?.string("id"), (mine.first?.int("lamport") ?? 0) - (conv == general.id ? 6 : 0)]) }
		}
		if case .everyday(let mirror, let holdLast, let away, let sending) = talk {
			// The newest lines, sent for real so their delivery is real: mine to Sam (or, from the
			// friend's side, Maya's to me); held back for a "before" picture.
			anaPhone.setOnline(false)
			if away || sending { sam.setOnline(false) }
			if !holdLast { _ = try (mirror ? sam : me).send(dmSam.id, Draft(text: "see you saturday ✌️")) }
			if sending, let mesh = me.mesh { mesh.setOnline(sam, true, sync: false) }
			_ = try ana.send(dmAna.id, Draft(text: "dinner thursday?"))
			_ = try jo.send(weekend.id, Draft(text: "who's in for saturday?"))
			return
		}
		// One line to Sam, carried by Ana's Mac while Sam is away: the sentence the product exists for.
		sam.setOnline(false); anaPhone.setOnline(false)
		_ = try me.send(dmSam.id, Draft(text: "sent this while you were out; Ana's Mac is holding it for you"))
		_ = try ana.send(dmAna.id, Draft(text: "back online, catching up"))
		_ = try jo.send(weekend.id, Draft(text: "who's in for saturday?"))
	}
}

extension LocalCore {
	/// Seed-time insert: the feed entry and its state, without posting or emitting.
	func applyQuietly(_ e: WireEvent) {
		let saved = listeners; listeners = [:]
		apply(e, carriedBy: nil)
		listeners = saved
	}
}

struct LCG: RandomNumberGenerator {
	var state: UInt64
	init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
	mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
	mutating func next(_ r: Range<Int>) -> Int { r.lowerBound + Int(next() >> 33) % r.count }
	mutating func next(_ r: ClosedRange<Int>) -> Int { next(r.lowerBound..<(r.upperBound + 1)) }
}
