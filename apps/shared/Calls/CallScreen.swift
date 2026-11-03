/// The call, on screen. Always dark, and always the person's colour: the colour's own near-black,
/// their face on the loud fill with a ring of it that swells with their voice. Two people: their
/// video fills the whole screen, edge to edge, under the status bar and the home indicator; on a
/// voice call (or with their camera off) their face sits in the middle and breathes with their
/// voice. A video call that's still ringing shows my own camera full screen, the way I'll be seen.
/// A group: everyone in tiles (one fills the screen, two split it, up to four share it two by two,
/// more scroll), the one speaking lit by their voice. Mine is a small picture in a corner I can drag
/// it to, mirrored for the front camera only. One row of round controls floats at the bottom and
/// steps aside while video plays, back on a tap anywhere or a move of the mouse; the button at the
/// top makes the call small (`CallMini`) so the rest of baud can be used. Status is one line:
/// "Ringing…", "4:12 · Direct · 14 ms", "3:02 · 4 in the call", "Ana declined".
import AVFoundation
import BaudCore
import SwiftUI

struct CallScreen: View {
	@Environment(AppModel.self) private var model
	@Environment(\.accessibilityReduceMotion) private var still
	@Environment(\.callStills) private var stills
	let session: CallCenter.Session
	@State private var controls = true
	@State private var touched = Date()
	@State private var corner = Alignment.bottomTrailing
	@State private var drag = CGSize.zero

	private var calls: CallCenter { model.calls }
	private var grid: Bool { session.group && !session.participants.isEmpty && !session.phase.over }
	/// Their picture, arriving, fills the screen.
	private var theirVideo: Bool {
		guard !session.group, session.video, session.remoteCamera, session.phase == .live else { return false }
		return stills != nil || session.participants.first?.showing == true
	}
	/// Video fills the screen: the controls step aside after a while.
	private var immersive: Bool { theirVideo || (grid && session.video) }
	private var cameraUp: Bool { session.video && session.cameraOn && !session.phase.over && session.phase != .incoming }
	/// Mine fills the screen while it rings, and until their picture comes: how I'll look.
	private var mineFull: Bool { cameraUp && !grid && !theirVideo && !(session.phase == .live && !session.remoteCamera) }
	/// Otherwise mine is the small one in the corner: over their picture, or beside their face when
	/// their camera is off.
	private var mineSmall: Bool { cameraUp && !grid && !mineFull }
	private var shown: Bool { controls || !immersive }

	var body: some View {
		let ink = Tones.make(hex: model.accentHex, dark: true)
		ZStack {
			// Edge to edge: the room, and whatever picture fills it.
			GeometryReader { geo in
				ZStack {
					ink.surface
					if theirVideo {
						RemoteVideo(session: session, size: geo.size).transition(.opacity)
					} else if mineFull {
						LocalVideo(session: session).frame(width: geo.size.width, height: geo.size.height).clipped().transition(.opacity)
					}
				}
			}
			.ignoresSafeArea()
			// Inside the safe area: faces, tiles and the controls.
			GeometryReader { geo in
				ZStack {
					if grid {
						Tiles(session: session, size: geo.size, still: still).transition(.opacity)
					} else if !theirVideo {
						if mineFull { Calling(session: session).transition(.opacity) } else { Presence(session: session, still: still).transition(.opacity) }
					}
					if mineSmall { mine(geo.size) }
					top.opacity(shown ? 1 : 0)
					VStack(spacing: 0) {
						Spacer()
						notes
						bar.opacity(shown ? 1 : 0).offset(y: shown ? 0 : 24)
					}
					.padding(.bottom, Self.barBottom)
				}
			}
		}
		.animation(still ? nil : .smooth(duration: 0.35), value: theirVideo)
		.animation(still ? nil : .smooth(duration: 0.35), value: mineFull)
		.animation(still ? nil : .smooth(duration: 0.35), value: session.participants.count)
		.animation(still ? nil : .smooth(duration: 0.3), value: controls)
		.environment(\.colorScheme, .dark)
		.environment(\.tones, ink)
		.contentShape(Rectangle())
		#if os(macOS)
		// A double-click takes the whole screen, and gives it back, as a video player does.
		.onTapGesture(count: 2) { if session.video { NSApp.keyWindow?.toggleFullScreen(nil) } }
		#endif
		.onTapGesture { touch(toggle: true) }
		#if os(macOS)
		.onContinuousHover { _ in touch() }
		#endif
		.task(id: touched) {
			// Five quiet seconds into a video call and the controls step aside. A touch in those five
			// seconds starts them again: the wait it cuts short hides nothing (it used to hide the
			// controls the instant a tap showed them, so on a video call they never came back).
			do { try await Task.sleep(for: .seconds(5)) } catch { return }
			if immersive, session.phase == .live { controls = false }
		}
		.onChange(of: immersive) { _, on in if on { touch() } }
	}

	private func touch(toggle: Bool = false) {
		if toggle, immersive, controls { controls = false; return }
		controls = true; touched = Date()
	}

	#if os(macOS)
	static let barBottom: CGFloat = 26
	static let tile = CGSize(width: 208, height: 130)
	#else
	static let barBottom: CGFloat = 12
	static let tile = CGSize(width: 108, height: 152)
	#endif

	// MARK: pieces

	/// The call's clock, unless the system already shows it: on the iPhone a CallKit call has its
	/// own in the Dynamic Island (or the status bar), and a second one under it is noise.
	private var clock: Bool {
		#if os(iOS)
		return !session.callKit
		#else
		return true
		#endif
	}

	/// The top row: the call made small, and over a picture, who it is, in plain words on a soft
	/// shade (no capsule: one island at the top of a phone is the system's), with how it's going
	/// only when that's worth a word.
	private var top: some View {
		ZStack(alignment: .top) {
			if theirVideo || grid || mineFull && session.phase == .live {
				LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom)
					.frame(height: 170).padding(.top, -80).allowsHitTesting(false)
				VStack(spacing: 2) {
					Text(session.name).font(.system(size: 17, weight: .semibold)).lineLimit(1)
					if clock || StatusLine.notable(session) {
						StatusLine(session: session, clock: clock).font(.system(size: 13, weight: .medium)).monospacedDigit().lineLimit(1).opacity(0.8)
					}
				}
				.foregroundStyle(.white)
				.shadow(color: .black.opacity(0.3), radius: 6, y: 1)
				.padding(.horizontal, 64)
				.padding(.top, 6)
			}
			if !session.phase.over, session.phase != .incoming {
				HStack {
					#if os(macOS)
					Spacer()
					#endif
					CallButton(symbol: "pip.enter", label: "Make the call small", style: .glass, small: true, keys: "⇧⌘M") { calls.minimized = true }
						.keyboardShortcut("m", modifiers: [.command, .shift])
					#if os(iOS)
					Spacer()
					#endif
				}
				.padding(.horizontal, 16)
			}
		}
		.frame(maxHeight: .infinity, alignment: .top)
		#if os(macOS)
		.padding(.top, 34)
		#else
		.padding(.top, 8)
		#endif
	}

	/// My own picture, in the corner I last dragged it to.
	private func mine(_ size: CGSize) -> some View {
		let ink = Tones.make(hex: model.accentHex, dark: true)
		return LocalVideo(session: session)
			.frame(width: Self.tile.width, height: Self.tile.height)
			.clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
			.overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(ink.raised, lineWidth: 2))
			.shadow(color: .black.opacity(0.5), radius: 16, y: 8)
			.overlay { if session.videoPaused { Text("Paused").font(.system(size: 12, weight: .bold)).foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 5).background(ink.raised, in: Capsule()) } }
			.offset(drag)
			.gesture(DragGesture()
				.onChanged { drag = $0.translation }
				.onEnded { g in
					let p = CGPoint(x: g.predictedEndLocation.x, y: g.predictedEndLocation.y)
					let left = p.x < size.width / 2, top = p.y < size.height / 2
					withAnimation(still ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
						corner = top ? (left ? .topLeading : .topTrailing) : (left ? .bottomLeading : .bottomTrailing)
						drag = .zero
					}
				})
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner)
			.padding(.horizontal, 16)
			// Clear of the controls while they're up; lower when they step aside.
			#if os(macOS)
			.padding(.top, 76).padding(.bottom, shown ? 100 : 26)
			#else
			.padding(.top, 60).padding(.bottom, shown ? 96 : 16)
			#endif
			.animation(still ? nil : .smooth(duration: 0.3), value: shown)
	}

	/// A word above the controls when something about the call changed underneath it.
	@ViewBuilder private var notes: some View {
		// Over video only: with the controls away, these are the one place it shows. Without video,
		// their face carries a mute badge and my mute button says the rest.
		let words: String? = session.phase != .live || !theirVideo ? nil
			: session.videoPaused ? "Your video is paused: the connection is weak"
			: session.remoteMuted ? "\(session.first) is muted"
			: session.muted ? "You're muted" : nil
		if let words {
			Text(words).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
				.padding(.horizontal, 14).padding(.vertical, 7)
				.background(Tones.make(hex: model.accentHex, dark: true).raised, in: Capsule())
				.padding(.bottom, 12)
				.transition(.opacity)
		}
	}

	@ViewBuilder private var bar: some View {
		switch session.phase {
		case .incoming:
			HStack(spacing: 44) {
				CallButton(symbol: "phone.down.fill", label: "Decline", style: .danger, big: true) { calls.decline() }
				if session.video { CallButton(symbol: "video.slash.fill", label: "Audio only", style: .glass, big: true) { calls.accept(camera: false) } }
				CallButton(symbol: session.video ? "video.fill" : "phone.fill", label: "Accept", style: .accept, big: true) { calls.accept(camera: true) }
			}
		case .ended:
			EmptyView()
		default:
			HStack(spacing: 12) {
				#if os(iOS)
				if session.video {
					CallButton(symbol: "arrow.triangle.2.circlepath.camera.fill", label: session.front ? "Use the back camera" : "Use the front camera", style: .glass) { calls.flip() }
						.disabled(!session.cameraOn).opacity(session.cameraOn ? 1 : 0.45)
				}
				#endif
				if session.video {
					CallButton(symbol: session.cameraOn ? "video.fill" : "video.slash.fill", label: session.cameraOn ? "Turn camera off" : "Turn camera on", style: session.cameraOn ? .glass : .on, keys: "⇧⌘V") { calls.toggleCamera() }
						.keyboardShortcut("v", modifiers: [.command, .shift])
				}
				CallButton(symbol: session.muted ? "mic.slash.fill" : "mic.fill", label: session.muted ? "Unmute" : "Mute", style: session.muted ? .on : .glass, keys: "⇧⌘A") { calls.toggleMute() }
					.keyboardShortcut("a", modifiers: [.command, .shift])
				#if os(iOS)
				RouteButton(routes: calls.routes)
				#endif
				CallButton(symbol: "phone.down.fill", label: session.phase == .live ? "End call" : "Cancel", style: .danger) { calls.end() }
			}
			.padding(10)
			.background(Capsule().fill(Tones.make(hex: model.accentHex, dark: true).raised))
			.shadow(color: .black.opacity(0.45), radius: 20, y: 10)
		}
	}
}

/// A call button's face: the symbol on its disc, and under the big ones, what it does.
struct CallDisc: View {
	@Environment(\.tones) private var tones
	let symbol: String
	let label: String
	var style: CallButton.Style = .glass
	var big = false
	var small = false
	var hover = false
	#if os(macOS)
	private var size: CGFloat { big ? 56 : small ? 34 : 46 }
	#else
	private var size: CGFloat { big ? 68 : small ? 40 : 54 }
	#endif
	var body: some View {
		VStack(spacing: 8) {
			Image(systemName: symbol)
				.font(.system(size: size * 0.38, weight: .semibold))
				.foregroundStyle(style == .on ? tones.onLoud : .white)
				.contentTransition(.symbolEffect(.replace))
				.frame(width: size, height: size)
				.background(Circle().fill(fill))
				.scaleEffect(hover ? 1.05 : 1)
			if big { Text(label).font(.system(size: 13, weight: .semibold)).foregroundStyle(tones.text) }
		}
		// A finger's worth around the small ones.
		.padding(small ? 4 : 0)
		.contentShape(Rectangle())
	}
	private var fill: Color {
		switch style {
		case .glass: return hover ? tones.quiet : tones.field
		case .on: return tones.loud
		case .danger: return CallInk.danger
		case .accept: return CallInk.accept
		}
	}
}

#if os(iOS)
/// The middle button, for where the call sounds. With only the iPhone, it turns the speaker on and
/// off. With AirPods, a car or headphones around, it shows where the sound is now (their symbol, lit
/// on the speaker) and a tap lists every place it can go, the current one ticked.
struct RouteButton: View {
	let routes: AudioRoutes
	var body: some View {
		if routes.choosable, let now = routes.current {
			Menu {
				Picker("Audio", selection: Binding(get: { now.id }, set: { id in if let r = routes.available.first(where: { $0.id == id }) { routes.choose(r) } })) {
					ForEach(routes.available) { r in Label(r.name, systemImage: r.symbol).tag(r.id) }
				}
				.pickerStyle(.inline)
			} label: {
				CallDisc(symbol: now.symbol, label: now.name, style: now.kind == .speaker ? .on : .glass)
			}
			.buttonStyle(CallButton.Press())
			.accessibilityLabel("Audio: \(now.name)")
			.onAppear { routes.refresh() }
		} else {
			CallButton(symbol: "speaker.wave.2.fill", label: routes.onSpeaker ? "Speaker off" : "Speaker", style: routes.onSpeaker ? .on : .glass) { routes.toggleSpeaker() }
				.onAppear { routes.refresh() }
		}
	}
}
#endif

/// Their picture, the whole screen. Filled when it's the same way round as the screen; whole, on the
/// room's colour, when it isn't (a phone held upright on a wide Mac window), so no one is cut to a
/// sliver of forehead.
private struct RemoteVideo: View {
	@Environment(\.callStills) private var stills
	let session: CallCenter.Session
	let size: CGSize
	var body: some View {
		let fill = Self.fills(session.remoteAspect, size)
		Group {
			if let still = stills?.remote { Image(decorative: still, scale: 1).resizable().aspectRatio(contentMode: fill ? .fill : .fit) }
			else { VideoLayer(layer: session.remote, gravity: fill ? .resizeAspectFill : .resizeAspect) }
		}
		.frame(width: size.width, height: size.height).clipped()
	}
	static func fills(_ aspect: CGFloat?, _ size: CGSize) -> Bool {
		guard let aspect, size.height > 0 else { return true }
		return (aspect >= 1) == (size.width / size.height >= 1)
	}
}

/// My camera: mirrored for the front one, as a mirror would show me; the back one as it is.
private struct LocalVideo: View {
	@Environment(\.callStills) private var stills
	let session: CallCenter.Session
	var body: some View {
		if let still = stills?.local { Image(decorative: still, scale: 1).resizable().scaledToFill().scaleEffect(x: session.front ? -1 : 1) }
		else { VideoLayer(layer: session.local, mirrored: session.front) }
	}
}

/// A video call still ringing, over my own camera: who, and the line, on a solid card at the top.
private struct Calling: View {
	@Environment(\.tones) private var tones
	let session: CallCenter.Session
	var body: some View {
		HStack(spacing: 12) {
			Face(name: session.name, hash: session.avatar, group: session.group).frame(width: 48, height: 48)
			VStack(alignment: .leading, spacing: 2) {
				Text(session.name).font(.system(size: 18, weight: .heavy)).foregroundStyle(tones.text).lineLimit(1)
				StatusLine(session: session).font(.system(size: 14, weight: .medium)).monospacedDigit().foregroundStyle(tones.secondary).lineLimit(1)
			}
		}
		.padding(.leading, 10).padding(.trailing, 18).padding(.vertical, 10)
		.background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(tones.raised))
		.frame(maxWidth: 360)
		.padding(.horizontal, 16)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
		#if os(macOS)
		.padding(.top, 76)
		#else
		.padding(.top, 64)
		#endif
	}
}

/// Stills in place of the live video layers, for pictures of the screen (CallShots): a layer's
/// frames never reach an offscreen renderer.
struct CallStills { var remote: CGImage?; var local: CGImage?; var remotes: [CGImage] = [] }
private struct CallStillsKey: EnvironmentKey { static let defaultValue: CallStills? = nil }
extension EnvironmentValues { var callStills: CallStills? { get { self[CallStillsKey.self] } set { self[CallStillsKey.self] = newValue } } }

/// The fixed palette of the call screen: dark in every theme.
enum CallInk {
	static let background = Color(red: 0.043, green: 0.043, blue: 0.051)
	static let accept = Color(red: 0.19, green: 0.64, blue: 0.42)   // the swatches' green, 30A46C
	static let danger = Color(red: 0.90, green: 0.28, blue: 0.30)   // the swatches' red, E5484D
}

/// Their face, large, with a ring that swells with their voice (mine while it's still ringing on
/// their side), their name, and the line.
private struct Presence: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	let session: CallCenter.Session
	let still: Bool
	var body: some View {
		VStack(spacing: 22) {
			Ring(session: session, still: still, size: 128)
			VStack(spacing: 6) {
				Text(session.name).font(.system(size: 30, weight: .heavy)).foregroundStyle(tones.text).multilineTextAlignment(.center)
				StatusLine(session: session).font(.system(size: 15, weight: .medium)).monospacedDigit().foregroundStyle(tones.secondary).multilineTextAlignment(.center)
			}
			.padding(.horizontal, 32)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		// Centred in the room above the controls.
		.padding(.bottom, 110)
	}
}

/// Their face with the ring of the loud colour: it thickens and swells as they speak, and breathes
/// slowly when nobody does.
struct Ring: View {
	@Environment(\.tones) private var tones
	let session: CallCenter.Session
	let still: Bool
	let size: CGFloat
	var body: some View {
		SwiftUI.TimelineView(.animation(minimumInterval: 1 / 30, paused: still)) { ctx in
			let level = CGFloat(session.phase == .live ? session.remoteLevel : 0)
			let t = ctx.date.timeIntervalSinceReferenceDate
			let breath = still ? 0 : 0.025 * sin(t * 2 * .pi / 4.5)
			let swell = 1 + breath + level * 0.28
			let k = size / 128
			ZStack {
				Circle().strokeBorder(tones.loud, lineWidth: (4 + level * 14) * k)
					.frame(width: size * 1.25, height: size * 1.25).scaleEffect(swell)
				Face(name: session.name, hash: session.avatar, group: session.group).frame(width: size, height: size)
					.overlay(alignment: .bottomTrailing) {
						if session.remoteMuted {
							Image(systemName: "mic.slash.fill").font(.system(size: 13 * max(k, 0.7), weight: .bold)).foregroundStyle(tones.text)
								.frame(width: 34 * max(k, 0.7), height: 34 * max(k, 0.7)).background(Circle().fill(tones.raised)).overlay(Circle().strokeBorder(tones.surface, lineWidth: 3))
								.offset(x: 2, y: 2).accessibilityLabel("\(session.first) is muted").transition(.scale.combined(with: .opacity))
						}
					}
			}
			.frame(width: size * 2.03, height: size * 2.03)
		}
	}
}

/// Their photo, or their initials on a soft disc.
struct Face: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	let name: String
	let hash: BlobHash?
	var group = false
	var body: some View {
		if group {
			Circle().fill(tones.loud)
				.overlay(GeometryReader { g in Image(systemName: "person.2.fill").font(.system(size: g.size.width * 0.32, weight: .bold)).foregroundStyle(tones.onLoud).frame(maxWidth: .infinity, maxHeight: .infinity) })
		} else if let hash, let img = model.image(hash) {
			img.resizable().scaledToFill().clipShape(Circle())
		} else {
			Circle().fill(tones.loud)
				.overlay(GeometryReader { g in Text(initials).font(.system(size: g.size.width * 0.38, weight: .heavy, design: .rounded)).foregroundStyle(tones.onLoud).frame(maxWidth: .infinity, maxHeight: .infinity) })
		}
	}
	private var initials: String {
		let parts = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
		return parts.isEmpty ? "?" : parts.uppercased()
	}
}

/// A group call in tiles that share the screen, me last: two split it (side by side when it's
/// wide, stacked when it's tall), up to four sit two by two, six three by two, more scroll. A tile is the
/// person's video, or their face when the camera is off; its edge lights with their voice, so the
/// one speaking is easy to find.
private struct Tiles: View {
	let session: CallCenter.Session
	let size: CGSize
	let still: Bool
	@Environment(\.callStills) private var stills
	#if os(macOS)
	private let top: CGFloat = 92, bottom: CGFloat = 100
	#else
	private let top: CGFloat = 68, bottom: CGFloat = 96
	#endif
	var body: some View {
		let ps = session.participants
		let n = ps.count + 1
		let wide = size.width > size.height
		let cols = n == 1 ? 1 : n == 2 ? (wide ? 2 : 1) : n <= 4 ? 2 : (wide ? 3 : 2)
		let rows = Int(ceil(Double(n) / Double(cols)))
		let gap: CGFloat = 8
		let w = (size.width - 16 - gap * CGFloat(cols - 1)) / CGFloat(cols)
		let fits = n <= 6
		let h = fits ? (size.height - top - bottom - gap * CGFloat(rows - 1)) / CGFloat(rows) : w * (wide ? 9 / 16 : 4 / 3)
		// Rows of `cols`, the last one centred when it is short (five people: three, then two).
		let cells = ps.indices.map { (id: "\(ps[$0].id)", i: $0) } + [(id: "me", i: ps.count)]
		let grid = VStack(spacing: gap) {
			ForEach(Array(stride(from: 0, to: n, by: cols)), id: \.self) { start in
				HStack(spacing: gap) {
					ForEach(cells[start..<min(start + cols, n)], id: \.id) { c in
						Group {
							if c.i < ps.count { Tile(session: session, p: ps[c.i], image: stills.flatMap { $0.remotes.isEmpty ? nil : $0.remotes[c.i % $0.remotes.count] }) }
							else { Tile(session: session, p: nil, image: stills?.local) }
						}
						.frame(width: w, height: max(80, h))
					}
				}
			}
		}
		Group {
			if fits { grid.frame(maxHeight: .infinity) } else { ScrollView { grid.padding(.vertical, 4) }.scrollIndicators(.never) }
		}
		.padding(.horizontal, 8).padding(.top, top).padding(.bottom, bottom)
	}
}

/// One person in a group call (`p` nil: me).
private struct Tile: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	let session: CallCenter.Session
	let p: CallCenter.Participant?
	let image: CGImage?
	var body: some View {
		let camera = session.video && (p?.camera ?? session.cameraOn)
		let name = p?.first ?? "You"
		let muted = p?.muted ?? session.muted
		// A flexible base the size of the tile: whatever fills it is clipped to it.
		tones.card
			.overlay {
				if camera {
					if let image { Image(decorative: image, scale: 1).resizable().scaledToFill().scaleEffect(x: p == nil && session.front ? -1 : 1) }
					else if let p { VideoLayer(layer: p.layer) } else { VideoLayer(layer: session.local, mirrored: session.front) }
				} else {
					GeometryReader { g in
						let side = min(g.size.width, g.size.height) * 0.42
						Face(name: p?.name ?? model.me.name, hash: p?.avatar ?? model.me.avatar).frame(width: side, height: side).position(x: g.size.width / 2, y: g.size.height / 2)
					}
				}
			}
			.overlay(alignment: .bottomLeading) {
				HStack(spacing: 5) {
					if muted { Image(systemName: "mic.slash.fill").font(.system(size: 11, weight: .semibold)) }
					Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
				}
				.foregroundStyle(tones.text)
				.padding(.horizontal, 10).padding(.vertical, 5)
				.background(tones.raised, in: Capsule())
				.padding(10)
			}
			.clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
			.overlay {
				// The one speaking: the edge lights with their voice.
				SwiftUI.TimelineView(.animation(minimumInterval: 1 / 20, paused: false)) { _ in
					let level = CGFloat(p.map { session.level($0) } ?? session.media?.localLevel ?? 0)
					RoundedRectangle(cornerRadius: 16, style: .continuous)
						.strokeBorder(level > 0.25 ? tones.loud : .clear, lineWidth: 2 + level * 3)
				}
			}
			.accessibilityElement(children: .combine)
			.accessibilityLabel(name + (muted ? ", muted" : ""))
	}
}

/// "Calling…", "Ringing…", "4:12 · Direct · 14 ms", or why it ended.
struct StatusLine: View {
	let session: CallCenter.Session
	var short = false
	/// The call's running time (off where the system shows its own).
	var clock = true
	/// The path is worth a word on screen: through someone's device, the microphone off, a group's
	/// count. A plain direct path isn't (that's how a call should be).
	static func notable(_ s: CallCenter.Session) -> Bool { s.phase != .live || !(s.path.isEmpty || s.path.hasPrefix("Direct")) }
	var body: some View {
		SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { ctx in Text(words(at: ctx.date)) }
	}
	private func words(at now: Date) -> String {
		switch session.phase {
		case .calling: return session.group ? "Calling everyone…" : "Calling…"
		case .ringing: return "Ringing…"
		case .incoming: return (session.group ? "\(session.caller) · " : "") + (session.video ? "Video call" : "Call")
		case .connecting: return "Connecting…"
		case .ended(let why): return why
		case .live:
			let s = Int(now.timeIntervalSince(session.startedAt ?? now))
			let time = s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
			let note = short || !Self.notable(session) ? nil : session.path
			return [clock ? time : nil, note].compactMap { $0 }.joined(separator: " · ")
		}
	}
}

/// A round control: a solid step of the call's dark, on (the loud colour), the red that ends, the
/// green that answers.
struct CallButton: View {
	@Environment(\.tones) private var tones
	@Environment(\.isEnabled) private var enabled
	enum Style { case glass, on, danger, accept }
	let symbol: String
	let label: String
	var style: Style = .glass
	var big = false
	var small = false
	/// The keys it answers to on the Mac, for its tooltip: "⇧⌘A".
	var keys: String? = nil
	let action: () -> Void
	@State private var hover = false
	var body: some View {
		Button {
			#if os(iOS)
			UIImpactFeedbackGenerator(style: style == .danger ? .medium : .light).impactOccurred()
			#endif
			action()
		} label: {
			CallDisc(symbol: symbol, label: label, style: style, big: big, small: small, hover: hover && enabled)
		}
		.buttonStyle(Press())
		.help(keys.map { "\(label) (\($0))" } ?? label)
		.accessibilityLabel(label)
		.onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
	}
	struct Press: ButtonStyle {
		func makeBody(configuration: Configuration) -> some View {
			configuration.label.scaleEffect(configuration.isPressed ? 0.92 : 1).opacity(configuration.isPressed ? 0.85 : 1)
				.animation(.easeOut(duration: 0.12), value: configuration.isPressed)
		}
	}
}

/// A sample-buffer layer as a view: frames go to the layer straight from the decoder, no copies.
/// The view takes no clicks or touches (the screen's own tap and hover pass through it), and a
/// layer is in one place at a time: when the call moves (made small, made big again), the newest
/// view holds it and an old one lets it be.
#if os(macOS)
struct VideoLayer: NSViewRepresentable {
	let layer: AVSampleBufferDisplayLayer
	var mirrored = false
	var gravity: AVLayerVideoGravity = .resizeAspectFill
	func makeNSView(context: Context) -> LayerHost {
		let v = LayerHost(); v.wantsLayer = true
		v.hold(layer)
		update(v)
		return v
	}
	func updateNSView(_ v: LayerHost, context: Context) { update(v) }
	private func update(_ v: LayerHost) {
		CATransaction.begin(); CATransaction.setDisableActions(true)
		layer.setAffineTransform(mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
		layer.videoGravity = gravity
		CATransaction.commit()
	}
	final class LayerHost: NSView {
		private var hosted: CALayer?
		func hold(_ l: CALayer) { hosted = l; layer?.addSublayer(l); needsLayout = true }
		override func hitTest(_ point: NSPoint) -> NSView? { nil }
		override func layout() {
			super.layout()
			guard let hosted, hosted.superlayer === layer else { return }
			CATransaction.begin(); CATransaction.setDisableActions(true); hosted.bounds = bounds; hosted.position = CGPoint(x: bounds.midX, y: bounds.midY); CATransaction.commit()
		}
	}
}
#else
struct VideoLayer: UIViewRepresentable {
	let layer: AVSampleBufferDisplayLayer
	var mirrored = false
	var gravity: AVLayerVideoGravity = .resizeAspectFill
	func makeUIView(context: Context) -> LayerHost {
		let v = LayerHost(); v.isUserInteractionEnabled = false
		v.hold(layer)
		update(v)
		return v
	}
	func updateUIView(_ v: LayerHost, context: Context) { update(v) }
	private func update(_ v: LayerHost) {
		CATransaction.begin(); CATransaction.setDisableActions(true)
		layer.setAffineTransform(mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
		layer.videoGravity = gravity
		CATransaction.commit()
	}
	final class LayerHost: UIView {
		private var hosted: CALayer?
		func hold(_ l: CALayer) { hosted = l; layer.addSublayer(l); setNeedsLayout() }
		override func layoutSubviews() {
			super.layoutSubviews()
			guard let hosted, hosted.superlayer === layer else { return }
			CATransaction.begin(); CATransaction.setDisableActions(true); hosted.bounds = bounds; hosted.position = CGPoint(x: bounds.midX, y: bounds.midY); CATransaction.commit()
		}
	}
}
#endif
