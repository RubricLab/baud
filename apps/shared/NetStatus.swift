/// This device's status: one mark and at most three words, the same four on every device. Online
/// (the internet reaches this device: its router opened a port, it runs a relay, or the network
/// lets a punch through, over IPv6 or a NAT that keeps one port), Through
/// <device> (connected to the one that is), Not reachable, Offline. A tap opens one calm sheet:
/// this device, a fine line to each device and friend it is connected to right now (name and how
/// fast), the state in a word and one sentence; the fix only when nothing reaches it, and what the
/// router said and Local Network as one quiet line at the foot. Local Network off is an issue
/// beside the status, whatever it says: a badge on the chip, a card in the sheet.
import BaudCore
import SwiftUI

@MainActor
extension AppModel.NetState {
	var mark: Mark {
		switch self { case .offline: return .neverSeen; case .online: return .direct; case .through: return .stable; case .notReachable: return .waiting }
	}
	func words(connecting: Bool) -> String {
		switch self {
		case .offline: return "Offline"
		case .online: return "Online"
		case .through(let n, _): return "Through \(n)"
		case .notReachable: return connecting ? "Connecting" : "Not reachable"
		}
	}
	var lit: Bool { switch self { case .online, .through: return true; default: return false } }
	/// Under the state, and under this device in the network picture.
	func line(connecting: Bool) -> String {
		switch self {
		case .offline: return "No network."
		case .online: return "Your devices and friends reach this \(AppModel.thisKind) from anywhere."
		case .through(let n, let own): return "Your devices and friends reach this \(AppModel.thisKind) through \(own ? "your " : "")\(n)."
		case .notReachable: return connecting ? "Reaching your devices." : "Nothing outside reaches this \(AppModel.thisKind) yet."
		}
	}
}

/// The status chip: the mark and the words; a tap opens the sheet.
struct NetStatusChip: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	@State private var open = false
	/// The width it may take (beside the centred title on the iPhone); past it, the mark alone.
	var room: CGFloat = .infinity
	var body: some View {
		let s = model.netState
		let words = s.words(connecting: model.connecting)
		let issue = model.localNetworkOff
		let tall = issue || { if case .notReachable = s { return true }; return false }()
		Button { open = true } label: {
			ViewThatFits(in: .horizontal) {
				HStack(spacing: 4) {
					MarkView(mark: s.mark, size: 12, color: s.lit ? tones.strong : tones.secondary)
					Text(words).font(.system(size: Theme.small, weight: .semibold)).foregroundStyle(s.lit ? tones.text : tones.secondary).lineLimit(1).fixedSize()
					if issue { IssueBadge(size: 11) }
				}
				MarkView(mark: s.mark, size: 14, color: s.lit ? tones.strong : tones.secondary)
					.overlay(alignment: .topTrailing) { if issue { IssueBadge(size: 8).offset(x: 4, y: -3) } }
			}
			.padding(.horizontal, 5).frame(height: 24)
			.frame(maxWidth: room, alignment: .leading)
		}
		.buttonStyle(Pill())
		.accessibilityLabel(issue ? "\(words). Local Network is off" : words)
		.sheet(isPresented: $open) { NetStatusSheet().presentationDetents(tall ? [.medium, .large] : [.medium]).presentationBackground(tones.surface).presentationDragIndicator(.visible) }
		// `BAUD_STATUS_SHEET=1`: the sheet open at launch, for a look at it without a click.
		.onAppear { if ProcessInfo.processInfo.environment["BAUD_STATUS_SHEET"] == "1" { open = true } }
	}
}

/// This device and what it is connected to, the state in a word and a sentence, and the fix.
struct NetStatusSheet: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	@Environment(\.dismiss) private var dismiss
	var body: some View {
		let s = model.netState
		let here = model.me.devices.first { $0.id == model.me.thisDevice }
		ScrollView { VStack(spacing: 22) {
			Constellation(here: here.map(DeviceShape.init) ?? (AppModel.deviceKind == .iphone ? .iphone : .macbook), state: s, links: links, carrier: carrierId)
			VStack(spacing: 6) {
				HStack(spacing: 7) {
					MarkView(mark: s.mark, size: 15, color: s.lit ? tones.strong : tones.secondary)
					Text(s.words(connecting: model.connecting)).font(Theme.headingFont)
				}
				Text(s.line(connecting: model.connecting)).font(Theme.font).foregroundStyle(tones.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
			}
			if case .notReachable = s, !model.connecting { NotReachable(compact: false) }
			if model.localNetworkOff { LocalNetworkIssue() }
			Text(footnote).font(Theme.smallFont).foregroundStyle(tones.secondary).multilineTextAlignment(.center)
			#if os(macOS)
			// No drag to close on the Mac: Done, and ⎋.
			Button("Done") { dismiss() }.buttonStyle(Quiet()).keyboardShortcut(.cancelAction)
			#endif
		}
		.padding(.horizontal, 28).padding(.top, 32).padding(.bottom, 24)
		.frame(maxWidth: 440)
		.frame(maxWidth: .infinity) }
		.scrollBounceBehavior(.basedOnSize)
		.frame(maxHeight: .infinity)
		.background(tones.surface)
	}

	/// Who this device holds a live connection to now: my devices first, then friends, four at most.
	private var links: [Constellation.Link] {
		let live = model.peers.filter(\.device.online).sorted { ($0.own ? 0 : 1, $0.userName) < ($1.own ? 0 : 1, $1.userName) }
		let shown = live.prefix(4).map { p in
			Constellation.Link(id: p.device.id, name: p.own ? Names.device(p.device.name) : Names.first(p.userName), detail: speed(p.device.path), shape: p.own ? DeviceShape(p.device) : nil)
		}
		return shown + (live.count > 4 ? [Constellation.Link(id: "more", name: "\(live.count - 4) more", detail: "", shape: nil)] : [])
	}
	private func speed(_ p: BaudCore.Path) -> String {
		switch p {
		case .direct(let ms): return ms.map { "\($0) ms" } ?? "Direct"
		case .relay: return "Relayed"
		case .nearby: return "Nearby"
		default: return ""
		}
	}
	private var carrierId: DeviceId? { if case .through = model.netState { return model.carrier?.device.id }; return nil }

	/// What the router said and Local Network, in one quiet line.
	private var footnote: String {
		let router: String
		if model.mappedAddress != nil { router = "Router opened a port" }
		else if !model.onLAN { router = "On cellular" }
		else {
			switch model.gateway {
			// A port onto an address that isn't public: another NAT in front (the provider's).
			case .mapped: router = "Router's port is behind your provider"
			case .refused: router = "Router refused a port"
			case .none: router = "Router opens no ports"
			case .noInternet: router = "Router lost its internet"
			case .unknown: router = model.connecting ? "Asking the router…" : "Router didn't answer"
			}
		}
		return router + " · Local Network " + (model.localNetworkOff ? "off" : "on")
	}
}

/// This device, and a fine line down to each device and friend it is connected to, with its name
/// and how fast. Nothing connected: a dotted line ending in the state's mark.
struct Constellation: View {
	@Environment(\.tones) private var tones
	struct Link: Identifiable { let id: String; let name: String; let detail: String; let shape: DeviceShape? }
	let here: DeviceShape
	let state: AppModel.NetState
	let links: [Link]
	let carrier: DeviceId?
	@State private var drawn = false

	var body: some View {
		VStack(spacing: 0) {
			DeviceGlyph(shape: here, lit: state != .offline, size: 64)
			if links.isEmpty {
				Rectangle().fill(tones.text.opacity(0.28)).frame(width: 1.2, height: 34)
					.mask(VStack(spacing: 4) { ForEach(0..<6, id: \.self) { _ in Rectangle().frame(height: 3) } })
					.padding(.top, 6)
				MarkView(mark: state.mark, size: 20, color: tones.secondary).padding(.top, 6)
			} else {
				Canvas { ctx, size in
					let n = links.count
					for (i, l) in links.enumerated() {
						let x = size.width * (CGFloat(i) + 0.5) / CGFloat(n)
						var p = SwiftUI.Path()
						p.move(to: CGPoint(x: size.width / 2, y: 0))
						p.addCurve(to: CGPoint(x: x, y: size.height), control1: CGPoint(x: size.width / 2, y: size.height * 0.55), control2: CGPoint(x: x, y: size.height * 0.45))
						let strong = l.id == carrier
						ctx.stroke(p.trimmedPath(from: 0, to: drawn ? 1 : 0), with: .color(tones.strong.opacity(strong ? 0.9 : 0.45)), lineWidth: strong ? 1.6 : 1)
					}
				}
				.frame(height: 40).padding(.top, 2)
				HStack(alignment: .top, spacing: 0) {
					ForEach(links) { l in
						VStack(spacing: 5) {
							Group {
								if let shape = l.shape { DeviceGlyph(shape: shape, size: 30) }
								else if l.id == "more" { Circle().stroke(tones.hairline).frame(width: 28, height: 28).overlay(Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold)).foregroundStyle(tones.secondary)) }
								else { Avatar(name: l.name, size: 28) }
							}
							.frame(height: 32)
							Text(l.name).font(Theme.smallFont.weight(.medium)).lineLimit(1)
							if !l.detail.isEmpty { Text(l.detail).font(Theme.smallFont).foregroundStyle(tones.secondary).monospacedDigit().lineLimit(1) }
						}
						.frame(maxWidth: .infinity)
					}
				}
				.padding(.top, 4)
			}
		}
		.frame(maxWidth: CGFloat(max(1, links.count)) * 104)
		.onAppear { withAnimation(.easeOut(duration: 0.5).delay(0.1)) { drawn = true } }
		.accessibilityElement(children: .ignore)
		.accessibilityLabel(links.isEmpty ? "Not connected to anything" : "Connected to " + links.map(\.name).joined(separator: ", "))
	}
}

/// Why nothing reaches this device, and what fixes it: the status sheet and the Add screen say the
/// same thing. With a meeting device in my circle I'm not connected to: baud open on it. With
/// none: what this network's router said when asked for a port, and its fix; on the iPhone, a Mac
/// at home besides (and, without Local Network, that permission: the Add screen's card here, the
/// sheet's below it).
struct NotReachable: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	/// The Add screen's version: a heading of its own.
	let compact: Bool
	var body: some View {
		let away: String? = { if case .notReachable(let a) = model.netState { return a }; return nil }()
		VStack(spacing: 10) {
			if compact { Text(model.connecting ? "Connecting" : "Not reachable yet").font(Theme.font.weight(.semibold)) }
			if model.connecting {
				Sentence("Reaching your devices.")
			} else if let away {
				Sentence("Your circle reaches you through \(away), and this \(AppModel.thisKind) can't reach it right now. baud has to be open there.")
			} else {
				Sentence(AppModel.deviceKind == .mac ? router : "\(router) Or keep a Mac at home with baud open: you're reachable through it from anywhere.")
			}
			if compact, model.localNetworkOff { LocalNetworkIssue() }
		}
	}
}

extension NotReachable {
	/// What this network's router said when asked to open a port, and the one thing that fixes it.
	var router: String {
		guard model.onLAN else { return "A cellular network opens no ports." }
		switch model.gateway {
		case .noInternet: return "Your router has lost its internet side and opens nothing. Restart it."
		case .refused: return "Your router refused to open a port. Turn on UPnP in its settings, or restart it."
		case .none: return "This network's router opens no ports. If its settings have UPnP, turn it on."
		case .mapped: return "Your router opened a port, but another network sits in front of it, like your internet provider's. Nothing to change here."
		case .unknown: return "Your router hasn't opened a port. Restart it, or turn on UPnP in its settings."
		}
	}
}

/// Local Network is off for baud here: the issue, why baud needs it, and the way to the switch.
/// Until it's on, devices on the same Wi-Fi can't reach this one at its local address, and behind
/// a router that doesn't loop its public address back inside, not at all.
struct LocalNetworkIssue: View {
	@Environment(\.tones) private var tones
	var body: some View {
		VStack(spacing: 8) {
			HStack(spacing: 6) {
				IssueBadge(size: 14)
				Text("Local Network is off").font(Theme.font.weight(.semibold))
			}
			Text(LocalNetwork.why).font(Theme.smallFont).foregroundStyle(tones.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
			Button("Turn it on") { LocalNetwork.openSettings() }.buttonStyle(Quiet(strong: true))
			Text(LocalNetwork.path).font(Theme.smallFont).foregroundStyle(tones.secondary).multilineTextAlignment(.center)
		}
		.padding(16)
		.frame(maxWidth: .infinity)
		.background(RoundedRectangle(cornerRadius: 12).fill(tones.raised))
		.overlay(RoundedRectangle(cornerRadius: 12).stroke(tones.hairline, lineWidth: 1))
	}
}

/// Something here needs fixing: beside the status, and on the card that says what.
struct IssueBadge: View {
	@Environment(\.tones) private var tones
	let size: CGFloat
	var body: some View {
		Image(systemName: "exclamationmark.circle.fill").font(.system(size: size, weight: .semibold)).foregroundStyle(tones.strong)
			.accessibilityHidden(true)
	}
}

private struct Sentence: View {
	let text: String
	init(_ text: String) { self.text = text }
	var body: some View { Text(text).font(Theme.font).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true) }
}
