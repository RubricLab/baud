/// `BAUD_MEASURE=1`: open the biggest channel with everything loaded, scroll it top to bottom
/// under a display link, print the numbers, and quit. The same code runs on both platforms.
import BaudCore
import Foundation
import SwiftUI

enum Bench {
	nonisolated(unsafe) static var scrollTo: ((String, UnitPoint) -> Void)?
	nonisolated(unsafe) static var typeInto: ((String) -> Void)?
	/// Mac only: glide the table up for `seconds`, returning how many rows passed.
	nonisolated(unsafe) static var glide: ((Double) async -> Int)?
	nonisolated(unsafe) static var rows = 0

	@MainActor
	static func runIfAsked(_ model: AppModel) async {
		guard Measure.on, let big = model.conversations.max(by: { $0.eventCount < $1.eventCount }) else { return }
		model.open(big.id)
		let t = model.timeline(big.id)
		let t0 = Date()
		t.loadAll()
		Measure.log("loaded \(t.events.count) events into rows in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
		rows = t.rows.count
		try? await Task.sleep(for: .seconds(1.5))
		FrameLink.start()
		let ids = t.rows.map(\.id)
		// A fast flick: fifty rows every quarter second, up through the timeline for twelve
		// seconds, then back to the bottom. The first hop lays the table out and is not counted.
		withAnimation(.easeInOut(duration: 0.3)) { scrollTo?(ids[max(0, ids.count - 60)], .top) }
		try? await Task.sleep(for: .seconds(1))
		Measure.scrollBegan()
		var i = ids.count - 60
		let t1 = Date()
		if ProcessInfo.processInfo.environment["BAUD_MEASURE"] == "glide", let glide = Bench.glide {
			// One continuous twelve-second glide up through the timeline: a long flick, rows filling a few per frame.
			let rows = await glide(12)
			Measure.scrollEnded(rows: rows)
		} else {
			while i > 0, Date().timeIntervalSince(t1) < 12 {
				i = max(0, i - 50)
				withAnimation(.linear(duration: 0.25)) { scrollTo?(ids[i], .top) }
				try? await Task.sleep(for: .seconds(0.25))
			}
			Measure.scrollEnded(rows: ids.count - 60 - i)
		}
		withAnimation(.easeInOut(duration: 0.5)) { scrollTo?("bottom", .bottom) }
		try? await Task.sleep(for: .seconds(1))
		// A keypress: the composer appends a character and the next frame is timed.
		Measure.armed = true
		for _ in 0..<5 { typeInto?("x"); try? await Task.sleep(for: .seconds(0.3)) }
		FrameLink.stop()
		try? await Task.sleep(for: .seconds(0.3))
		exit(0)
	}
}

#if os(macOS)
import AppKit
enum FrameLink {
	nonisolated(unsafe) static var link: CADisplayLink?
	@MainActor static func start() {
		guard let v = NSApp.keyWindow?.contentView ?? NSApp.windows.first?.contentView else { return }
		link = v.displayLink(target: Tick.shared, selector: #selector(Tick.tick(_:))); link?.add(to: .main, forMode: .common)
	}
	static func stop() { link?.invalidate(); link = nil }
}
#else
import UIKit
enum FrameLink {
	nonisolated(unsafe) static var link: CADisplayLink?
	static func start() { link = CADisplayLink(target: Tick.shared, selector: #selector(Tick.tick(_:))); link?.add(to: .main, forMode: .common) }
	static func stop() { link?.invalidate(); link = nil }
}
#endif
final class Tick: NSObject, @unchecked Sendable {
	static let shared = Tick()
	@objc func tick(_ l: CADisplayLink) { Measure.frame(l.timestamp) }
}
