/// The picture a test call sends in place of the camera's: detail everywhere (a collage of shapes,
/// edges and fine lines that pans like a hand-held camera), things moving on their own over it, a
/// patch of grain that changes every frame the way a sensor's does, and the time across the top as
/// forty black and white blocks (32 bits of the host clock in tenths of a millisecond, then 8 of
/// check: calltest reads them off the decoded picture, for latency from drawn to shown). Enough
/// that an encoder has to work for its bits at 1080p60. The collage and the grain are drawn once;
/// each frame copies them in row by row at whole-pixel offsets (a millisecond or two at 1080p), and
/// only the small moving things are drawn.
import CoreGraphics
import CoreVideo
import Foundation

final class TestPattern {
	let width: Int, height: Int
	private let pan: Int, bob: Int
	/// The collage, (width + pan) × (height + 2 bob), BGRA, top row first.
	private let backdrop: [UInt8]
	private let backdropRow: Int
	private let grain: [[UInt8]]
	private let side: Int
	private static let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

	init(width: Int, height: Int) {
		self.width = width; self.height = height
		pan = width / 3; bob = max(2, height / 100)
		var seed: UInt64 = 0x9E3779B97F4A7C15
		func next() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
		let space = CGColorSpaceCreateDeviceRGB()
		let s = Double(height) / 1080
		let bw = width + pan, bh = height + 2 * bob
		backdropRow = bw * 4
		var pixels = [UInt8](repeating: 0, count: backdropRow * bh)
		pixels.withUnsafeMutableBytes { raw in
			guard let ctx = CGContext(data: raw.baseAddress, width: bw, height: bh, bitsPerComponent: 8, bytesPerRow: bw * 4, space: space, bitmapInfo: Self.info) else { return }
			ctx.setFillColor(CGColor(red: 0.16, green: 0.18, blue: 0.22, alpha: 1))
			ctx.fill(CGRect(x: 0, y: 0, width: bw, height: bh))
			for _ in 0..<1400 {
				let w = (4 + next() * 160) * s, h = (4 + next() * 120) * s
				let r = CGRect(x: next() * Double(bw), y: next() * Double(bh), width: w, height: h)
				ctx.setFillColor(CGColor(red: next(), green: next(), blue: next(), alpha: 0.5 + next() / 2))
				if next() < 0.3 { ctx.fillEllipse(in: r) } else { ctx.fill(r) }
			}
			for _ in 0..<500 {
				ctx.setStrokeColor(CGColor(red: next(), green: next(), blue: next(), alpha: 1))
				ctx.setLineWidth(max(1, (1 + next() * 2) * s))
				let x = next() * Double(bw), y = next() * Double(bh)
				ctx.strokeLineSegments(between: [CGPoint(x: x, y: y), CGPoint(x: x + (next() - 0.5) * 300 * s, y: y + (next() - 0.5) * 300 * s)])
			}
		}
		backdrop = pixels
		// Grain: eight tiles of noise around a mid grey, one after another.
		let side = max(64, height / 5)
		self.side = side
		grain = (0..<8).map { _ in
			var t = [UInt8](repeating: 255, count: side * side * 4)
			for i in 0..<side * side {
				let v = UInt8(110 + Int(next() * 36))
				t[i * 4] = v; t[i * 4 + 1] = v &+ 6; t[i * 4 + 2] = v &+ 12
			}
			return t
		}
	}

	/// The host clock now, in tenths of a millisecond: what the barcode says.
	static func stamp() -> UInt32 { UInt32(truncatingIfNeeded: DispatchTime.now().uptimeNanoseconds / 100_000) }

	/// One frame, `time` seconds in.
	func draw(into pb: CVPixelBuffer, time t: Double, stamp: UInt32) {
		CVPixelBufferLockBaseAddress(pb, [])
		defer { CVPixelBufferUnlockBaseAddress(pb, []) }
		guard let base = CVPixelBufferGetBaseAddress(pb), CVPixelBufferGetWidth(pb) == width, CVPixelBufferGetHeight(pb) == height else { return }
		let row = CVPixelBufferGetBytesPerRow(pb)
		// The pan: back and forth across the collage, a little up and down, whole pixels at a time.
		let x = Int((sin(t * 0.7) * 0.5 + 0.5) * Double(pan)), y = bob + Int(sin(t * 1.1) * Double(bob))
		backdrop.withUnsafeBytes { src in
			for r in 0..<height { memcpy(base + r * row, src.baseAddress! + (r + y) * backdropRow + x * 4, width * 4) }
		}
		let g = grain[Int(t * 60) % grain.count]
		let gx = width / 10, gy = height / 2
		g.withUnsafeBytes { src in
			for r in 0..<min(side, height - gy) { memcpy(base + (gy + r) * row + gx * 4, src.baseAddress! + r * side * 4, min(side, width - gx) * 4) }
		}
		guard let ctx = CGContext(data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: row, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: Self.info) else { return }
		let w = Double(width), h = Double(height)
		// A ball on a figure of eight, and a bar going round.
		let bx = w / 2 + cos(t * 1.3) * w * 0.3, by = h / 2 + sin(t * 2.6) * h * 0.25, r = h * 0.09
		ctx.setFillColor(CGColor(red: 0.95, green: 0.9, blue: 0.8, alpha: 1))
		ctx.fillEllipse(in: CGRect(x: bx - r, y: by - r, width: 2 * r, height: 2 * r))
		ctx.saveGState()
		ctx.translateBy(x: w * 0.75, y: h * 0.35)
		ctx.rotate(by: t * 2)
		ctx.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
		ctx.fill(CGRect(x: -h * 0.2, y: -h * 0.02, width: h * 0.4, height: h * 0.04))
		ctx.restoreGState()
		Self.barcode(ctx, width: w, height: h, stamp: stamp)
	}

	/// Forty blocks across the top: the stamp's 32 bits, then their bytes XORed with 0x5a.
	static func barcode(_ ctx: CGContext, width w: Double, height h: Double, stamp: UInt32) {
		let bytes = [UInt8(stamp >> 24), UInt8(stamp >> 16 & 0xff), UInt8(stamp >> 8 & 0xff), UInt8(stamp & 0xff)]
		let all = bytes + [bytes.reduce(UInt8(0x5a)) { $0 ^ $1 }]
		let bw = w * 0.022, bh = h * 0.04, top = h * (1 - 0.02 - 0.04)
		for i in 0..<40 {
			let on = all[i / 8] >> (7 - i % 8) & 1 == 1
			ctx.setFillColor(on ? CGColor(red: 1, green: 1, blue: 1, alpha: 1) : CGColor(red: 0, green: 0, blue: 0, alpha: 1))
			ctx.fill(CGRect(x: w * 0.02 + Double(i) * bw, y: top, width: bw, height: bh))
		}
	}
}
