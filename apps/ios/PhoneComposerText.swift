/// The iPhone composer's text: a UITextView of baud's own, so sending leaves it empty. With the
/// system's field, the keyboard's word in progress (an inline prediction, an autocorrection, marked
/// text) was committed after the field had been cleared, and wrote the message back into it. Here
/// a send first commits that word into the text being sent, then empties the view itself, and
/// nothing the keyboard says afterwards about the old text is taken. One line sits centred on the
/// buttons' height; more lines grow the field upward, to eight, then it scrolls.
import SwiftUI
import UIKit

/// What the composer asks of its field: the text as the keyboard has it now, and emptied.
@MainActor final class ComposerField {
	fileprivate weak var view: UITextView?
	fileprivate var quietUntil = Date.distantPast
	fileprivate var sent = ""
	/// The text with the keyboard's word in progress committed.
	func commit() -> String? {
		guard let v = view else { return nil }
		if v.markedTextRange != nil { v.unmarkText() }
		return v.text
	}
	/// Emptied now, and deaf for a moment to the keyboard's late word about what was just sent.
	func clear(sent: String) {
		guard let v = view else { return }
		self.sent = sent
		quietUntil = Date().addingTimeInterval(0.4)
		if v.markedTextRange != nil { v.unmarkText() }
		v.inputDelegate?.textWillChange(v)
		v.text = ""
		v.inputDelegate?.textDidChange(v)
		(v as? PhoneComposerText.Field)?.refresh()
	}
}

struct PhoneComposerText: UIViewRepresentable {
	@Environment(\.tones) private var tones
	@Binding var text: String
	let placeholder: String
	let field: ComposerField
	/// One line's height: the buttons beside it are this tall, so their middles meet.
	static let line: CGFloat = 30

	func makeUIView(context: Context) -> Field {
		let v = Field()
		v.delegate = context.coordinator
		v.backgroundColor = .clear
		v.textContainer.lineFragmentPadding = 0
		v.isScrollEnabled = false
		v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		v.setContentHuggingPriority(.defaultLow, for: .horizontal)
		v.text = text
		field.view = v
		style(v)
		return v
	}

	func updateUIView(_ v: Field, context: Context) {
		context.coordinator.parent = self
		field.view = v
		style(v)
		if v.text != text {
			if v.markedTextRange != nil { v.unmarkText() }
			v.text = text
		}
		v.refresh()
	}

	private func style(_ v: Field) {
		let font = UIFont.systemFont(ofSize: Theme.body)
		if v.font != font { v.font = font; v.label.font = font }
		v.textColor = UIColor(tones.text)
		v.tintColor = UIColor(tones.strong)
		v.label.textColor = UIColor(tones.secondary)
		v.label.text = placeholder
		v.accessibilityLabel = placeholder
		// The line's own height, centred in the buttons' height.
		let pad = max(2, ((Self.line - font.lineHeight) / 2).rounded(.down))
		let inset = UIEdgeInsets(top: pad, left: 0, bottom: pad, right: 0)
		if v.textContainerInset != inset { v.textContainerInset = inset }
	}

	func sizeThatFits(_ proposal: ProposedViewSize, uiView v: Field, context: Context) -> CGSize? {
		let width = proposal.width ?? 280
		let fit = v.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
		let most = (v.font?.lineHeight ?? 20) * 8 + v.textContainerInset.top + v.textContainerInset.bottom
		let scrolls = fit > most
		if v.isScrollEnabled != scrolls { DispatchQueue.main.async { v.isScrollEnabled = scrolls } }
		return CGSize(width: width, height: max(Self.line, min(fit, most)))
	}

	func makeCoordinator() -> Coordinator { Coordinator(self) }

	@MainActor final class Coordinator: NSObject, UITextViewDelegate {
		var parent: PhoneComposerText
		init(_ p: PhoneComposerText) { parent = p }
		func textViewDidChange(_ v: UITextView) {
			(v as? Field)?.refresh()
			// The keyboard's late word about a message just sent (a piece of it, back in the empty
			// field): not taken, and not shown. A new key pressed that soon is one letter, and stays.
			let f = parent.field
			if Date() < f.quietUntil, parent.text.isEmpty, v.text.count > 1, f.sent.contains(v.text.trimmingCharacters(in: .whitespacesAndNewlines)) {
				v.text = ""; (v as? Field)?.refresh(); return
			}
			if parent.text != v.text { parent.text = v.text }
		}
	}

	/// The text view with its placeholder, laid where the first line's words go.
	final class Field: UITextView {
		let label = UILabel()
		override init(frame: CGRect, textContainer: NSTextContainer?) {
			super.init(frame: frame, textContainer: textContainer)
			label.isAccessibilityElement = false
			addSubview(label)
		}
		required init?(coder: NSCoder) { fatalError() }
		func refresh() { label.isHidden = !text.isEmpty; setNeedsLayout(); invalidateIntrinsicContentSize() }
		override func layoutSubviews() {
			super.layoutSubviews()
			let i = textContainerInset
			label.frame = CGRect(x: i.left, y: i.top, width: bounds.width - i.left - i.right, height: font?.lineHeight ?? 20)
		}
	}
}
