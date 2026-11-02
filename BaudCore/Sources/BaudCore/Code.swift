/// An invite or device link as a code: the seven fields after the `#`, nothing else. People copy
/// or read it; the app pastes it. `baud://add#<code>` stays only as the QR payload and the
/// Camera path. The crate's `link::code()` replaces this when it lands.
import Foundation

public enum Code {
	/// The code for a link: its fragment, grouped in fours so it reads and wraps well.
	public static func from(_ link: Link) -> String { fragment(link.url) }
	static func fragment(_ url: String) -> String { url.components(separatedBy: "#").last ?? url }

	/// A pasted code, a `baud://add#…`/`baud://link#…` URL, or the https form: all become a link.
	/// Spaces and line breaks a copy picked up inside it are dropped, and the sentence around it.
	public static func parse(_ text: String) -> Link? {
		let t = text.filter { !$0.isWhitespace }.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?()<>\"'"))
		if t.contains("#") { return parseLink(url: t) }
		// A bare grouped or dotless token: its own kind says which door it is.
		if !t.contains("."), let l = parseLink(url: t) { return parseLink(url: "baud://\(l.kind == .device ? "link" : "add")#" + t) }
		let parts = t.components(separatedBy: ".")
		guard parts.count == 7, parts[0] == "peer1" else { return nil }
		return parseLink(url: "baud://\(parts[1] == "m" ? "link" : "add")#" + t)
	}

	/// Text that set out as a baud link and doesn't read as one: an app on its way cut it short.
	public static func cut(_ text: String) -> Bool {
		let t = text.filter { !$0.isWhitespace }.lowercased()
		return parse(text) == nil && (t.contains("baud.rubric.sh/add") || t.contains("baud.rubric.sh/link") || t.hasPrefix("baud://") || t.hasPrefix("peer1."))
	}
}
