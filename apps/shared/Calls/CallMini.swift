/// The call made small, so the rest of baud can be used while it goes on: on the iPhone a picture in
/// a corner over the app, on the Mac a small window over everything. Their video while it shows;
/// otherwise their face breathing with their voice and the call's time. My mute shows as a badge.
/// A tap makes the call big again. The iPhone's window carries the tap and the drag (CallPresenter);
/// on the Mac the picture is dragged anywhere, and hovering it shows mute, back to big, and end.
import AVFoundation
import BaudCore
import SwiftUI

struct CallMini: View {
	@Environment(AppModel.self) private var model
	@Environment(\.accessibilityReduceMotion) private var still
	@Environment(\.callStills) private var stills
	let session: CallCenter.Session
	/// The Mac: the window follows the pointer while dragged (screen points moved since the drag
	/// began; nil when it ends).
	var move: ((CGSize?) -> Void)? = nil
	@State private var hover = false

	private var video: Bool {
		!session.group && session.video && session.remoteCamera && session.phase == .live && session.participants.first?.showing == true
	}

	/// How big it is: the shape of their picture, or a card for a voice call.
	static func size(_ s: CallCenter.Session) -> CGSize {
		let showing = !s.group && s.video && s.remoteCamera && s.phase == .live && s.participants.first?.showing == true
		#if os(macOS)
		guard showing else { return CGSize(width: 288, height: 72) }
		let a = min(1.9, max(0.5, s.remoteAspect ?? 16 / 9))
		return a < 1 ? CGSize(width: 180, height: (180 / a).rounded()) : CGSize(width: 320, height: (320 / a).rounded())
		#else
		guard showing else { return CGSize(width: 108, height: 138) }
		let a = min(1.9, max(0.5, s.remoteAspect ?? 9 / 16))
		return a < 1 ? CGSize(width: 112, height: (112 / a).rounded()) : CGSize(width: 176, height: (176 / a).rounded())
		#endif
	}

	var body: some View {
		let ink = Tones.make(hex: model.accentHex, dark: true)
		ZStack {
			ink.surface
			if video {
				if let still = stills?.remote { Image(decorative: still, scale: 1).resizable().scaledToFill() } else { VideoLayer(layer: session.remote) }
			} else {
				#if os(macOS)
				voiceRow
				#else
				VStack(spacing: 4) {
					Ring(session: session, still: still, size: 46)
					StatusLine(session: session, short: true).font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(ink.text).lineLimit(1)
				}
				.padding(.bottom, 6)
				#endif
			}
		}
		.overlay(alignment: .topLeading) {
			if session.muted {
				Image(systemName: "mic.slash.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(ink.onLoud)
					.frame(width: 24, height: 24).background(Circle().fill(ink.loud)).padding(7)
					.accessibilityLabel("You're muted")
			}
		}
		#if os(macOS)
		.overlay(alignment: .bottom) { if video && hover { macButtons.padding(.bottom, 10).transition(.opacity) } }
		.onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
		.gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
			.onChanged { g in move?(CGSize(width: g.translation.width, height: -g.translation.height)) }
			.onEnded { _ in move?(nil) })
		.onTapGesture { model.calls.minimized = false }
		#endif
		.clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
		.overlay(RoundedRectangle(cornerRadius: Self.corner, style: .continuous).strokeBorder(ink.raised, lineWidth: 2))
		.environment(\.colorScheme, .dark)
		.environment(\.tones, ink)
		.accessibilityElement(children: .combine)
		.accessibilityLabel("Call with \(session.name)")
		.accessibilityHint("Makes the call big again")
		.accessibilityAddTraits(.isButton)
	}

	#if os(macOS)
	static let corner: CGFloat = 16
	#else
	static let corner: CGFloat = 18
	#endif

	#if os(macOS)
	/// A voice call, small: who, the time, and the buttons.
	private var voiceRow: some View {
		HStack(spacing: 10) {
			Face(name: session.name, hash: session.avatar, group: session.group).frame(width: 36, height: 36)
				.padding(5)
				.overlay(Circle().strokeBorder(Tones.make(hex: model.accentHex, dark: true).loud, lineWidth: 2 + CGFloat(session.remoteLevel) * 3))
			VStack(alignment: .leading, spacing: 1) {
				Text(session.name).font(.system(size: 13, weight: .bold)).lineLimit(1)
				StatusLine(session: session, short: true).font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(Tones.make(hex: model.accentHex, dark: true).secondary)
			}
			Spacer(minLength: 4)
			macButtons
		}
		.padding(.leading, 16).padding(.trailing, 12)
	}

	private var macButtons: some View {
		HStack(spacing: 8) {
			CallButton(symbol: session.muted ? "mic.slash.fill" : "mic.fill", label: session.muted ? "Unmute" : "Mute", style: session.muted ? .on : .glass, small: true) { model.calls.toggleMute() }
			if video { CallButton(symbol: "pip.exit", label: "Make the call big", style: .glass, small: true) { model.calls.minimized = false } }
			CallButton(symbol: "phone.down.fill", label: "End call", style: .danger, small: true) { model.calls.end() }
		}
	}
	#endif
}
