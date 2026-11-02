/// What the composer knows beyond its text: the @mention in progress, :shortcodes:, the first
/// link's host, and the markdown my cells can show. Pure functions over strings.
import BaudCore
import Foundation

enum Composing {
	/// The `@name` being typed at the end of the text, or nil.
	static func mentionPrefix(_ text: String) -> String? {
		guard let at = text.lastIndex(of: "@") else { return nil }
		let tail = text[text.index(after: at)...]
		guard !tail.contains(where: { $0.isWhitespace }), at == text.startIndex || text[text.index(before: at)].isWhitespace else { return nil }
		return String(tail)
	}
	/// Replace the `@prefix` at the end with `@Name `.
	static func complete(_ text: String, with name: String) -> String {
		guard let at = text.lastIndex(of: "@") else { return text }
		return String(text[..<at]) + "@" + name + " "
	}
	static let emoji: [String: String] = ["smile": "😄", "grin": "😁", "joy": "😂", "sweat_smile": "😅", "wink": "😉", "heart": "❤️", "thumbsup": "👍", "+1": "👍", "-1": "👎", "fire": "🔥", "eyes": "👀", "tada": "🎉", "rocket": "🚀", "wave": "👋", "pray": "🙏", "clap": "👏", "thinking": "🤔", "sob": "😭", "ok_hand": "👌", "100": "💯", "check": "✅", "white_check_mark": "✅", "x": "❌", "warning": "⚠️", "bulb": "💡", "coffee": "☕", "ship": "🚢", "sparkles": "✨", "muscle": "💪", "shrug": "🤷", "skull": "💀", "pizza": "🍕", "beer": "🍺", "cat": "🐱", "dog": "🐶"]
	/// `:tada:` becomes 🎉 the moment the closing colon lands.
	static func expandShortcodes(_ text: String) -> String {
		guard text.hasSuffix(":"), let open = text.dropLast().lastIndex(of: ":") else { return text }
		let code = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
		guard !code.isEmpty, !code.contains(" "), let e = emoji[code] else { return text }
		return String(text[..<open]) + e
	}
	/// The host of the first link in the text, for the preview sentence.
	static func firstLinkHost(_ text: String) -> String? {
		guard let r = text.range(of: #"https?://[^\s]+"#, options: .regularExpression), let u = URL(string: String(text[r])) else { return nil }
		return u.host
	}
}
