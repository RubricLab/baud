/// My network as one picture: this device in the middle, in the loud fill; my other devices
/// fanned above it, each joined by how it is reached right now: a solid line direct (its time on
/// it), dashed through a helper (whose), dotted while it is away. Under it, my friends in one line:
/// how many I reach directly, through a helper, and how many are away. Friends have their own card;
/// this is the map of my own devices.
import BaudCore
import SwiftUI

struct NetworkPicture: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	@State private var width: CGFloat = 0

	struct Node: Identifiable {
		let id: DeviceId
		let shape: DeviceShape
		let name: String
		let status: String
		let on: Bool
		var ms: Int? = nil
		var via: String? = nil
	}

	static let me: CGFloat = 66, node: CGFloat = 50
	/// Before the card has a width (a picture drawn offscreen): about what it has on each.
	#if os(iOS)
	static let fallback: CGFloat = 326
	#else
	static let fallback: CGFloat = 560
	#endif

	var body: some View {
		let (here, others) = nodes()
		let w = width > 0 ? width : Self.fallback
		let r = min(w / 2 - 64, 150)
		let h: CGFloat = others.isEmpty ? 150 : r + 160
		let c = CGPoint(x: w / 2, y: others.isEmpty ? 54 : r + 84)
		let at = Self.fan(others.count, around: c, radius: r)
		VStack(alignment: .leading, spacing: 18) {
			ZStack(alignment: .topLeading) {
				ForEach(Array(others.enumerated()), id: \.element.id) { i, n in line(n, from: c, to: at[i]) }
				ForEach(Array(others.enumerated()), id: \.element.id) { i, n in chip(n).position(Self.toward(c, at[i], 0.42)) }
				ForEach(Array(others.enumerated()), id: \.element.id) { i, n in device(n, size: Self.node, loud: false, above: true).position(at[i]) }
				device(here, size: Self.me, loud: true).position(c)
				if others.isEmpty {
					Text("Only this \(AppModel.thisKind) so far").font(Theme.smallFont).foregroundStyle(tones.secondary)
						.position(x: c.x, y: c.y + Self.me / 2 + 62)
				}
			}
			.frame(width: w, height: h)
			.frame(maxWidth: .infinity)
			.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
			FriendsReach()
		}
	}

	/// Where my other devices sit: one straight above, more spread over the top half.
	static func fan(_ n: Int, around c: CGPoint, radius r: CGFloat) -> [CGPoint] {
		(0..<n).map { i in
			let deg = n == 1 ? -90.0 : -162.0 + 144.0 * Double(i) / Double(n - 1)
			let a = deg * .pi / 180
			return CGPoint(x: c.x + r * CGFloat(cos(a)), y: c.y + r * CGFloat(sin(a)))
		}
	}
	/// The way along a line from `a` to `b`: the chips sit nearer this device, clear of the labels.
	static func toward(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }

	/// How it is reached: solid when direct, dashed through a helper, dotted while away.
	private func line(_ n: Node, from a: CGPoint, to b: CGPoint) -> some View {
		let d = hypot(b.x - a.x, b.y - a.y), ux = (b.x - a.x) / d, uy = (b.y - a.y) / d
		let start = CGPoint(x: a.x + ux * (Self.me / 2 + 6), y: a.y + uy * (Self.me / 2 + 6))
		let end = CGPoint(x: b.x - ux * (Self.node / 2 + 6), y: b.y - uy * (Self.node / 2 + 6))
		let style: StrokeStyle = !n.on ? StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [0.1, 7]) : n.via != nil ? StrokeStyle(lineWidth: 3, lineCap: .round, dash: [9, 7]) : StrokeStyle(lineWidth: 3.5, lineCap: .round)
		return SwiftUI.Path { p in p.move(to: start); p.addLine(to: end) }.stroke(n.on ? tones.text : tones.tertiary, style: style)
	}

	@ViewBuilder private func chip(_ n: Node) -> some View {
		let words: String? = !n.on ? nil : n.via.map { "via \($0)" } ?? n.ms.map { "\($0) ms" }
		if let words {
			Text(words).font(.system(size: Theme.small - 1, weight: .bold)).monospacedDigit().lineLimit(1)
				.padding(.horizontal, 8).frame(height: 20)
				.background(Capsule().fill(tones.card).lifted(tones, by: 0.5))
				.foregroundStyle(tones.text)
		}
	}

	/// A device: a disc with its kind drawn on it, its name and how it is beside it: under this
	/// device, over the others (the lines come from below, so they never cross the words).
	private func device(_ n: Node, size: CGFloat, loud: Bool, above: Bool = false) -> some View {
		let words = VStack(spacing: 1) {
			Text(n.name).font(Theme.smallFont.weight(.bold)).foregroundStyle(tones.text).lineLimit(1)
			Text(n.status).font(.system(size: Theme.small - 1, weight: .medium)).foregroundStyle(tones.secondary).lineLimit(1)
		}.fixedSize()
		return VStack(spacing: 6) {
			if above { words }
			Circle().fill(loud ? tones.loud : n.on ? tones.card : Color.clear)
				.overlay { if !loud && !n.on { Circle().strokeBorder(tones.tertiary, style: StrokeStyle(lineWidth: 2, dash: [4, 4])) } }
				.overlay(Image(systemName: Self.symbol(n.shape)).font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(loud ? tones.onLoud : n.on ? tones.text : tones.tertiary))
				.frame(width: size, height: size)
				.modifier(LiftIf(on: loud || n.on, tones: tones))
			if !above { words }
		}
		// The disc's centre is the point: the words hang beside it.
		.offset(y: (above ? -1 : 1) * ((size + 6 + 30) / 2 - size / 2))
		.accessibilityElement(children: .combine)
	}
	private struct LiftIf: ViewModifier {
		let on: Bool; let tones: Tones
		func body(content: Content) -> some View { if on { content.lifted(tones) } else { content } }
	}

	static func symbol(_ s: DeviceShape) -> String {
		switch s {
		case .iphone: return "iphone"
		case .android: return "candybarphone"
		case .ipad: return "ipad"
		case .macbook, .pcLaptop: return "laptopcomputer"
		case .imac: return "desktopcomputer"
		case .macMini: return "macmini"
		case .macStudio: return "macstudio"
		case .pcTower: return "pc"
		}
	}

	// MARK: who is in the picture

	private func nodes() -> (Node, [Node]) {
		#if DEBUG
		if let staged = Self.staged() { return staged }
		#endif
		let thisID = model.me.thisDevice
		let here = model.me.devices.first { $0.id == thisID }
		let net = model.netState
		let me = Node(id: thisID, shape: here.map(DeviceShape.init) ?? (AppModel.deviceKind == .iphone ? .iphone : .macbook), name: "This \(AppModel.thisKind)", status: net.words(connecting: model.connecting), on: net != .offline)
		let mine = model.peers.filter(\.own).sorted { ($0.device.online ? 0 : 1, $0.device.name) < ($1.device.online ? 0 : 1, $1.device.name) }
		let others = mine.map { p -> Node in
			var n = Node(id: p.device.id, shape: DeviceShape(p.device), name: Names.device(p.device.name), status: p.device.online ? "Online" : p.device.word.capitalizedFirst, on: p.device.online)
			switch p.device.path {
			case .direct(let ms): n.ms = ms
			case .relay(_, let name): n.via = Names.device(name)
			default: break
			}
			return n
		}
		return (me, others)
	}

	#if DEBUG
	/// `BAUD_PICTURE=staged`: a Mac mini direct, an iPad through it, a phone away.
	static func staged() -> (Node, [Node])? {
		guard ProcessInfo.processInfo.environment["BAUD_PICTURE"] != nil else { return nil }
		let phone = AppModel.deviceKind == .iphone
		return (Node(id: "me", shape: phone ? .iphone : .macbook, name: "This \(AppModel.thisKind)", status: "Online", on: true),
			[Node(id: "mini", shape: .macMini, name: "Mac mini", status: "Online", on: true, ms: 4),
			 Node(id: "ipad", shape: .ipad, name: "iPad", status: "Online", on: true, via: "Mac mini"),
			 Node(id: "phone", shape: phone ? .macbook : .iphone, name: phone ? "MacBook" : "iPhone", status: "Away 2 h", on: false)])
	}
	#endif
}

/// My friends, in one line: how many I reach directly, through a helper, and how many are away.
struct FriendsReach: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	var body: some View {
		let ways = model.contacts.map { k -> Int in
			let on = k.devices.filter(\.online)
			if on.contains(where: { if case .direct = $0.path { return true }; if case .nearby = $0.path { return true }; return false }) { return 0 }
			return on.isEmpty ? 2 : 1
		}
		let counts = [ways.filter { $0 == 0 }.count, ways.filter { $0 == 1 }.count, ways.filter { $0 == 2 }.count]
		if !model.contacts.isEmpty {
			HStack(spacing: 8) {
				Text("Friends").font(Theme.smallFont.weight(.bold)).foregroundStyle(tones.text)
				ForEach(Array(zip(["direct", "through a helper", "away"], counts).enumerated()), id: \.offset) { i, w in
					if w.1 > 0 {
						Text("\(w.1) \(w.0)").font(.system(size: Theme.small, weight: .semibold)).monospacedDigit()
							.padding(.horizontal, 9).frame(height: 22)
							.background(Capsule().fill(i == 0 ? tones.loud : tones.quiet))
							.foregroundStyle(i == 0 ? tones.onLoud : tones.text)
					}
				}
				Spacer(minLength: 0)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.accessibilityElement(children: .combine)
		}
	}
}

/// Why a computer at home: two phones that can't find each other; a Mac fades in at home; both
/// lines bend to it and light; a message travels phone → Mac → phone. Plays on a loop. `withMac`
/// false is the same picture stopped before the Mac comes (the Add screen when nothing is stable).
struct StablePicture: View {
	@Environment(\.tones) private var tones
	var withMac = true
	var body: some View {
		SwiftUI.TimelineView(.animation(minimumInterval: 1 / 30, paused: !withMac)) { ctx in
			let t = withMac ? ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4.4) / 4.4 : 0.1
			GeometryReader { g in
				let w = g.size.width, h = g.size.height
				let left = CGPoint(x: w * 0.2, y: h * 0.3), right = CGPoint(x: w * 0.8, y: h * 0.3), home = CGPoint(x: w * 0.5, y: h * 0.74)
				let mac = clamp((t - 0.22) / 0.12)          // the Mac fades in
				let lines = clamp((t - 0.36) / 0.1)         // the bent lines light
				ZStack {
					// The direct line between the phones, dashed, broken in the middle: it fails.
					SwiftUI.Path { p in p.move(to: left); p.addLine(to: CGPoint(x: w * 0.44, y: h * 0.3)); p.move(to: CGPoint(x: w * 0.56, y: h * 0.3)); p.addLine(to: right) }
						.stroke(tones.text.opacity(0.35 * (1 - lines)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [3, 4]))
					Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(tones.secondary).position(x: w * 0.5, y: h * 0.3).opacity(1 - lines)
					SwiftUI.Path { p in p.move(to: left); p.addLine(to: home); p.addLine(to: right) }
						.stroke(tones.strong.opacity(0.85 * lines), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
					if withMac {
						DeviceGlyph(shape: .macMini, size: 52).overlay(alignment: .topTrailing) { MarkView(mark: .stable, size: 14, color: tones.strong).offset(x: 4, y: -2) }
							.position(home).opacity(mac)
						// The message: phone → Mac → phone.
						let m = clamp((t - 0.5) / 0.4)
						if m > 0, m < 1 {
							Circle().fill(tones.strong).frame(width: 9, height: 9)
								.position(m < 0.5 ? lerp(left, home, m * 2) : lerp(home, right, (m - 0.5) * 2))
						}
					}
					DeviceGlyph(shape: .iphone, size: 44).position(left)
					DeviceGlyph(shape: .iphone, size: 44).position(right)
				}
			}
		}
		.frame(height: 190)
		.accessibilityLabel("A computer at home carries messages between phones")
	}
	private func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
	private func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }
}
