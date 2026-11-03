#if DEBUG
/// `BAUD_CALL_SHOTS=<dir>` (Debug, on demo data): every state of a call drawn offscreen to PNG,
/// the video stood in for by stills, then quit. For looking at the design without a call, a
/// camera, a microphone or a screen capture.
import BaudCore
import SwiftUI

enum CallShots {
	@MainActor static func runIfAsked(_ model: AppModel) {
		guard let dir = ProcessInfo.processInfo.environment["BAUD_CALL_SHOTS"] else { return }
		Task { @MainActor in
			try? await Task.sleep(for: .seconds(3))
			try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
			let friend = model.contacts.first { $0.name == "Sam" } ?? model.contacts.first
			let conv = model.conversations.first { $0.isDirect && $0.members.contains(friend?.user ?? "") }?.id ?? ""
			@MainActor func session(video: Bool, outgoing: Bool, phase: CallCenter.Phase, camera: Bool = true, remoteCamera: Bool = true, muted: Bool = false, level: Float = 0.45) -> CallCenter.Session {
				let s = CallCenter.Session(id: UUID().uuidString, conv: conv, outgoing: outgoing, video: video, title: friend?.name ?? "Sam", group: false, caller: friend?.name ?? "Sam", user: friend?.user, avatar: friend?.avatar, phase: phase)
				s.cameraOn = camera; s.startedAt = Date().addingTimeInterval(-252); s.path = "Direct · 14 ms"; s.stillLevel = level
				if phase == .live {
					let p = CallCenter.Participant(device: "d", user: friend?.user ?? "", name: friend?.name ?? "Sam", avatar: friend?.avatar, camera: remoteCamera)
					p.muted = muted; p.showing = remoteCamera; s.participants = [p]
				}
				return s
			}
			/// A group call in "weekend" with these people in it, the second one speaking.
			@MainActor func group(_ names: [String], video: Bool, phase: CallCenter.Phase = .live) -> CallCenter.Session {
				let s = CallCenter.Session(id: UUID().uuidString, conv: conv, outgoing: true, video: video, title: "weekend", group: true, caller: "Ana", user: nil, avatar: nil, phase: phase)
				s.startedAt = Date().addingTimeInterval(-181); s.path = "\(names.count + 1) in the call"
				s.participants = names.enumerated().map { i, n in
					let p = CallCenter.Participant(device: "d\(i)", user: "u\(i)", name: n, avatar: nil, camera: i != 2)
					p.stillLevel = i == 1 ? 0.7 : 0.05; p.muted = i == 3
					return p
				}
				return s
			}
			let stills = CallStills(remote: scene(1280, 720, warm: true), local: scene(1280, 720, warm: false), remotes: [scene(1280, 720, warm: true), scene(1280, 720, warm: false), scene(1280, 720, warm: true), scene(1280, 720, warm: false)].compactMap { $0 })
			let phone = stills.remote.flatMap { _ in scene(720, 1280, warm: true) }
			#if os(macOS)
			let wide = CGSize(width: 880, height: 560), tall = CGSize(width: 400, height: 540)
			#else
			let wide = CGSize(width: 390, height: 844), tall = wide
			#endif
			let shots: [(String, CGSize, CallCenter.Session, CallStills?)] = [
				("ringing", tall, session(video: false, outgoing: true, phase: .ringing, level: 0), nil),
				("voice", tall, session(video: false, outgoing: true, phase: .live), nil),
				("voice-muted", tall, session(video: false, outgoing: false, phase: .live, muted: true, level: 0.1), nil),
				("video", wide, session(video: true, outgoing: true, phase: .live), stills),
				("video-camera-off", wide, session(video: true, outgoing: true, phase: .live, remoteCamera: false), stills),
				("incoming", tall, session(video: true, outgoing: false, phase: .incoming, level: 0), nil),
				("ended", tall, session(video: false, outgoing: true, phase: .ended("\(friend?.name ?? "Sam") declined"), level: 0), nil),
				("phone-video", CGSize(width: 390, height: 844), session(video: true, outgoing: true, phase: .live), CallStills(remote: phone, local: stills.local)),
				("group-video-2", wide, group(["Ana", "Jo"], video: true), stills),
				("group-video-4", wide, group(["Ana", "Jo", "Sam", "Lee"], video: true), stills),
				("group-voice-3", CGSize(width: 640, height: 480), group(["Ana", "Jo", "Sam"], video: false), nil),
				("group-ringing", tall, group([], video: true, phase: .ringing), nil),
				("group-phone-4", CGSize(width: 390, height: 844), group(["Ana", "Jo", "Sam", "Lee"], video: true), stills),
				("phone-calling-video", CGSize(width: 390, height: 844), session(video: true, outgoing: true, phase: .ringing, level: 0), CallStills(remote: nil, local: phone)),
			]
			for (name, size, s, st) in shots {
				write(CallScreen(session: s).environment(model).environment(\.callStills, st).frame(width: size.width, height: size.height), to: "\(dir)/call-\(name).png")
			}
			// The call made small: their picture, and a voice call.
			let small: [(String, CallCenter.Session, CallStills?)] = [
				("mini-video", { let s = session(video: true, outgoing: true, phase: .live); s.remoteAspect = 16 / 9; return s }(), stills),
				("mini-phone-video", { let s = session(video: true, outgoing: true, phase: .live); s.remoteAspect = 9 / 16; return s }(), CallStills(remote: phone, local: stills.local)),
				("mini-voice", session(video: false, outgoing: true, phase: .live, muted: false, level: 0.4), nil),
			]
			for (name, s, st) in small {
				let size = CallMini.size(s)
				write(CallMini(session: s).environment(model).environment(\.callStills, st).frame(width: size.width, height: size.height).padding(24).background(Color(white: 0.55)), to: "\(dir)/call-\(name).png")
			}
			#if os(macOS)
			write(IncomingCall(session: session(video: true, outgoing: false, phase: .incoming)).environment(model).frame(width: 372, height: 92).padding(24).background(Color(white: 0.55)), to: "\(dir)/call-panel.png")
			let g = CallCenter.Session(id: "g", conv: conv, outgoing: false, video: true, title: "weekend", group: true, caller: "Ana", user: nil, avatar: nil, phase: .incoming)
			write(IncomingCall(session: g).environment(model).frame(width: 372, height: 92).padding(24).background(Color(white: 0.55)), to: "\(dir)/call-panel-group.png")
			#endif
			Measure.log("call shots in \(dir)")
			exit(0)
		}
	}

	/// `BAUD_CALL_AUTO=voice|video` (Debug, with `BAUD_CALL_TEST=1`): once a direct chat's other
	/// side (or, with `BAUD_CALL_TO=self`, another device of mine) is online, call it, talk for `BAUD_CALL_SECONDS` (10), hang up. The other side answers
	/// with `BAUD_CALL_ANSWER=1`. The proof is the log: ringing, live, a stats line a second, ended,
	/// and the line each side's chat shows.
	@MainActor static func autoCall(_ model: AppModel) {
		let env = ProcessInfo.processInfo.environment
		guard let kind = env["BAUD_CALL_AUTO"] else { return }
		let hold = Double(env["BAUD_CALL_SECONDS"] ?? "") ?? 10
		Task { @MainActor in
			var placed: ConversationId?
			for _ in 0..<90 {
				// `BAUD_CALL_TO=self`: my chat with myself, once another device of mine is online or can be woken.
				if env["BAUD_CALL_TO"] == "self", let n = model.notes, model.me.devices.contains(where: { $0.id != model.me.thisDevice && ($0.online || model.local.canWake($0.id)) }) {
					Measure.log("auto call: \(kind) to my other devices")
					model.calls.start(n.id, video: kind == "video"); placed = n.id; break
				}
				if env["BAUD_CALL_TO"] != "self", let c = model.core.conversations(.chat).first(where: { $0.isDirect }),
				   model.core.members(c.id).contains(where: { !$0.me && $0.devices.contains(where: \.online) }) {
					Measure.log("auto call: \(kind) to \(model.title(c))")
					model.calls.start(c.id, video: kind == "video"); placed = c.id; break
				}
				try? await Task.sleep(for: .seconds(1))
			}
			guard let conv = placed else { Measure.log("auto call: nobody online to call"); return }
			for _ in 0..<60 { if let s = model.calls.session, s.phase == .live || s.phase.over { break }; try? await Task.sleep(for: .milliseconds(500)) }
			try? await Task.sleep(for: .seconds(hold))
			model.calls.end()
			try? await Task.sleep(for: .seconds(3))
			Measure.log("auto call: the chat says \(model.core.events(conv, before: nil, limit: 5).compactMap(\.system))")
		}
	}

	/// `BAUD_GROUP_CALL=host|b|c|…` (Debug, with `BAUD_LINK_FILE` and `BAUD_CALL_TEST=1`): people
	/// and a group. The host invites the others (`BAUD_GROUP_OTHERS`, "b,c" by default), makes "weekend" with them, and once both
	/// are online calls it on video, holds `BAUD_CALL_SECONDS` (30) and hangs up. The others answer
	/// or decline by `BAUD_CALL_ANSWER`; `BAUD_CALL_JOIN_AT=s` joins from the chat that long after
	/// hearing of the call; `BAUD_CALL_LEAVE_AT=s` leaves that long after it went live.
	@MainActor static func groupCall(_ model: AppModel) {
		let env = ProcessInfo.processInfo.environment
		guard let role = env["BAUD_GROUP_CALL"], let file = env["BAUD_LINK_FILE"] else { return }
		Task { @MainActor in
			try? await Task.sleep(for: .seconds(3))
			if role == "host" {
				// `BAUD_GROUP_OTHERS=b,c,d`: who else comes, one invite each.
				let others = (env["BAUD_GROUP_OTHERS"] ?? "b,c").split(separator: ",").map(String.init)
				for o in others {
					guard let link = try? model.core.invite() else { Measure.log("group host: invite failed"); return }
					try? link.url.write(toFile: file + "." + o, atomically: true, encoding: .utf8)
				}
				for _ in 0..<60 { if model.core.contacts().count >= others.count { break }; try? await Task.sleep(for: .seconds(1)) }
				guard model.core.contacts().count >= others.count, let g = try? model.core.createGroup("weekend", users: model.core.contacts().map(\.user)) else { Measure.log("group host: no group"); return }
				Measure.log("group host: made weekend with \(model.core.members(g.id).count) members")
				for _ in 0..<60 {
					if model.core.members(g.id).filter({ !$0.me }).allSatisfy({ $0.devices.contains(where: \.online) }) { break }
					try? await Task.sleep(for: .seconds(1))
				}
				try? await Task.sleep(for: .seconds(3))
				model.calls.start(g.id, video: true)
				try? await Task.sleep(for: .seconds(Double(env["BAUD_CALL_SECONDS"] ?? "") ?? 30))
				Measure.log("group host: hanging up with \(model.calls.session?.participants.map(\.name) ?? [])")
				model.calls.end()
				try? await Task.sleep(for: .seconds(3))
				Measure.log("group host: the chat says \(model.core.events(g.id, before: nil, limit: 6).compactMap(\.system))")
			} else {
				var url: String?
				for _ in 0..<60 { url = try? String(contentsOfFile: file + "." + role, encoding: .utf8); if url != nil { break }; try? await Task.sleep(for: .seconds(1)) }
				guard let url, let link = parseLink(url: url.trimmingCharacters(in: .whitespacesAndNewlines)) else { Measure.log("group \(role): no link"); return }
				do { let k = try await model.core.add(link); Measure.log("group \(role): added \(k.name)") } catch { Measure.log("group \(role): add failed: \(error)"); return }
				if let at = env["BAUD_CALL_JOIN_AT"].flatMap(Double.init) {
					for _ in 0..<120 { if !model.calls.ongoing.isEmpty, model.calls.session == nil { break }; try? await Task.sleep(for: .milliseconds(500)) }
					guard let conv = model.calls.ongoing.keys.first else { Measure.log("group \(role): never heard of a call"); return }
					Measure.log("group \(role): heard of the call: \(model.calls.ongoing[conv]?.peers.map(\.name) ?? [])")
					try? await Task.sleep(for: .seconds(at))
					Measure.log("group \(role): joining")
					model.calls.join(conv)
				}
				if let at = env["BAUD_CALL_LEAVE_AT"].flatMap(Double.init) {
					for _ in 0..<120 { if model.calls.session?.phase == .live { break }; try? await Task.sleep(for: .milliseconds(500)) }
					try? await Task.sleep(for: .seconds(at))
					Measure.log("group \(role): leaving")
					model.calls.end()
				}
			}
		}
	}

	@MainActor private static func write(_ view: some View, to path: String) {
		let r = ImageRenderer(content: view)
		r.scale = 2
		guard let cg = r.cgImage else { Measure.log("call shot \(path): nothing drawn"); return }
		let url = URL(fileURLWithPath: path) as CFURL
		guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else { return }
		CGImageDestinationAddImage(dest, cg, nil); CGImageDestinationFinalize(dest)
	}

	/// A stand-in for a video frame: a room in soft light, out of focus.
	private static func scene(_ w: Int, _ h: Int, warm: Bool) -> CGImage? {
		guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
		let base: [CGColor] = warm
			? [CGColor(red: 0.36, green: 0.27, blue: 0.22, alpha: 1), CGColor(red: 0.13, green: 0.10, blue: 0.10, alpha: 1)]
			: [CGColor(red: 0.20, green: 0.26, blue: 0.33, alpha: 1), CGColor(red: 0.07, green: 0.09, blue: 0.12, alpha: 1)]
		let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: base as CFArray, locations: [0, 1])!
		ctx.drawRadialGradient(g, startCenter: CGPoint(x: Double(w) * 0.62, y: Double(h) * 0.58), startRadius: 0, endCenter: CGPoint(x: Double(w) * 0.5, y: Double(h) * 0.5), endRadius: Double(max(w, h)) * 0.75, options: [.drawsAfterEndLocation])
		// Lamps and windows, out of focus.
		var rng = SystemRandomNumberGenerator()
		for i in 0..<14 {
			let r = Double.random(in: 30...110, using: &rng)
			let x = Double.random(in: 0...Double(w), using: &rng), y = Double.random(in: Double(h) * 0.35...Double(h), using: &rng)
			let a = Double.random(in: 0.05...0.16, using: &rng)
			ctx.setFillColor(warm ? CGColor(red: 1, green: 0.82, blue: 0.6, alpha: a) : CGColor(red: 0.7, green: 0.85, blue: 1, alpha: a))
			ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
			_ = i
		}
		// Someone in the middle of the frame: a soft head and shoulders.
		let cx = Double(w) * 0.5, s = Double(min(w, h))
		ctx.setFillColor(CGColor(red: 0.08, green: 0.06, blue: 0.06, alpha: 0.55))
		ctx.fillEllipse(in: CGRect(x: cx - s * 0.42, y: -s * 0.25, width: s * 0.84, height: s * 0.62))
		ctx.setFillColor(CGColor(red: 0.62, green: 0.47, blue: 0.40, alpha: warm ? 0.9 : 0.75))
		ctx.fillEllipse(in: CGRect(x: cx - s * 0.16, y: s * 0.30, width: s * 0.32, height: s * 0.38))
		return ctx.makeImage()
	}
}
#endif
