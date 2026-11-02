import AppKit
import SwiftUI

// Draws the app icon: the mark, light, on the family's near-black tile. Tile and main are
// shared with Rubric's other apps (Computer's AppIcon.swift); only Mark differs. Writes an .iconset for the Mac,
// a 1024 with the margin for the asset catalog's mac slot, a full-bleed 1024 for iOS and
// watchOS, and the mark alone for the favicon and the landing page.

struct Tile: View {
	var mark: Color = .strong
	var fill: [Color] = [.raised2, .background]
	var body: some View {
		ZStack {
			RoundedRectangle(cornerRadius: 185, style: .continuous)
				.fill(LinearGradient(colors: fill, startPoint: .top, endPoint: .bottom))
				.overlay(
					RoundedRectangle(cornerRadius: 185, style: .continuous)
						.strokeBorder(LinearGradient(colors: [.white.opacity(0.14), .white.opacity(0.03)], startPoint: .top, endPoint: .bottom), lineWidth: 3)
				)
				.frame(width: 824, height: 824)
				.shadow(color: .black.opacity(0.35), radius: 14, y: 10)
			Mark()
				.stroke(mark, style: Mark.stroke(for: 500))
				.frame(width: 500, height: 500)
		}
		.frame(width: 1024, height: 1024)
	}
}

/// The same art with the 100 px margin removed: iOS masks its own corners.
struct FullBleed: View {
	var mark: Color = .strong
	var fill: [Color] = [.raised2, .background]
	var body: some View {
		ZStack {
			Rectangle().fill(LinearGradient(colors: fill, startPoint: .top, endPoint: .bottom))
			Mark()
				.stroke(mark, style: Mark.stroke(for: 500 * 1024 / 824))
				.frame(width: 500 * 1024 / 824, height: 500 * 1024 / 824)
		}
		.frame(width: 1024, height: 1024)
	}
}

struct MarkOnly: View {
	var body: some View {
		Mark().stroke(Color.strong, style: Mark.stroke(for: 24)).frame(width: 24, height: 24).padding(2).frame(width: 28, height: 28)
	}
}

@main
enum AppIcon {
	@MainActor
	static func main() {
		let out = URL(fileURLWithPath: CommandLine.arguments[1])
		// `alternates`: the whole tile in each swatch's colour, the mark light on it (Hue.tile): iOS
		// alternate icons and the Mac's live Dock icon.
		if CommandLine.arguments.count > 2, CommandLine.arguments[2] == "alternates" {
			for (name, hex) in Hue.swatches {
				let t = Hue.tile(hex)
				write(FullBleed(mark: t.mark, fill: [t.top, t.bottom]), scale: 1, to: out.appendingPathComponent("AppIcon-\(name).png"))
				write(Tile(mark: t.mark, fill: [t.top, t.bottom]), scale: 1, to: out.appendingPathComponent("IconMac-\(name).png"))
			}
			return
		}
		let iconset = out.appendingPathComponent("baud.iconset")
		try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
		for size in [16, 32, 128, 256, 512] {
			for scale in [1, 2] {
				write(Tile(), scale: CGFloat(size * scale) / 1024, to: iconset.appendingPathComponent(scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"))
			}
		}
		write(Tile(), scale: 1, to: out.appendingPathComponent("icon-mac-1024.png"))
		write(FullBleed(), scale: 1, to: out.appendingPathComponent("icon-ios-1024.png"))
		write(MarkOnly(), scale: 8, to: out.appendingPathComponent("mark-224.png"))
	}
	@MainActor static func write<V: View>(_ v: V, scale: CGFloat, to url: URL) {
		let r = ImageRenderer(content: v)
		r.scale = scale
		guard let img = r.cgImage, let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { fatalError("the icon didn't render") }
		try? png.write(to: url)
	}
}
