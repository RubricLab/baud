/// Calls, the app's side. A call is a mesh: everyone in it holds a live connection to everyone
/// else, and two people are a mesh of one. Calling rings every online device of every other
/// member; each person's first device to answer takes the call for them (their others stop) and
/// hears who else is in it, to connect to. Members who weren't rung, or missed it, see "Call in
/// progress" in the chat and can join. One call at a time: a ring that arrives during one hears
/// "busy". The caller's device leaves the call's line in the chat ("Video call · 4 min", "Missed
/// call from Ana"). On the iPhone, CallKit carries the ring and the audio session. A sleeping iPhone
/// whose wake ticket I hold is woken through the wake relay first (BaudCore's Wake.swift), then
/// dialed until it answers the dial; its ring takes the place of the call its wake reported.
import AVFoundation
import BaudCore
import Foundation
import SwiftUI

@MainActor @Observable
final class CallCenter {
	enum Phase: Equatable {
		/// Mine, dialing; theirs, showing it; mine, answered and starting; talking; over, and why.
		case calling, ringing, incoming, connecting, live, ended(String)
		var over: Bool { if case .ended = self { return true }; return false }
	}

	/// Someone else's device in the call.
	@MainActor @Observable
	final class Participant: Identifiable {
		let device: String
		let user: UserId
		let name: String
		let avatar: BlobHash?
		var muted = false
		var camera: Bool
		nonisolated var id: String { device }
		var first: String { name.split(separator: " ").first.map(String.init) ?? name }
		@ObservationIgnored let layer = AVSampleBufferDisplayLayer()
		@ObservationIgnored var link: CallRoute?
		/// Who opened the link: when two of us dial each other at once, both keep the one opened by
		/// the smaller device id.
		@ObservationIgnored var dialedByMe = false
		/// A level to draw with when there's no media (pictures of the screen).
		@ObservationIgnored var stillLevel: Float = 0
		init(device: String, user: UserId, name: String, avatar: BlobHash?, camera: Bool) {
			self.device = device; self.user = user; self.name = name; self.avatar = avatar; self.camera = camera
			layer.videoGravity = .resizeAspectFill
		}
	}

	@MainActor @Observable
	final class Session: Identifiable {
		let id: String
		let conv: ConversationId
		let outgoing: Bool
		let video: Bool
		/// Two people: the other's name. A group: the group's.
		let title: String
		let group: Bool
		/// Who started it ("Ana is calling weekend").
		let caller: String
		/// Two people: the other, also before they've answered.
		let user: UserId?
		let avatar: BlobHash?
		var phase: Phase
		var startedAt: Date?
		var muted = false
		var cameraOn: Bool
		var speaker: Bool
		var videoPaused = false
		/// "Direct · 14 ms", "Through your Mac mini": the honest status, in a few words.
		var path = ""
		var participants: [Participant] = []
		/// Between my own devices, from my chat with myself: a way to try a call alone.
		var own = false
		/// The iPhone: CallKit carries it. False when the system wouldn't take it (Do Not Disturb,
		/// a Focus): it rings in baud's own window, and baud takes the audio itself.
		var callKit = true
		/// CallKit's name for it; a ring that follows a wake takes over the call the wake reported.
		var uuid = UUID()
		@ObservationIgnored let local = AVSampleBufferDisplayLayer()
		@ObservationIgnored let spare = AVSampleBufferDisplayLayer()
		/// Mine, still ringing: by device, whose.
		@ObservationIgnored var ringing: [String: (link: CallLink, user: UserId)] = [:]
		@ObservationIgnored var answered: Set<UserId> = []
		@ObservationIgnored var refused: [UserId: String] = [:]
		/// Theirs: the ring's link to the caller's device, and the caller.
		@ObservationIgnored var ringLink: CallLink?
		@ObservationIgnored var callerUser: UserId?
		@ObservationIgnored var media: CallMedia?
		@ObservationIgnored var failures = 0
		/// Mine: ring a device again on a new connection (its last one dropped while it rang).
		@ObservationIgnored var ringAgain: ((String, UserId) -> Void)?
		@ObservationIgnored let began = Date()
		@ObservationIgnored var stillLevel: Float = 0
		init(id: String, conv: ConversationId, outgoing: Bool, video: Bool, title: String, group: Bool, caller: String, user: UserId?, avatar: BlobHash?, phase: Phase) {
			self.id = id; self.conv = conv; self.outgoing = outgoing; self.video = video; self.title = title; self.group = group; self.caller = caller
			self.user = user; self.avatar = avatar; self.phase = phase
			cameraOn = video; speaker = video
			local.videoGravity = .resizeAspectFill
		}
		var name: String { title }
		var first: String { group ? title : (title.split(separator: " ").first.map(String.init) ?? title) }
		// The one other person, for a call between two.
		var remote: AVSampleBufferDisplayLayer { participants.first?.layer ?? spare }
		var remoteCamera: Bool { participants.first?.camera ?? video }
		var remoteMuted: Bool { participants.first?.muted ?? false }
		/// Levels for the rings: read by the screen as it draws, never observed.
		var remoteLevel: Float { media?.remoteLevel ?? stillLevel }
		func level(_ p: Participant) -> Float { media?.level(p.device) ?? p.stillLevel }
	}

	private(set) var session: Session?
	/// A call is ringing, waiting for its ring after a wake, or going on: the device stays online
	/// whatever the app's lifecycle says, or the call's connection goes with it.
	var holdsOnline: Bool {
		if let s = session, !s.phase.over { return true }
		#if os(iOS)
		return kit.waiting
		#else
		return false
		#endif
	}
	/// Calls going on in chats, as their members say (for "Call in progress · Join").
	private(set) var ongoing: [ConversationId: CallPresence] = [:]
	@ObservationIgnored weak var model: AppModel?
	@ObservationIgnored private weak var baud: Baud?
	@ObservationIgnored private let ringer = Ringer()
	/// `BAUD_CALL_TEST=1`: a drawn picture and a synthetic voice instead of the camera and the
	/// microphone, nothing out of the speaker, no CallKit; for proving calls without anyone's devices.
	nonisolated static let test = ProcessInfo.processInfo.environment["BAUD_CALL_TEST"] == "1"
	/// The most a mesh holds: everyone sends to everyone, and a home uplink carries about this many.
	static let most = 8
	#if os(iOS)
	@ObservationIgnored private lazy var kit = CallKitBridge(center: self)
	#endif

	func attach(_ model: AppModel, _ baud: Baud?) {
		self.model = model; self.baud = baud
		baud?.onCall = { [weak self] conn in Task { @MainActor in self?.arrived(conn) } }
		model.local.onCallPresence = { [weak self] conv, p in Task { @MainActor in self?.heard(conv, p) } }
		callLog = { Measure.log($0); CallRecord.keep($0) }
		// Calls nobody has spoken for in a while are over.
		Task { [weak self] in
			while !Task.isCancelled {
				try? await Task.sleep(for: .seconds(10))
				guard let self else { return }
				let now = Date().timeIntervalSince1970
				for (c, p) in ongoing where p.until < now { ongoing[c] = nil }
			}
		}
		#if DEBUG
		CallShots.runIfAsked(model)
		CallShots.autoCall(model)
		CallShots.groupCall(model)
		#endif
	}

	/// Whether a call can be placed (or joined) in this chat.
	func callable(_ conv: ConversationId) -> Bool {
		guard let model, let c = model.conversation(conv) else { return false }
		// My chat with myself calls my other devices.
		if c.kind == .home { return model.me.devices.count > 1 }
		return c.kind == .chat && (2...Self.most).contains(c.members.count)
	}

	/// A device of mine by its name: "MacBook Pro", "iPhone".
	private func deviceName(_ d: String) -> String? {
		model?.me.devices.first { $0.id == d }.map { Names.device($0.name) }
	}

	// MARK: calling

	/// Ring every online device of everyone else in this chat; or, with a call already going on
	/// in it, join that.
	func start(_ conv: ConversationId, video: Bool) {
		guard session == nil, let model, let c = model.conversation(conv) else { return }
		if ongoing[conv] != nil { join(conv); return }
		let own = c.kind == .home
		let others = model.core.members(conv).filter { !$0.me }
		guard own || (!others.isEmpty && others.count < Self.most) else { model.error = "Calls are for up to \(Self.most) people."; return }
		let group = !own && !c.isDirect
		let one = group || own ? nil : others.first
		let mine = model.me.devices.filter { $0.id != model.me.thisDevice }
		let title = own ? (mine.count == 1 ? Names.device(mine[0].name) : "Your devices") : group ? model.title(c) : one?.name ?? ""
		let s = Session(id: UUID().uuidString, conv: conv, outgoing: true, video: video, title: title, group: group, caller: model.me.name,
			user: one?.user, avatar: one.flatMap { o in model.contacts.first { $0.user == o.user }?.avatar }, phase: .calling)
		s.own = own
		session = s
		let all = own ? mine.map { (device: $0, user: model.me.user) } : others.flatMap { m in m.devices.map { (device: $0, user: m.user) } }
		let targets = all.filter(\.device.online).map { (device: $0.device.id, user: $0.user) }
		// Asleep, but I hold a ticket to wake it: woken, then dialed until it's up.
		let sleepers = all.filter { !$0.device.online && model.local.canWake($0.device.id) }.map { (device: $0.device.id, user: $0.user) }
		guard let node = baud?.callNode, !targets.isEmpty || !sleepers.isEmpty else {
			finish(s, (own ? "Your other devices aren't online." : group ? "Nobody in \(s.title) is online." : "\(s.first) isn't online.") + " A device rings only while baud is open on it.", record: nil)
			return
		}
		Task { await Permissions.ask(video: video) }
		#if os(iOS)
		if !Self.test { kit.outgoing(s) }
		#endif
		let me = model.me
		callLog("call \(s.id.prefix(8)): ringing \(targets.count) device(s)\(sleepers.isEmpty ? "" : ", waking \(sleepers.count)") of \(Set((targets + sleepers).map(\.user)).count) \(group ? "in \(s.title)" : s.first)\(video ? ", video" : "")")
		let total = targets.count + sleepers.count
		let ring = { [weak self] (t: (device: String, user: UserId), patience: TimeInterval) in
			await self?.dialRing(s, t, node: node, total: total, conv: conv, video: video, me: me, patience: patience)
		}
		s.ringAgain = { t, u in Task { await ring((device: t, user: u), 15) } }
		for t in targets {
			let wakeable = model.local.canWake(t.device)
			Task { await ring(t, wakeable ? 25 : 0) }
			// It can look online and be asleep (iOS froze it before its connection timed out): not
			// reached in two seconds, it's woken too.
			guard wakeable else { continue }
			Task {
				try? await Task.sleep(for: .seconds(2))
				guard session === s, !s.phase.over, s.ringing[t.device] == nil, !s.answered.contains(t.user) else { return }
				callLog("call \(s.id.prefix(8)): \(t.device.prefix(8)) didn't answer the dial; \(await model.local.wake(t.device, .call) ? "woke it" : "couldn't wake it")")
			}
		}
		for t in sleepers {
			Task {
				let woke = await model.local.wake(t.device, .call)
				callLog("call \(s.id.prefix(8)): \(woke ? "woke" : "couldn't wake") \(t.device.prefix(8))")
				await ring(t, woke ? 25 : 0)
			}
		}
		Task {
			try? await Task.sleep(for: .seconds(45))
			guard session === s, !s.phase.over else { return }
			stopRinging(s, "timeout")
			if s.participants.isEmpty { finish(s, group ? "Nobody answered" : "No answer", record: "missed") }
		}
	}

	/// Reach one device and ring it. One just woken takes a few seconds to come online: it's dialed
	/// again every second and a half for `patience` seconds.
	private func dialRing(_ s: Session, _ t: (device: String, user: UserId), node: Crate.Node, total: Int, conv: ConversationId, video: Bool, me: Person, patience: TimeInterval) async {
		let until = Date().addingTimeInterval(patience)
		while true {
			do {
				let link = try await node.dialCall(t.device)
				guard session === s, !s.phase.over, !s.answered.contains(t.user), s.refused[t.user] == nil else { await link.last(.cancel(reason: "elsewhere"), reason: "late"); return }
				listen(link)
				s.ringing[t.device] = (link, t.user)
				link.start()
				await link.send(.ring(id: s.id, conv: conv, video: video, user: me.user, name: me.name))
				return
			} catch {
				if Date() < until, session === s, !s.phase.over, !s.answered.contains(t.user) { try? await Task.sleep(for: .milliseconds(1500)); continue }
				callLog("call \(s.id.prefix(8)): couldn't reach \(t.device.prefix(8)): \(error)")
				s.failures += 1
				if s.failures >= total, session === s, s.participants.isEmpty, s.ringing.isEmpty {
					finish(s, s.group ? "Couldn't reach anyone in \(s.title)." : "Couldn't reach \(s.first)'s devices. They may need the latest baud.", record: nil)
				}
				return
			}
		}
	}

	/// The iPhone, woken by a call push: it rings now (iOS insists), online to hear the ring itself.
	func wokenForCall() {
		#if os(iOS)
		kit.wakeCall()
		#endif
		model?.core.setOnline(true)
		callLog("call: woken by a push")
	}

	/// Join the call going on in this chat: connect to everyone in it.
	func join(_ conv: ConversationId) {
		guard session == nil, let model, let p = ongoing[conv], let c = model.conversation(conv) else { return }
		let me = model.me
		let own = c.kind == .home
		let targets = p.peers.filter { $0.device != me.thisDevice && (own || $0.user != me.user) }
		guard let first = targets.first else { return }
		let group = !own && !c.isDirect
		let s = Session(id: p.id, conv: conv, outgoing: false, video: p.video, title: own ? "Your devices" : group ? model.title(c) : first.name, group: group, caller: first.name,
			user: group || own ? nil : first.user, avatar: group || own ? nil : model.contacts.first { $0.user == first.user }?.avatar, phase: .connecting)
		s.own = own
		session = s
		callLog("call \(s.id.prefix(8)): joining \(targets.count) in \(s.title)")
		Task {
			await Permissions.ask(video: p.video)
			guard begin(s) else { return }
			for t in targets { connect(s, to: t, introducer: first.device) }
		}
		Task {
			try? await Task.sleep(for: .seconds(15))
			if session === s, s.participants.isEmpty, !s.phase.over { finish(s, "Couldn't join the call", record: nil) }
		}
	}

	// MARK: answering

	/// A call connection arrived: its signals say a ring, a newcomer joining, or the rest.
	private func arrived(_ conn: UInt64) {
		guard let node = baud?.callNode else { return }
		Task {
			guard let link = try? await node.acceptCall(conn) else { return }
			link.onSignal = { [weak self, weak link] sig in Task { @MainActor in if let self, let link { self.route(sig, on: link) } } }
			link.onClose = { [weak self, weak link] in Task { @MainActor in if let self, let link { self.closed(link) } } }
			link.start()
		}
	}

	private func route(_ sig: CallSignal, on link: CallRoute) {
		switch sig {
		case .forward(let from, let to, let inner):
			guard let s = session, let me = model?.me.thisDevice, let direct = link as? CallLink else { return }
			if to == me {
				if let r = s.participants.first(where: { $0.device == from })?.link as? RelayedLink, r.helper === direct { route(inner, on: r); return }
				// Someone in the call reaching me through this one for the first time: joining.
				guard case .join = inner else { return }
				let r = RelayedLink(device: from, me: me, helper: direct)
				listen(r)
				route(inner, on: r)
			} else if let next = s.participants.first(where: { $0.device == to })?.link as? CallLink {
				// For someone they can't reach and I can: on it goes, as it came.
				Task { await next.send(sig) }
			}
		case .ring(let id, let conv, let video, let user, let name):
			// Rings come on a connection of their own, never through someone.
			if let direct = link as? CallLink { ring(id: id, conv: conv, video: video, user: user, name: name, on: direct) }
		case .join(let id, let user, let name, let video):
			guard let s = session, s.id == id, !s.phase.over, s.media != nil else { Task { await link.last(.cancel(reason: "not in it"), reason: "not in it") }; return }
			admit(s, link, user: user, name: name, camera: video, dialedByMe: false)
			// It may not know everyone here yet: tell it.
			let others = s.participants.filter { $0.device != link.device }.map { CallPeer(device: $0.device, user: $0.user, name: $0.name) }
			if !others.isEmpty { Task { await link.send(.roster(others)) } }
		default: signal(sig, from: link)
		}
	}

	private func ring(id: String, conv: ConversationId, video: Bool, user: UserId, name: String, on link: CallLink) {
		guard let model else { return }
		if let s = session {
			// The same call ringing again, on a new connection (the last dropped while it rang): it
			// carries the call from here.
			if s.id == id, !s.outgoing, s.phase == .incoming || s.phase == .connecting {
				s.ringLink = link
				callLog("call \(id.prefix(8)): rang again on a new connection")
				Task { await link.send(.ringing) }
				return
			}
			Task { await link.last(.busy, reason: "busy") }; return
		}
		// Only someone I share this chat with (the crate already admits only devices I hold cards for).
		// Or another device of mine, from my chat with myself.
		guard let c = model.conversation(conv),
			  c.kind == .home ? user == model.me.user : model.core.members(conv).contains(where: { $0.user == user && !$0.me }) else { link.close("unknown"); return }
		let own = c.kind == .home
		let group = !own && !c.isDirect
		let who = model.contacts.first { $0.user == user }
		let from = own ? deviceName(link.device) ?? "Your other device" : who?.name ?? name
		let s = Session(id: id, conv: conv, outgoing: false, video: video, title: group ? model.title(c) : from, group: group, caller: from,
			user: group || own ? nil : user, avatar: group || own ? nil : who?.avatar, phase: .incoming)
		s.own = own
		s.ringLink = link; s.callerUser = user
		session = s
		callLog("call \(id.prefix(8)): \(s.caller) is calling\(group ? " \(s.title)" : "")\(video ? ", video" : "")")
		Task { await link.send(.ringing) }
		#if os(iOS)
		if !Self.test, !kit.adopt(s) { kit.incoming(s) }
		#else
		if !Self.test { ringer.start() }
		#endif
		#if DEBUG
		// `BAUD_CALL_ANSWER=1|decline` (Debug): answer, or say no, a second in.
		switch ProcessInfo.processInfo.environment["BAUD_CALL_ANSWER"] {
		case "1": Task { try? await Task.sleep(for: .seconds(1)); accept(camera: true) }
		case "decline": Task { try? await Task.sleep(for: .seconds(1)); decline() }
		default: break
		}
		#endif
	}

	/// Answer here; with the camera or without it on a video call.
	func accept(camera: Bool) {
		guard let s = session, !s.outgoing, s.phase == .incoming, let link = s.ringLink, let caller = s.callerUser else { return }
		ringer.stop()
		s.cameraOn = s.video && camera
		s.phase = .connecting
		Task {
			await Permissions.ask(video: s.cameraOn)
			// Yes goes to the caller only once this side can carry the call: a yes followed by
			// nothing left the caller in a call the other side had already ended.
			guard begin(s) else { return }
			// The ring's connection may have dropped (a phone just woken): the caller rings again on
			// a new one, and the yes goes there.
			var to = link
			var said = await to.send(.accept(video: s.cameraOn))
			for _ in 0..<24 where !said {
				try? await Task.sleep(for: .milliseconds(250))
				guard session === s, !s.phase.over else { return }
				if let l = s.ringLink, l !== to { to = l; said = await l.send(.accept(video: s.cameraOn)) }
			}
			guard said else { callLog("call \(s.id.prefix(8)): the caller's connection is gone"); failed(s, CallError.audio("The call didn't connect.")); return }
			admit(s, to, user: caller, camera: s.video, dialedByMe: false)
		}
	}

	func decline() {
		guard let s = session, !s.outgoing, s.phase == .incoming, let link = s.ringLink else { return }
		Task { await link.last(.decline, reason: "declined") }
		s.ringLink = nil
		finish(s, "Declined", record: nil)
	}

	// MARK: during

	/// Leave the call (the others carry on), or stop calling.
	func end() {
		guard let s = session, !s.phase.over else { session = nil; return }
		if s.phase == .incoming { decline(); return }
		if s.participants.isEmpty {
			stopRinging(s, "hangup")
			finish(s, "Cancelled", record: s.outgoing ? "cancelled" : nil)
			return
		}
		for p in s.participants { if let l = p.link { Task { await l.last(.end, reason: "end") } }; p.link = nil }
		stopRinging(s, "hangup")
		finish(s, "Call ended", record: nil)
	}

	func toggleMute() { guard let s = session else { return }; setMuted(!s.muted) }
	func setMuted(_ on: Bool) {
		guard let s = session else { return }
		s.muted = on
		s.media?.audio.muted = on
		sendState(s)
		#if os(iOS)
		kit.muted(s)
		#endif
	}

	func toggleCamera() {
		guard let s = session, s.video else { return }
		s.cameraOn.toggle()
		if s.cameraOn { Task { await Permissions.ask(video: true); s.media?.video?.setCamera(true) } } else { s.media?.video?.setCamera(false) }
		if !s.cameraOn { s.local.sampleBufferRenderer.flush(removingDisplayedImage: true) {} }
		sendState(s)
	}

	func flip() { session?.media?.video?.flip() }

	func toggleSpeaker() {
		guard let s = session else { return }
		s.speaker.toggle()
		#if os(iOS)
		try? AVAudioSession.sharedInstance().overrideOutputAudioPort(s.speaker ? .speaker : .none)
		#endif
	}

	private func sendState(_ s: Session) {
		let (m, c) = (s.muted, s.cameraOn)
		for p in s.participants { if let l = p.link { Task { await l.send(.state(muted: m, camera: c)) } } }
	}

	// MARK: signals

	private func listen(_ link: CallRoute) {
		link.onSignal = { [weak self, weak link] sig in Task { @MainActor in if let self, let link { self.route(sig, on: link) } } }
		link.onClose = { [weak self, weak link] in Task { @MainActor in if let self, let link { self.closed(link) } } }
	}

	private func signal(_ sig: CallSignal, from link: CallRoute) {
		guard let s = session else { return }
		if let m = s.media, m.handle(sig, from: link.device) { return }
		switch sig {
		case .ringing:
			if s.outgoing, s.phase == .calling { s.phase = .ringing }
		case .accept(let video):
			guard s.outgoing, let r = s.ringing.removeValue(forKey: link.device) else { return }
			// Answered on another of theirs already: this one stands down.
			if s.answered.contains(r.user) { Task { await link.last(.cancel(reason: "elsewhere"), reason: "elsewhere") }; return }
			s.answered.insert(r.user)
			for (d, o) in s.ringing where o.user == r.user { s.ringing[d] = nil; Task { await o.link.last(.cancel(reason: "elsewhere"), reason: "elsewhere") } }
			// Everyone already here, for it to connect to.
			let others = s.participants.map { CallPeer(device: $0.device, user: $0.user, name: $0.name) }
			Task { await link.send(.roster(others)) }
			guard begin(s) else { return }
			admit(s, link, user: r.user, camera: video, dialedByMe: true)
		case .decline, .busy:
			guard s.outgoing, let r = s.ringing.removeValue(forKey: link.device) else { return }
			link.close("done")
			s.refused[r.user] = sig == .busy ? "busy" : "declined"
			for (d, o) in s.ringing where o.user == r.user { s.ringing[d] = nil; Task { await o.link.last(.cancel(reason: "declined"), reason: "declined") } }
			if s.participants.isEmpty, s.ringing.isEmpty {
				let busy = s.refused.values.allSatisfy { $0 == "busy" }
				if s.group { finish(s, busy ? "Everyone's on another call" : "Nobody answered", record: busy ? "busy" : "declined") }
				else { finish(s, busy ? "\(s.first) is on another call" : "\(s.first) declined", record: busy ? "busy" : "declined") }
			}
		case .cancel(let reason):
			guard !s.outgoing, s.ringLink === link, s.phase == .incoming else { return }
			finish(s, reason == "elsewhere" ? "Answered on another device" : "Missed call", record: nil)
		case .roster(let peers):
			guard let me = model?.me else { return }
			for p in peers where p.device != me.thisDevice && (s.own || p.user != me.user) && !s.participants.contains(where: { $0.device == p.device }) { connect(s, to: p, introducer: link.device) }
		case .end:
			leave(s, link, dropped: false)
		case .state(let muted, let camera):
			guard let p = s.participants.first(where: { $0.link === link }) else { return }
			p.muted = muted; p.camera = camera
			if !camera { p.layer.sampleBufferRenderer.flush(removingDisplayedImage: true) {} }
		case .ring, .join, .keyframe, .stats, .forward, .caps: break
		}
	}

	private func closed(_ link: CallRoute) {
		guard let s = session else { return }
		if s.participants.contains(where: { $0.link === link }) { leave(s, link, dropped: true) }
		else if s.ringLink === link, s.phase == .incoming || s.phase == .connecting {
			// The ring's connection dropped: a caller still calling rings again on a new one.
			Task { try? await Task.sleep(for: .seconds(6)); if session === s, s.ringLink === link, s.phase == .incoming { finish(s, "Missed call", record: nil) } }
		}
		else if let (d, r) = s.ringing.first(where: { $0.value.link === link }) {
			s.ringing[d] = nil
			// It dropped while ringing (a phone just woken, still settling): ring it again, for a while.
			if s.outgoing, !s.phase.over, !s.answered.contains(r.user), Date().timeIntervalSince(s.began) < 30, let again = s.ringAgain {
				callLog("call \(s.id.prefix(8)): lost the ring to \(d.prefix(8)); ringing again")
				again(d, r.user)
				return
			}
			if s.outgoing, s.ringing.isEmpty, s.participants.isEmpty, !s.phase.over { finish(s, "The call didn't connect", record: nil) }
		}
	}

	/// Someone left (or their link dropped): the rest carry on; alone with nobody ringing, it's over.
	private func leave(_ s: Session, _ link: CallRoute, dropped: Bool) {
		guard let i = s.participants.firstIndex(where: { $0.link === link }) else { return }
		let p = s.participants.remove(at: i)
		s.media?.remove(p.device)
		callLog("call \(s.id.prefix(8)): \(p.first) \(dropped ? "dropped" : "left"), \(s.participants.count) still in")
		// Whoever I reached through them, I can't now.
		for q in s.participants where q.link?.via == p.device { if let l = q.link { leave(s, l, dropped: true) } }
		announce(s)
		if s.participants.isEmpty, s.ringing.isEmpty, !s.phase.over {
			finish(s, s.group ? "Everyone left" : dropped ? "The connection dropped" : "Call ended", record: nil)
		}
	}

	private func stopRinging(_ s: Session, _ reason: String) {
		for (_, r) in s.ringing { Task { await r.link.last(.cancel(reason: reason), reason: reason) } }
		s.ringing = [:]
	}

	// MARK: the mesh

	/// Open a link to someone already in the call; if theirs can't be reached from here (members of
	/// a group who aren't friends hold each other's cards, not each other's addresses), through the
	/// one who told me about them, who reaches us both.
	private func connect(_ s: Session, to peer: CallPeer, introducer: String?) {
		guard let node = baud?.callNode, let me = model?.me else { return }
		Task {
			do {
				let link = try await node.dialCall(peer.device)
				guard session === s, !s.phase.over else { link.close("late"); return }
				listen(link)
				link.start()
				await link.send(.join(id: s.id, user: me.user, name: me.name, video: s.cameraOn))
				admit(s, link, user: peer.user, name: peer.name, camera: s.video, dialedByMe: true)
			} catch {
				callLog("call \(s.id.prefix(8)): can't reach \(peer.name)'s device directly (\(error)); through someone in the call")
				// The one who told me about them may still be connecting: give it a few seconds.
				for _ in 0..<20 {
					guard session === s, !s.phase.over, !s.participants.contains(where: { $0.device == peer.device }) else { return }
					let helper = s.participants.first { $0.device == introducer && $0.link is CallLink } ?? s.participants.first { $0.link is CallLink && $0.device != peer.device }
					if let h = helper, let hl = h.link as? CallLink {
						let r = RelayedLink(device: peer.device, me: me.thisDevice, helper: hl)
						listen(r)
						await r.send(.join(id: s.id, user: me.user, name: me.name, video: s.cameraOn))
						admit(s, r, user: peer.user, name: peer.name, camera: s.video, dialedByMe: true)
						return
					}
					try? await Task.sleep(for: .milliseconds(250))
				}
				callLog("call \(s.id.prefix(8)): couldn't reach \(peer.name)'s device at all")
			}
		}
	}

	/// A device is in the call with me now: into the mix, onto the screen.
	private func admit(_ s: Session, _ link: CallRoute, user: UserId, name: String? = nil, camera: Bool, dialedByMe: Bool) {
		guard let model, let media = s.media else { return }
		let mine = model.me.thisDevice
		if let p = s.participants.first(where: { $0.device == link.device }) {
			// Two ways to one device: a connection of our own beats one through someone; between two
			// of our own, both sides keep the one opened by the smaller device id.
			let direct = link.via == nil, wasDirect = p.link?.via == nil
			let keepNew = direct != wasDirect ? direct : (dialedByMe ? mine : link.device) < (p.dialedByMe ? mine : p.device)
			if !keepNew { return }
			let old = p.link
			p.link = link; p.dialedByMe = dialedByMe
			media.remove(p.device)
			media.add(link, onFrame: Self.renderer(p.layer))
			old?.close("duplicate")
			return
		}
		let who = model.contacts.first { $0.user == user }
		// My name for them if they're a friend; else the group's, else the one they gave.
		let p = Participant(device: link.device, user: user, name: (user == model.me.user ? deviceName(link.device) : nil) ?? who?.name ?? model.core.members(s.conv).first { $0.user == user }?.name ?? name ?? "Someone", avatar: who?.avatar, camera: camera)
		p.link = link; p.dialedByMe = dialedByMe
		s.participants.append(p)
		media.add(link, onFrame: Self.renderer(p.layer))
		if s.phase != .live {
			s.phase = .live
			s.startedAt = Date()
			#if os(iOS)
			if !Self.test { kit.connected(s) }
			#endif
			keepAnnouncing(s)
		}
		s.path = pathLine(s)
		let (m, c) = (s.muted, s.cameraOn)
		Task { await link.send(.state(muted: m, camera: c)) }
		callLog("call \(s.id.prefix(8)): \(p.first) in\(link.via.map { _ in " (through someone in the call)" } ?? ""), \(s.participants.count + 1) in the call\(s.group ? "" : ", " + s.path)")
		announce(s)
	}

	private static func renderer(_ layer: AVSampleBufferDisplayLayer) -> @Sendable (CMSampleBuffer) -> Void {
		let r = Renderer(layer.sampleBufferRenderer)
		return { r.r.enqueue($0) }
	}

	// MARK: media

	/// The media starts with the first one in: my voice and picture out, everyone's in.
	@discardableResult private func begin(_ s: Session) -> Bool {
		guard s.media == nil else { return true }
		#if os(iOS)
		if !s.callKit, !Self.test { kit.takeAudio(s) }
		#endif
		do {
			let m = try CallMedia(video: s.video, test: Self.test, me: model?.me.thisDevice ?? "")
			let local = Renderer(s.local.sampleBufferRenderer)
			m.video?.onLocal = { local.r.enqueue($0) }
			if !s.cameraOn { m.video?.setCamera(false) }
			m.audio.muted = s.muted
			m.onChange = { [weak self, weak s] in Task { @MainActor in if let s, let self { s.videoPaused = m.videoPaused; s.path = self.pathLine(s) } } }
			s.media = m
			try m.start(audio: audioReady)
			if m.audio.micOff { callLog("call \(s.id.prefix(8)): the microphone is off for baud; listening only") }
			s.path = pathLine(s)
			return true
		} catch {
			callLog("call \(s.id.prefix(8)): media failed: \(error)")
			failed(s, error)
			return false
		}
	}

	/// The call can't go on here (its audio wouldn't start): it ends, saying why, and everyone on
	/// it or still ringing hears that it's over rather than waiting on silence.
	private func failed(_ s: Session, _ error: Error) {
		for p in s.participants { if let l = p.link { Task { await l.last(.end, reason: "failed") } }; p.link = nil }
		if let l = s.ringLink { Task { await l.last(.end, reason: "failed") } }
		stopRinging(s, "failed")
		let why: String
		if case CallError.audio(let w) = error { why = w } else { why = "The call's audio wouldn't start." }
		finish(s, why, record: nil)
	}

	/// On the iPhone the voice waits for CallKit to hand over the audio session.
	private var audioReady: Bool {
		#if os(iOS)
		return Self.test || kit.audioActive
		#else
		return true
		#endif
	}
	/// CallKit activated the audio session.
	func audioActivated() {
		guard let s = session, let m = s.media else { return }
		do { try m.startAudio(); s.path = pathLine(s) } catch { callLog("call \(s.id.prefix(8)): audio failed: \(error)"); failed(s, error) }
	}

	/// Two people: how the link goes. More: how many, and the worst of the links.
	func pathLine(_ s: Session) -> String {
		guard let model else { return "" }
		if s.media?.audio.micOff == true { return "Microphone off for baud" }
		if s.group { return "\(s.participants.count + 1) in the call" }
		guard let link = s.participants.first?.link else { return "" }
		if let r = link.relay {
			let p = model.peers.first { $0.device.id == r }
			return "Through " + (p.map { $0.own ? "your \($0.device.name)" : "\($0.userName)'s \($0.device.name)" } ?? "a device")
		}
		return "Direct" + (link.rtt.map { " · \($0) ms" } ?? "") + picture(s, link.device)
	}

	/// Their picture as it arrives, in the words video is sold in: " · 1080p60".
	private func picture(_ s: Session, _ device: String) -> String {
		guard s.video, s.remoteCamera, let q = s.media?.quality(device), q.inFps > 0 else { return "" }
		let sides = q.inSize.split { $0 == "×" || $0 == "x" }.compactMap { Int($0) }
		guard sides.count == 2, let short = sides.min(), short > 0 else { return "" }
		return " · \(short)p\(q.inFps >= 55 ? 60 : q.inFps >= 28 ? 30 : q.inFps)"
	}

	// MARK: presence

	/// To the chat's other members: a call is going on here, and who's in it.
	private func announce(_ s: Session) {
		guard let model, s.startedAt != nil else { return }
		let me = model.me
		let peers = s.phase.over ? [] : [CallPeer(device: me.thisDevice, user: me.user, name: me.name)] + s.participants.map { CallPeer(device: $0.device, user: $0.user, name: $0.name) }
		model.local.announceCall(s.conv, CallPresence(id: s.id, video: s.video, peers: peers, until: Date().addingTimeInterval(40).timeIntervalSince1970))
	}

	private func keepAnnouncing(_ s: Session) {
		Task { [weak self] in
			while let self, self.session === s, !s.phase.over {
				try? await Task.sleep(for: .seconds(15))
				if self.session === s, !s.phase.over { self.announce(s) }
			}
		}
	}

	/// A member's word about a call in a chat.
	private func heard(_ conv: ConversationId, _ p: CallPresence) {
		if p.peers.isEmpty || p.until < Date().timeIntervalSince1970 { if ongoing[conv]?.id == p.id { ongoing[conv] = nil }; return }
		ongoing[conv] = p
	}

	// MARK: the end

	private func finish(_ s: Session, _ why: String, record: String?) {
		guard session === s, !s.phase.over else { return }
		ringer.stop()
		let wasIn = s.startedAt != nil
		s.media?.stop(); s.media = nil
		// The links go half a second later, so the last signal (end, decline) gets there first:
		// closing at once can cut it off, and the other side would hear "dropped".
		let links: [CallRoute] = s.participants.compactMap(\.link) + (s.ringLink.map { [$0] } ?? [])
		Task { try? await Task.sleep(for: .milliseconds(500)); for l in links { l.close("end") } }
		let seconds = s.startedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
		// The caller's device writes the line, once, for everyone.
		if s.outgoing, let outcome = wasIn ? "talked" : record {
			try? model?.local.recordCall(s.conv, video: s.video, outcome: outcome, seconds: seconds)
		}
		s.phase = .ended(why)
		if !s.outgoing, why == "Missed call" { Notifier.shared.missedCall(from: s.caller, conv: s.conv, video: s.video) }
		if wasIn { announce(s) }
		if ongoing[s.conv]?.id == s.id, s.group == false { ongoing[s.conv] = nil }
		callLog("call \(s.id.prefix(8)): ended: \(why)\(seconds > 0 ? ", \(seconds) s" : "")")
		#if os(iOS)
		if !Self.test { kit.ended(s) }
		// Over, with baud in the background: offline again, as it would have been without the call.
		Task { try? await Task.sleep(for: .seconds(5)); if !holdsOnline, UIApplication.shared.applicationState != .active { model?.core.setOnline(false) } }
		#endif
		Task { try? await Task.sleep(for: .seconds(why.count > 40 ? 3.5 : 1.6)); if session === s { session = nil } }
	}
}

/// The last calls' milestones and stats, kept on the device (counts, levels and devices; never
/// what was said): what a call that went wrong did, readable afterwards from the preferences
/// (`callLog`).
enum CallRecord {
	private static let key = "callLog", most = 500
	private static let queue = DispatchQueue(label: "baud.callrecord", qos: .utility)
	nonisolated(unsafe) private static var lines: [String]?
	nonisolated(unsafe) private static let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"; return f }()

	static func keep(_ line: String) {
		let now = Date()
		queue.async {
			var l = lines ?? UserDefaults.standard.stringArray(forKey: key) ?? []
			l.append(stamp.string(from: now) + " " + line)
			if l.count > most { l.removeFirst(l.count - most) }
			lines = l
			UserDefaults.standard.set(l, forKey: key)
		}
	}
}

/// The microphone and, for video, the camera: asked for the first time a call needs them (never
/// at launch, and never in a test call).
enum Permissions {
	static func ask(video: Bool) async {
		guard !CallCenter.test else { return }
		if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined { _ = await AVCaptureDevice.requestAccess(for: .audio) }
		if video, AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined { _ = await AVCaptureDevice.requestAccess(for: .video) }
	}
}

/// A soft two-note chime every three seconds while a call waits to be answered on the Mac. Quiet
/// on purpose: it should be noticed, not startle.
@MainActor
final class Ringer {
	private var engine: AVAudioEngine?
	private var player: AVAudioPlayerNode?
	private var task: Task<Void, Never>?

	func start() {
		guard task == nil else { return }
		let e = AVAudioEngine(), p = AVAudioPlayerNode()
		let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
		e.attach(p); e.connect(p, to: e.mainMixerNode, format: fmt)
		e.mainMixerNode.outputVolume = 0.22
		guard (try? e.start()) != nil, let chime = Self.chime(fmt) else { return }
		engine = e; player = p
		p.play()
		task = Task { [weak self] in
			while !Task.isCancelled {
				self?.player?.scheduleBuffer(chime, completionHandler: nil)
				try? await Task.sleep(for: .seconds(3))
			}
		}
	}

	func stop() {
		task?.cancel(); task = nil
		player?.stop(); engine?.stop(); player = nil; engine = nil
	}

	/// E5 then A5, each with a soft attack and a long tail, and a touch of the octave.
	private static func chime(_ fmt: AVAudioFormat) -> AVAudioPCMBuffer? {
		let n = 48_000 * 9 / 10
		guard let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)) else { return nil }
		b.frameLength = AVAudioFrameCount(n)
		let out = b.floatChannelData![0]
		for i in 0..<n {
			let t = Double(i) / 48_000
			var v = 0.0
			for (start, f) in [(0.0, 659.25), (0.28, 880.0)] where t >= start {
				let u = t - start
				let env = min(1, u / 0.012) * exp(-u * 5)
				v += env * (sin(2 * .pi * f * u) + 0.2 * sin(4 * .pi * f * u))
			}
			out[i] = Float(v * 0.35)
		}
		return b
	}
}

/// A sample-buffer renderer handed to a media queue: each is fed from one queue only.
private struct Renderer: @unchecked Sendable {
	let r: AVSampleBufferVideoRenderer
	init(_ r: AVSampleBufferVideoRenderer) { self.r = r }
}
