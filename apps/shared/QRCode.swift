import CoreImage.CIFilterBuiltins
import SwiftUI

/// A link as a QR code, for people in the room.
struct QRCode: View {
	let text: String
	var body: some View {
		if let image = Self.render(text) {
			Image(decorative: image, scale: 1).interpolation(.none).resizable().scaledToFit()
				.clipShape(RoundedRectangle(cornerRadius: Theme.sheetCorner))
		}
	}
	static func render(_ text: String) -> CGImage? {
		let f = CIFilter.qrCodeGenerator()
		f.message = Data(text.utf8)
		f.correctionLevel = "M"
		guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
		return CIContext().createCGImage(out, from: out.extent)
	}
}

/// Demo photos: a flat grey block with a hairline, the size the message says. No gradients.
enum DemoImage {
	/// A dusk over water: something that reads as a photo in the demo, not a grey slab.
	static func make(_ w: Int, _ h: Int) -> Data {
		let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
		let W = CGFloat(w), H = CGFloat(h), horizon = H * 0.40   // CG's origin is the bottom
		let space = CGColorSpaceCreateDeviceRGB()
		func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor { CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: 1) }
		let sky = CGGradient(colorsSpace: space, colors: [rgb(245, 166, 98), rgb(214, 108, 112), rgb(62, 58, 112), rgb(26, 32, 70)] as CFArray, locations: [0, 0.25, 0.7, 1])!
		ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: horizon), end: CGPoint(x: 0, y: H), options: [.drawsAfterEndLocation])
		ctx.setFillColor(rgb(255, 214, 140)); ctx.fillEllipse(in: CGRect(x: W * 0.58, y: horizon - W * 0.05, width: W * 0.13, height: W * 0.13))
		let sea = CGGradient(colorsSpace: space, colors: [rgb(18, 26, 56), rgb(70, 62, 104)] as CFArray, locations: [0, 1])!
		ctx.saveGState(); ctx.clip(to: CGRect(x: 0, y: 0, width: W, height: horizon))
		ctx.drawLinearGradient(sea, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: horizon), options: [])
		ctx.setFillColor(rgb(255, 200, 130).copy(alpha: 0.55)!)
		for i in 0..<9 { let y = horizon - CGFloat(i + 1) * H * 0.035; let wd = W * (0.12 - CGFloat(i) * 0.01); ctx.fill(CGRect(x: W * 0.645 - wd / 2, y: y, width: wd, height: max(1, H * 0.008))) }
		ctx.restoreGState()
		ctx.setFillColor(rgb(20, 22, 44))
		ctx.move(to: CGPoint(x: 0, y: horizon)); ctx.addCurve(to: CGPoint(x: W * 0.42, y: horizon), control1: CGPoint(x: W * 0.12, y: horizon + H * 0.16), control2: CGPoint(x: W * 0.26, y: horizon + H * 0.05)); ctx.closePath(); ctx.fillPath()
		let img = ctx.makeImage()!
		let data = NSMutableData()
		let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
		CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
		return data as Data
	}
}
