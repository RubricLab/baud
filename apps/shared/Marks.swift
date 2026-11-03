/// baud's marks: one family of small drawings on the 24 grid at the family stroke (2.25, round caps
/// and joins), the family dot (a 4.5 disc) as the light. Four sets, each mark meaning one thing:
/// delivery (sending, carried, delivered, read), propagation (direct, through a helper, carried by
/// a device, waiting), presence (online direct, online relayed, away, never seen) and identity
/// (verified, vouched, unverified). The same drawings on the Mac and the iPhone, in the message
/// row, the conversation row, the member list and the network picture; documented with their
/// paths, at three sizes, by the Mac app's Shots mode.
import BaudCore
import SwiftUI

enum Mark: String, CaseIterable, Identifiable {
	// delivery: what happened to a message I sent
	case sending, carried, delivered, read
	// propagation: how bytes travel between two devices
	case direct, relayed, held, waiting
	// presence: a person or a device, right now
	case online, onlineRelayed, away, neverSeen
	// identity: has anyone I trust checked this key
	case verified, vouched, unverified
	// stable: a device reachable from outside, a home for messages when phones can't meet
	case stable
	var id: String { rawValue }

	/// One line for a tooltip or VoiceOver; the sentences with names come from the core.
	var meaning: String {
		switch self {
		case .sending: return "Sending: still only on this device"
		case .carried: return "Carried: a device is holding it for them"
		case .delivered: return "Delivered to their device"
		case .read: return "Read"
		case .direct: return "Direct: device to device, nothing in between"
		case .relayed: return "Through a helper: a friend's or your own device forwards it"
		case .held: return "Carried by a device until they come back"
		case .waiting: return "Waiting: nobody online to carry it yet"
		case .online: return "Online, direct"
		case .onlineRelayed: return "Online, through a helper"
		case .away: return "Away"
		case .neverSeen: return "Never seen online"
		case .verified: return "Verified by you"
		case .vouched: return "Vouched for by someone you verified"
		case .unverified: return "Not verified"
		case .stable: return "Reachable"
		}
	}

	/// The drawing in 24-grid units.
	var drawing: Drawing {
		var d = Drawing()
		switch self {
		case .sending:
			// The light, not out yet: a ring left open at the top, so it reads as on its way, not as a letter.
			d.stroke(SwiftUI.Path { p in p.addArc(center: .init(x: 12, y: 12), radius: 7.25, startAngle: .degrees(-55), endAngle: .degrees(-125), clockwise: false) })
		case .carried:
			d.stroke(SwiftUI.Path { p in p.move(to: .init(x: 5, y: 12.5)); p.addLine(to: .init(x: 9.5, y: 17)); p.addLine(to: .init(x: 19, y: 6.5)) })
		case .delivered:
			d.stroke(SwiftUI.Path { p in p.move(to: .init(x: 2, y: 12.5)); p.addLine(to: .init(x: 6.5, y: 17)); p.addLine(to: .init(x: 15.5, y: 7)) })
			d.stroke(SwiftUI.Path { p in p.move(to: .init(x: 10, y: 15)); p.addLine(to: .init(x: 12, y: 17)); p.addLine(to: .init(x: 21, y: 7)) })
		case .read:
			d.fill(SwiftUI.Path(ellipseIn: CGRect(x: 1, y: 1, width: 22, height: 22)))
			d.knock(SwiftUI.Path { p in p.move(to: .init(x: 5, y: 12.5)); p.addLine(to: .init(x: 8.25, y: 15.75)); p.addLine(to: .init(x: 14.5, y: 8.75)) })
			d.knock(SwiftUI.Path { p in p.move(to: .init(x: 11.25, y: 14.5)); p.addLine(to: .init(x: 12.5, y: 15.75)); p.addLine(to: .init(x: 19, y: 8.75)) })
		case .direct:
			// baud's own mark: two lights and the line between them, nothing in the middle.
			d.dot(4.5, 12); d.dot(19.5, 12)
			d.stroke(SwiftUI.Path { p in p.move(to: .init(x: 9.5, y: 12)); p.addLine(to: .init(x: 14.5, y: 12)) })
		case .relayed:
			// the two ends, and a helper above them the path bends through.
			d.dot(3.5, 17); d.dot(20.5, 17); d.dot(12, 5)
			d.stroke(SwiftUI.Path { p in p.move(to: .init(x: 6.4, y: 12.9)); p.addLine(to: .init(x: 9.1, y: 9.1)) })
			d.stroke(SwiftUI.Path { p in p.move(to: .init(x: 14.9, y: 9.1)); p.addLine(to: .init(x: 17.6, y: 12.9)) })
		case .held:
			// a light held in a cup: a device keeping it until they come back.
			d.stroke(SwiftUI.Path { p in p.move(to: .init(x: 5, y: 7.5)); p.addLine(to: .init(x: 5, y: 12.5)); p.addArc(center: .init(x: 12, y: 12.5), radius: 7, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true); p.addLine(to: .init(x: 19, y: 7.5)) })
			d.dot(12, 11)
		case .waiting:
			// the light still here, the way on not there yet.
			d.dot(4.5, 12)
			d.stroke(SwiftUI.Path { p in p.move(to: .init(x: 10, y: 12)); p.addLine(to: .init(x: 21, y: 12)) }, dash: [1.5, 3.25])
		case .online:
			d.fill(SwiftUI.Path(ellipseIn: CGRect(x: 2, y: 2, width: 20, height: 20)), opacity: 0.22)
			d.fill(SwiftUI.Path(ellipseIn: CGRect(x: 6.5, y: 6.5, width: 11, height: 11)))
		case .onlineRelayed:
			d.stroke(SwiftUI.Path(ellipseIn: CGRect(x: 3.25, y: 3.25, width: 17.5, height: 17.5)))
			d.fill(SwiftUI.Path(ellipseIn: CGRect(x: 8.25, y: 8.25, width: 7.5, height: 7.5)))
		case .away:
			// the light, off: its outline only.
			d.stroke(SwiftUI.Path(ellipseIn: CGRect(x: 6.25, y: 6.25, width: 11.5, height: 11.5)))
		case .neverSeen:
			d.stroke(SwiftUI.Path(ellipseIn: CGRect(x: 6.25, y: 6.25, width: 11.5, height: 11.5)), dash: [2.2, 2.6], opacity: 0.6)
		case .verified:
			d.stroke(SwiftUI.Path(ellipseIn: CGRect(x: 3.25, y: 3.25, width: 17.5, height: 17.5)))
			d.stroke(SwiftUI.Path { p in p.move(to: .init(x: 8.25, y: 12.25)); p.addLine(to: .init(x: 10.9, y: 14.9)); p.addLine(to: .init(x: 15.9, y: 9.25)) })
		case .vouched:
			d.stroke(SwiftUI.Path(ellipseIn: CGRect(x: 3.25, y: 3.25, width: 17.5, height: 17.5)), dash: [3, 2.5])
			d.stroke(SwiftUI.Path { p in p.move(to: .init(x: 8.25, y: 12.25)); p.addLine(to: .init(x: 10.9, y: 14.9)); p.addLine(to: .init(x: 15.9, y: 9.25)) })
		case .unverified:
			d.stroke(SwiftUI.Path(ellipseIn: CGRect(x: 3.25, y: 3.25, width: 17.5, height: 17.5)), dash: [0.01, 3.6], opacity: 0.7)
		case .stable:
			// a house with its light on: the device that is always home.
			d.stroke(SwiftUI.Path { p in p.move(to: .init(x: 3.5, y: 11)); p.addLine(to: .init(x: 12, y: 3.75)); p.addLine(to: .init(x: 20.5, y: 11)) })
			d.stroke(SwiftUI.Path { p in p.move(to: .init(x: 6, y: 9.5)); p.addLine(to: .init(x: 6, y: 20)); p.addLine(to: .init(x: 18, y: 20)); p.addLine(to: .init(x: 18, y: 9.5)) })
			d.dot(12, 14.5)
		}
		return d
	}

	struct Drawing {
		struct Part { var path: SwiftUI.Path; var kind: Kind; var dash: [CGFloat] = []; var opacity: Double = 1 }
		enum Kind { case stroke, fill, knock }
		var parts: [Part] = []
		mutating func stroke(_ p: SwiftUI.Path, dash: [CGFloat] = [], opacity: Double = 1) { parts.append(Part(path: p, kind: .stroke, dash: dash, opacity: opacity)) }
		mutating func fill(_ p: SwiftUI.Path, opacity: Double = 1) { parts.append(Part(path: p, kind: .fill, opacity: opacity)) }
		/// Drawn out of what is under it (the checks in `read`).
		mutating func knock(_ p: SwiftUI.Path) { parts.append(Part(path: p, kind: .knock)) }
		/// The family dot: a circle of radius 1.1 under the 2.25 stroke, a 4.5 disc.
		mutating func dot(_ x: CGFloat, _ y: CGFloat) { fill(SwiftUI.Path(ellipseIn: CGRect(x: x - 2.25, y: y - 2.25, width: 4.5, height: 4.5))) }
	}

	// MARK: what the data says

	static func delivery(_ d: Delivery) -> Mark {
		switch d.best { case .sent: return .sending; case .carried: return .carried; case .delivered: return .delivered; case .read: return .read }
	}
	static func presence(_ d: Device) -> Mark {
		if d.online { if case .relay = d.path { return .onlineRelayed }; return .online }
		return d.lastOnline == nil ? .neverSeen : .away
	}
	/// A person: their best device.
	static func presence(_ devices: [Device]) -> Mark {
		let marks = devices.map(presence)
		for m in [Mark.online, .onlineRelayed, .away] where marks.contains(m) { return m }
		return .neverSeen
	}
	static func path(_ p: BaudCore.Path) -> Mark? {
		switch p {
		case .direct, .nearby: return .direct
		case .relay: return .relayed
		case .waiting, .unreachable, .none: return nil
		}
	}
}

/// The mark at a size, in the colour of the text around it unless told otherwise.
struct MarkView: View {
	@Environment(\.tones) private var tones
	let mark: Mark
	var size: CGFloat = 14
	var color: Color? = nil
	var body: some View {
		let s = size / 24
		// Optical size: a mark beside small type keeps a stroke you can see (1.4 pt at 12 pt, not 1.1).
		let w = 2.25 * s * (size < 18 ? 1.25 : 1)
		let c = color ?? tones.text
		ZStack {
			ForEach(Array(mark.drawing.parts.enumerated()), id: \.offset) { _, part in
				let shape = Grid(path: part.path)
				switch part.kind {
				case .stroke: shape.stroke(c, style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round, dash: part.dash.map { $0 * s })).opacity(part.opacity)
				case .fill: shape.fill(c).opacity(part.opacity)
				case .knock: shape.stroke(Color.black, style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round)).blendMode(.destinationOut)
				}
			}
		}
		.compositingGroup()
		.frame(width: size, height: size)
		.accessibilityLabel(mark.meaning)
	}
	/// A path in 24-grid units, scaled to the frame.
	struct Grid: Shape {
		let path: SwiftUI.Path
		func path(in r: CGRect) -> SwiftUI.Path { path.applying(CGAffineTransform(scaleX: r.width / 24, y: r.height / 24).translatedBy(x: r.minX * 24 / r.width, y: r.minY * 24 / r.height)) }
	}
}

/// A mark as an image, to sit inside a line of text and wrap with it. Drawn once per look.
@MainActor
enum MarkImage {
	private static var cache: [String: Image] = [:]
	static func image(_ mark: Mark, size: CGFloat, color: Color) -> Image {
		let key = "\(mark.rawValue)-\(size)-\(color.description)"
		if let i = cache[key] { return i }
		let r = ImageRenderer(content: MarkView(mark: mark, size: size, color: color))
		#if os(macOS)
		r.scale = NSScreen.main?.backingScaleFactor ?? 2
		let img = r.nsImage.map { Image(nsImage: $0) } ?? Image(systemName: "circle")
		#else
		r.scale = 3
		let img = r.uiImage.map { Image(uiImage: $0) } ?? Image(systemName: "circle")
		#endif
		cache[key] = img
		return img
	}
}

/// The sending ring turns while it's on its way to someone online, and sits still while it waits
/// for them: the difference between "now" and "when they're back", at a glance.
struct Turning: ViewModifier {
	@Environment(\.accessibilityReduceMotion) private var still
	let on: Bool
	func body(content: Content) -> some View {
		if on && !still {
			SwiftUI.TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
				content.rotationEffect(.degrees(ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2 * 360))
			}
		} else { content }
	}
}

/// A delivery mark with its sentence a hover (Mac) or a tap (iPhone) away.
struct DeliveryMark: View {
	@Environment(\.tones) private var tones
	let delivery: Delivery
	var size: CGFloat = 14
	/// Its own tap target (in a chat); in a list row it's only a mark, and the row takes the tap.
	var interactive = true
	@State private var showing = false
	var body: some View {
		let m = Mark.delivery(delivery)
		let mark = MarkView(mark: m, size: size, color: m == .sending ? tones.secondary : tones.text)
			.modifier(Turning(on: m == .sending && delivery.devices.contains { $0.device.online }))
			.help(delivery.sentence)
			.accessibilityLabel(delivery.sentence)
		#if os(iOS)
		if interactive {
			mark.contentShape(Rectangle().inset(by: -6))
				.onTapGesture { showing.toggle() }
				.popover(isPresented: $showing) { Text(delivery.sentence).font(Theme.smallFont).padding(10).frame(maxWidth: 320).presentationCompactAdaptation(.popover) }
		} else {
			mark.allowsHitTesting(false)
		}
		#else
		mark
		#endif
	}
}

// MARK: devices

/// What a device is, for its icon: the kind the crate gives, sharpened by its name.
enum DeviceShape: String {
	case iphone, android, ipad, macbook, imac, macMini = "mac-mini", macStudio = "mac-studio", pcLaptop = "pc-laptop", pcTower = "pc-tower"
	init(_ d: Device) {
		let n = d.name.lowercased()
		if n.contains("ipad") { self = .ipad; return }
		switch d.kind {
		case .iphone: self = .iphone
		case .android: self = .android
		case .mac: self = n.contains("mini") ? .macMini : n.contains("studio") ? .macStudio : n.contains("imac") ? .imac : .macbook
		case .node: self = .pcLaptop
		}
	}
	/// The word for it.
	var word: String {
		switch self {
		case .iphone: return "iPhone"
		case .android: return "Android phone"
		case .ipad: return "iPad"
		case .macbook, .imac: return "Mac"
		case .macMini: return "Mac mini"
		case .macStudio: return "Mac Studio"
		case .pcLaptop, .pcTower: return "computer"
		}
	}
}

/// A device as the family's tile (apps/icon/devices): front-on, the face one step off the
/// surface, a hairline outline and a 1 px soft shadow, the screen a plain inset. Two designed sizes:
/// the hero (above 28) with its details, the mark (20) with the silhouette and one. No light inside:
/// presence is the word and the light beside the name; an away device is the same tile, quieter.
struct DeviceGlyph: View {
	@Environment(\.tones) private var tones
	let shape: DeviceShape
	var lit: Bool = true
	var size: CGFloat = 20
	var color: Color? = nil
	var body: some View {
		let a = Art.of(shape)
		let mark = size <= 28
		let keep: Set<Art.Role> = mark ? Set(a.mark) : [.body, .screen, .dark, .detail]
		let line = 1 / (size / 24)
		ZStack {
			ForEach(Array(a.body.enumerated()), id: \.offset) { _, s in MarkView.Grid(path: s.path).fill(tones.device) }
				.shadow(color: .black.opacity(tones.dark ? 0.5 : 0.14), radius: 0.6, y: 0.6)
			ForEach(Array(a.body.enumerated()), id: \.offset) { _, s in MarkView.Grid(path: s.path).stroke(tones.text.opacity(0.2), lineWidth: line * size / 24) }
			if keep.contains(.screen) { ForEach(Array(a.screen.enumerated()), id: \.offset) { _, s in MarkView.Grid(path: s.path).fill(tones.deviceScreen) } }
			if keep.contains(.dark) { ForEach(Array(a.dark.enumerated()), id: \.offset) { _, s in MarkView.Grid(path: s.path).fill(Color.black.opacity(0.88)) } }
			if keep.contains(.detail) { ForEach(Array(a.detail.prefix(mark ? 1 : 99).enumerated()), id: \.offset) { _, s in MarkView.Grid(path: s.path).fill(tones.text.opacity(0.38)) } }
		}
		.frame(width: size, height: size)
		.opacity(lit ? 1 : 0.4)
		.accessibilityLabel(shape.word)
	}

	/// The parts of a device on the 24 grid, written by apps/icon/devices/make.py.
	struct Art {
		enum Role { case body, screen, dark, detail }
		enum Shape {
			case rect(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)
			case poly([(CGFloat, CGFloat)])
			var path: SwiftUI.Path {
				switch self {
				case .rect(let x, let y, let w, let h, let r): return SwiftUI.Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r, style: .circular)
				case .poly(let pts): return SwiftUI.Path { p in p.addLines(pts.map { CGPoint(x: $0.0, y: $0.1) }); p.closeSubpath() }
				}
			}
		}
		let body: [Shape], screen: [Shape], dark: [Shape], detail: [Shape], mark: [Role]
		static func of(_ shape: DeviceShape) -> Art {
			switch shape.rawValue {
		case "iphone": return Art(body: [.rect(6.55, 5.4, 0.7, 0.8, 0.25), .rect(6.55, 7.4, 0.7, 1.6, 0.25), .rect(6.55, 9.8, 0.7, 1.6, 0.25), .rect(16.75, 8, 0.7, 2.8, 0.25), .rect(7, 1.5, 10, 21, 2.6)], screen: [.rect(7.8, 2.3, 8.4, 19.4, 1.9)], dark: [.rect(10.7, 3.1, 2.6, 0.8, 0.4)], detail: [], mark: [.body, .screen])
		// A phone with its buttons on the right and a punch-hole camera: no island.
		case "android": return Art(body: [.rect(16.75, 6.2, 0.7, 1.6, 0.25), .rect(16.75, 8.6, 0.7, 3.2, 0.25), .rect(7, 1.5, 10, 21, 2.2)], screen: [.rect(7.7, 2.2, 8.6, 19.6, 1.6)], dark: [.rect(11.6, 3, 0.8, 0.8, 0.4)], detail: [], mark: [.body, .screen])
		case "ipad": return Art(body: [.rect(4.5, 1.5, 15, 21, 1.9)], screen: [.rect(5.5, 2.5, 13, 19, 1.1)], dark: [], detail: [], mark: [.body, .screen])
		case "macbook": return Art(body: [.rect(3.5, 4, 17, 12.2, 1.1), .rect(1.25, 16.2, 21.5, 1.4, 0.7)], screen: [.rect(4.4, 4.9, 15.2, 10.8, 0.45)], dark: [.rect(10.9, 4.9, 2.2, 0.7, 0.35)], detail: [.rect(10.4, 16.2, 3.2, 0.45, 0.22), .rect(3, 17.6, 1.6, 0.5, 0.25), .rect(19.4, 17.6, 1.6, 0.5, 0.25)], mark: [.body, .screen])
		case "imac": return Art(body: [.poly([(10.2, 17.4), (13.8, 17.4), (14.4, 20.6), (9.6, 20.6)]), .rect(8.4, 20.3, 7.2, 0.9, 0.45), .rect(2, 2.5, 20, 15, 1.3)], screen: [.rect(2.9, 3.4, 18.2, 10.6, 0.4)], dark: [], detail: [], mark: [.body, .screen])
		case "mac-mini": return Art(body: [.rect(4, 14.9, 16, 1.6, 0.7), .rect(2.5, 8.25, 19, 7.25, 2.2)], screen: [], dark: [], detail: [.rect(6, 11.2, 0.7, 1.6, 0.35), .rect(7.5, 11.2, 0.7, 1.6, 0.35)], mark: [.body, .detail])
		case "mac-studio": return Art(body: [.rect(4.4, 14.6, 15.2, 1.6, 0.7), .rect(3, 6.25, 18, 9.25, 2.4)], screen: [], dark: [], detail: [.rect(5.6, 11.4, 0.7, 1.6, 0.35), .rect(7.1, 11.4, 0.7, 1.6, 0.35), .rect(9.4, 12.1, 3.2, 0.6, 0.3)], mark: [.body, .detail])
		case "pc-laptop": return Art(body: [.rect(3.25, 4, 17.5, 12.2, 0.6), .rect(1.25, 16.2, 21.5, 1.4, 0.4)], screen: [.rect(4.2, 4.9, 15.6, 10.6, 0.2)], dark: [], detail: [.rect(10.4, 16.2, 3.2, 0.45, 0.22)], mark: [.body, .screen])
		case "pc-tower": return Art(body: [.rect(6.5, 1.5, 11, 21, 1.1)], screen: [], dark: [], detail: [.rect(8.6, 4.2, 6.8, 0.6, 0.3), .rect(8.6, 6, 6.8, 0.6, 0.3)], mark: [.body, .detail])
		case "drive": return Art(body: [.rect(2, 8, 20, 8, 2)], screen: [], dark: [], detail: [.rect(4.6, 12.6, 5, 0.6, 0.3)], mark: [.body, .detail])
			default: return Art(body: [.rect(3.25, 4, 17.5, 12.2, 0.6)], screen: [], dark: [], detail: [], mark: [.body])
			}
		}
	}
}

/// Online or not, beside a name: the family's light, small. The only place presence is drawn on a device.
struct Light: View {
	@Environment(\.tones) private var tones
	let on: Bool
	var size: CGFloat = 7
	var body: some View {
		Circle().fill(on ? tones.strong : Color.clear)
			.overlay(Circle().strokeBorder(on ? Color.clear : tones.secondary, lineWidth: 1.2))
			.frame(width: size, height: size)
			.accessibilityLabel(on ? "Online" : "Away")
	}
}

// MARK: presence in words

extension Device {
	/// One short word or two for a row: "online", "via Jo's Mac", "away 2 h", "never seen".
	var word: String {
		if online {
			if case .relay(_, let name) = path { return "via \(name)" }
			if case .direct(let ms?) = path { return "direct, \(ms) ms" }
			return "online"
		}
		if case .waiting = path { return "reaching…" }
		if let l = lastOnline { return "away " + agoShort(l) }
		return "never seen"
	}
}

/// "2 h", "3 d", "now".
func agoShort(_ d: Date) -> String {
	let s = Date().timeIntervalSince(d)
	if s < 60 { return "now" }
	if s < 3600 { return "\(Int(s / 60)) min" }
	if s < 86_400 { return "\(Int(s / 3600)) h" }
	return "\(Int(s / 86_400)) d"
}

/// A person's devices in one short phrase: "online", "relayed", "away 2 h", "never seen".
func presenceWord(_ devices: [Device]) -> String {
	switch Mark.presence(devices) {
	case .online, .onlineRelayed: return "online"
	case .away: return devices.compactMap(\.lastOnline).max().map { "away " + agoShort($0) } ?? "away"
	default: return "never seen"
	}
}

/// Names as the pictures show them: one line, the first name or the short device name ("Mac mini",
/// not "Ana's Mac mini"), a middle ellipsis only past 14 characters.
enum Names {
	static func cap(_ s: String) -> String {
		guard s.count > 14 else { return s }
		return String(s.prefix(7)) + "…" + String(s.suffix(6))
	}
	static func device(_ name: String) -> String {
		let n = name.replacingOccurrences(of: "\u{2019}", with: "'")
		if let r = n.range(of: "'s ") { return cap(String(n[r.upperBound...])) }
		return cap(name)
	}
	static func first(_ name: String) -> String { cap(name.split(separator: " ").first.map(String.init) ?? name) }
}
