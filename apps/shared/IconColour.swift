/// The app icon in the colour: the whole tile in the nearest swatch, the mark light on it. The
/// Mac's Dock icon changes live; the iPhone switches to that swatch's alternate icon when You
/// closes (iOS says so each time it changes, so only for the colour kept: AppModel.settleIcon).
/// A colour that isn't a swatch takes the nearest hue; None and a grey are the icon as shipped.
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
enum IconColour {
	static func swatch(_ hex: String?) -> String? {
		guard let hex, let lch = OKLCH.parse(hex), lch.c >= 0.04 else { return nil }
		if let s = Accent.swatches.first(where: { $0.hex.caseInsensitiveCompare(hex) == .orderedSame }) { return s.name }
		func gap(_ a: Double, _ b: Double) -> Double { let d = abs(a - b).truncatingRemainder(dividingBy: 2 * .pi); return min(d, 2 * .pi - d) }
		return Accent.swatches.min { gap(OKLCH.parse($0.hex)!.h, lch.h) < gap(OKLCH.parse($1.hex)!.h, lch.h) }?.name
	}
	static func apply(_ hex: String?) {
		let name = swatch(hex)
		#if os(macOS)
		NSApp?.applicationIconImage = name.flatMap { NSImage(named: "IconMac-\($0)") }
		#else
		let want = name.map { "AppIcon-\($0)" }
		guard UIApplication.shared.supportsAlternateIcons, UIApplication.shared.alternateIconName != want else { return }
		UIApplication.shared.setAlternateIconName(want) { e in Measure.log(e.map { "icon: \($0)" } ?? "icon: \(want ?? "the shipped one")") }
		#endif
	}
}
