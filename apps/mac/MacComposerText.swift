/// The Mac composer's text: an NSTextView so the keys and the clipboard behave like a real
/// editor. ⏎ sends, ⇧⏎ breaks the line, ↑ on an empty field edits my last message, ⎋ cancels,
/// ⌘B/⌘I/⇧⌘C wrap the selection in markdown, pasted images and dropped files become
/// attachments, and the @mention list takes ↑↓⏎⇥ while it is up.
import AppKit
import SwiftUI

struct MacComposerText: NSViewRepresentable {
	@Environment(\.tones) private var tones
	@Binding var text: String
	let placeholder: String
	var onSend: () -> Void
	var onEscape: () -> Bool          // true if handled (a strip was closed)
	var onUpEmpty: () -> Bool         // true if handled (editing began)
	var onFiles: ([URL]) -> Void
	var onArrow: (Int) -> Bool        // mention list: moved
	var onAccept: () -> Bool          // mention list: completed
	var focus: Bool

	func makeNSView(context: Context) -> NSScrollView {
		let tv = Editor()
		tv.delegate = context.coordinator
		tv.coordinator = context.coordinator
		tv.isRichText = false
		tv.font = NSFont.systemFont(ofSize: Theme.body)
		tv.textColor = NSColor(tones.text); tv.insertionPointColor = NSColor(tones.text); tv.placeholderColor = NSColor(tones.secondary)
		tv.textContainerInset = NSSize(width: 0, height: 4)
		tv.textContainer?.lineFragmentPadding = 0
		tv.isAutomaticQuoteSubstitutionEnabled = false
		tv.isAutomaticDashSubstitutionEnabled = false
		tv.allowsUndo = true
		tv.drawsBackground = false
		tv.placeholder = placeholder
		tv.registerForDraggedTypes([.fileURL])
		let scroll = NSScrollView()
		scroll.documentView = tv
		scroll.drawsBackground = false
		scroll.hasVerticalScroller = false
		scroll.borderType = .noBorder
		tv.autoresizingMask = [.width]
		tv.isVerticallyResizable = true
		tv.textContainer?.widthTracksTextView = true
		context.coordinator.view = tv
		return scroll
	}

	func updateNSView(_ scroll: NSScrollView, context: Context) {
		if let tv = scroll.documentView as? Editor { tv.textColor = NSColor(tones.text); tv.insertionPointColor = NSColor(tones.text); tv.placeholderColor = NSColor(tones.secondary) }
		guard let tv = scroll.documentView as? Editor else { return }
		context.coordinator.parent = self
		if tv.string != text {
			tv.string = text; tv.invalidateIntrinsicContentSize()
			// Emptied after several lines (sent, or switched away): back to the top, so the
			// placeholder sits where one line does, centred on the buttons beside it.
			if text.isEmpty { scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView) }
		}
		tv.placeholder = placeholder
		if focus, tv.window?.firstResponder !== tv { tv.window?.makeFirstResponder(tv) }
	}

	func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
		guard let tv = nsView.documentView as? Editor, let lm = tv.layoutManager, let tc = tv.textContainer else { return nil }
		tc.containerSize = NSSize(width: proposal.width ?? 400, height: .greatestFiniteMagnitude)
		lm.ensureLayout(for: tc)
		let h = lm.usedRect(for: tc).height + tv.textContainerInset.height * 2
		return CGSize(width: proposal.width ?? 400, height: min(max(h, 22), 8 * 17 + 8))
	}

	func makeCoordinator() -> Coordinator { Coordinator(self) }

	@MainActor final class Coordinator: NSObject, NSTextViewDelegate {
		var parent: MacComposerText
		weak var view: Editor?
		init(_ p: MacComposerText) { parent = p }
		func textDidChange(_ n: Notification) {
			guard let tv = view else { return }
			parent.text = tv.string
			tv.invalidateIntrinsicContentSize()
		}
		func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
			switch sel {
			case #selector(NSResponder.insertNewline(_:)):
				if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { tv.insertNewlineIgnoringFieldEditor(nil); return true }
				if parent.onAccept() { return true }
				// The word being composed (marked text, an accent being picked) belongs to this
				// message: committed, and the text taken as it stands, before it goes.
				if tv.hasMarkedText() { tv.unmarkText() }
				if parent.text != tv.string { parent.text = tv.string }
				parent.onSend()
				// Sent: emptied here and now, not on SwiftUI's next pass, so no late keystroke
				// lands on the old text.
				if parent.text.isEmpty, !tv.string.isEmpty { tv.string = ""; tv.invalidateIntrinsicContentSize(); tv.needsDisplay = true }
				return true
			case #selector(NSResponder.insertTab(_:)): return parent.onAccept()
			case #selector(NSResponder.cancelOperation(_:)): return parent.onEscape()
			case #selector(NSResponder.moveUp(_:)):
				if parent.onArrow(-1) { return true }
				return tv.string.isEmpty && parent.onUpEmpty()
			case #selector(NSResponder.moveDown(_:)): return parent.onArrow(1)
			default: return false
			}
		}
	}
}

/// The text view itself: a placeholder, markdown wrapping on ⌘B/⌘I/⇧⌘C, images from the
/// clipboard and files from the desktop.
final class Editor: NSTextView {
	weak var coordinator: MacComposerText.Coordinator?
	var placeholder = "" { didSet { needsDisplay = true } }
	var placeholderColor: NSColor = .placeholderTextColor { didSet { needsDisplay = true } }
	override var intrinsicContentSize: NSSize {
		guard let lm = layoutManager, let tc = textContainer else { return super.intrinsicContentSize }
		lm.ensureLayout(for: tc)
		return NSSize(width: NSView.noIntrinsicMetric, height: lm.usedRect(for: tc).height + textContainerInset.height * 2)
	}
	override func draw(_ rect: NSRect) {
		super.draw(rect)
		if string.isEmpty, let f = font {
			(placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width, y: textContainerInset.height), withAttributes: [.font: f, .foregroundColor: placeholderColor])
		}
	}
	override func keyDown(with e: NSEvent) {
		let cmd = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
		if cmd.contains(.command), let k = e.charactersIgnoringModifiers?.lowercased() {
			if k == "b", cmd == .command { wrap("**"); return }
			if k == "i", cmd == .command { wrap("*"); return }
			if k == "c", cmd == [.command, .shift] { wrap(selectedText().contains("\n") ? "\n```\n" : "`"); return }
		}
		super.keyDown(with: e)
	}
	private func selectedText() -> String { (string as NSString).substring(with: selectedRange()) }
	/// Wrap the selection (or the word at the cursor) in a marker; toggle it off if it's already there.
	private func wrap(_ m: String) {
		var r = selectedRange()
		let ns = string as NSString
		if r.length == 0 { r = ns.rangeOfWord(at: r.location) }
		let inner = ns.substring(with: r)
		let before = NSRange(location: max(0, r.location - m.count), length: min(m.count, r.location))
		let after = NSRange(location: r.location + r.length, length: min(m.count, ns.length - r.location - r.length))
		if ns.substring(with: before) == m, ns.substring(with: after) == m {
			let whole = NSRange(location: before.location, length: before.length + r.length + after.length)
			if shouldChangeText(in: whole, replacementString: inner) { replaceCharacters(in: whole, with: inner); didChangeText(); setSelectedRange(NSRange(location: before.location, length: inner.count)) }
		} else if shouldChangeText(in: r, replacementString: m + inner + m) {
			replaceCharacters(in: r, with: m + inner + m); didChangeText()
			setSelectedRange(NSRange(location: r.location + m.count, length: inner.count))
		}
	}
	override func paste(_ sender: Any?) {
		let pb = NSPasteboard.general
		if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty { coordinator?.parent.onFiles(urls); return }
		if let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
			let url = FileManager.default.temporaryDirectory.appendingPathComponent("pasted-\(Int(Date().timeIntervalSince1970)).png")
			try? png.write(to: url); coordinator?.parent.onFiles([url]); return
		}
		pasteAsPlainText(sender)
	}
	override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
		if let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty { coordinator?.parent.onFiles(urls); return true }
		return super.performDragOperation(sender)
	}
	override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : super.draggingEntered(sender) }
}

extension NSString {
	func rangeOfWord(at i: Int) -> NSRange {
		let s = self as String
		guard !s.isEmpty else { return NSRange(location: i, length: 0) }
		var lo = min(i, length), hi = lo
		while lo > 0, !(character(at: lo - 1) == 32 || character(at: lo - 1) == 10) { lo -= 1 }
		while hi < length, !(character(at: hi) == 32 || character(at: hi) == 10) { hi += 1 }
		return NSRange(location: lo, length: hi - lo)
	}
}
