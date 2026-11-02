/// Calls on the Mac. A call that's ringing here is a small panel at the top right of the screen,
/// over whatever is in front, until it's answered or it stops. A call under way has a window of
/// its own, dark, with the traffic lights over it; closing it hangs up.
import AppKit
import SwiftUI

/// Root's modifier: keeps the panel and the window in step with the call.
struct CallPresenter: ViewModifier {
	@Environment(AppModel.self) private var model
	func body(content: Content) -> some View {
		content
			.onChange(of: model.calls.session?.id, initial: true) { _, _ in CallWindows.shared.sync(model) }
			.onChange(of: model.calls.session?.phase) { _, _ in CallWindows.shared.sync(model) }
	}
}

@MainActor
final class CallWindows: NSObject, NSWindowDelegate {
	static let shared = CallWindows()
	private var panel: NSPanel?
	private var window: NSWindow?
	private var shown: String?

	func sync(_ model: AppModel) {
		guard let s = model.calls.session else { closePanel(); closeWindow(); return }
		if s.phase == .incoming {
			closeWindow()
			if panel == nil { showPanel(s, model) }
		} else {
			closePanel()
			if window == nil || shown != s.id { showWindow(s, model) }
		}
	}

	// MARK: the ring

	private func showPanel(_ s: CallCenter.Session, _ model: AppModel) {
		let size = NSSize(width: 372, height: 92)
		let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
		p.level = .floating
		p.isFloatingPanel = true
		p.hidesOnDeactivate = false
		p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
		p.backgroundColor = .clear
		p.isOpaque = false
		p.hasShadow = true
		p.isMovableByWindowBackground = true
		let host = NSHostingView(rootView: IncomingCall(session: s).environment(model).modifier(Tinted(hex: model.accentHex)))
		host.frame = NSRect(origin: .zero, size: size)
		p.contentView = host
		if let screen = NSScreen.main?.visibleFrame { p.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 16, y: screen.maxY - size.height - 16)) }
		p.alphaValue = 0
		p.orderFrontRegardless()
		NSAnimationContext.runAnimationGroup { $0.duration = 0.25; p.animator().alphaValue = 1 }
		panel = p
	}

	private func closePanel() {
		guard let p = panel else { return }
		panel = nil
		NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) })
	}

	// MARK: the call

	private func showWindow(_ s: CallCenter.Session, _ model: AppModel) {
		closeWindow()
		let size = s.video ? NSSize(width: 880, height: 560) : s.group ? NSSize(width: 640, height: 480) : NSSize(width: 400, height: 540)
		let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
		w.titlebarAppearsTransparent = true
		w.titleVisibility = .hidden
		w.title = (s.video ? "Video call" : "Call") + (s.group ? " in \(s.title)" : " with \(s.title)")
		w.appearance = NSAppearance(named: .darkAqua)
		w.backgroundColor = NSColor(Tones.make(hex: model.accentHex, dark: true).surface)
		w.isMovableByWindowBackground = true
		w.minSize = s.video ? NSSize(width: 480, height: 320) : NSSize(width: 340, height: 440)
		w.isReleasedWhenClosed = false
		w.delegate = self
		w.contentView = NSHostingView(rootView: CallScreen(session: s).environment(model).modifier(Tinted(hex: model.accentHex)))
		w.center()
		// A test call never takes the screen from whoever is using it.
		if CallCenter.test { w.orderFrontRegardless() } else { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
		window = w; shown = s.id
		self.model = model
	}
	private weak var model: AppModel?

	private func closeWindow() {
		guard let w = window else { return }
		window = nil; shown = nil
		w.delegate = nil
		w.close()
	}

	/// The red button hangs up.
	func windowWillClose(_ notification: Notification) {
		window = nil; shown = nil
		if let s = model?.calls.session, !s.phase.over { model?.calls.end() }
	}
}

/// The ring, at the top right: who, what kind of call, and the answers.
struct IncomingCall: View {
	@Environment(AppModel.self) private var model
	let session: CallCenter.Session
	var body: some View {
		let ink = Tones.make(hex: model.accentHex, dark: true)
		HStack(spacing: 12) {
			Group {
				if session.group { Circle().fill(ink.loud).overlay(Image(systemName: "person.2.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(ink.onLoud)) }
				else if let h = session.avatar, let img = model.image(h) { img.resizable().scaledToFill() }
				else { Circle().fill(ink.loud).overlay(Text(String(session.name.prefix(1)).uppercased()).font(.system(size: 19, weight: .heavy, design: .rounded)).foregroundStyle(ink.onLoud)) }
			}
			.frame(width: 44, height: 44).clipShape(Circle())
			VStack(alignment: .leading, spacing: 2) {
				Text(session.title).font(.system(size: 15, weight: .bold)).foregroundStyle(ink.text).lineLimit(1)
				Text((session.group ? "\(session.caller) · " : "") + (session.video ? "Video call" : "Call")).font(.system(size: 12, weight: .medium)).foregroundStyle(ink.secondary).lineLimit(1)
			}
			Spacer(minLength: 8)
			HStack(spacing: 10) {
				small("phone.down.fill", "Decline", CallInk.danger) { model.calls.decline() }
				if session.video { small("video.slash.fill", "Answer without video", ink.field) { model.calls.accept(camera: false) } }
				small(session.video ? "video.fill" : "phone.fill", "Answer", CallInk.accept) { model.calls.accept(camera: true) }
			}
		}
		.padding(.horizontal, 16)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(ink.raised))
		.environment(\.colorScheme, .dark)
	}
	private func small(_ symbol: String, _ label: String, _ fill: Color, _ action: @escaping () -> Void) -> some View {
		Button(action: action) {
			Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
				.frame(width: 36, height: 36).background(Circle().fill(fill))
		}
		.buttonStyle(.plain).help(label).accessibilityLabel(label)
	}
}
