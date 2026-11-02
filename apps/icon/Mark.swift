import SwiftUI

/// baud's mark: two lights and the line between them, with nothing else on it. Built from the
/// family dot (darkroom's lit dot, Computer's screen light, life's centre): each dot is a tiny
/// circle under the family stroke, so the one `stroke` call every app uses renders it as a
/// solid 4.5-unit disc, and the dash is the same stroke. Read as Morse it is R, received.
struct Mark: Shape {
	func path(in rect: CGRect) -> Path {
		let u = min(rect.width, rect.height) / 24
		let x = rect.minX + (rect.width - 24 * u) / 2, y = rect.minY + (rect.height - 24 * u) / 2
		func p(_ px: CGFloat, _ py: CGFloat) -> CGPoint { CGPoint(x: x + px * u, y: y + py * u) }
		var path = Path()
		for cx in [4.5, 19.5] as [CGFloat] {
			path.addEllipse(in: CGRect(x: p(cx, 12).x - Mark.dot * u, y: p(cx, 12).y - Mark.dot * u, width: 2 * Mark.dot * u, height: 2 * Mark.dot * u))
		}
		path.move(to: p(9.5, 12))
		path.addLine(to: p(14.5, 12))
		return path
	}
	/// The family dot: a circle of this radius under a 2.25 stroke is a solid disc 4.5 wide.
	static let dot: CGFloat = 1.1
	/// Computer draws its mark 2.25 wide on a 24 grid; same weight here.
	static func stroke(for size: CGFloat) -> StrokeStyle {
		StrokeStyle(lineWidth: size / 24 * 2.25, lineCap: .round, lineJoin: .round)
	}
}
