/// A timestamp drawn into the synthetic picture and read back off the decoded one: latency from
/// drawing to showing, measured on the pixels, whatever any engine did in between. Forty blocks
/// across the top, white for one and black for nought: 32 bits of the host clock in tenths of a
/// millisecond, then 8 of check. Sized by the picture, so it reads at any resolution down to 360p.
/// The engine's own test pattern draws the same code (VideoPipe); this is the reader, and the
/// drawer for the 0.2.15 copy.
import CoreGraphics
import CoreVideo
import Foundation

public enum Barcode {
	static let count = 40
	static let left = 0.02, width = 0.022, top = 0.02, height = 0.04

	/// The host clock now, in tenths of a millisecond.
	public static func now() -> UInt32 { UInt32(truncatingIfNeeded: DispatchTime.now().uptimeNanoseconds / 100_000) }

	static func bits(_ stamp: UInt32) -> [Bool] {
		let b = [UInt8(stamp >> 24), UInt8(stamp >> 16 & 0xff), UInt8(stamp >> 8 & 0xff), UInt8(stamp & 0xff)]
		let check = b.reduce(UInt8(0x5a)) { $0 ^ $1 }
		return (b + [check]).flatMap { byte in (0..<8).map { byte >> (7 - $0) & 1 == 1 } }
	}

	/// Into a context the size of the picture (origin bottom left, as CoreGraphics has it).
	public static func draw(_ ctx: CGContext, width w: Int, height h: Int, stamp: UInt32) {
		let bw = Double(w) * width, bh = Double(h) * height
		let y = Double(h) * (1 - top - height)
		for (i, on) in bits(stamp).enumerated() {
			ctx.setFillColor(on ? CGColor(red: 1, green: 1, blue: 1, alpha: 1) : CGColor(red: 0, green: 0, blue: 0, alpha: 1))
			ctx.fill(CGRect(x: Double(w) * left + Double(i) * bw, y: y, width: bw, height: bh))
		}
	}

	/// Off a decoded picture (4:2:0 bi-planar, as the decoders give them): nil when it doesn't check.
	public static func read(_ pb: CVPixelBuffer) -> UInt32? {
		guard CVPixelBufferGetPlaneCount(pb) >= 1 else { return nil }
		CVPixelBufferLockBaseAddress(pb, .readOnly)
		defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
		guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)?.assumingMemoryBound(to: UInt8.self) else { return nil }
		let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0), row = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
		let y = Int(Double(h) * (top + height / 2))
		var bytes = [UInt8](repeating: 0, count: 5)
		for i in 0..<count {
			let x = Int(Double(w) * (left + (Double(i) + 0.5) * width))
			var sum = 0
			for dy in -1...1 { for dx in -1...1 { sum += Int(base[(y + dy) * row + x + dx]) } }
			if sum / 9 > 125 { bytes[i / 8] |= 1 << (7 - i % 8) }
		}
		guard bytes[0...3].reduce(UInt8(0x5a), { $0 ^ $1 }) == bytes[4] else { return nil }
		return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
	}

	/// Milliseconds from a stamp to now.
	public static func age(_ stamp: UInt32) -> Double { Double(Int32(bitPattern: now() &- stamp)) / 10 }
}
