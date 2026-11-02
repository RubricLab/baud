/// Add: one screen for a friend and for my own device, on both platforms. My link as a QR and a
/// Share button; under it, Scan or paste. A link read from anywhere (scanned, pasted, opened)
/// lands here too, already read. A friend link from a device nobody can reach is still handed out:
/// whoever opens it, and can't get through, sends an answer back, and opening that meets us. A
/// device link can't be answered, so with nobody able to reach this device it's never shown.
import BaudCore
import SwiftUI
#if os(iOS)
import VisionKit
#endif

struct AddView: View {
	#if os(iOS)
	static let gap: CGFloat = 12
	#else
	static let gap: CGFloat = 18
	#endif
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	@State private var kind: AppModel.Offer = .friend
	@State private var scanning = false

	var body: some View {
		VStack(spacing: Self.gap) {
			if let link = model.join?.link {
				JoinPane(link: link)
			} else if scanning || model.join != nil {
				ScanPaste(expect: kind, done: { scanning = false })
			} else if let ask = model.linkAsk, kind == .device {
				AskBody(ask: ask)
			} else {
				// Two screens from two places, never a toggle: New friend (compose) and Add a device
				// (You → Devices), each looking like what it makes.
				if kind == .friend {
					Text("New friend").font(Theme.headingFont)
				} else {
					Text("Add a device").font(Theme.headingFont)
					HStack(spacing: 10) {
						ForEach(model.me.devices) { d in DeviceGlyph(shape: DeviceShape(d), size: 28) }
						RoundedRectangle(cornerRadius: 6).strokeBorder(tones.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 3])).frame(width: 24, height: 20)
							.overlay(Image(systemName: "plus").font(.system(size: 10, weight: .bold)).foregroundStyle(tones.secondary))
					}
				}
				OfferPane(kind: kind).id(kind)
				Button { scanning = true } label: { Label("Scan or paste", systemImage: "qrcode.viewfinder") }.buttonStyle(Quiet())
			}
		}
		.padding(.horizontal, 24).padding(.top, 30).padding(.bottom, 16)
		#if os(macOS)
		.frame(width: 400)
		.background(tones.surface.ignoresSafeArea())
		#else
		// On the iPhone it sits on the sheet's lit ground (or onboarding's); a fill of its own
		// showed as a flat band across a full-height sheet.
		.frame(maxWidth: .infinity, alignment: .top)
		#endif
		.onAppear { kind = model.offer ?? .friend }
		.onChange(of: model.offer) { _, o in if let o { kind = o } }
		.onDisappear { model.offer = nil; if model.join?.link == nil { model.join = nil } }
	}
}

/// My link: the QR (or, unreachable, a greyed one and Scan), Share, and who arrived.
struct OfferPane: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	let kind: AppModel.Offer
	@State private var link: BaudCore.Link?
	@State private var before: Set<String> = []
	@State private var arrived: String?
	@State private var failed = false

	var body: some View {
		let meeting = model.meeting
		VStack(spacing: 14) {
			if let arrived { Arrived(id: arrived, kind: kind) }
			else if meeting == .none, kind == .device || model.connecting || model.netState == .offline {
				// Nobody could meet this device: no code, the reason, and Scan (in the pane below).
				NotReachable(compact: true)
			} else if let link {
				QRSquare(text: link.url, greyed: false)
				status(meeting)
				HStack(spacing: 10) {
					if let url = URL(string: link.web) { ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }.buttonStyle(Quiet(strong: true)) }
				}
			} else if failed {
				Text("Try again").font(Theme.font.weight(.semibold))
				Button("Try again", action: make).buttonStyle(Quiet())
			}
		}
		.onAppear(perform: make)
		// The link names the meeting device: a new one is minted when that changes.
		.onChange(of: meeting) { _, _ in if link != nil { make() } }
		// The link just works: an expired one is quietly replaced.
		.task { while !Task.isCancelled { try? await Task.sleep(for: .seconds(30)); if let l = link, l.expires < Date() { make() } } }
		.onChange(of: model.contacts) { _, _ in check() }
		.onChange(of: model.me) { _, _ in check() }
	}
	@ViewBuilder private func status(_ m: AppModel.Meeting) -> some View {
		switch m {
		case .through(let name): HStack(spacing: 5) { MarkView(mark: .stable, size: 14, color: tones.secondary); Text("Through \(name)").font(Theme.smallFont).foregroundStyle(tones.secondary) }
		case .here: HStack(spacing: 5) { MarkView(mark: .direct, size: 14, color: tones.secondary); Text("Online").font(Theme.smallFont).foregroundStyle(tones.secondary) }
		// Nothing reaches this device from the internet: the code carries its local address only.
		case .sameWiFi: HStack(spacing: 5) { MarkView(mark: .waiting, size: 14, color: tones.secondary); Text("Same Wi-Fi only").font(Theme.smallFont).foregroundStyle(tones.secondary) }
		// Nothing reaches this device: whoever opens the link answers it, and opening that meets us.
		case .none:
			VStack(spacing: 4) {
				HStack(spacing: 5) { MarkView(mark: .waiting, size: 14, color: tones.secondary); Text("Not reachable yet").font(Theme.smallFont).foregroundStyle(tones.secondary) }
				Text("Whoever opens it can send an answer back. Open that here and you'll meet.").font(Theme.smallFont).foregroundStyle(tones.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
			}
		}
	}
	private func make() {
		failed = false
		before = kind == .friend ? Set(model.contacts.map(\.user)) : Set(model.me.devices.map(\.id))
		do { link = kind == .friend ? try model.core.invite() : try model.core.linkDevice() } catch { failed = true; Measure.log("add: no link: \(error)") }
		// The smoke reads the link from a file, since nobody can scan a screenshot.
		if let f = ProcessInfo.processInfo.environment["BAUD_LINK_FILE"], let link { try? link.url.write(toFile: f, atomically: true, encoding: .utf8) }
	}
	private func check() {
		guard arrived == nil, link != nil else { return }
		let now = kind == .friend ? Set(model.contacts.map(\.user)) : Set(model.me.devices.map(\.id))
		if let new = now.subtracting(before).first { arrived = new; model.onboarded = true }
	}
}

/// The QR on a white card with its quiet zone, about 60% of the width; greyed when it must not be used.
struct QRSquare: View {
	#if os(iOS)
	static let side: CGFloat = 186
	#else
	static let side: CGFloat = 220
	#endif
	let text: String
	let greyed: Bool
	var body: some View {
		QRCode(text: text)
			.padding(10)
			.background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
			.frame(width: QRSquare.side, height: QRSquare.side)
			.opacity(greyed ? 0.18 : 1)
			.blur(radius: greyed ? 1.5 : 0)
			.accessibilityLabel(greyed ? "Not reachable yet" : "Your link")
	}
}

/// Who my link brought: their face (or the device), their name, and the one thing to do next.
struct Arrived: View {
	@Environment(AppModel.self) private var model
	@Environment(\.dismiss) private var dismiss
	let id: String
	let kind: AppModel.Offer
	var body: some View {
		VStack(spacing: 12) {
			if kind == .friend, let c = model.contacts.first(where: { $0.user == id }) {
				Avatar(name: c.name, hash: c.avatar, size: 72, presence: Mark.presence(c.devices))
				Text(c.name).font(Theme.titleFont)
				Button("Message") { model.message(c.user); model.offer = nil; dismiss() }.buttonStyle(Quiet(strong: true)).keyboardShortcut(.defaultAction)
			} else if let d = model.me.devices.first(where: { $0.id == id }) {
				DeviceGlyph(shape: DeviceShape(d), size: 72)
				Text(d.name).font(Theme.titleFont)
				Button("Done") { model.offer = nil; dismiss() }.buttonStyle(Quiet(strong: true)).keyboardShortcut(.defaultAction)
			}
		}
	}
}

/// A link I was given: who it is from, one button, then reaching them, then them.
struct JoinPane: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	@Environment(\.dismiss) private var dismiss
	let link: BaudCore.Link
	@State private var name = ""
	typealias Phase = AppModel.Join.Phase
	// Kept on the model: joining can swap the whole window under this view (the device becomes
	// someone's, first run ends), and the new view must carry on, not offer Join again.
	private var phase: Phase { model.join?.phase ?? .ready }
	private var user: UserId? { model.join?.user }
	private func set(_ p: Phase) { model.join?.phase = p }
	@FocusState private var focused: Bool

	/// My answer is out, and nothing has got through yet: the answer is the screen.
	private var answering: Bool {
		guard model.join?.reply != nil else { return false }
		switch phase { case .working, .replying: return true; default: return false }
	}

	var body: some View {
		VStack(spacing: 14) {
			if answering, let reply = model.join?.reply {
				ReplyCard(theirs: link, reply: reply, scanned: model.join?.scanned ?? false)
			} else {
				pane
			}
		}
		.onAppear {
			if ProcessInfo.processInfo.environment["BAUD_AUTO_OPEN"] != nil, phase == .ready {
				Task { try? await Task.sleep(for: .seconds(3)); if !model.named { name = link.kind == .friend ? (ProcessInfo.processInfo.environment["BAUD_AUTO_NAME"] ?? "Ana") : "" }; await go() }
			} else if link.kind == .reply, model.named, phase == .ready {
				// Their answer to my link: I already asked for this, and they're dialing me now.
				Task { await go() }
			}
		}
	}

	@ViewBuilder private var pane: some View {
		VStack(spacing: 14) {
			if link.kind != .device {
				Avatar(name: link.name, size: 72)
			} else {
				DeviceGlyph(shape: AppModel.deviceKind == .iphone ? .macbook : .iphone, size: 72)
			}
			// A device link inherits the person: no name asked, ever; only a friend link on a first run asks.
			Text(link.kind != .device ? link.name : (phase == .done ? model.me.name : "This \(AppModel.thisKind) becomes \(link.name)'s")).font(Theme.titleFont).lineLimit(2).multilineTextAlignment(.center)
			if link.kind == .reply, phase != .done { Text("Answered your link").font(Theme.smallFont).foregroundStyle(tones.secondary) }
			switch phase {
			case .ready:
				if !model.named, link.kind != .device {
					TextField("Your name", text: $name).textFieldStyle(.plain).font(.system(size: Theme.heading)).multilineTextAlignment(.center)
						.padding(10).background(RoundedRectangle(cornerRadius: 8).fill(tones.field)).frame(maxWidth: 260)
						.focused($focused).onSubmit { Task { await go() } }.onAppear { focused = true }
				}
				Button(link.kind != .device ? "Add" : "Join") { Task { await go() } }.buttonStyle(Quiet(strong: true, large: true)).keyboardShortcut(.defaultAction)
					.disabled(link.kind != .device && !model.named && name.trimmingCharacters(in: .whitespaces).isEmpty)
			case .working(let since):
				// Only dialing: no code yet, the other side hasn't been reached (0.2.4 showed the digits
				// here, before anything was reached, and a phone that never got through showed them anyway).
				SwiftUI.TimelineView(.periodic(from: since, by: 1)) { ctx in
					HStack(spacing: 6) {
						MarkView(mark: .waiting, size: 14, color: tones.secondary)
						Text("Reaching \(who)… \(Int(ctx.date.timeIntervalSince(since))) s").font(Theme.smallFont).foregroundStyle(tones.secondary).monospacedDigit()
					}
				}
			case .reached:
				if link.kind == .device, let code = model.joiningCode {
					Text(code.count == 6 ? code.prefix(3) + " " + code.suffix(3) : code).font(.system(size: 34, weight: .bold, design: .monospaced))
					Text("Press Add on your other device if it shows the same code.").font(Theme.smallFont).foregroundStyle(tones.secondary).multilineTextAlignment(.center)
				} else {
					HStack(spacing: 6) { MarkView(mark: .relayed, size: 14, color: tones.secondary); Text("Reached \(link.name)").font(Theme.smallFont).foregroundStyle(tones.secondary) }
				}
			case .replying: EmptyView()
			case .done:
				if link.kind != .device, let user {
					Button("Message") { model.message(user); finish() }.buttonStyle(Quiet(strong: true, large: true)).keyboardShortcut(.defaultAction)
				} else {
					Button("Done") { finish() }.buttonStyle(Quiet(strong: true, large: true)).keyboardShortcut(.defaultAction)
				}
			case .failed(let why):
				Text(why).font(Theme.font).foregroundStyle(tones.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
				if model.localNetworkOff, model.onLAN {
					Button("Turn on Local Network") { LocalNetwork.openSettings() }.buttonStyle(Quiet(strong: true))
				}
				Button("Try again") { model.join?.reply = nil; set(.ready) }.buttonStyle(Quiet())
			}
		}
	}

	private func go() async {
		// One attempt at a time: a second tap, or the pane appearing twice, redeemed the same link
		// again, and its "already used" overwrote the first attempt, which had reached the device.
		guard case .ready = phase else { return }
		if link.kind != .device, !model.named {
			model.setName(name.trimmingCharacters(in: .whitespaces))
			guard model.named else { set(.failed("Name didn't save")); model.error = nil; return }
		}
		set(.working(Date()))
		Measure.log("join: working on \(link.kind) link from \(link.name)")
		// A friend's link still not through after a few seconds: my answer, for them to open or scan.
		// The add goes on meanwhile, and whichever meets first wins.
		let answer = link.kind == .friend ? Task { @MainActor in
			try? await Task.sleep(for: .seconds(model.join?.scanned == true ? 3 : 5))
			guard !Task.isCancelled, case .working? = model.join?.phase else { return }
			answerThem()
		} : nil
		defer { answer?.cancel() }
		do {
			if link.kind != .device {
				let c = try await model.core.add(link)
				model.join?.user = c.user
				model.refreshAll()
				Measure.log("join: added \(c.name) · \(c.sentence)")
			} else {
				try await model.link(link)
				Measure.log("join: linked as \(model.me.name)")
			}
			model.onboarded = true
			set(.done)
		} catch {
			// My answer met them while this add was still trying: that's the outcome.
			if phase == .done { return }
			let reached: Bool = { if case .reached = phase { return true }; return false }()
			Measure.log("join: failed \(error) (\(reached ? "after" : "before") reaching it)")
			// Nothing got through: my answer waits for them (made now, if it wasn't yet).
			if link.kind == .friend, !reached, Crate.unreachable(error) {
				if model.join?.reply == nil { answerThem() }
				if model.join?.reply != nil, model.join?.phase != .done { set(.replying); return }
			}
			if link.kind == .reply, let why = Crate.replyTrouble(error, name: Names.first(link.name)) { set(.failed(why)); return }
			if let e = error as? CoreError {
				switch e { case .expired: set(.failed("That code has expired. Show a new one.")); case .used: set(.failed("That code was already used. Show a new one.")); case .badLink: set(.failed("That isn't a baud code.")); default: set(.failed(unreached)) }
			} else { set(.failed(Crate.unreachable(error) ? (reached ? "\(who.prefix(1).uppercased() + who.dropFirst()) stopped answering. Try again." : unreached) : Crate.short(for: error))) }
		}
	}
	private var who: String { link.kind != .device ? link.name : "your other device" }
	/// My answer to their link, once: the crate dials them from here until they open it.
	private func answerThem() {
		guard model.join?.reply == nil, let b = model.core as? Baud else { return }
		do { model.join?.reply = try b.reply(link); Measure.log("join: answered \(link.name)'s link, waiting for it to be opened") }
		catch { Measure.log("join: no answer: \(error)") }
		// The lab reads the answer from a file, as it does the link.
		if let f = ProcessInfo.processInfo.environment["BAUD_REPLY_FILE"], let r = model.join?.reply { try? r.url.write(toFile: f, atomically: true, encoding: .utf8) }
	}
	/// Why a link couldn't be met, with the one thing that fixes it.
	private var unreached: String {
		if model.localNetworkOff, model.onLAN { return "Couldn't reach \(who). Local Network is off for baud on this \(AppModel.thisKind), and on this network that's the way there." }
		return "Couldn't reach \(who). baud has to be open there, and say Online or Through at the bottom."
	}
	private func finish() { if model.named { model.onboarded = true }; model.refreshAll(); model.join = nil; model.offer = nil; dismiss() }
}

/// My answer to a friend's link that isn't getting through: their network keeps baud out, so they
/// open this (or scan it, standing here) and both sides dial at once. It waits up to fifteen
/// minutes, never past their link.
struct ReplyCard: View {
	@Environment(\.tones) private var tones
	let theirs: BaudCore.Link
	let reply: BaudCore.Link
	/// I scanned their code: they're here to scan mine back.
	let scanned: Bool
	var body: some View {
		let first = Names.first(theirs.name)
		VStack(spacing: 12) {
			Text(scanned ? "Let \(first) scan this" : "Send this back to \(first)").font(Theme.titleFont).multilineTextAlignment(.center)
			Text(scanned ? "\(first)'s network isn't letting baud through. On \(first)'s screen: Scan or paste, then point it here." : "\(first)'s network isn't letting baud through. Send this to \(first) the way the link came. When \(first) opens it, you'll meet.")
				.font(Theme.smallFont).foregroundStyle(tones.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
			QRSquare(text: reply.url, greyed: false).accessibilityLabel("Your answer")
			if let url = URL(string: reply.web) {
				ShareLink(item: url) { Label("Send back", systemImage: "arrowshape.turn.up.left") }.buttonStyle(Quiet(strong: !scanned))
			}
			SwiftUI.TimelineView(.periodic(from: .now, by: 30)) { ctx in
				let left = max(1, Int(reply.expires.timeIntervalSince(ctx.date) / 60))
				HStack(spacing: 6) {
					MarkView(mark: .waiting, size: 14, color: tones.secondary)
					Text("Waiting for \(first) · \(left) min left").font(Theme.smallFont).foregroundStyle(tones.secondary).monospacedDigit()
				}
			}
		}
	}
}

/// Scan a code with the camera (iPhone), or paste one. Whatever it reads becomes the link above.
struct ScanPaste: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	/// The screen it was opened from: a friend's link on Add a device (or the other way round) is refused.
	let expect: AppModel.Offer
	let done: () -> Void
	@State private var text = ""
	@State private var bad = false
	@State private var wrong: String?
	#if DEBUG
	/// `BAUD_SCAN_STILL=1`: draw where the camera goes on a device without one.
	static let still = ProcessInfo.processInfo.environment["BAUD_SCAN_STILL"] != nil
	#else
	static let still = false
	#endif
	var body: some View {
		VStack(spacing: 14) {
			#if os(iOS)
			if DataScannerViewController.isSupported, DataScannerViewController.isAvailable {
				Scanner { read($0, scanned: true) }.frame(height: 260).clipShape(RoundedRectangle(cornerRadius: 12))
			} else if Self.still {
				// Pictures of the app on a simulator, which has no camera: the camera's place, black.
				Color.black.frame(height: 260).clipShape(RoundedRectangle(cornerRadius: 12))
			}
			#endif
			HStack(spacing: 8) {
				TextField("Paste a link", text: $text).textFieldStyle(.plain).font(Theme.mono)
					.padding(10).background(RoundedRectangle(cornerRadius: 8).fill(tones.field))
					.onSubmit { read(text) }
				Button("Paste") { text = pasteboard() ?? ""; read(text) }.buttonStyle(Quiet())
			}
			if bad { Text(Code.cut(text) ? "That link was cut short on its way. Ask for a new one." : "Not a baud link").font(Theme.smallFont).foregroundStyle(tones.secondary).multilineTextAlignment(.center) }
			if let wrong { Text(wrong).font(Theme.smallFont.weight(.semibold)) }
			Button("Back") { model.join = nil; done() }.buttonStyle(Quiet())
		}
		.onAppear { if let p = pasteboard(), Code.parse(p) != nil { text = p } }
	}
	private func read(_ s: String, scanned: Bool = false) {
		guard let l = Code.parse(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { bad = !s.isEmpty; wrong = nil; return }
		bad = false
		// A stranger can never become my device by a scan on the wrong screen, nor my device a friend.
		// A fresh device (no friends, no other device of mine yet) is joining its person: take it.
		let fresh = model.contacts.isEmpty && model.me.devices.count <= 1
		if expect == .friend, l.kind == .device, !fresh { wrong = "That's a device link. Use Devices."; return }
		if expect == .device, l.kind != .device { wrong = "That's a friend link. Use New friend."; return }
		model.join = AppModel.Join(link: l, scanned: scanned); done()
	}
}

#if os(iOS)
/// The camera, reading QR codes; the first baud link it sees is the one.
struct Scanner: UIViewControllerRepresentable {
	let found: (String) -> Void
	func makeUIViewController(context: Context) -> DataScannerViewController {
		let v = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced, isHighlightingEnabled: true)
		v.delegate = context.coordinator
		try? v.startScanning()
		return v
	}
	func updateUIViewController(_ v: DataScannerViewController, context: Context) {}
	func makeCoordinator() -> Coordinator { Coordinator(found: found) }
	final class Coordinator: NSObject, DataScannerViewControllerDelegate {
		let found: (String) -> Void
		init(found: @escaping (String) -> Void) { self.found = found }
		func dataScanner(_ s: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
			for case .barcode(let b) in items { if let v = b.payloadStringValue, Code.parse(v) != nil { s.stopScanning(); found(v); return } }
		}
	}
}
#endif
