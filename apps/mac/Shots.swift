/// `BAUD_SHOTS=<dir>`: the app walks its own screens on staged data, photographs every window it
/// has open with `screencapture -l` (the real pixels, by window id, nothing activated) and quits.
/// `BAUD_APPEARANCE=light|dark|system` picks the appearance (light by default), `BAUD_ACCENT`
/// the colour, `BAUD_SHOTS_STEPS=channel,dm,…` a subset, `BAUD_HOLD=secs` how long each screen
/// stays up (for a person watching, or a capture from outside).
import AppKit
import BaudCore
import SwiftUI

enum Shots {
	static let all = Features.spaces ? ["channel", "members", "dm", "home", "spaces", "hike", "palette", "add", "settings", "page"] : ["dm", "members", "hike", "home", "palette", "add", "page"]

	@MainActor
	static func runIfAsked(_ model: AppModel, show: @escaping (String) -> Void) async {
		let env = ProcessInfo.processInfo.environment
		guard let dir = env["BAUD_SHOTS"] else { return }
		// Without `BAUD_APPEARANCE` the pictures are in the system's appearance and say so.
		let mode = env["BAUD_APPEARANCE"] ?? "system"
		// The appearance comes from `BAUD_APPEARANCE` through `Appearance.read()`; the windows wear the hue's chrome.
		let suffix = mode == "system" ? "-system" : (mode == "dark" ? "-dark" : "")
		let hold = Double(env["BAUD_HOLD"] ?? "") ?? 0
		let steps = env["BAUD_SHOTS_STEPS"].map { $0.split(separator: ",").map(String.init) } ?? all

		try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		// `BAUD_SHOTS_AT=secs`: start later, after a real friend has arrived and talked.
		if let at = env["BAUD_SHOTS_AT"].flatMap(Double.init) { try? await Task.sleep(for: .seconds(at)) }
		Measure.log("shots in \(dir): \(steps)")
		func snap(_ name: String) async {
			try? await Task.sleep(for: .seconds(1.2 + hold))
			for w in NSApp.windows where w.isVisible { w.orderFrontRegardless(); w.contentView?.layoutSubtreeIfNeeded(); w.displayIfNeeded() }
			try? await Task.sleep(for: .milliseconds(300))
			let wins = NSApp.windows.filter { $0.isVisible && $0.frame.width > 200 && $0.frame.height > 120 }.sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
			let paths = wins.indices.map { i in URL(fileURLWithPath: dir).appendingPathComponent(i == 0 ? "mac-\(name)\(suffix).png" : "mac-\(name)-\(i)\(suffix).png") }
			// First the app's own drawing of each window (works with the screen locked; AppKit tables
			// that draw nothing into a cached display come out blank), then the real pixels from
			// outside: the tour script reads `.want` ("path window-id" per line), replaces each picture
			// it can capture, and removes the file. The app may not record the screen itself.
			for (w, url) in zip(wins, paths) {
				drawn(w).map { try? $0.write(to: url) }
				if env["BAUD_SHOT_DEBUG"] != nil, let v = w.contentView, let layer = v.layer {
					let img = NSImage(size: v.bounds.size); img.lockFocus()
					if let ctx = NSGraphicsContext.current?.cgContext { layer.render(in: ctx) }
					img.unlockFocus()
					if let t = img.tiffRepresentation, let b = NSBitmapImageRep(data: t) { try? b.representation(using: .png, properties: [:])?.write(to: url.deletingPathExtension().appendingPathExtension("layer.png")) }
				}
			}
			// `BAUD_SHOTS_CAPTURE=1`: a script outside is there to take the real pixels.
			if env["BAUD_SHOTS_CAPTURE"] != nil {
				let want = URL(fileURLWithPath: dir).appendingPathComponent(".want")
				try? (zip(wins, paths).map { "\($1.path) \($0.windowNumber)" }.joined(separator: "\n") + "\n").write(to: want, atomically: true, encoding: .utf8)
				for _ in 0..<50 where FileManager.default.fileExists(atPath: want.path) { try? await Task.sleep(for: .milliseconds(100)) }
			}
			Measure.log("snap \(name): \(wins.map(\.title))")
			if env["BAUD_SHOT_DEBUG"] != nil {
				func dump(_ x: NSView, _ d: Int) -> String { String(repeating: "  ", count: d) + "\(type(of: x)) \(Int(x.frame.width))x\(Int(x.frame.height)) hidden=\(x.isHidden) alpha=\(x.alphaValue)\n" + (d < 4 ? x.subviews.prefix(5).map { dump($0, d + 1) }.joined() : "") }
				for w in wins { Measure.log("window \(w.title) bg=\(w.backgroundColor.description) appearance=\(w.appearance?.name.rawValue ?? "-") key=\(w.isKeyWindow) occl=\(w.occlusionState.rawValue)\n" + (w.contentView.map { dump($0, 0) } ?? "no content")) }
			}
		}
		func close(_ title: String) { NSApp.windows.first { $0.title == title }?.close() }
		// The demo's #general and Sam, or on real data the first channel and the first chat.
		let general = model.conversations.first { $0.kind == .channel && $0.name == "general" } ?? model.conversations.first { $0.kind == .channel }
		let sam = model.chats.first { c in c.isDirect && model.title(c) == "Sam" } ?? model.chats.first
		for step in steps {
			switch step {
			case "channel":
				if let g = general { model.open(g.id) }
				await snap(step)
			case "members":
				if Features.spaces, let g = general { model.open(g.id) } else if let s = sam { model.open(s.id) }
				show("members"); await snap(step); show("members")
			case "dm":
				if let s = sam { model.open(s.id) }
				await snap(step)
			case "files":
				// A photo, a document and two reactions in Sam's chat: the look of attachments.
				if let s = sam, let urls = sampleFiles() {
					model.open(s.id)
					model.attempt {
						let e = try model.core.send(s.id, Draft(text: "the cabin, and the plan for saturday", attachments: urls))
						try model.core.react(s.id, e.id, "🔥", on: true); try model.core.react(s.id, e.id, "🏔️", on: true)
					}
				}
				await snap(step)
			case "emoji":
				// The reaction picker, in a panel of its own (a popover can't be opened from here).
				let panel = NSPanel(contentRect: NSRect(x: 240, y: 240, width: 304, height: 376), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
				panel.titlebarAppearsTransparent = true
				panel.contentView = NSHostingView(rootView: EmojiPicker(pick: { _ in }).modifier(Tinted(hex: model.shownHex)).environment(model))
				if env["BAUD_HIDDEN"] == "1" { panel.alphaValue = 0; panel.ignoresMouseEvents = true }
				panel.orderFront(nil)
				await snap(step)
				panel.close()
			case "home":
				model.show(.home); model.open(nil); await snap(step)
			case "spaces":
				model.leaveSpace(); await snap(step)
			case "palette":
				show("palette"); await snap(step); show("palette")
			case "newchat", "newgroup":
				// The New chat and New group sheets, then closed.
				show("sheet:" + (step == "newchat" ? "chat" : "group")); await snap(step); show("sheet:")
				try? await Task.sleep(for: .milliseconds(500))
			case "hike":
				// A group chat with someone who isn't my friend, its people open.
				if let h = model.chats.first(where: { $0.name == "hike" }) { model.open(h.id) }
				show("members"); await snap(step); show("members")
			case "marks":
				show("marks:" + dir + "/marks\(suffix).png")
				try? await Task.sleep(for: .seconds(1))
			case "now":
				// Whatever is on screen right now (a link being joined, a window a hook opened).
				await snap(step)
			case "add":
				// The Add screen, friend side; then closed.
				model.offer = .friend
				await snap(step)
				model.offer = nil; close("Add")
				try? await Task.sleep(for: .seconds(1))
			case "page":
				// Settings whole, rendered off screen: the window's scroll view draws nothing into the
				// app's own pictures, so the page is drawn by itself at the window's width.
				show("page:" + dir + "/mac-settings-page\(suffix).png")
				try? await Task.sleep(for: .seconds(1))
			case let s where s == "settings" || s.hasPrefix("settings-"):
				// Settings, in the main window: a section by name (`settings-updates`), then back.
				show(s == "settings" ? "settings" : "settings:" + String(s.dropFirst(9)))
				try? await Task.sleep(for: .seconds(0.6))
				await snap(s)
				show("back")
			case "friends":
				show("friends"); await snap(step); show("back")
			case "msginfo":
				// Info for my newest message in Sam's chat, and for Sam's newest: drawn by themselves.
				if let s = sam {
					let events = model.core.events(s.id, before: nil, limit: 100).filter { $0.type == .message && $0.text != nil }
					for (name, e) in [("mine", events.last { $0.mine }), ("theirs", events.last { !$0.mine })] {
						guard let e else { continue }
						Shots.render(MessageInfo(event: e).modifier(Tinted(hex: model.shownHex)).environment(model).font(Theme.font), width: 420, background: .clear, to: dir + "/mac-msginfo-\(name)\(suffix).png")
					}
				}
			case let s where s.hasPrefix("open-"):
				// Any chat by its name (`open-weekend`), at rest.
				if let c = model.chats.first(where: { model.title($0) == String(s.dropFirst(5)) }) { model.open(c.id) }
				await snap(s)
			case "connection":
				show("connection:" + dir + "/mac-connection\(suffix).png")
				try? await Task.sleep(for: .seconds(1))
			default: break
			}
		}
		exit(0)
	}

	/// A photo (a dusk over hills, drawn here) and a one-page PDF, for the attachments shot.
	@MainActor static func sampleFiles() -> [URL]? {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("baud-shot-files")
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		let img = NSImage(size: NSSize(width: 1600, height: 1100), flipped: false) { r in
			NSGradient(colors: [NSColor(srgbRed: 0.99, green: 0.70, blue: 0.47, alpha: 1), NSColor(srgbRed: 0.55, green: 0.42, blue: 0.70, alpha: 1), NSColor(srgbRed: 0.13, green: 0.16, blue: 0.34, alpha: 1)])?.draw(in: r, angle: 90)
			for (k, (y, shade)) in [(0.34, 0.20), (0.24, 0.12), (0.14, 0.06)].enumerated() {
				let p = NSBezierPath(); p.move(to: NSPoint(x: 0, y: 0)); p.line(to: NSPoint(x: 0, y: r.height * y))
				p.curve(to: NSPoint(x: r.width, y: r.height * (y - 0.06 + Double(k) * 0.05)), controlPoint1: NSPoint(x: r.width * 0.35, y: r.height * (y + 0.16)), controlPoint2: NSPoint(x: r.width * 0.6, y: r.height * (y - 0.12)))
				p.line(to: NSPoint(x: r.width, y: 0)); p.close()
				NSColor(srgbRed: shade, green: shade + 0.03, blue: shade + 0.12, alpha: 1).setFill(); p.fill()
			}
			return true
		}
		let photo = dir.appendingPathComponent("cabin.jpg"), pdf = dir.appendingPathComponent("Saturday plan.pdf")
		guard let tiff = img.tiffRepresentation, let jpg = NSBitmapImageRep(data: tiff)?.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return nil }
		try? jpg.write(to: photo)
		var box = CGRect(x: 0, y: 0, width: 612, height: 792)
		if let ctx = CGContext(pdf as CFURL, mediaBox: &box, nil) { ctx.beginPDFPage(nil); ctx.endPDFPage(); ctx.closePDF() }
		return [photo, pdf]
	}

	/// The window as its views draw it, composited on the window's colour.
	@MainActor static func drawn(_ w: NSWindow) -> Data? {
		guard let v = (ProcessInfo.processInfo.environment["BAUD_SHOT_CONTENT"] != nil ? w.contentView : w.contentView?.superview ?? w.contentView), let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
		v.cacheDisplay(in: v.bounds, to: rep)
		let out = NSImage(size: v.bounds.size)
		out.lockFocus()
		w.effectiveAppearance.performAsCurrentDrawingAppearance { (w.backgroundColor ?? .windowBackgroundColor).setFill() }
		v.bounds.fill()
		rep.draw(in: v.bounds)
		out.unlockFocus()
		guard let tiff = out.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff) else { return nil }
		return bmp.representation(using: .png, properties: [:])
	}

	/// A view rendered off screen at a width, on the surface, at the screen's scale.
	@MainActor static func render<V: View>(_ view: V, width: CGFloat, background: Color, to path: String) {
		let r = ImageRenderer(content: view.environment(\.rendering, true).frame(width: width).background(background))
		r.scale = NSScreen.main?.backingScaleFactor ?? 2
		r.proposedSize = ProposedViewSize(width: width, height: nil)
		guard let img = r.nsImage, let t = img.tiffRepresentation, let b = NSBitmapImageRep(data: t), let png = b.representation(using: .png, properties: [:]) else { Measure.log("render failed: \(path)"); return }
		try? png.write(to: URL(fileURLWithPath: path))
		Measure.log("rendered \(path) \(Int(img.size.width))x\(Int(img.size.height))")
	}

}

/// Every baud mark at three sizes with its meaning, for review.
struct MarksSheet: View {
	@Environment(\.tones) private var tones
	let sets: [(String, [Mark])] = [("Delivery", [.sending, .carried, .delivered, .read]), ("Propagation", [.direct, .relayed, .held, .waiting]), ("Presence", [.online, .onlineRelayed, .away, .neverSeen]), ("Identity", [.verified, .vouched, .unverified])]
	var body: some View {
		VStack(alignment: .leading, spacing: 22) {
			Text("baud marks").font(Theme.titleFont)
			ForEach(sets, id: \.0) { name, marks in
				VStack(alignment: .leading, spacing: 10) {
					Text(name.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(tones.secondary)
					HStack(alignment: .top, spacing: 18) {
						ForEach(marks) { m in
							VStack(alignment: .leading, spacing: 8) {
								HStack(alignment: .bottom, spacing: 12) {
									MarkView(mark: m, size: 48, color: m == .online || m == .onlineRelayed ? tones.strong : tones.text)
									MarkView(mark: m, size: 24, color: m == .online || m == .onlineRelayed ? tones.strong : tones.text)
									MarkView(mark: m, size: 14, color: m == .online || m == .onlineRelayed ? tones.strong : tones.text)
								}
								Text(m.rawValue).font(Theme.mono)
								Text(m.meaning).font(Theme.smallFont).foregroundStyle(tones.secondary).frame(width: 150, alignment: .leading).fixedSize(horizontal: false, vertical: true)
							}
						}
					}
				}
			}
			VStack(alignment: .leading, spacing: 10) {
				Text("DEVICES AND FACES").font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(tones.secondary)
				HStack(alignment: .bottom, spacing: 18) {
					ForEach([DeviceShape.macbook, .macMini, .iphone, .ipad, .pcTower], id: \.rawValue) { d in
						VStack(spacing: 6) { HStack(spacing: 6) { DeviceGlyph(shape: d, lit: true, size: 24); DeviceGlyph(shape: d, lit: false, size: 24) }; Text(d.rawValue).font(Theme.mono) }
					}
					ForEach([Mark.online, .onlineRelayed, .away, .neverSeen]) { m in
						VStack(spacing: 6) { Avatar(name: "Ana Ruiz", size: 36, presence: m); Text(m.rawValue).font(Theme.mono) }
					}
				}
			}
		}
		.padding(28)
	}
}
