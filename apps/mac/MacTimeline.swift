/// The Mac timeline: an NSTableView whose cells are the shared SwiftUI rows, with every row
/// height computed once from the text and cached, so ten thousand rows cost nothing to lay out
/// and a flick stays at the display's rate. Anchored at the bottom; older pages keep the view
/// still while they arrive above.
import AppKit
import BaudCore
import SwiftUI

struct MacTimeline: NSViewRepresentable {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	let timeline: Timeline
	var onReply: (Event) -> Void
	var onThread: (Event) -> Void

	enum Row: Identifiable {
		case row(Timeline.Row)
		case delivery(Delivery)
		case line(String, String, Mark?)   // id, text, its mark: my newest message's way
		case typing([String])
		var id: String { switch self { case .row(let r): return r.id; case .delivery: return "delivery"; case .line(let id, _, _): return id; case .typing: return "typing" } }
	}

	func makeCoordinator() -> Coordinator { Coordinator(model: model) }

	func makeNSView(context: Context) -> NSScrollView {
		let c = context.coordinator
		let table = NSTableView()
		table.addTableColumn(NSTableColumn(identifier: .init("row")))
		table.headerView = nil
		table.style = .plain
		table.selectionHighlightStyle = .none
		table.intercellSpacing = .zero
		table.backgroundColor = .clear
		table.usesAutomaticRowHeights = false
		table.allowsEmptySelection = true
		table.dataSource = c
		table.delegate = c
		let scroll = SwipeScroll()
		scroll.registerForDraggedTypes([.fileURL])
		dropInto(scroll)
		scroll.onSwipe = { [weak c] x, release in
			guard let c else { return }
			if release { withAnimation(.spring(duration: 0.35, bounce: 0.15)) { c.swipe.x = 0 } } else { c.swipe.x = x }
		}
		scroll.documentView = table
		scroll.hasVerticalScroller = true
		// Clear all the way down: the lit ground behind the conversation shows through.
		scroll.drawsBackground = false
		scroll.backgroundColor = .clear
		scroll.contentView.drawsBackground = false
		scroll.contentView.backgroundColor = .clear
		scroll.contentView.postsBoundsChangedNotifications = true
		scroll.contentView.postsFrameChangedNotifications = true
		NotificationCenter.default.addObserver(c, selector: #selector(Coordinator.scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
		NotificationCenter.default.addObserver(c, selector: #selector(Coordinator.resized), name: NSView.frameDidChangeNotification, object: scroll.contentView)
		c.table = table; c.scroll = scroll
		c.onReply = onReply; c.onThread = onThread
		Bench.scrollTo = { [weak c] id, anchor in c?.scroll(to: id, top: anchor == .top) }
		Bench.glide = { [weak c] seconds in await c?.glide(seconds: seconds) ?? 0 }
		return scroll
	}

	/// Files dropped on the messages go to this conversation's composer (again on every update: the
	/// same scroll view can show another conversation).
	private func dropInto(_ scroll: NSScrollView) {
		guard let scroll = scroll as? SwipeScroll else { return }
		let conv = timeline.conv, model = model
		scroll.onDragOver = { [weak model] on in guard let model else { return }; model.dropOver = on ? conv : (model.dropOver == conv ? nil : model.dropOver) }
		scroll.onFiles = { [weak model] urls in model?.dropped[conv, default: []] += urls }
	}

	func updateNSView(_ scroll: NSScrollView, context: Context) {
		dropInto(scroll)
		let c = context.coordinator
		c.onReply = onReply; c.onThread = onThread
		var rows: [Row] = timeline.rows.map { .row($0) }
		if let s = timeline.status { rows.append(.line("delivery-\(s)", s, timeline.statusMark)) }
		if !timeline.typing.isEmpty { rows.append(.typing(timeline.typing)) }
		c.apply(rows, timeline: timeline)
	}

	@MainActor
	final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
		let model: AppModel
		let swipe = Swipe()
		var table: NSTableView!
		var scroll: NSScrollView!
		var rows: [Row] = []
		var timeline: Timeline?
		var onReply: (Event) -> Void = { _ in }
		var onThread: (Event) -> Void = { _ in }
		var heights = Heights()
		var loading = false

		init(model: AppModel) { self.model = model }

		func apply(_ new: [Row], timeline: Timeline) {
			self.timeline = timeline
			let oldIds = rows.map(\.id), newIds = new.map(\.id)
			guard oldIds != newIds else {
				// Same rows, maybe new content (an edit, a reaction): redraw what is visible.
				rows = new
				heights.forget(rows.map(\.id))
				let r = table.rows(in: table.visibleRect); table.reloadData(forRowIndexes: IndexSet(integersIn: r.location..<(r.location + r.length)), columnIndexes: [0])
				return
			}
			let wasAtBottom = atBottom || rows.isEmpty
			let prepended = !oldIds.isEmpty && newIds.count > oldIds.count && Array(newIds.suffix(oldIds.count)) == oldIds
			let before = table.bounds.height
			let origin = scroll.contentView.bounds.origin
			rows = new
			heights.width = scroll.contentView.bounds.width
			heights.prefetch(rows, width: max(heights.width, 200), model: model, timeline: timeline)
			table.reloadData()
			prewarm()
			if prepended {
				// Older rows arrived above: keep what the eye was on where it was.
				let added = table.bounds.height - before
				scroll.contentView.scroll(to: NSPoint(x: 0, y: origin.y + added))
				scroll.reflectScrolledClipView(scroll.contentView)
			} else if wasAtBottom || (newIds.last != oldIds.last && lastIsMine) {
				scrollToBottom(animated: !oldIds.isEmpty)
			}
			loading = false
		}

		/// A pool of cells ahead of time, so a page-fill hop reuses views instead of making them.
		private var warmed = false
		private func prewarm() {
			guard !warmed, !rows.isEmpty else { return }
			warmed = true
			let want = Int(scroll.contentView.bounds.height / 24) * 2 + 8
			var pool: [HostCell] = []
			for i in 0..<min(want, rows.count) {
				let c = HostCell(model: model)
				c.host.rootView = RowHost(row: rows[max(0, rows.count - 1 - i)], onReply: onReply, onThread: onThread, model: model)
				c.frame = NSRect(x: 0, y: 0, width: table.bounds.width, height: 40)
				c.layoutSubtreeIfNeeded()
				pool.append(c)
			}
			spare = pool
		}
		private var spare: [HostCell] = []

		var lastIsMine: Bool { timeline?.events.last?.mine == true }
		var atBottom: Bool {
			let v = scroll.contentView.bounds
			return v.maxY >= table.bounds.height - 40
		}

		func scrollToBottom(animated: Bool) {
			let y = max(0, table.bounds.height - scroll.contentView.bounds.height)
			if animated { NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.15; scroll.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: y)) } }
			else { scroll.contentView.scroll(to: NSPoint(x: 0, y: y)) }
			scroll.reflectScrolledClipView(scroll.contentView)
		}

		func scroll(to id: String, top: Bool) {
			if id == "bottom" { scrollToBottom(animated: true); return }
			guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
			let r = table.rect(ofRow: i)
			let y = top ? r.minY : max(0, r.maxY - scroll.contentView.bounds.height)
			NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.25; scroll.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: y)) }
			scroll.reflectScrolledClipView(scroll.contentView)
		}

		/// A new width changes every wrapped line: forget the heights and let the table ask again.
		/// A long flick: the clip view's origin animated linearly for `seconds` at about 2,400 pt/s.
		func glide(seconds: Double) async -> Int {
			let from = scroll.contentView.bounds.origin.y
			let to = max(0, from - 2400 * seconds)
			let startRow = table.row(at: NSPoint(x: 1, y: from))
			await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
				NSAnimationContext.runAnimationGroup({ ctx in
					ctx.duration = seconds; ctx.timingFunction = CAMediaTimingFunction(name: .linear)
					scroll.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: to))
				}, completionHandler: { k.resume() })
			}
			scroll.reflectScrolledClipView(scroll.contentView)
			return abs(startRow - table.row(at: NSPoint(x: 1, y: to)))
		}

		@objc func resized() {
			let w = scroll.contentView.bounds.width
			guard w > 0, w != heights.width else { return }
			let wasAtBottom = atBottom
			heights.width = w
			table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
			if wasAtBottom { scrollToBottom(animated: false) }
		}

		@objc func scrolled() {
			guard let timeline, !timeline.exhausted, !loading, scroll.contentView.bounds.minY < 600 else { return }
			loading = true
			timeline.loadMore()
		}

		// Laying cells out ahead of the scroll (one per run-loop turn) was tried and measured: the
		// layout work landed inside the animation's frames and cost 10–20 ms per worst frame, so it
		// is gone. The floor now is a hosting view's first layout when a row enters; below 16 ms
		// means drawing the common message shape natively.

		func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

		func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
			heights.height(for: rows[row], width: max(heights.width, 200), model: model, timeline: timeline)
		}

		/// Rows paint nothing; the window's colour shows through.
	func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
		let v = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("row"), owner: nil) as? NSTableRowView ?? NSTableRowView()
		v.identifier = NSUserInterfaceItemIdentifier("row"); v.backgroundColor = .clear; v.wantsLayer = true; v.layer?.backgroundColor = nil
		// A bubble's shadow falls past its row; cut at the row's edge, it drew a hard line under each.
		v.clipsToBounds = false
		return v
	}
	func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
			let cell = (tableView.makeView(withIdentifier: HostCell.id, owner: nil) as? HostCell) ?? spare.popLast() ?? HostCell(model: model)
			cell.host.rootView = RowHost(row: rows[row], onReply: onReply, onThread: onThread, model: model, swipe: swipe)
			return cell
		}
	}
}

/// One concrete root view per cell, so an update is a diff of the same type, not a new tree.
struct RowHost: View {
	let row: MacTimeline.Row
	var onReply: (Event) -> Void
	var onThread: (Event) -> Void
	let model: AppModel
	/// How far a two-finger swipe has drawn the messages aside (their times beside them).
	var swipe: Swipe? = nil
	var body: some View {
		Group {
			switch row {
			case .row(.day(let d)): DayRow(date: d)
			case .row(.event(let e, let first, let last)):
				if e.type == .message { MessageRow(event: e, first: first, last: last, onReply: onReply, onThread: onThread) } else { SystemRow(event: e) }
			case .delivery: EmptyView()
			case .line(_, let text, let mark): DeliveryRow(text: text, mark: mark)
			case .typing(let names): TypingRow(names: names)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.environment(\.reveal, TimelineView.held ?? swipe?.x ?? 0)
		.environment(model).modifier(Tinted(hex: model.accentHex))
	}
}

/// The swipe that draws every message aside to show its time and way, as a drag does on the
/// iPhone: shared by every row on screen.
@MainActor @Observable
final class Swipe { var x: CGFloat = 0 }

/// The timeline's scroll view: a two-finger swipe to the left (more sideways than up or down)
/// draws the messages aside while the fingers stay and lets them spring back on release; anything
/// else scrolls as ever. A mouse wheel has no phases and only ever scrolls.
final class SwipeScroll: NSScrollView {
	var onSwipe: ((CGFloat, Bool) -> Void)?
	/// Files dragged over the messages: said, and taken, here too (the table under SwiftUI's own
	/// drop area would otherwise swallow them).
	var onDragOver: ((Bool) -> Void)?
	var onFiles: (([URL]) -> Void)?
	override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { onDragOver?(true); return .copy }
	override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
	override func draggingExited(_ sender: NSDraggingInfo?) { onDragOver?(false) }
	override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
		onDragOver?(false)
		guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
		onFiles?(urls.map { _ = $0.startAccessingSecurityScopedResource(); return $0 })
		return true
	}
	private var x: CGFloat = 0
	private var sideways: Bool?
	override func scrollWheel(with e: NSEvent) {
		if e.phase == .began || e.phase == .mayBegin { sideways = nil; x = 0 }
		if sideways == nil, e.phase == .began || e.phase == .changed {
			let dx = abs(e.scrollingDeltaX), dy = abs(e.scrollingDeltaY)
			if dx > 0.5 || dy > 0.5 { sideways = dx > dy * 1.5 }
		}
		guard sideways == true else { super.scrollWheel(with: e); return }
		if e.phase == .began || e.phase == .changed {
			// The fingers' own way, whichever way the person has scrolling set.
			let fingers = e.isDirectionInvertedFromDevice ? e.scrollingDeltaX : -e.scrollingDeltaX
			x = max(0, x - fingers)
			let w = TimelineView.revealWidth
			onSwipe?(x < w ? x : w + (x - w) * 0.15, false)
		} else if e.phase == .ended || e.phase == .cancelled {
			onSwipe?(0, true); sideways = nil; x = 0
		}
		// Momentum after a sideways swipe moves nothing.
	}
}

/// One reusable cell hosting a SwiftUI row.
final class HostCell: NSTableCellView {
	static let id = NSUserInterfaceItemIdentifier("host")
	let host: NSHostingView<RowHost>
	@MainActor init(model: AppModel) {
		host = NSHostingView(rootView: RowHost(row: .line("", "", nil), onReply: { _ in }, onThread: { _ in }, model: model))
		super.init(frame: .zero)
		identifier = Self.id
		clipsToBounds = false
		host.clipsToBounds = false
		host.sizingOptions = []
		host.translatesAutoresizingMaskIntoConstraints = false
		addSubview(host)
		// A column at most `MessageRow.column` wide, centred: on a narrow window, the cell less 16 a side.
		let fill = host.widthAnchor.constraint(equalTo: widthAnchor, constant: -32)
		fill.priority = .defaultHigh
		NSLayoutConstraint.activate([host.centerXAnchor.constraint(equalTo: centerXAnchor), host.widthAnchor.constraint(lessThanOrEqualToConstant: MessageRow.column), fill, host.topAnchor.constraint(equalTo: topAnchor), host.bottomAnchor.constraint(equalTo: bottomAnchor)])
	}
	required init?(coder: NSCoder) { nil }
}

/// Row heights from the text, computed once per row and width. The constants are the SwiftUI
/// rows' own metrics, measured once at launch by hosting a few sample rows, so the arithmetic
/// matches what the cell draws.
@MainActor
struct Heights {
	var width: CGFloat = 0 { didSet { if width != oldValue { cache.removeAll() } } }
	private var cache: [String: CGFloat] = [:]
	private static var metrics: Metrics?

	struct Metrics: @unchecked Sendable {
		var day: CGFloat, system: CGFloat, line: CGFloat, typing: CGFloat
		var header: CGFloat, textLine: CGFloat, firstTop: CGFloat, top: CGFloat, lastBottom: CGFloat, bottom: CGFloat
		/// A bubble's own top and bottom padding; a group's name line over someone's first message.
		var bubblePad: CGFloat, name: CGFloat
		var quote: CGFloat, reactions: CGFloat, replies: CGFloat, file: CGFloat
		var font: NSFont
	}

	mutating func forget(_ ids: [String]) { for id in ids { cache.removeValue(forKey: id) } }

	/// Everything the table will ask for, computed in parallel before it asks (text measurement
	/// is thread-safe; the hosting-view calibration is done once on main first).
	mutating func prefetch(_ rows: [MacTimeline.Row], width: CGFloat, model: AppModel, timeline: Timeline?) {
		let m = Self.metrics ?? Self.measure(model: model)
		let todo = rows.filter { cache[$0.id] == nil }
		guard todo.count > 64 else { return }
		let texts = todo.map { r -> AttributedString? in if case .row(.event(let e, _, _)) = r, e.type == .message { return timeline?.text(for: e) ?? e.text.map(AttributedString.init) }; return nil }
		let quoted = todo.map { r -> Bool in if case .row(.event(let e, _, _)) = r, let q = e.reply { return timeline?.byId[q] != nil }; return false }
		let direct = timeline.flatMap { model.conversation($0.conv) }.map { $0.isDirect || $0.kind == .home } ?? true
		var out = [CGFloat](repeating: 0, count: todo.count)
		out.withUnsafeMutableBufferPointer { buf in
			let p = buf.baseAddress!
			DispatchQueue.concurrentPerform(iterations: todo.count) { i in p[i] = Self.compute(todo[i], text: texts[i], quoted: quoted[i], direct: direct, width: width, m: m) }
		}
		for (i, r) in todo.enumerated() { cache[r.id] = out[i] }
	}

	mutating func height(for row: MacTimeline.Row, width: CGFloat, model: AppModel, timeline: Timeline?) -> CGFloat {
		if let h = cache[row.id] { return h }
		let m = Self.metrics ?? Self.measure(model: model)
		var text: AttributedString?, quoted = false
		if case .row(.event(let e, _, _)) = row { text = timeline?.text(for: e) ?? e.text.map(AttributedString.init); if let q = e.reply { quoted = timeline?.byId[q] != nil } }
		let direct = timeline.flatMap { model.conversation($0.conv) }.map { $0.isDirect || $0.kind == .home } ?? true
		let h = Self.compute(row, text: text, quoted: quoted, direct: direct, width: width, m: m)
		cache[row.id] = h
		return h
	}

	nonisolated static func compute(_ row: MacTimeline.Row, text: AttributedString?, quoted: Bool, direct: Bool, width: CGFloat, m: Metrics) -> CGFloat {
		let h: CGFloat
		switch row {
		case .row(.day): h = m.day
		case .row(.event(let e, _, _)) where e.type != .message: h = m.system
		case .line, .delivery: h = m.line
		case .typing: h = m.typing
		case .row(.event(let e, let first, let last)):
			var sum = (first ? m.firstTop : m.top) + (last ? m.lastBottom : m.bottom)
			if first, !e.mine, !direct { sum += m.name }
			if text != nil || quoted { sum += m.bubblePad }
			// The column (the row's insets, or its widest), the far side's spacer, the bubble's own
			// padding, and a face in a group.
			let textWidth = min(width - 32, MessageRow.column) - MessageRow.gutter - MessageRow.padH * 2 - (direct || e.mine ? 0 : 36)
			if quoted { sum += m.quote > 0 ? m.quote : 33 }
			if let t = text {
				let ns = NSMutableAttributedString(t)
				ns.addAttribute(.font, value: m.font, range: NSRange(location: 0, length: ns.length))
				if e.edited { ns.append(NSAttributedString(string: "  edited", attributes: [.font: NSFont.systemFont(ofSize: Theme.small)])) }
				let r = ns.boundingRect(with: NSSize(width: max(40, textWidth), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
				sum += max(1, (r.height / m.textLine).rounded()) * m.textLine
			}
			for a in e.attachments {
				// AttachmentBlock's photo box: at most photoMax on each side, never wider than its pixels.
				let most = AttachmentBlock.photoMax
				if a.isImage, let w = a.width, let hh = a.height, w > 0, hh > 0 {
					let width = min(most, CGFloat(w), most * CGFloat(w) / CGFloat(hh))
					sum += width * CGFloat(hh) / CGFloat(w) + 3
				} else { sum += m.file }
			}
			if !e.reactions.isEmpty { sum += m.reactions }
			if e.replies > 0 { sum += m.replies }
			h = sum.rounded(.up)
		}
		return h
	}
	/// Host the shared rows once, measure, and keep the numbers.
	static func measure(model: AppModel) -> Metrics {
		let w: CGFloat = 600
		func h<V: View>(_ v: V) -> CGFloat {
			let host = NSHostingView(rootView: AnyView(v.frame(maxWidth: .infinity, alignment: .leading).environment(model).modifier(Tinted(hex: model.accentHex))))
			host.frame = NSRect(x: 0, y: 0, width: w, height: 10)
			return host.fittingSize.height
		}
		let e1 = Event(id: "m1", conv: "", device: "", seq: 1, user: "u", at: Date(), lamport: 1, type: .message, text: "one line")
		var e2 = e1; e2.id = "m2"; e2.text = "two\nlines"
		var e3 = e1; e3.id = "m3"; e3.reply = "x"
		var e4 = e1; e4.id = "m4"; e4.reactions = [Reaction(key: "👍", users: ["u"], mine: false)]
		var e5 = e1; e5.id = "m5"; e5.replies = 2
		var e6 = e1; e6.id = "m6"; e6.attachments = [Attachment(hash: "h", mime: "application/pdf", size: 10, name: "f.pdf")]
		var e7 = e1; e7.id = "m7"; e7.system = "x"; e7.type = .member
		let noop: (Event) -> Void = { _ in }
		let first = h(MessageRow(event: e1, first: true, last: true, onReply: noop, onThread: noop))
		let firstNotLast = h(MessageRow(event: e1, first: true, last: false, onReply: noop, onThread: noop))
		let middle = h(MessageRow(event: e1, first: false, last: false, onReply: noop, onThread: noop))
		let two = h(MessageRow(event: e2, first: false, last: false, onReply: noop, onThread: noop))
		let textLine = two - middle
		let bottom = Theme.rowGap, top = Theme.rowGap, lastBottom = Theme.groupBottom, firstTop = Theme.groupGap
		let header = firstNotLast - middle - (firstTop - top)
		let m = Metrics(day: h(DayRow(date: Date())), system: h(SystemRow(event: e7)), line: h(DeliveryRow(text: "read", mark: .read)), typing: h(TypingRow(names: ["Ana"])),
			header: header, textLine: textLine, firstTop: firstTop, top: top, lastBottom: lastBottom, bottom: bottom,
			bubblePad: middle - top - bottom - textLine, name: h(Text("Name").font(Theme.smallFont.weight(.semibold))) + 4,
			quote: h(MessageRow(event: e3, first: false, last: false, onReply: noop, onThread: noop)) - middle,
			reactions: h(MessageRow(event: e4, first: false, last: false, onReply: noop, onThread: noop)) - middle,
			replies: h(MessageRow(event: e5, first: false, last: false, onReply: noop, onThread: noop)) - middle,
			file: h(MessageRow(event: e6, first: false, last: false, onReply: noop, onThread: noop)) - middle,
			font: NSFont.systemFont(ofSize: Theme.message))
		_ = first
		if Measure.on { Measure.log("row metrics: line \(textLine) header \(header) first \(first) middle \(middle) day \(m.day) quote \(m.quote) reactions \(m.reactions) replies \(m.replies) file \(m.file)") }
		metrics = m
		return m
	}
}
