/// Depth, made of the colour itself and nothing else. The ground is one solid step of it, with no
/// gradient and no glow; raised things (their messages, fields, cards) are solid steps lifted off
/// it by a shadow in the hue's own deep ink: a tight contact shadow where they touch, a soft one
/// under them. Mine are the loud fill. Contrast and shadow make the depth, never a veil.
import SwiftUI

extension Tones {
	/// Their messages and other cards.
	var glass: Color { card }
	/// My messages.
	var mine: Color { loud }
	var onMine: Color { onLoud }
	var onMineSecondary: Color { onLoudSecondary }
}

/// The ground under every screen: the colour, solid.
struct Ground: View {
	@Environment(\.tones) private var tones
	var body: some View { tones.surface.ignoresSafeArea() }
}

extension View {
	/// Raised: a solid card, lifted by the hue's shadow.
	func glass<S: InsettableShape>(_ shape: S, lifted: Bool = true) -> some View { modifier(Lift(shape: shape, lifted: lifted)) }
	func glass(corner: CGFloat, lifted: Bool = true) -> some View { glass(RoundedRectangle(cornerRadius: corner, style: .continuous), lifted: lifted) }
	/// Lifted off the ground: a contact shadow where it touches, a soft one under it.
	func lifted(_ tones: Tones, by depth: CGFloat = 1) -> some View {
		self.shadow(color: tones.shade, radius: 0.5 * depth, y: 0.5 * depth)
			.shadow(color: tones.shade.opacity(0.7), radius: 7 * depth, y: 3.5 * depth)
	}
}

private struct Lift<S: InsettableShape>: ViewModifier {
	@Environment(\.tones) private var tones
	let shape: S
	let lifted: Bool
	func body(content: Content) -> some View {
		content
			.background {
				if lifted { shape.fill(tones.card).lifted(tones) } else { shape.fill(tones.card) }
			}
	}
}
