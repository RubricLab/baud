import SwiftUI

// The family's tile colors, shared with Rubric's other apps (Computer's Theme.swift): the tile
// must be identical across them, so these never drift.
extension Color {
	init(hex: UInt32) {
		self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
	}
	static let background = Color(hex: 0x08090A)
	static let raised2 = Color(hex: 0x23262D)
	static let strong = Color(hex: 0xF4F4F5)
}
