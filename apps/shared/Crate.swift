/// The only file that names the peer package's types: Swift lets its class `Peer` shadow the
/// module, so the adapter next door (which also imports BaudCore) takes plain values from here.
/// `BAUD_CRATE=1` (or the `crate` default) turns it on; without the package built it is off.
import Foundation
import PeerKit

enum Crate {
	/// On by default: the crate is the network. `BAUD_CRATE=0` runs the stub alone (tests, demo shots).
	static var wanted: Bool { ProcessInfo.processInfo.environment["BAUD_CRATE"].map { $0 != "0" } ?? true }
	static var version: String { peerVersion() }

	/// A device as the crate's network loop reports it: online means a live connection; the path; the
	/// last time it was connected; how old its address record is and how it was found.
	struct Dev { var id: String; var name: String; var online: Bool; var path: BaudPath; var user: String; var kind: String
		var lastSeen: Date?; var recordAge: TimeInterval?; var foundBy: String? }
	enum BaudPath { case direct(ms: Int?), relay(String), nearby, waiting, unreachable }
	struct Card { var user: String; var name: String; var fingerprint: String; var verified: Bool; var devices: [Dev]; var redirectedFrom: String? = nil }
	struct Me { var user: String; var name: String; var fingerprint: String; var thisDevice: String; var devices: [(id: String, name: String, kind: String)] }
	struct Record { var device: String; var relay: String?; var reachable: Bool; var awake: Bool; var seq: Int; var age: TimeInterval; var foundBy: String }
	enum Event { case online(String), offline(String), pathChanged(String), pathMoved(String), dialing(String), reached(String), recordChanged(String), contactsChanged, meChanged, linkRequest(String), inbound(UInt64), callInbound(UInt64), inbox, delivered(String), removed, network, redirected(from: String, to: String), unfriended(String), replied(String), replyLapsed(String), other }
	/// Whose device the next link names to meet at (v0.2.2 `inviteMeeting`).
	struct Meet { enum Kind { case own, friend, none }; var kind: Kind; var device: String?; var deviceName: String; var userName: String }

	/// The app's own keychain (data-protection, 0600 file when unsigned), handed to the crate as
	/// closures so the legacy keychain never prompts.
	struct KeyStore { var get: @Sendable (String) -> Data?; var put: @Sendable (String, Data) -> Void; var delete: @Sendable (String) -> Void }
	final class Bridge: Keychain, @unchecked Sendable {
		let k: KeyStore
		init(_ k: KeyStore) { self.k = k }
		func get(item: String) throws -> Data? { k.get("peer-" + item) }
		func put(item: String, bytes: Data) throws { k.put("peer-" + item, bytes) }
		func delete(item: String) throws { k.delete("peer-" + item) }
	}

	/// Opens the crate in `<dir>/peer` with the app's keys.
	/// A Mac runs the crate's relay: the computer at home becomes its person's meeting device while
	/// the router confirms its mapping (the crate withdraws it when the mapping lapses).
	static var relay: Bool {
		#if os(macOS)
		return ProcessInfo.processInfo.environment["BAUD_RELAY"] != "0"
		#else
		return false
		#endif
	}
	/// `BAUD_PUBLIC=1` (Debug, the lab only): the relay is offered without a router's word, to
	/// prove the meeting-device path while the home router maps nothing.
	static var labPublic: Bool {
		#if DEBUG
		return ProcessInfo.processInfo.environment["BAUD_PUBLIC"] == "1"
		#else
		return false
		#endif
	}
	/// `BAUD_PORTMAP=0` (Debug, the lab only): never ask the router for a port, so lab processes
	/// on the home network leave its table alone.
	static var portmap: Bool {
		#if DEBUG
		return ProcessInfo.processInfo.environment["BAUD_PORTMAP"] != "0"
		#else
		return true
		#endif
	}
	/// `BAUD_NEARBY=0` (Debug, the lab only): announce nothing on the local network either.
	static var nearby: Bool {
		#if DEBUG
		return ProcessInfo.processInfo.environment["BAUD_NEARBY"] != "0"
		#else
		return true
		#endif
	}
	/// `BAUD_VPN=0` (Debug, the lab only): neither advertise nor dial VPN addresses (Tailscale's),
	/// so a test between two networks measures the internet path, not the tunnel.
	static var vpn: Bool {
		#if DEBUG
		return ProcessInfo.processInfo.environment["BAUD_VPN"] != "0"
		#else
		return true
		#endif
	}
	static func open(dir: URL, name: String, deviceName: String, deviceKind: String, keys: KeyStore, on event: @escaping @Sendable (Event) -> Void) async throws -> Node {
		let p = try await Peer.open(dir: dir.appendingPathComponent("peer").path, keychain: Bridge(keys),
			config: Config(app: "baud", name: name, deviceName: deviceName, linkScheme: "baud://add", nearby: nearby, alpns: [alpn, CallLink.alpn], deviceKind: deviceKind, vpn: vpn, portmap: portmap, relay: relay, public: labPublic))
		let l = Forward(event)
		p.subscribe(listener: l)
		return Node(p: p, listener: l)
	}

	struct Inbound { var id: String; var from: String?; var bytes: Data; var carriedBy: [String] }
	/// baud's own protocol on the crate's connections. 2 since the wipe: a 0.2.4 device speaks 1,
	/// and the two never exchange a frame.
	static let alpn = "baud/2"

	/// The crate, held behind plain-value methods.
	final class Node: @unchecked Sendable {
		let p: Peer
		let listener: Forward
		private let lock = NSLock()
		private var conns: [String: Conn] = [:]
		init(p: Peer, listener: Forward) { self.p = p; self.listener = listener }

		// MARK: bytes between devices
		/// One connection per device, class small, baud's ALPN; a stream per frame, length-prefixed.
		var onFrame: (@Sendable (Data, String) -> Void)?
		func send(_ bytes: Data, to device: String) async -> Bool {
			do {
				let c: Conn
				if let cached = lock.withLock({ conns[device] }) { c = cached } else {
					c = try await p.connect(device: device, class: .small, alpn: Crate.alpn)
					lock.withLock { conns[device] = c }
					serve(c, from: device)
				}
				let s = try await c.open()
				var n = UInt32(bytes.count).bigEndian
				try await s.send(bytes: Data(bytes: &n, count: 4) + bytes)
				try await s.finish()
				return true
			} catch {
				Measure.log("send to \(device.prefix(8)) failed: \(error)")
				lock.withLock { _ = conns.removeValue(forKey: device) }
				return false
			}
		}
		func post(_ bytes: Data, to device: String, ttl: TimeInterval) async -> [String] {
			do {
				_ = try await p.post(to: device, bytes: bytes, ttlSecs: UInt64(ttl))
				return (try? p.helpersFor(device: device)) ?? []
			} catch { Measure.log("post to \(device.prefix(8)) failed: \(error)"); return [] }
		}
		/// An inbound connection: keep it, either side opens streams on it from here on.
		func accept(_ conn: UInt64) {
			guard let c = try? p.accept(conn: conn) else { Measure.log("accept \(conn) failed"); return }
			let from = c.identity().device
			Measure.log("inbound from \(from.prefix(8))")
			lock.withLock { conns[from] = c }
			serve(c, from: from)
		}
		/// Read every stream the other side opens on a connection, dialed or accepted, until it closes.
		private func serve(_ c: Conn, from: String) {
			Task { [weak self] in
				while let s = try? await c.acceptStream() {
					var buf = Data()
					while let d = try? await s.recv(max: 1 << 20) { buf += d }
					var off = 0
					while buf.count - off >= 4 {
						let n = Int(UInt32(bigEndian: buf[off..<off + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
						guard buf.count - off - 4 >= n else { break }
						self?.onFrame?(buf[(off + 4)..<(off + 4 + n)], from); off += 4 + n
					}
				}
				self?.lock.withLock { if self?.conns[from] === c { self?.conns.removeValue(forKey: from) } }
			}
		}
		/// Groups: admit a co-member's devices for this conversation (crate 16aa249; the Swift
		/// binding is `addMember(group:card:)` once regenerated; the card comes from `contacts()`).
		func addMember(group: String, card: Data) { do { try p.addMember(group: group, card: card) } catch { Measure.log("addMember failed: \(error)") } }
		/// Name a group's tier before its first member (crate 94e9812): a space makes every member a
		/// mutual; a group chat reaches non-contacts only through mutuals in it.
		func makeGroup(_ group: String, space: Bool) { do { try p.createGroup(group: group, kind: space ? .space : .chat) } catch { Measure.log("createGroup failed: \(error)") } }
		func myCard() -> Data { p.myCard() }
		/// A contact's card as the crate holds it (bf2f831), to admit them into a group for someone else.
		func cardOf(_ user: String) -> Data? { (try? p.cardOf(user: user)) ?? nil }
		// Device links: the existing device sees a request and six digits; the joining one shows the same digits while it waits.
		func linkAsk(_ req: UInt64) -> (code: String, device: String, name: String, kind: String)? {
			guard let c = try? p.linkCode(req: req), let d = try? p.linkRequest(req: req) else { return nil }
			return (c, d, (try? p.linkRequestName(req: req)) ?? "", (try? p.linkRequestKind(req: req)) ?? "")
		}
		func confirmLink(_ req: UInt64, accept: Bool) { try? p.confirmLink(req: req, accept: accept) }
		func joiningCode(_ url: String) -> String? { try? p.joiningCode(link: url) }
		/// A device went away: its connection is dead, dial afresh next time.
		func forget(_ device: String) { lock.withLock { _ = conns.removeValue(forKey: device) } }
		func inbox() -> [Inbound] { p.inbox().map { Inbound(id: $0.id, from: $0.from, bytes: $0.bytes, carriedBy: $0.carriedBy) } }
		func ack(_ id: String) { try? p.ack(id: id) }
		func isOnline(_ device: String) -> Bool { p.peers().first { $0.device == device }?.online ?? false }
		/// True when a card the crate holds (mine, a contact's, or a co-member's) lists the device, so
		/// a post to it can be sealed. Presence alone is not enough: "online" can arrive before the
		/// card. Mine counts: a post to my own device that is away is carried like any other (0.2.4
		/// held it here, "no card yet", until the two met again).
		func holdsCard(for device: String) -> Bool { p.me().devices.contains { $0.id == device } || p.contacts().contains { $0.devices.contains { $0.device == device } } }
		func rtt(_ device: String) -> Int? { p.peers().first { $0.device == device }?.rttMs.map(Int.init) }

		func me() -> Me { let m = p.me(); return Me(user: m.user, name: m.name, fingerprint: m.fingerprint, thisDevice: m.thisDevice, devices: m.devices.map { ($0.id, $0.name, $0.kind) }) }
		func setName(_ n: String) throws { try p.setName(name: n) }
		func linkDevice() throws -> String { try p.linkDevice() }
		func link(_ url: String, deviceName: String) async throws { try await p.link(link: url, deviceName: deviceName) }
		func invite() throws -> String { try p.invite() }
		func add(_ url: String) async throws -> Card { card(try await p.add(link: url)) }
		/// A reply to a friend link whose maker I can't reach: theirs opens it, and we meet.
		func reply(_ url: String) throws -> String { try p.reply(link: url) }
		/// Whose link this is: its maker's user.
		func linkUser(_ url: String) -> String? { try? PeerKit.parseLink(link: url).user }
		func contacts() -> [Card] { p.contacts().map(card) }
		func verify(_ user: String, _ fp: String) throws -> Bool { try p.verify(user: user, fingerprint: fp) }
		func peers() -> [Dev] { p.peers().map(dev) }
		func records() -> [Record] { p.records().map { Record(device: $0.device, relay: $0.relay, reachable: $0.reachableUdp || $0.reachableTcp, awake: $0.awake, seq: Int($0.seq), age: Double($0.ageMs) / 1000, foundBy: $0.foundBy) } }
		func setOnline(_ on: Bool) { p.setOnline(online: on) }
		/// What the router last said when asked to open a port: none here, no internet side, refused, mapped.
		enum Gate { case unknown, none, noInternet, refused, mapped }
		func gateway() -> Gate {
			switch p.gateway() { case .unknown: return .unknown; case .none: return .none; case .noInternet: return .noInternet; case .refused: return .refused; case .mapped: return .mapped }
		}
		/// Can a device outside reach this one: yes, no, or not known yet.
		enum Reach { case yes, no, unknown }
		func reachable() -> Reach { switch p.reachable() { case .yes: return .yes; case .no: return .no; case .unknown: return .unknown } }
		/// The public "ip:port" a port the router holds for this device opens, or nil.
		func mapped() -> String? { p.mapped() }
		/// The devices that would carry for this one while it is away.
		func helpers(_ device: String) -> [String] { (try? p.helpersFor(device: device)) ?? [] }
		/// One of my devices leaves my account: the others stop trusting it.
		func revoke(_ device: String) throws { try p.revoke(device: device) }
		/// No longer friends; the crate tells their devices.
		func remove(_ user: String) throws { try p.remove(user: user) }
		/// One of my devices leaves: its card entry goes, mutuals are told, it hears `removed`.
		func removeDevice(_ device: String) throws { try p.removeDevice(device: device) }
		/// This device forgets everything it is (keys, store), before the app starts over.
		func reset() async { try? await p.reset() }
		/// The meeting device the next link names: mine that runs a relay, a friend's, or none.
		func meeting() -> Meet {
			let m = p.inviteMeeting()
			let k: Meet.Kind = { switch m.kind { case .own: return .own; case .friend: return .friend; case .none: return .none } }()
			return Meet(kind: k, device: m.device, deviceName: m.deviceName, userName: m.userName)
		}
		/// The system's network changed: the crate re-binds and re-probes.
		func networkChanged() { p.networkChanged() }
		func close() async { await p.close() }
		/// The crate's timing log, one JSON line per milestone (dials and what they tried, records,
		/// port mappings, the relay offered or not), oldest first.
		func trace() -> [String] { p.trace() }

		private func card(_ c: Contact) -> Card { Card(user: c.user, name: c.name, fingerprint: (try? fingerprint(user: c.user)) ?? "", verified: c.verified, devices: c.devices.map(dev), redirectedFrom: c.redirectedFrom) }
		/// Old identities that now point to new ones: from, to.
		func redirects() -> [(from: String, to: String)] { p.redirects().map { ($0.from, $0.to) } }
		private func dev(_ s: PeerStatus) -> Dev {
			let path: BaudPath
			switch s.path {
			case .direct: path = .direct(ms: s.rttMs.map(Int.init))
			case .relay(let d): path = .relay(d)
			case .nearby: path = .nearby
			case .waiting: path = .waiting
			case .unreachable: path = .unreachable
			}
			return Dev(id: s.device, name: s.name, online: s.online, path: path, user: s.user, kind: s.kind,
				lastSeen: s.lastSeen.map { Date(timeIntervalSince1970: Double($0) / 1000) }, recordAge: s.recordAgeMs.map { Double($0) / 1000 }, foundBy: s.foundBy)
		}
	}

	final class Forward: Listener, @unchecked Sendable {
		let sink: @Sendable (Event) -> Void
		init(_ sink: @escaping @Sendable (Event) -> Void) { self.sink = sink }
		func on(event: PeerEvent) {
			switch event {
			case .online(let d): sink(.online(d))
			case .offline(let d): sink(.offline(d))
			case .pathChanged(let d): sink(.pathChanged(d))
			case .pathMoved(let d): sink(.pathMoved(d))
			case .dialing(let d): sink(.dialing(d))
			case .reached(let d): sink(.reached(d))
			case .recordChanged(let d): sink(.recordChanged(d))
			case .contactsChanged: sink(.contactsChanged)
			case .meChanged: sink(.meChanged)
			case .linkRequest(let r): sink(.linkRequest(String(r)))
			// baud's frames, or a call: each on its own protocol.
			case .inbound(let c, let alpn): if alpn == Crate.alpn { sink(.inbound(c)) } else if alpn == CallLink.alpn { sink(.callInbound(c)) }
			case .inbox: sink(.inbox)
			case .delivered(let id): sink(.delivered(id))
			case .removed: sink(.removed)
			case .contactRedirected(let from, let to): sink(.redirected(from: from, to: to))
			case .contactRemoved(let user): sink(.unfriended(user))
			case .replied(let user): sink(.replied(user))
			case .replyLapsed(let user): sink(.replyLapsed(user))
			case .networkChanged, .reachabilityChanged: sink(.network)
			default: sink(.other)
			}
		}
	}
}

extension Crate {
	/// The crate's flat errors as the sentence a person reads, with the other side named. `own` is a
	/// device link (the other side is my own device); nil when the error isn't the crate's.
	static func sentence(for error: Error, name: String, own: Bool) -> String? {
		guard let e = error as? PeerError else { return nil }
		let theirs = own ? "your other device" : "\(name)'s device"
		let fresh = own ? "Make a new one on your other device." : "Ask \(name) for a fresh one."
		switch e {
		case .Expired: return "That link has expired. \(fresh)"
		case .Used: return "That link was already used; each works once. \(fresh)"
		case .NotInTheirBook: return own ? "Your other device said no." : "\(name)'s device said no."
		case .Unreachable, .Net: return "Couldn't reach \(theirs). baud has to be open there, and online or through one of your devices. Try again, or ask for a fresh link."
		// Its first part read, the rest didn't: an app on its way cut it short.
		case .Encoding: return "That link was cut short on its way. \(fresh)"
		case .BadKey, .BadSignature: return "That isn't a usable baud link."
		case .NotFound(let m), .PolicyRefused(let m), .Budget(let m), .Keychain(let m), .Store(let m), .Failed(let m): return m
		}
	}
}

extension Crate {
	/// The far side was never reached, or stopped answering.
	static func unreachable(_ error: Error) -> Bool {
		guard let e = error as? PeerError else { return false }
		switch e { case .Unreachable, .Net: return true; default: return false }
	}

	/// Why a reply I opened (someone answering my link) didn't meet them, in a sentence.
	static func replyTrouble(_ error: Error, name: String) -> String? {
		guard let e = error as? PeerError else { return nil }
		switch e {
		case .Expired: return "\(name)'s answer ran out. Show \(name) a new link."
		case .Used: return "Your link was used by someone else. Show \(name) a new one."
		case .NotFound: return "This answers a link from another of your devices. Open baud there and try again."
		case .Encoding, .BadKey, .BadSignature: return "That isn't a usable baud link."
		default: return nil
		}
	}

	/// The same, in five words or fewer, for the Add screen.
	static func short(for error: Error) -> String {
		guard let e = error as? PeerError else { return "Didn't work" }
		switch e {
		case .Expired: return "Link expired"
		case .Used: return "Link already used"
		case .NotInTheirBook: return "They said no"
		case .Unreachable, .Net: return "Couldn't reach it"
		case .Encoding: return "Link cut short"
		case .BadKey, .BadSignature: return "Not a baud link"
		default: return "Didn't work"
		}
	}
}

/// At file scope `version()` is the module's; inside a type it would be shadowed by a member.
private func peerVersion() -> String { PeerKit.version() }
