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
		.sheet(isPresented: $open) { ConnectionSheet().presentationDetents(tall ? [.large] : [.medium, .large]).presentationBackground(tones.surface).presentationDragIndicator(.visible) }
		// `BAUD_STATUS_SHEET=1`: the sheet open at launch, for a look at it without a click.
		.onAppear { if ProcessInfo.processInfo.environment["BAUD_STATUS_SHEET"] == "1" { open = true } }
	}
}

/// Connection, compact: this device and its word, my devices and how each is reached right now (one
/// line each), the fix when nothing reaches me, and what the router said, in one quiet line. The
/// status chip's sheet and Settings ▸ Connection both show it.
struct ConnectionDetails: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	var body: some View {
		let s = model.netState
		let here = model.me.devices.first { $0.id == model.me.thisDevice }
		VStack(alignment: .leading, spacing: Space.section) {
			ListCard {
				HStack(spacing: Rows.gap) {
					DeviceGlyph(shape: here.map(DeviceShape.init) ?? (AppModel.deviceKind == .iphone ? .iphone : .macbook), lit: s != .offline, size: Rows.personFace - 4).frame(width: Rows.personFace)
					VStack(alignment: .leading, spacing: 2) {
						Text("This \(AppModel.thisKind)").font(Theme.font.weight(.medium))
						Text(s.line(connecting: model.connecting)).font(Theme.smallFont).foregroundStyle(tones.secondary).fixedSize(horizontal: false, vertical: true)
					}
					Spacer(minLength: 8)
					HStack(spacing: 4) {
						MarkView(mark: s.mark, size: 12, color: s.lit ? tones.strong : tones.secondary)
						Text(s.words(connecting: model.connecting)).font(Theme.font.weight(.semibold)).foregroundStyle(s.lit ? tones.text : tones.secondary)
					}
				}
				.frame(minHeight: Rows.person)
				.cardRow()
			}
			if case .notReachable = s, !model.connecting { NotReachable(compact: false) }
			if model.localNetworkOff { LocalNetworkIssue() }
			let others = model.me.devices.filter { $0.id != model.me.thisDevice }
			ListCard(title: "Your other devices", footer: "A Mac at home with baud open keeps your devices reachable from anywhere, and carries for them while they're away.") {
				ForEach(others) { d in DeviceRow(d: d, this: false).cardRow() }
				if others.isEmpty { Text("None yet. Add one in Devices.").font(Theme.font).foregroundStyle(tones.secondary).frame(minHeight: Rows.line).cardRow() }
			}
			Text(footnote).font(Theme.smallFont).foregroundStyle(tones.secondary).padding(.horizontal, Rows.inset + Rows.pad)
		}
	}

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

/// The status chip's sheet: Connection, a header and its details.
struct ConnectionSheet: View {
	@Environment(\.tones) private var tones
	var body: some View {
		VStack(spacing: 0) {
			SheetHeader(title: "Connection")
			ScrollView { ConnectionDetails().padding(.horizontal, Space.side).padding(.vertical, Space.section) }
		}
		.background(tones.surface.ignoresSafeArea())
		#if os(macOS)
		.frame(width: 440, height: 520)
		#endif
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
