/// Monochrome, dense, sharp: the few numbers and colours every screen uses. One accent, used
/// only for the unread dot and the online dot; everything else is primary and secondary.
import BaudCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The one colour the person chose; everything coloured in the app derives from it. Until they
/// choose, it is the text colour, so the app is pure monochrome.
private struct AccentKey: EnvironmentKey { static let defaultValue: Color = .primary }
extension EnvironmentValues { var accent: Color { get { self[AccentKey.self] } set { self[AccentKey.self] = newValue } } }

/// One hue, a full ramp of it, and nothing else: every surface is a solid step of the colour the
/// person chose, never a veil or a gradient. In light the window is the colour itself at full
/// strength (deep picks deepened until white words read at 7:1, pale ones under near-black ink);
/// in dark the window is the colour's own near-black and the colour, still at full strength, is
/// what's loud on it: my messages, the selected row, the count, the send button. None is the same
/// in greys. Every word is a solid colour solved for contrast, not text with its opacity turned down.
struct Tones {
	let tinted: Bool
	/// The person's appearance (the system's), not the window's.
	let dark: Bool
	let hue: Double, chroma: Double
	/// The window's lightness, and whether its words are light.
	let base: Double
	let light: Bool

	/// The window: header, timeline and composer on one ground.
	var surface: Color
	/// The sidebar and the people beside the chat: the same colour a step deeper, never paler.
	var raised: Color
	/// What you type into, and quiet raised things (a field's words are `text`).
	var field: Color
	/// Their messages: a card lifted off the ground.
	var card: Color
	/// The loudest fill: my messages, the selected row, the send button, a count, an online light.
	var loud: Color
	var onLoud: Color
	var onLoudSecondary: Color
	/// Words: the main ink, a solid step under it (at least 5:1), and one for marks (3:1).
	var text: Color
	var secondary: Color
	var tertiary: Color
	var hairline: Color
	var hover: Color
	var pressed: Color
	/// Under reactions, tiles and the like.
	var quiet: Color
	/// The disc behind initials, and what is written on it.
	var face: Color
	var onFace: Color
	/// Shadows are the hue's own deep step, never grey.
	var shade: Color
	/// A device's face, and its screen.
	var device: Color
	var deviceScreen: Color

	var selected: Color { loud }
	var heading: Color { text }
	/// Buttons, the send mark, dots, rings: the loud colour.
	var strong: Color { loud }
	var onStrong: Color { onLoud }
	/// The system chrome the window wants (title bars, tab bars, sheets, menus, the keyboard).
	var chromeDark: Bool { light }

	nonisolated(unsafe) private static var made: [String: Tones] = [:]
	private static let lock = NSLock()

	static func make(hex: String?, dark: Bool) -> Tones {
		let key = "\(hex ?? "-")\(dark)"
		if let t = lock.withLock({ made[key] }) { return t }
		let t = build(hex: hex, dark: dark)
		lock.withLock { made[key] = t }
		return t
	}

	private static func build(hex: String?, dark: Bool) -> Tones {
		guard let hex, let lch = OKLCH.parse(hex) else { return greys(dark: dark) }
		// A pick with no colour in it: black is black in either light; white or a grey is the plain
		// ramp (its hue would be noise, and its own lightness can't carry a loud fill).
		if lch.c < 0.03 { return lch.l < 0.4 ? blacks() : greys(dark: dark) }
		let (h, c0) = (lch.h, lch.c)
		func p(_ l: Double, _ c: Double) -> Color { OKLCH.p3(l: l, c: c, h: h) }
		func y(_ l: Double, _ c: Double) -> Double { OKLCH.luminance(l: l, c: c, h: h) }
		// A pale pick (orange, amber) reads under near-black ink; a deep one under white.
		let pale = lch.l >= 0.66
		let inkL = 0.17, inkC = min(c0, 0.06)
		let whiteC = min(c0, 0.02)
		if dark {
			// Warm hues (orange, amber) go brown when deep: their near-black keeps less chroma, so it
			// reads as a warm black under the colour, not as mud.
			let warm = max(0, cos(min(1, abs(h * 180 / .pi - 65) / 50) * .pi / 2))
			let cg = min(c0, 0.06) * (1 - 0.6 * warm)
			let g = 0.19
			// The colour at full strength: white words at 4.5:1 or better on a deep pick, near-black on a pale one.
			// Solved against the white actually drawn on it, not pure white.
			// A very deep pick is lifted to the middle, so it is still loud on the near-black.
			let loudL = pale ? lch.l : max(0.5, OKLCH.deepest(l: lch.l, c: c0, h: h, against: y(0.99, whiteC), ratio: 4.6))
			let text = p(0.975, min(c0, 0.015))
			let secL = OKLCH.reach(from: g, to: 0.975, c: cg * 0.8, h: h, on: [y(g, cg), y(0.165, cg), y(0.29, cg * 1.25)], ratio: 4.6)
			let terL = OKLCH.reach(from: g, to: 0.975, c: cg, h: h, on: [y(g, cg), y(0.165, cg)], ratio: 3.1)
			return Tones(tinted: true, dark: true, hue: h, chroma: c0, base: g, light: true,
				surface: p(g, cg), raised: p(0.165, cg), field: p(0.265, cg * 1.1), card: p(0.29, cg * 1.25),
				loud: p(loudL, c0), onLoud: pale ? p(inkL, inkC) : p(0.99, whiteC), onLoudSecondary: pale ? p(0.3, min(c0, 0.09)) : p(0.92, min(c0, 0.04)),
				text: text, secondary: p(secL, cg * 0.8), tertiary: p(terL, cg),
				hairline: p(0.29, cg), hover: p(0.235, cg), pressed: p(0.27, cg), quiet: p(0.28, cg * 1.2),
				face: p(0.4, cg * 1.6), onFace: p(0.985, whiteC), shade: p(0.07, cg).opacity(0.55),
				device: p(0.36, cg), deviceScreen: p(0.14, cg))
		}
		if pale {
			// The colour itself, lifted just enough that its near-black ink reads at 7:1.
			let g = OKLCH.shallowest(l: lch.l, c: c0, h: h, text: y(inkL, inkC), ratio: 7)
			let side = g - 0.045
			let white = p(0.985, min(c0 * 0.12, 0.02))
			let secL = OKLCH.reach(from: side, to: inkL, c: c0, h: h, on: [y(g, c0), y(side, c0)], ratio: 5)
			let terL = OKLCH.reach(from: side, to: inkL, c: c0, h: h, on: [y(g, c0), y(side, c0)], ratio: 3.1)
			return Tones(tinted: true, dark: false, hue: h, chroma: c0, base: g, light: false,
				surface: p(g, c0), raised: p(side, c0 * 1.04), field: white, card: white,
				loud: p(0.2, min(c0, 0.085)), onLoud: p(0.985, whiteC), onLoudSecondary: p(0.8, min(c0, 0.08)),
				text: p(inkL, inkC), secondary: p(secL, min(c0, 0.14)), tertiary: p(terL, c0),
				hairline: p(g - 0.13, c0), hover: p(side - 0.05, c0), pressed: p(side - 0.09, c0), quiet: p(g - 0.07, c0),
				face: p(0.2, min(c0, 0.085)), onFace: p(0.985, whiteC), shade: p(0.25, c0 * 0.8).opacity(0.3),
				device: white, deviceScreen: p(g - 0.12, c0))
		}
		// Deep: the colour, deepened until white reads at 7:1.
		// Never so deep that the sidebar a step below it has nowhere to go.
		let g = max(0.14, OKLCH.deepest(l: min(lch.l, 0.55), c: c0, h: h, against: y(0.985, whiteC), ratio: 7))
		let side = g - 0.045
		let card = g + 0.075
		let secL = OKLCH.reach(from: card, to: 0.985, c: c0 * 0.35, h: h, on: [y(g, c0), y(side, c0), y(card, c0)], ratio: 4.6)
		let terL = OKLCH.reach(from: g, to: 0.985, c: c0 * 0.5, h: h, on: [y(g, c0), y(side, c0)], ratio: 3.1)
		return Tones(tinted: true, dark: false, hue: h, chroma: c0, base: g, light: true,
			surface: p(g, c0), raised: p(side, c0), field: p(card, c0 * 0.95), card: p(card, c0 * 0.95),
			loud: p(0.975, min(c0 * 0.15, 0.03)), onLoud: p(0.36, c0), onLoudSecondary: p(0.5, c0),
			text: p(0.985, whiteC), secondary: p(secL, c0 * 0.35), tertiary: p(terL, c0 * 0.5),
			hairline: p(g + 0.1, c0), hover: p(g + 0.02, c0), pressed: p(side - 0.06, c0), quiet: p(g + 0.07, c0),
			face: p(0.975, min(c0 * 0.15, 0.03)), onFace: p(0.36, c0), shade: p(0.14, c0).opacity(0.4),
			device: p(g + 0.12, c0), deviceScreen: p(side - 0.05, c0))
	}

	/// Black, picked: the window black in light and dark alike, white the loud fill.
	private static func blacks() -> Tones {
		func g(_ l: Double) -> Color { OKLCH.color(l: l, c: 0, h: 0) }
		return Tones(tinted: false, dark: true, hue: 0, chroma: 0, base: 0.1, light: true,
			surface: g(0.1), raised: g(0.065), field: g(0.2), card: g(0.225),
			loud: g(0.97), onLoud: g(0.12), onLoudSecondary: g(0.42),
			text: g(0.97), secondary: g(0.72), tertiary: g(0.56), hairline: g(0.24), hover: g(0.15), pressed: g(0.19), quiet: g(0.2),
			face: g(0.32), onFace: g(0.97), shade: Color.black.opacity(0.6), device: g(0.3), deviceScreen: g(0.06))
	}

	/// No colour: the same ramp in greys.
	private static func greys(dark: Bool) -> Tones {
		func g(_ l: Double) -> Color { OKLCH.color(l: l, c: 0, h: 0) }
		if dark {
			return Tones(tinted: false, dark: true, hue: 0, chroma: 0, base: 0.175, light: true,
				surface: g(0.175), raised: g(0.15), field: g(0.25), card: g(0.275),
				loud: g(0.97), onLoud: g(0.16), onLoudSecondary: g(0.42),
				text: g(0.97), secondary: g(0.74), tertiary: g(0.58), hairline: g(0.28), hover: g(0.215), pressed: g(0.25), quiet: g(0.26),
				face: g(0.36), onFace: g(0.97), shade: Color.black.opacity(0.5), device: g(0.34), deviceScreen: g(0.12))
		}
		return Tones(tinted: false, dark: false, hue: 0, chroma: 0, base: 1, light: false,
			surface: g(1), raised: g(0.968), field: g(0.94), card: g(0.935),
			loud: g(0.18), onLoud: g(0.985), onLoudSecondary: g(0.78),
			text: g(0.16), secondary: g(0.45), tertiary: g(0.6), hairline: g(0.89), hover: g(0.935), pressed: g(0.9), quiet: g(0.935),
			face: g(0.88), onFace: g(0.16), shade: Color.black.opacity(0.13), device: g(1), deviceScreen: g(0.9))
	}

	/// The same tones for what sits on a loud fill (the selected row, my message): its words flip.
	var onLoudTones: Tones {
		var t = self
		t.text = onLoud; t.secondary = onLoudSecondary; t.tertiary = onLoudSecondary
		t.surface = loud; t.hairline = onLoudSecondary
		t.loud = onLoud; t.onLoud = loud; t.onLoudSecondary = loud
		if !dark || !tinted { t.face = onLoud; t.onFace = loud }
		return t
	}

	/// The colour of the mark on the app icon: the hue itself, light enough to read on the tile.
	var iconMark: Color { tinted ? OKLCH.color(l: 0.82, c: chroma, h: hue) : Color(white: 0.96) }
	/// The app icon's tile: the family's near-black, or the colour itself, a breath lighter at the
	/// top, the mark light on it (dark on a colour too light for it). apps/icon draws the same.
	var iconTile: (fill: [Color], mark: Color) {
		// The nearest swatch, as IconColour picks the alternate icon; a grey is the shipped tile.
		func gap(_ a: Double, _ b: Double) -> Double { let d = abs(a - b).truncatingRemainder(dividingBy: 2 * .pi); return min(d, 2 * .pi - d) }
		guard tinted, chroma >= 0.04, let lch = Accent.swatches.compactMap({ OKLCH.parse($0.hex) }).min(by: { gap($0.h, hue) < gap($1.h, hue) }) else {
			return ([Color(white: 0.16), Color(white: 0.05)], Color(white: 0.96))
		}
		return ([OKLCH.color(l: lch.l + 0.05, c: lch.c, h: lch.h), OKLCH.color(l: lch.l - 0.07, c: lch.c, h: lch.h)],
				lch.l > 0.75 ? Color(.sRGB, red: 8 / 255, green: 9 / 255, blue: 10 / 255) : .white)
	}
	static func ink(onLightness l: Double, hue: Double, chroma: Double) -> Color {
		l > 0.62 ? OKLCH.color(l: 0.18, c: min(chroma, 0.05), h: hue) : OKLCH.color(l: 0.98, c: min(chroma, 0.02), h: hue)
	}
}
/// True while a view is drawn off screen for a picture: controls backed by platform views (a colour
/// well) draw a still likeness instead of a placeholder.
private struct RenderingKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues { var rendering: Bool { get { self[RenderingKey.self] } set { self[RenderingKey.self] = newValue } } }
private struct TonesKey: EnvironmentKey { static let defaultValue = Tones.make(hex: nil, dark: false) }
extension EnvironmentValues { var tones: Tones { get { self[TonesKey.self] } set { self[TonesKey.self] = newValue } } }

/// Sets accent and palette from the model's colour and the scheme in force.
struct Tinted: ViewModifier {
	let hex: String?
	func body(content: Content) -> some View {
		// The person's appearance, read from the app, not the window: each window wears the hue's
		// own chrome (dark under white text), which would otherwise feed back into the ramp.
		let t = Tones.make(hex: hex, dark: Appearance.shared.dark)
		content.environment(\.accent, t.strong).environment(\.tones, t).tint(t.strong).foregroundStyle(t.text)
			.modifier(Chrome(tones: t))
	}
}

/// Light or dark, as the person set it for the whole Mac or iPhone: observed, so a flip redraws.
/// Read from the system, never from the app's own appearance, which follows the hue's chrome
/// (`preferredColorScheme`) and would otherwise feed back into the ramp.
@MainActor @Observable
final class Appearance {
	static let shared = Appearance()
	private(set) var dark: Bool
	#if os(macOS)
	private var watch: NSObjectProtocol?
	#endif
	init() {
		dark = Self.read()
		#if os(macOS)
		watch = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { _ in Task { @MainActor in Appearance.shared.refresh() } }
		#endif
	}
	func refresh() { let d = Self.read(); if d != dark { dark = d } }
	static func read() -> Bool {
		// `BAUD_APPEARANCE=light|dark` for the pictures.
		if let a = ProcessInfo.processInfo.environment["BAUD_APPEARANCE"], a != "system" { return a == "dark" }
		#if os(macOS)
		return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
		#else
		// The screen's style is the system's, untouched by the window's override.
		return (UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen.traitCollection.userInterfaceStyle ?? .light) == .dark
		#endif
	}
}

/// The bars around the content: on iOS the navigation and tab bars take the surface and flip
/// their own text to match; on the Mac the window does this through WindowTint.
struct Chrome: ViewModifier {
	let tones: Tones
	func body(content: Content) -> some View {
		#if os(iOS)
		// The window's style follows the hue, so the tab bar's glass, sheets, menus and the keyboard
		// are dark under white text and light under near-black.
		content.background(WindowStyle(dark: tones.chromeDark).frame(width: 0, height: 0))
		#else
		// The window's appearance (SwiftUI owns it; setting NSWindow.appearance is undone).
		content.preferredColorScheme(tones.chromeDark ? .dark : .light)
		#endif
	}
}

#if os(iOS)
struct WindowStyle: UIViewRepresentable {
	let dark: Bool
	func makeUIView(context: Context) -> UIView { Probe() }
	func updateUIView(_ v: UIView, context: Context) { (v as? Probe)?.style = dark ? .dark : .light; (v as? Probe)?.apply() }
	final class Probe: UIView {
		var style: UIUserInterfaceStyle = .unspecified
		override func didMoveToWindow() { super.didMoveToWindow(); apply() }
		func apply() { if let w = window, w.overrideUserInterfaceStyle != style { w.overrideUserInterfaceStyle = style } }
	}
}
#endif

/// OKLCH in and sRGB out, with chroma pulled in until the colour fits the gamut.
enum OKLCH {
	struct LCH { var l: Double, c: Double, h: Double }
	static func parse(_ hex: String) -> LCH? {
		guard let v = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) else { return nil }
		let r = lin(Double(v >> 16 & 0xFF) / 255), g = lin(Double(v >> 8 & 0xFF) / 255), b = lin(Double(v & 0xFF) / 255)
		let l_ = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
		let m_ = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
		let s_ = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
		let L = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_
		let a = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_
		let bb = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
		return LCH(l: L, c: sqrt(a * a + bb * bb), h: atan2(bb, a))
	}
	/// The lowest lightness at or over `l` where text of luminance `text` reads at `ratio` on it.
	static func shallowest(l: Double, c: Double, h: Double, text: Double, ratio: Double) -> Double {
		var l = l
		while l < 0.95 {
			let y = luminance(l: l, c: c, h: h)
			if (max(text, y) + 0.05) / (min(text, y) + 0.05) >= ratio { return l }
			l += 0.01
		}
		return l
	}
	/// The first lightness from `from` toward `to` where this colour reads at `ratio` on every one of
	/// `on` (luminances): a secondary ink as close to its ground as it can be and still be read.
	static func reach(from: Double, to: Double, c: Double, h: Double, on: [Double], ratio: Double) -> Double {
		let dir = to > from ? 0.005 : -0.005
		var l = from
		while (dir > 0 ? l < to : l > to) {
			let y = luminance(l: l, c: c, h: h)
			if on.allSatisfy({ (max($0, y) + 0.05) / (min($0, y) + 0.05) >= ratio }) { return l }
			l += dir
		}
		return to
	}
	/// Relative luminance of an OKLCH colour, its chroma pulled in until it is in gamut.
	static func luminance(l: Double, c: Double, h: Double) -> Double {
		var c = c
		for _ in 0..<12 {
			if let rgb = srgb(l: l, c: c, h: h) { return 0.2126 * lin(rgb.0) + 0.7152 * lin(rgb.1) + 0.0722 * lin(rgb.2) }
			c *= 0.8
		}
		return 0
	}
	/// The highest lightness at or under `l` where text of luminance `against` reads at `ratio`.
	static func deepest(l: Double, c: Double, h: Double, against: Double, ratio: Double) -> Double {
		var l = l
		while l > 0.2 {
			if let rgb = srgb(l: l, c: c, h: h) ?? srgb(l: l, c: c * 0.5, h: h) {
				let y = 0.2126 * lin(rgb.0) + 0.7152 * lin(rgb.1) + 0.0722 * lin(rgb.2)
				if (max(against, y) + 0.05) / (min(against, y) + 0.05) >= ratio { return l }
			}
			l -= 0.01
		}
		return l
	}
	static func color(l: Double, c: Double, h: Double) -> Color {
		var c = c
		for _ in 0..<12 {
			if let rgb = srgb(l: l, c: c, h: h) { return Color(.sRGB, red: rgb.0, green: rgb.1, blue: rgb.2) }
			c *= 0.8
		}
		let rgb = srgb(l: l, c: 0, h: h) ?? (0.5, 0.5, 0.5)
		return Color(.sRGB, red: rgb.0, green: rgb.1, blue: rgb.2)
	}
	/// The same colour in Display P3: a deep, saturated step keeps chroma that sRGB would shed (and
	/// go grey for). Chroma is pulled in only until the colour fits P3.
	static func p3(l: Double, c: Double, h: Double) -> Color {
		var c = c
		for _ in 0..<14 {
			let (r, g, b) = linear(l: l, c: c, h: h)
			let pr = 0.8224621 * r + 0.1775380 * g, pg = 0.0331941 * r + 0.9668058 * g, pb = 0.0170827 * r + 0.0723974 * g + 0.9105199 * b
			let eps = 0.002
			if [pr, pg, pb].allSatisfy({ $0 >= -eps && $0 <= 1 + eps }) {
				return Color(.displayP3, red: gam(min(max(pr, 0), 1)), green: gam(min(max(pg, 0), 1)), blue: gam(min(max(pb, 0), 1)))
			}
			c *= 0.85
		}
		return color(l: l, c: 0, h: h)
	}
	private static func linear(l: Double, c: Double, h: Double) -> (Double, Double, Double) {
		let a = c * cos(h), b = c * sin(h)
		let l_ = l + 0.3963377774 * a + 0.2158037573 * b
		let m_ = l - 0.1055613458 * a - 0.0638541728 * b
		let s_ = l - 0.0894841775 * a - 1.2914855480 * b
		let L = l_ * l_ * l_, M = m_ * m_ * m_, S = s_ * s_ * s_
		return (4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S, -1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S, -0.0041960863 * L - 0.7034186147 * M + 1.7076147010 * S)
	}
	private static func srgb(l: Double, c: Double, h: Double) -> (Double, Double, Double)? {
		let a = c * cos(h), b = c * sin(h)
		let l_ = l + 0.3963377774 * a + 0.2158037573 * b
		let m_ = l - 0.1055613458 * a - 0.0638541728 * b
		let s_ = l - 0.0894841775 * a - 1.2914855480 * b
		let L = l_ * l_ * l_, M = m_ * m_ * m_, S = s_ * s_ * s_
		let r = 4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S
		let g = -1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S
		let bl = -0.0041960863 * L - 0.7034186147 * M + 1.7076147010 * S
		let eps = 0.002
		guard r >= -eps, r <= 1 + eps, g >= -eps, g <= 1 + eps, bl >= -eps, bl <= 1 + eps else { return nil }
		return (gam(min(max(r, 0), 1)), gam(min(max(g, 0), 1)), gam(min(max(bl, 0), 1)))
	}
	private static func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
	private static func gam(_ v: Double) -> Double { v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055 }
}

enum Accent {
	/// Bold, saturated, equal weight: the row of swatches in Settings and on first run.
	/// Black, as the swatch row offers it beside white (no colour).
	static let black = "000000"
	static let swatches: [(name: String, hex: String)] = [("red", "E5484D"), ("orange", "F76B15"), ("amber", "FFB224"), ("green", "30A46C"), ("teal", "12A594"), ("blue", "0090FF"), ("violet", "6E56CF"), ("pink", "E93D82")]
	static func color(_ hex: String?) -> Color? {
		guard let hex, let v = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) else { return nil }
		return Color(.sRGB, red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
	}
	static func hex(_ c: Color) -> String {
		#if os(macOS)
		let n = NSColor(c).usingColorSpace(.sRGB) ?? .black
		return String(format: "%02X%02X%02X", Int(n.redComponent * 255), Int(n.greenComponent * 255), Int(n.blueComponent * 255))
		#else
		var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
		UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a)
		return String(format: "%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
		#endif
	}
}

/// One type scale: small, body, heading, title, display. Nothing else is set in another size.
enum Theme {
	#if os(macOS)
	static let row: CGFloat = 32
	static let body: CGFloat = 13
	static let small: CGFloat = 11
	static let display: CGFloat = 26
	/// What people say is set a step larger than the chrome around it.
	static let message: CGFloat = 14
	#else
	static let row: CGFloat = 44
	// Dynamic Type: the person's text size, each step from its own text style, up to twice the
	// default so the fixed chrome (rows, tiles, chips) still holds it.
	static var body: CGFloat { scaled(16, .body) }
	static var small: CGFloat { scaled(13, .footnote) }
	static var display: CGFloat { scaled(30, .largeTitle) }
	static var message: CGFloat { scaled(17, .body) }
	static func scaled(_ v: CGFloat, _ style: UIFont.TextStyle) -> CGFloat { min(UIFontMetrics(forTextStyle: style).scaledValue(for: v), v * 2) }
	#endif
	static let corner: CGFloat = 6
	static let rowInsets = EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
	/// The conversation title and the space's name: much larger and heavier than rows.
	static var title: CGFloat { body + 6 }
	/// Section headings (Chats, Friends, Channels): set apart by size and the space above them.
	static var heading: CGFloat { body + 3 }
	/// Between message groups; within one; under the last of one.
	static let groupGap: CGFloat = 14
	static let rowGap: CGFloat = 2
	static let groupBottom: CGFloat = 2
	/// Above a sidebar section heading.
	static let sectionGap: CGFloat = 28
	/// The Mac's top band: the traffic lights, the mode switch beside them, the conversation's title
	/// level with them. Everything starts at the window's top edge.
	static let band: CGFloat = 32
	/// The conversation header under the band's top edge.
	static let header: CGFloat = 54
	/// The Mac composer takes the keyboard on open; the phone waits for a tap so the keyboard doesn't cover the chat.
	#if os(macOS)
	static let autofocus = true
	#else
	static let autofocus = false
	#endif
	static let sheetCorner: CGFloat = 10

	static var font: Font { .system(size: body) }
	static var messageFont: Font { .system(size: message) }
	static var headingFont: Font { .system(size: heading, weight: .bold) }
	static var titleFont: Font { .system(size: title, weight: .bold) }
	static var displayFont: Font { .system(size: display, weight: .bold) }
	static var smallFont: Font { .system(size: small) }
	static var mono: Font { .system(size: small, design: .monospaced) }
}

struct Hairline: View {
	@Environment(\.tones) private var tones
	var body: some View { Rectangle().fill(tones.hairline).frame(height: 1) }
}

/// A face: their photo, or their initials on a solid disc; when they're online, a light cut into
/// the bottom corner (whatever is behind shows through the cut, on any row). Away and never seen
/// draw nothing on the face: the words beside it say so, and a list of mostly-away friends stays
/// clean, so the ones who are here stand out.
struct Avatar: View {
	@Environment(\.accent) private var accent
	@Environment(\.tones) private var tones
	@Environment(AppModel.self) private var model
	let name: String
	var hash: BlobHash? = nil
	var size: CGFloat = 24
	var presence: Mark? = nil
	var ring: Bool = false

	private var initials: String {
		let parts = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
		return parts.isEmpty ? "?" : parts.uppercased()
	}
	private var lit: Bool { presence == .online || presence == .onlineRelayed }
	var body: some View {
		let badge = max(8, (size * 0.36).rounded())
		let gap = max(3, size / 10)
		ZStack(alignment: .bottomTrailing) {
			Group {
				if let hash, let img = model.image(hash) { img.resizable().scaledToFill() }
				else {
					Circle().fill(tones.face)
						.overlay(Text(initials).font(.system(size: size * (initials.count > 1 ? 0.38 : 0.44), weight: .bold, design: .rounded)).foregroundStyle(tones.onFace))
				}
			}
			.frame(width: size, height: size).clipShape(Circle())
			.overlay(Circle().stroke(ring ? accent : Color.clear, lineWidth: max(1.5, size / 16)))
			if lit {
				Circle().frame(width: badge + gap, height: badge + gap).offset(x: 1.5, y: 1.5).blendMode(.destinationOut)
			}
		}
		.compositingGroup()
		.overlay(alignment: .bottomTrailing) {
			if lit { PresenceLight(relayed: presence == .onlineRelayed, size: badge).offset(x: 1.5 - gap / 2, y: 1.5 - gap / 2) }
		}
		.frame(width: size, height: size)
		.help(presence?.meaning ?? "")
	}
}

/// Online: a solid light in the loud colour. Through a helper, the same light with its middle
/// open, so the difference is there for whoever looks and quiet for whoever doesn't.
struct PresenceLight: View {
	@Environment(\.tones) private var tones
	var relayed = false
	var size: CGFloat = 8
	var body: some View {
		Circle().fill(tones.strong)
			.overlay { if relayed { Circle().fill(Color.black).frame(width: size * 0.4, height: size * 0.4).blendMode(.destinationOut) } }
			.compositingGroup()
			.frame(width: size, height: size)
			.accessibilityLabel(relayed ? "Online, through a helper" : "Online")
	}
}

func clock(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
func dayTitle(_ d: Date) -> String {
	if Calendar.current.isDateInToday(d) { return "Today" }
	if Calendar.current.isDateInYesterday(d) { return "Yesterday" }
	return d.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
}
func whenShort(_ d: Date) -> String {
	if Calendar.current.isDateInToday(d) { return clock(d) }
	if Calendar.current.isDateInYesterday(d) { return "Yesterday" }
	return d.formatted(.dateTime.month(.abbreviated).day())
}

/// Inside a NavigationStack on iOS: the bar takes the surface and flips its title to match.
struct Bars: ViewModifier {
	@Environment(\.tones) private var tones
	func body(content: Content) -> some View {
		#if os(iOS)
		content.toolbarBackground(tones.surface, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
			.toolbarColorScheme(tones.chromeDark ? .dark : .light, for: .navigationBar)
		#else
		content
		#endif
	}
}
