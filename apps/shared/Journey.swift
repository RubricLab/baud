/// Two processes, one machine, no demo people: `BAUD_JOURNEY=host` writes its invite link to
/// `BAUD_LINK_FILE` and says whatever arrives; `BAUD_JOURNEY=guest` waits for that file, adds
/// the link, and sends `BAUD_SAY`. Everything they see goes to stderr, so the proof is a log.
/// `BAUD_SEND_FILE=a,b` on the guest sends those files with it; the host fetches each one as it
/// arrives and logs its size, the time it took and whether its hash matches.
import BaudCore
import Foundation

enum Journey {
	@MainActor static var fetching = Set<String>()
	/// A file that arrived in a message: fetched, timed, and checked against its hash.
	@MainActor static func fetch(_ a: Attachment, role: String, model: AppModel) {
		let t0 = Date()
		Task {
			do {
				let url = try await model.core.blob(a.hash, key: a.key)
				let ok = (try? fileHash(url)) == a.hash
				Measure.log("\(role): file \(a.name ?? "?") \(a.mime) \(a.size) bytes\(a.width.map { " \($0)x\(a.height ?? 0)" } ?? "") arrived in \(Int(Date().timeIntervalSince(t0) * 1000)) ms, hash \(ok ? "ok" : "MISMATCH")")
			} catch { Measure.log("\(role): file \(a.name ?? "?") never came: \(error)") }
		}
	}
	@MainActor static func run(_ model: AppModel) {
		let env = ProcessInfo.processInfo.environment
		// `BAUD_NAME_LATE=x` types a name two seconds in, through the same path a tap takes: the
		// first screen must move on by itself (it didn't on the real iPhone before the fix).
		if let late = env["BAUD_NAME_LATE"] { Task { @MainActor in try? await Task.sleep(for: .seconds(2)); model.setName(late); Measure.log("late name set; named=\(model.named)") } }
		// `BAUD_SEED=Sam|/a.jpg,/b.pdf` (demo pictures): those files and two reactions in that chat.
		if let seed = env["BAUD_SEED"]?.split(separator: "|"), seed.count == 2 {
			Task { @MainActor in
				for _ in 0..<40 {
					try? await Task.sleep(for: .milliseconds(250))
					guard let c = model.conversations.first(where: { model.title($0) == String(seed[0]) }) else { continue }
					model.attempt {
						let e = try model.core.send(c.id, Draft(text: "the cabin, and the plan for saturday", attachments: seed[1].split(separator: ",").map { URL(fileURLWithPath: String($0)) }))
						try model.core.react(c.id, e.id, "🔥", on: true); try model.core.react(c.id, e.id, "🏔️", on: true)
					}
					return
				}
			}
		}
		guard let role = env["BAUD_JOURNEY"], let file = env["BAUD_LINK_FILE"] else { return }
		let say = env["BAUD_SAY"] ?? "hello from the other side"
		_ = model.core.subscribe { c in
			Task { @MainActor in
				switch c {
				case .contacts: Measure.log("\(role) contacts: \(model.core.contacts().map { "\($0.name) \($0.sentence)" })")
				case .conversation(let id):
					let last = model.core.events(id, before: nil, limit: 1).last
					let title = model.core.conversation(id).map(model.title) ?? "conv \(id.prefix(8)) (no row yet)"
					if let last, last.type != .message { Measure.log("\(role) \(title): \(last.system ?? last.type.rawValue) · members \(model.core.members(id).count)") }
					if let last, last.type == .message { Measure.log("\(role) \(title): \(last.mine ? "me" : model.name(of: last.user)): \(last.text ?? "") \(last.carriedBy.map { "(carried by \($0.prefix(8)))" } ?? "") · delivery: \(model.core.delivery(id, last.id).sentence)") }
					if let last, last.type == .message, !last.mine { for a in last.attachments where fetching.insert(a.hash).inserted { fetch(a, role: role, model: model) } }
				case .peers: Measure.log("\(role) peers: \(model.core.peers().map { "\($0.device.name) \($0.device.sentence)" })")
				case .delivery(let id):
					if let last = model.core.events(id, before: nil, limit: 1).last, last.mine { Measure.log("\(role) delivery now: \(model.core.delivery(id, last.id).sentence)") }
				default: break
				}
			}
		}
		// After the meeting has settled: how many direct chats each side keeps, and how many it shows.
		Task { @MainActor in
			try? await Task.sleep(for: .seconds(Double(env["BAUD_REPORT_CHATS_AT"] ?? "30") ?? 30))
			for k in model.core.contacts() {
				let shown = model.core.conversations(.chat).filter { $0.isDirect && $0.members.contains(k.user) }
				Measure.log("\(role) chats with \(k.name): stored \(model.local.directChatCount(with: k.user)), shown \(shown.count) \(shown.map { String($0.id.prefix(8)) }) · \(shown.first.map { model.core.events($0.id, before: nil, limit: 50).filter { $0.type == .message }.compactMap(\.text) } ?? [])")
			}
		}
		// `BAUD_PHOTO=<path>`: this side sets a photo once it has a friend. Either way, each side
		// reports its friends' photos as it learns them: the hash on the card, then the picture.
		Task { @MainActor in
			var seen: Set<String> = []
			for _ in 0..<45 {
				try? await Task.sleep(for: .seconds(2))
				if let photo = env["BAUD_PHOTO"], !model.core.contacts().isEmpty || model.core.me().devices.count > 1, model.core.me().avatar == nil {
					do { try model.core.setAvatar(URL(fileURLWithPath: photo)); Measure.log("\(role): photo set \(model.core.me().avatar?.prefix(8) ?? "-")") }
					catch { Measure.log("\(role): photo failed \(error)") }
				}
				let people = model.core.contacts().map { ($0.name, $0.avatar) } + [("me", model.core.me().avatar)]
				for (name, avatar) in people {
					guard let h = avatar, env["BAUD_PHOTO"] == nil || name != "me", seen.insert(h).inserted else { continue }
					let t = Date()
					let url = try? await model.core.blob(h, key: "")
					Measure.log("\(role): photo of \(name) \(h.prefix(8)) \(url == nil ? "didn't come" : "is here in \(Int(Date().timeIntervalSince(t) * 1000)) ms")")
				}
			}
		}
		Measure.log("journey \(role): starting")
		Task { @MainActor in
			try? await Task.sleep(for: .seconds(4))
			Measure.log("journey \(role): going")
			if role.hasSuffix("3") { await three(role, model: model, file: file, say: say); return }
			if role.hasPrefix("merge-") { await merge(role, model: model, file: file, say: say); return }
			if role.hasPrefix("own-") { await own(role, model: model, file: file); return }
			if role.hasPrefix("group-") { await group(role, model: model, file: file); return }
			if role == "host" {
				guard let link = try? model.core.invite() else { Measure.log("host: invite failed"); return }
				try? link.url.write(toFile: file, atomically: true, encoding: .utf8)
				Measure.log("host: invite written to \(file)")
			} else {
				var url: String?
				for _ in 0..<60 { url = try? String(contentsOfFile: file, encoding: .utf8); if url != nil { break }; try? await Task.sleep(for: .seconds(1)) }
				guard let url, let link = parseLink(url: url.trimmingCharacters(in: .whitespacesAndNewlines)) else { Measure.log("guest: no link"); return }
				do {
					let c = try await model.core.add(link)
					Measure.log("guest: added \(c.name), \(c.sentence)")
					// `BAUD_RACE_CHAT=1`: open a chat at once, racing the host's, the way a person tapping
					// the new friend did (two "TEST" chats, 0.1.10); both sides must still show one.
					if env["BAUD_RACE_CHAT"] != nil { model.local.forceDirectChat(with: c.user); Measure.log("guest: raced a chat with \(c.name)") }
					let files = (env["BAUD_SEND_FILE"] ?? "").split(separator: ",").map { URL(fileURLWithPath: String($0)) }
					for _ in 0..<30 { if let chat = model.core.conversations(.chat).first { model.send(chat.id, Draft(text: say, attachments: files)); Measure.log("guest: sent '\(say)' with \(files.count) files"); break }; try? await Task.sleep(for: .seconds(1)) }
				} catch let e as CoreError { Measure.log("guest: add failed: \(e.sentence)") } catch { Measure.log("guest: add failed: \(error)") }
			}
		}
	}
}

/// Three devices over the crate (runs once the crate's groups bindings land): the host invites
/// two friends who are not each other's contacts, makes a space with #general, adds both; the
/// third goes offline; the guest posts; the host shows it direct and the sentence names the host
/// as carrier for the third; the third returns and sees `carried by Host's Mac`.
///   BAUD_JOURNEY=host3   writes <file>.b and <file>.c (two invite links)
///   BAUD_JOURNEY=guest3  adds <file>.b, waits for #general, sends BAUD_SAY
///   BAUD_JOURNEY=third3  adds <file>.c, goes offline after BAUD_OFFLINE_AT seconds, back after BAUD_ONLINE_AT
extension Journey {
	@MainActor static func three(_ role: String, model: AppModel, file: String, say: String) async {
		let env = ProcessInfo.processInfo.environment
		switch role {
		case "host3":
			guard let b = try? model.core.invite(), let c = try? model.core.invite() else { Measure.log("host3: invite failed"); return }
			try? b.url.write(toFile: file + ".b", atomically: true, encoding: .utf8)
			try? c.url.write(toFile: file + ".c", atomically: true, encoding: .utf8)
			Measure.log("host3: two invites written")
			// Both friends in, then the space with its default channel and both as members.
			for _ in 0..<60 { if model.core.contacts().count >= 2 { break }; try? await Task.sleep(for: .seconds(1)) }
			guard model.core.contacts().count >= 2 else { Measure.log("host3: friends never came"); return }
			model.attempt {
				let space = try model.core.createSpace("rubric")
				let general = try model.core.createChannel(space: space.id, name: "general")
				for k in model.core.contacts() { try model.core.addMember(space.id, k.user) }
				Measure.log("host3: space + #general with \(model.core.members(general.id).count) members")
			}
		case "guest3", "third3":
			let which = role == "guest3" ? ".b" : ".c"
			var url: String?
			for _ in 0..<60 { url = try? String(contentsOfFile: file + which, encoding: .utf8); if url != nil { break }; try? await Task.sleep(for: .seconds(1)) }
			guard let url, let link = parseLink(url: url.trimmingCharacters(in: .whitespacesAndNewlines)) else { Measure.log("\(role): no link"); return }
			do { let k = try await model.core.add(link); Measure.log("\(role): added \(k.name)") } catch { Measure.log("\(role): add failed: \(error)"); return }
			if role == "third3" {
				let off = Double(env["BAUD_OFFLINE_AT"] ?? "20") ?? 20, on = Double(env["BAUD_ONLINE_AT"] ?? "45") ?? 45
				try? await Task.sleep(for: .seconds(off)); model.core.setOnline(false); Measure.log("third3: offline")
				try? await Task.sleep(for: .seconds(on - off)); model.core.setOnline(true); Measure.log("third3: back online")
				try? await Task.sleep(for: .seconds(25))
				for c in model.core.conversations(.channel) {
					for e in model.core.events(c.id, before: nil, limit: 3) where e.type == .message {
						let carrier = e.carriedBy.map { id in model.peers.first { $0.device.id == id }.map { "\($0.userName)'s \($0.device.possessive)" } ?? String(id.prefix(8)) }
						Measure.log("third3 #\(c.name ?? ""): \(model.name(of: e.user)): \(e.text ?? "") \(carrier.map { "carried by \($0)" } ?? "direct")")
					}
				}
			} else {
				for _ in 0..<60 { if let g = model.core.conversations(.channel).first { try? await Task.sleep(for: .seconds(Double(env["BAUD_SAY_AT"] ?? "30") ?? 30)); model.send(g.id, Draft(text: say)); Measure.log("guest3: sent '\(say)' to #\(g.name ?? "")"); break }; try? await Task.sleep(for: .seconds(1)) }
				try? await Task.sleep(for: .seconds(30))
				if let g = model.core.conversations(.channel).first, let last = model.core.events(g.id, before: nil, limit: 1).last { Measure.log("guest3 delivery: \(model.core.delivery(g.id, last.id).sentence)") }
			}
		case "back3":
			// Relaunched after being killed: what came while I was gone, and who carried it.
			try? await Task.sleep(for: .seconds(25))
			for c in model.core.conversations(.channel) {
				for e in model.core.events(c.id, before: nil, limit: 3) where e.type == .message {
					let carrier = e.carriedBy.map { id in model.core.peers().first { $0.device.id == id }.map { "\($0.userName)'s \($0.device.possessive)" } ?? String(id.prefix(8)) }
					Measure.log("back3 #\(c.name ?? ""): \(model.core.members(c.id).first { $0.user == e.user }?.name ?? "someone"): \(e.text ?? "") · \(carrier.map { "carried by \($0)" } ?? "direct")")
				}
			}
		default: break
		}
	}
}

/// Two identities become one, seen by their friend (the identity redirect):
///   BAUD_JOURNEY=merge-friend  writes <file>.mac and <file>.phone (two invites), reports its friends
///   BAUD_JOURNEY=merge-mac     adds <file>.mac, says hello, writes a device link to <file>.dev,
///                              accepts the phone's ask
///   BAUD_JOURNEY=merge-phone   adds <file>.phone, says hello, then joins the Mac's person by
///                              <file>.dev: its old identity redirects to the Mac's
/// The friend must end with one contact and one chat holding both hellos.
/// `BAUD_REMOVE_AT=s` on the Mac removes its other device (the phone) after s seconds.
extension Journey {
	@MainActor static func merge(_ role: String, model: AppModel, file: String, say: String) async {
		let env = ProcessInfo.processInfo.environment
		func read(_ path: String) async -> BaudCore.Link? {
			for _ in 0..<90 { if let u = try? String(contentsOfFile: path, encoding: .utf8), let l = parseLink(url: u.trimmingCharacters(in: .whitespacesAndNewlines)) { return l }; try? await Task.sleep(for: .seconds(1)) }
			return nil
		}
		switch role {
		case "merge-friend":
			guard let a = try? model.core.invite(), let b = try? model.core.invite() else { Measure.log("merge-friend: invite failed"); return }
			try? a.url.write(toFile: file + ".mac", atomically: true, encoding: .utf8)
			try? b.url.write(toFile: file + ".phone", atomically: true, encoding: .utf8)
			Measure.log("merge-friend: two invites written")
		case "merge-mac", "merge-phone":
			let mine = role == "merge-mac" ? ".mac" : ".phone"
			guard let l = await read(file + mine) else { Measure.log("\(role): no invite"); return }
			do {
				let k = try await model.core.add(l); Measure.log("\(role): added \(k.name)")
				// The way a person taps Message: the chat, made here if the friend's hasn't arrived.
				try? await Task.sleep(for: .seconds(2)); model.message(k.user)
			} catch { Measure.log("\(role): add failed \(error)"); return }
			for _ in 0..<30 { if let chat = model.core.conversations(.chat).first(where: \.isDirect) { model.send(chat.id, Draft(text: say)); Measure.log("\(role): sent '\(say)'"); break }; try? await Task.sleep(for: .seconds(1)) }
			if role == "merge-mac" {
				try? await Task.sleep(for: .seconds(Double(env["BAUD_DEVICE_LINK_AT"] ?? "8") ?? 8))
				guard let d = try? model.core.linkDevice() else { Measure.log("merge-mac: no device link"); return }
				try? d.url.write(toFile: file + ".dev", atomically: true, encoding: .utf8)
				Measure.log("merge-mac: device link written")
				for _ in 0..<90 { if let ask = model.linkAsk { model.answerLink(ask, accept: true); Measure.log("merge-mac: accepted \(ask.name)"); break }; try? await Task.sleep(for: .seconds(1)) }
				if let at = env["BAUD_REMOVE_AT"].flatMap(Double.init) {
					try? await Task.sleep(for: .seconds(at))
					if let other = model.me.devices.first(where: { $0.id != model.me.thisDevice }) { model.attempt { try model.core.revoke(other.id) }; Measure.log("merge-mac: removed \(other.name)") }
				}
			} else {
				guard let d = await read(file + ".dev") else { Measure.log("merge-phone: no device link"); return }
				do { try await model.link(d); Measure.log("merge-phone: linked as \(model.me.name)") } catch { Measure.log("merge-phone: link failed \(error)") }
			}
		default: break
		}
	}
}

/// Two devices of one person converge across two machines (0.2.5's sync): what one said while the
/// other was away, a conversation the other never saw, a delete. The runner (not the app) moves
/// the link between machines and quits and relaunches the second device.
///   BAUD_JOURNEY=own-a  writes a device link to <file>, accepts the ask, says "one" and "two" in a
///                       new group "Plans"; once <file>.away exists (the other device is quit), makes
///                       "Later", says "three" in it and deletes "Plans"
///   BAUD_JOURNEY=own-b  joins by <file> (unless it already belongs), then reports
/// Both report every five seconds: each chat they show and how many messages it holds.
extension Journey {
	@MainActor static func own(_ role: String, model: AppModel, file: String) async {
		Task { @MainActor in
			while true {
				let shown = (model.notes.map { [$0] } ?? []) + model.core.conversations(nil)
				let line = shown.map { c in "\(model.title(c))=\(model.core.events(c.id, before: nil, limit: 200).filter { $0.type == .message }.count)" }.joined(separator: " · ")
				Measure.log("own-report \(role): devices \(model.me.devices.count), online \(model.peers.filter { $0.own && $0.device.online }.count) · \(line)")
				try? await Task.sleep(for: .seconds(5))
			}
		}
		if role == "own-a" {
			guard let d = try? model.core.linkDevice() else { Measure.log("own-a: no device link"); return }
			try? d.url.write(toFile: file, atomically: true, encoding: .utf8)
			Measure.log("own-a: device link written")
			for _ in 0..<120 { if let ask = model.linkAsk { model.answerLink(ask, accept: true); Measure.log("own-a: accepted \(ask.name)"); break }; try? await Task.sleep(for: .seconds(1)) }
			for _ in 0..<60 { if model.peers.contains(where: { $0.own && $0.device.online }) { break }; try? await Task.sleep(for: .seconds(1)) }
			model.attempt {
				let plans = try model.core.createGroup("Plans", users: [])
				_ = try model.core.send(plans.id, Draft(text: "one"))
				_ = try model.core.send(plans.id, Draft(text: "two"))
			}
			Measure.log("own-a: said one and two in Plans")
			while !FileManager.default.fileExists(atPath: file + ".away") { try? await Task.sleep(for: .seconds(1)) }
			model.attempt {
				let later = try model.core.createGroup("Later", users: [])
				_ = try model.core.send(later.id, Draft(text: "three"))
				if let plans = model.core.conversations(nil).first(where: { $0.name == "Plans" }) { model.delete(plans) }
			}
			Measure.log("own-a: while the other was away, made Later, said three, deleted Plans")
		} else if model.me.devices.count < 2 {
			var url: String?
			for _ in 0..<120 { url = try? String(contentsOfFile: file, encoding: .utf8); if url != nil { break }; try? await Task.sleep(for: .seconds(1)) }
			guard let url, let link = parseLink(url: url.trimmingCharacters(in: .whitespacesAndNewlines)) else { Measure.log("own-b: no link"); return }
			do { try await model.link(link); Measure.log("own-b: linked as \(model.me.name)") } catch { Measure.log("own-b: link failed \(error)") }
		}
	}
}

/// A group of three over the crate, two of whom aren't each other's friends (0.2.7's group chats):
///   BAUD_JOURNEY=group-host  writes <file>.a and <file>.b (two invites), makes "Plans" with both
///                            friends once they're in, and says "plans for saturday"
///   BAUD_JOURNEY=group-a     adds <file>.a, says "i'm in" with BAUD_SEND_FILE, then once
///                            <file>.away exists (b is away) says "while you were out"
///   BAUD_JOURNEY=group-b     adds <file>.b, says "me too"; goes away at BAUD_OFFLINE_AT seconds
///                            (writing <file>.away) and comes back at BAUD_ONLINE_AT
/// Every five seconds each reports what it shows in Plans: the messages in order, and its files.
extension Journey {
	@MainActor static func group(_ role: String, model: AppModel, file: String) async {
		let env = ProcessInfo.processInfo.environment
		func plans() -> Conversation? { model.core.conversations(.chat).first { $0.name == "Plans" } }
		Task { @MainActor in
			while true {
				if let p = plans() {
					let msgs = model.core.events(p.id, before: nil, limit: 100).filter { $0.type == .message }
					let files = msgs.flatMap(\.attachments).map { "\($0.name ?? "?")=\(FileManager.default.fileExists(atPath: model.local.dir.appendingPathComponent("blobs/\($0.hash)").path) ? "here" : "missing")" }
					Measure.log("group-report \(role): members \(p.members.count) · \(msgs.map { "\(model.name(of: $0.user)): \($0.text ?? "")" }.joined(separator: " | ")) · files \(files)")
				} else { Measure.log("group-report \(role): no Plans yet") }
				try? await Task.sleep(for: .seconds(5))
			}
		}
		func read(_ path: String) async -> BaudCore.Link? {
			for _ in 0..<90 { if let u = try? String(contentsOfFile: path, encoding: .utf8), let l = parseLink(url: u.trimmingCharacters(in: .whitespacesAndNewlines)) { return l }; try? await Task.sleep(for: .seconds(1)) }
			return nil
		}
		func waitPlans() async -> Conversation? { for _ in 0..<90 { if let p = plans() { return p }; try? await Task.sleep(for: .seconds(1)) }; return nil }
		switch role {
		case "group-host":
			guard let a = try? model.core.invite(), let b = try? model.core.invite() else { Measure.log("group-host: invite failed"); return }
			try? a.url.write(toFile: file + ".a", atomically: true, encoding: .utf8)
			try? b.url.write(toFile: file + ".b", atomically: true, encoding: .utf8)
			Measure.log("group-host: two invites written")
			for _ in 0..<90 { if model.core.contacts().count >= 2 { break }; try? await Task.sleep(for: .seconds(1)) }
			guard model.core.contacts().count >= 2 else { Measure.log("group-host: friends never came"); return }
			model.attempt {
				let g = try model.core.createGroup("Plans", users: model.core.contacts().map(\.user))
				_ = try model.core.send(g.id, Draft(text: "plans for saturday"))
				Measure.log("group-host: made Plans with \(model.core.members(g.id).count) members")
			}
		case "group-a", "group-b":
			let mine = role == "group-a" ? ".a" : ".b"
			guard let l = await read(file + mine) else { Measure.log("\(role): no invite"); return }
			do { let k = try await model.core.add(l); Measure.log("\(role): added \(k.name)") } catch { Measure.log("\(role): add failed \(error)"); return }
			guard let p = await waitPlans() else { Measure.log("\(role): Plans never came"); return }
			try? await Task.sleep(for: .seconds(2))
			let files = (env["BAUD_SEND_FILE"] ?? "").split(separator: ",").map { URL(fileURLWithPath: String($0)) }
			model.send(p.id, Draft(text: role == "group-a" ? "i'm in" : "me too", attachments: files))
			Measure.log("\(role): said hello with \(files.count) files")
			if role == "group-a" {
				while !FileManager.default.fileExists(atPath: file + ".away") { try? await Task.sleep(for: .seconds(1)) }
				try? await Task.sleep(for: .seconds(2))
				model.send(p.id, Draft(text: "while you were out"))
				Measure.log("group-a: said while you were out")
			} else {
				let off = Double(env["BAUD_OFFLINE_AT"] ?? "25") ?? 25, on = Double(env["BAUD_ONLINE_AT"] ?? "45") ?? 45
				try? await Task.sleep(for: .seconds(max(0, off - 2)))
				model.core.setOnline(false); FileManager.default.createFile(atPath: file + ".away", contents: nil); Measure.log("group-b: away")
				try? await Task.sleep(for: .seconds(on - off)); model.core.setOnline(true); Measure.log("group-b: back")
			}
		default: break
		}
	}
}
