/// Calls on the iPhone. CallKit shows the ring (and the lock screen's call); baud's own screen covers
/// everything from the moment a call is placed or answered until it's over, in a window of its own
/// above the app's, edge to edge. Made small, that window shrinks to a picture in a corner: the app
/// underneath is in reach (chats, settings, sheets), the picture can be thrown to any corner, and a
/// tap makes the call big again.
import SwiftUI
import UIKit

struct CallPresenter: ViewModifier {
	@Environment(AppModel.self) private var model
	func body(content: Content) -> some View {
		content
			.onChange(of: model.calls.session?.id, initial: true) { _, _ in CallOverlay.shared.sync(model) }
			.onChange(of: model.calls.session?.phase) { _, _ in CallOverlay.shared.sync(model) }
			.onChange(of: model.calls.minimized) { _, _ in CallOverlay.shared.sync(model) }
			// The small picture takes the shape of theirs as it arrives.
			.onChange(of: model.calls.session?.remoteAspect) { _, _ in CallOverlay.shared.sync(model) }
			.onChange(of: model.calls.session?.participants.first?.showing) { _, _ in CallOverlay.shared.sync(model) }
	}
}

@MainActor
final class CallOverlay: NSObject {
	static let shared = CallOverlay()
	private var window: CallWindow?
	private var host: CallHost?
	private weak var model: AppModel?
	/// Where the small picture sits.
	private var corner = UIRectCorner.topRight
	private var dragFrom: CGPoint?

	func sync(_ model: AppModel) {
		self.model = model
		guard let s = model.calls.session else { hide(); return }
		// The ring is CallKit's (except in a test call, or one the system wouldn't ring).
		if s.phase == .incoming && !CallCenter.test && s.callKit { hide(); return }
		// Over while small: it goes quietly, rather than coming back big to say goodbye.
		if s.phase.over && model.calls.minimized { hide(); return }
		let small = model.calls.minimized && !s.phase.over
		guard let w = window ?? make(model) else { return }
		let was = w.small
		w.small = small
		host?.small = small
		place(w, s, animated: was != small || w.isHidden == false)
		w.isHidden = false
		if !small { w.makeKey() } else if was != small { mainWindow?.makeKey() }
	}

	private var scene: UIWindowScene? {
		let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
		return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
	}
	/// The app's own window, under the call's.
	private var mainWindow: UIWindow? { scene?.windows.first { !($0 is CallWindow) && $0.windowLevel == .normal } }

	private func make(_ model: AppModel) -> CallWindow? {
		guard let scene else { return nil }
		let w = CallWindow(windowScene: scene)
		w.windowLevel = .normal + 1
		w.backgroundColor = .clear
		let h = CallHost(rootView: AnyView(CallStage().environment(model).modifier(Tinted(hex: model.accentHex))))
		h.view.backgroundColor = .clear
		w.rootViewController = h
		w.frame = scene.coordinateSpace.bounds
		let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
		let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
		w.small = false
		w.addGestureRecognizer(pan); w.addGestureRecognizer(tap)
		w.pan = pan; w.tap = tap
		window = w; host = h
		return w
	}

	private func hide() {
		guard let w = window else { return }
		window = nil; host = nil
		w.isHidden = true
		mainWindow?.makeKey()
	}

	// MARK: where it sits

	private func place(_ w: CallWindow, _ s: CallCenter.Session, animated: Bool) {
		let target = w.small ? tileFrame(CallMini.size(s), corner) : (scene?.coordinateSpace.bounds ?? w.frame)
		guard target != w.frame else { return }
		if animated, !UIAccessibility.isReduceMotionEnabled {
			UIView.animate(withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) { w.frame = target }
		} else { w.frame = target }
	}

	/// The picture's frame in a corner, clear of the status bar, the home indicator and the edges.
	private func tileFrame(_ size: CGSize, _ c: UIRectCorner) -> CGRect {
		let bounds = scene?.coordinateSpace.bounds ?? UIScreen.main.bounds
		let inset = mainWindow?.safeAreaInsets ?? .zero
		let m: CGFloat = 12
		let x = c.contains(.topLeft) || c.contains(.bottomLeft) ? inset.left + m : bounds.width - inset.right - m - size.width
		let y = c.contains(.topLeft) || c.contains(.topRight) ? inset.top + m + 44 : bounds.height - inset.bottom - m - 60 - size.height
		return CGRect(origin: CGPoint(x: x, y: y), size: size)
	}

	// MARK: touch

	@objc private func tapped(_ g: UITapGestureRecognizer) {
		guard let w = window, w.small else { return }
		model?.calls.minimized = false
	}

	@objc private func panned(_ g: UIPanGestureRecognizer) {
		guard let w = window, w.small, let ref = mainWindow else { return }
		switch g.state {
		case .began: dragFrom = w.frame.origin
		case .changed:
			guard let from = dragFrom else { return }
			let t = g.translation(in: ref)
			w.frame.origin = CGPoint(x: from.x + t.x, y: from.y + t.y)
		default:
			dragFrom = nil
			// Thrown: the corner it's headed for, a little way ahead of where it was let go.
			let v = g.velocity(in: ref)
			let bounds = ref.bounds
			let p = CGPoint(x: w.frame.midX + v.x * 0.15, y: w.frame.midY + v.y * 0.15)
			corner = p.x < bounds.midX ? (p.y < bounds.midY ? .topLeft : .bottomLeft) : (p.y < bounds.midY ? .topRight : .bottomRight)
			if let s = model?.calls.session { place(w, s, animated: true) }
		}
	}
}

/// The call's window: the whole screen while the call is big, the picture's own size while it's
/// small. Its gestures move and open the small picture; the big call takes its touches as views do.
final class CallWindow: UIWindow {
	var small = false { didSet { pan?.isEnabled = small; tap?.isEnabled = small } }
	weak var pan: UIPanGestureRecognizer?
	weak var tap: UITapGestureRecognizer?
	override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
		// Small, the whole picture is one thing to tap or drag.
		if small { return self.point(inside: point, with: event) ? rootViewController?.view : nil }
		return super.hitTest(point, with: event)
	}
}

/// The status bar over the call: light on its dark, and out of the way when it's small.
final class CallHost: UIHostingController<AnyView> {
	var small = false { didSet { if small != oldValue { setNeedsStatusBarAppearanceUpdate() } } }
	override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
	override var prefersHomeIndicatorAutoHidden: Bool { !small }
}

/// What the call's window shows: the call, big or small.
private struct CallStage: View {
	@Environment(AppModel.self) private var model
	var body: some View {
		if let s = model.calls.session {
			if model.calls.minimized && !s.phase.over {
				CallMini(session: s).ignoresSafeArea()
			} else {
				CallScreen(session: s)
			}
		}
	}
}
