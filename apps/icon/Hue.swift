import SwiftUI

// The swatches and the mark's colour on the tile, as the app computes them (Theme.swift: Accent
// swatches, OKLCH, Tones.iconMark): the alternate icons must match the in-app tile.
enum Hue {
	static let swatches: [(String, String)] = [("red", "E5484D"), ("orange", "F76B15"), ("amber", "FFB224"), ("green", "30A46C"), ("teal", "12A594"), ("blue", "0090FF"), ("violet", "6E56CF"), ("pink", "E93D82")]
	static func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
	static func gam(_ v: Double) -> Double { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }
	static func iconMark(_ hex: String) -> Color {
		let v = UInt32(hex, radix: 16)!
		let r = lin(Double(v >> 16 & 0xFF) / 255), g = lin(Double(v >> 8 & 0xFF) / 255), b = lin(Double(v & 0xFF) / 255)
		let l_ = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
		let m_ = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
		let s_ = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
		let a = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_
		let bb = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
		var c = sqrt(a * a + bb * bb); let h = atan2(bb, a)
		for _ in 0..<12 {
			if let rgb = srgb(l: 0.82, c: c, h: h) { return Color(.sRGB, red: rgb.0, green: rgb.1, blue: rgb.2) }
			c *= 0.8
		}
		return Color(white: 0.96)
	}
	/// The alternate icon's tile: the swatch itself, a breath lighter at the top and deeper at the
	/// foot; the mark white on it, or the family's near-black on a colour too light for white
	/// (the app's Tones.iconTile, its preview in You).
	static func tile(_ hex: String) -> (top: Color, bottom: Color, mark: Color) {
		let v = UInt32(hex, radix: 16)!
		let r = lin(Double(v >> 16 & 0xFF) / 255), g = lin(Double(v >> 8 & 0xFF) / 255), b = lin(Double(v & 0xFF) / 255)
		let l_ = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
		let m_ = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
		let s_ = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
		let L = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_
		let a = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_
		let bb = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
		let c = sqrt(a * a + bb * bb), h = atan2(bb, a)
		func color(_ l: Double) -> Color {
			var c = c
			for _ in 0..<12 { if let rgb = srgb(l: l, c: c, h: h) { return Color(.sRGB, red: rgb.0, green: rgb.1, blue: rgb.2) }; c *= 0.9 }
			return Color(white: l)
		}
		return (color(L + 0.05), color(L - 0.07), L > 0.75 ? Color.background : .white)
	}
	static func srgb(l: Double, c: Double, h: Double) -> (Double, Double, Double)? {
		let a = c * cos(h), b = c * sin(h)
		let l_ = l + 0.3963377774 * a + 0.2158037573 * b, m_ = l - 0.1055613458 * a - 0.0638541728 * b, s_ = l - 0.0894841775 * a - 1.2914855480 * b
		let L = l_ * l_ * l_, M = m_ * m_ * m_, S = s_ * s_ * s_
		let r = 4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S
		let g = -1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S
		let bl = -0.0041960863 * L - 0.7034186147 * M + 1.7076147010 * S
		let out = [r, g, bl].map(gam)
		guard out.allSatisfy({ $0 >= -0.0005 && $0 <= 1.0005 }) else { return nil }
		return (min(max(out[0], 0), 1), min(max(out[1], 0), 1), min(max(out[2], 0), 1))
	}
}
