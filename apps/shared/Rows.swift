/// The rows Home and Spaces are made of, on both platforms: a chat, a friend, a device, a space, a
/// channel, a person in a space. One row look for all of them (`RowStyle`): under the pointer it
/// lifts a step, pressed it darkens, selected it is two steps deep and set in semibold.
import BaudCore
import SwiftUI

enum Rows {
	#if os(macOS)
	/// One line (a setting, an action); a face and two lines (a person, a device); a chat in the list.
	static let line: CGFloat = 32, person: CGFloat = 40, chat: CGFloat = 40, compact: CGFloat = 28, space: CGFloat = 40
	static let face: CGFloat = 28, personFace: CGFloat = 28, smallFace: CGFloat = 20, tile: CGFloat = 26
	/// A row's fill is set in from its card or column, its words a further step; between the face and the words.
	static let inset: CGFloat = 8, pad: CGFloat = 8, gap: CGFloat = 8
	#else
	static let line: CGFloat = 48, person: CGFloat = 60, chat: CGFloat = 66, compact: CGFloat = 46, space: CGFloat = 60
	static let face: CGFloat = 44, personFace: CGFloat = 40, smallFace: CGFloat = 30, tile: CGFloat = 40
	static let inset: CGFloat = 8, pad: CGFloat = 8, gap: CGFloat = 12
	#endif
}

/// The look of every row you can open. The fill is inset from the edges and rounded; nothing runs
/// to the edge, nothing sits on a rail. Selected, it takes the loud fill and its words flip to
/// read on it: unmistakable in any colour, light or dark.
struct RowStyle: ButtonStyle {
	var selected = false
	var focused = false
	func makeBody(configuration: Configuration) -> some View { Look(configuration: configuration, selected: selected, focused: focused) }
	struct Look: View {
		@Environment(\.tones) private var tones
		@State private var hover = false
		let configuration: Configuration
		let selected: Bool
		let focused: Bool
		var body: some View {
			let on = selected && !configuration.isPressed
			configuration.label
				.environment(\.tones, on ? tones.onLoudTones : tones)
				.environment(\.accent, on ? tones.onLoud : tones.strong)
				.foregroundStyle(on ? tones.onLoud : tones.text)
				.padding(.horizontal, Rows.pad)
				.frame(maxWidth: .infinity, alignment: .leading)
				.background(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).fill(fill))
				.contentShape(Rectangle())
				.padding(.horizontal, Rows.inset)
				.onHover { hover = $0 }
				.animation(Motion.quick, value: hover)
				.animation(Motion.press, value: configuration.isPressed)
		}
		private var fill: Color { configuration.isPressed ? tones.pressed : selected ? tones.loud : hover ? tones.hover : .clear }
	}
}

/// A small action in a heading or a header: a 24 pt target (44 on the iPhone) around its glyph,
/// lifting on hover, filled while pressed. Its tooltip names it and its keys.
struct IconButton: View {
	@Environment(\.tones) private var tones
	let symbol: String
	let help: String
	var size: CGFloat = Icon.row
	let action: () -> Void
	/// How far the target reaches past its glyph on each side: what lines a row of them up with words.
	#if os(macOS)
	static let slack: CGFloat = 6
	#else
	static let slack: CGFloat = 12
	#endif
	var body: some View {
		Button(action: action) { Image(systemName: symbol).font(Icon.font(size)) }
			.buttonStyle(IconStyle()).help(help).accessibilityLabel(spoken(help))
	}
	struct IconStyle: ButtonStyle {
		func makeBody(configuration: Configuration) -> some View { Look(configuration: configuration) }
		struct Look: View {
			@Environment(\.tones) private var tones
			@Environment(\.isEnabled) private var enabled
			@State private var hover = false
			let configuration: Configuration
			var body: some View {
				configuration.label
					.foregroundStyle(!enabled ? tones.tertiary : hover ? tones.text : tones.secondary)
					#if os(macOS)
					.frame(width: 24, height: 24)
					#else
					// 44 points under a finger: Apple's minimum, and the misses stop.
					.frame(width: 44, height: 44)
					#endif
					.background(Circle().fill(configuration.isPressed ? tones.pressed : hover ? tones.hover : .clear))
					.contentShape(Circle())
					.onHover { hover = $0 }
					.animation(Motion.quick, value: hover)
			}
		}
	}
}

/// A section's heading: set apart by size and the space above it, its one action at the end.
struct SectionHeading<Trailing: View>: View {
	@Environment(\.tones) private var tones
	let title: String
	var first = false
	@ViewBuilder var trailing: Trailing
	var body: some View {
		HStack(alignment: .center, spacing: 6) {
			Text(title).font(Theme.headingFont).foregroundStyle(tones.heading)
			Spacer(minLength: 4)
			trailing
		}
		.padding(.leading, Rows.inset + Rows.pad).padding(.trailing, Rows.inset + 2)
		.padding(.top, first ? 10 : Theme.sectionGap).padding(.bottom, 4)
		.accessibilityAddTraits(.isHeader)
	}
}
extension SectionHeading where Trailing == EmptyView {
	init(title: String, first: Bool = false) { self.title = title; self.first = first; self.trailing = EmptyView() }
}

/// A quiet sentence where a section is empty: what it is for and the one thing to do.
struct EmptyLine: View {
	@Environment(\.tones) private var tones
	let text: String
	var body: some View {
		Text(text).font(Theme.smallFont).foregroundStyle(tones.secondary).fixedSize(horizontal: false, vertical: true)
			.padding(.horizontal, Rows.inset + Rows.pad).padding(.vertical, 4)
	}
}

/// A chat in the list: their face and presence (or the group's faces), the name, when, and the
/// last line. Unread is the bold name and the count (a dot when I marked it unread); muted, a small
/// bell-slash and a quiet count. Whether my message got there is inside the chat, not here.
struct ChatRow: View {
	@Environment(\.tones) private var tones
	@Environment(AppModel.self) private var model
	@Environment(\.accent) private var accent
	let c: Conversation
	var selected = false
	var body: some View {
		let other = c.isDirect ? c.members.first { $0 != model.me.user } : nil
		let friend = other.flatMap { u in model.contacts.first { $0.user == u } }
		let unread = model.isUnread(c)
		let muted = model.muted(c.id) != nil
		HStack(spacing: 10) {
			if c.kind == .home { Avatar(name: model.me.name, hash: model.me.avatar, size: Rows.face) }
			else if c.kind == .chat && !c.isDirect { GroupFace(conversation: c, size: Rows.face) }
			else { Avatar(name: model.title(c), hash: friend?.avatar, size: Rows.face, presence: other.map { u in Mark.presence(friend?.devices ?? model.core.members(c.id).first { $0.user == u }?.devices ?? []) }) }
			VStack(alignment: .leading, spacing: 2) {
				HStack(alignment: .firstTextBaseline, spacing: 4) {
					Text(model.title(c)).font(Theme.font.weight(unread || selected ? .semibold : .regular)).lineLimit(1)
					if muted { Image(systemName: "bell.slash.fill").font(Icon.font(Icon.inline)).foregroundStyle(tones.tertiary).accessibilityLabel("Muted") }
					Spacer(minLength: 4)
					// My last message's mark, small, beside its time; its words are inside the chat.
					if c.lastUser == model.me.user, let e = c.lastEvent, c.kind != .home {
						let d = model.core.delivery(c.id, e)
						if !d.devices.isEmpty { DeliveryMark(delivery: d, size: Theme.small, interactive: false) }
					}
					if c.kind != .home || c.lastText != nil { Text(whenShort(c.lastAt)).font(Theme.smallFont).foregroundStyle(tones.secondary).monospacedDigit() }
				}
				HStack(spacing: 4) {
					Text(preview).font(Theme.smallFont).foregroundStyle(unread && !muted ? tones.text : tones.secondary).lineLimit(1)
					Spacer(minLength: 4)
					if c.unread > 0 { UnreadBadge(count: c.unread, quiet: muted) }
					else if unread { Circle().fill(muted ? tones.tertiary : tones.strong).frame(width: 10, height: 10).accessibilityLabel("Marked unread") }
				}
			}
		}
		.frame(minHeight: Rows.chat)
		.accessibilityElement(children: .combine)
	}
	private var preview: String {
		// An empty second line still takes its line (a no-break space), so every row is two lines tall;
		// my own chat says what it is until there's something in it.
		guard let raw = c.lastText else { return c.isDirect || c.kind == .home ? model.status(c) : "\u{00A0}" }
		let t = PlaceText.words(raw) ?? raw
		if c.kind == .home { return t }
		let who = c.lastUser == model.me.user ? "You: " : (c.isDirect ? "" : (c.lastUser.map { model.name(of: $0) + ": " } ?? ""))
		return who + t
	}
}

/// A friend with no chat yet: their face and name, and an invitation. Opening it makes the chat.
struct NewChatRow: View {
	@Environment(\.tones) private var tones
	let friend: Contact
	var body: some View {
		HStack(spacing: 10) {
			Avatar(name: friend.name, hash: friend.avatar, size: Rows.face, presence: Mark.presence(friend.devices))
			VStack(alignment: .leading, spacing: 2) {
				Text(friend.name).font(Theme.font).lineLimit(1)
				Text("Say hi").font(Theme.smallFont).foregroundStyle(tones.secondary).lineLimit(1)
			}
			Spacer(minLength: 4)
		}
		.frame(minHeight: Rows.chat)
		.accessibilityElement(children: .combine)
		.accessibilityHint("Starts a chat")
	}
}

/// Unread: a count on a pill in the strongest step; a muted chat's in a quiet one.
struct UnreadBadge: View {
	@Environment(\.tones) private var tones
	let count: Int
	var mention = false
	var quiet = false
	var body: some View {
		Text(count > 99 ? "99+" : "\(count)").font(.system(size: Theme.small - 1, weight: .heavy, design: .rounded)).monospacedDigit()
			.foregroundStyle(quiet ? tones.text : tones.onMine)
			.padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
			.background(Capsule().fill(quiet ? tones.quiet : tones.loud))
	}
}

/// A space in the list of spaces: its tile, its name, who is in it and who is online.
struct SpaceRow: View {
	@Environment(\.tones) private var tones
	@Environment(AppModel.self) private var model
	let s: Conversation
	var selected = false
	var body: some View {
		let people = model.people(in: s.id)
		let unread = model.unread(space: s.id)
		HStack(spacing: 10) {
			SpaceTile(name: s.name ?? "", size: Rows.tile)
			VStack(alignment: .leading, spacing: 1) {
				Text(s.name ?? "space").font(Theme.font.weight(unread > 0 || selected ? .semibold : .medium)).lineLimit(1)
				Text(model.peopleLine(people)).font(Theme.smallFont).foregroundStyle(tones.secondary).lineLimit(1)
			}
			Spacer(minLength: 4)
			if unread > 0 { UnreadBadge(count: unread) }
		}
		.frame(minHeight: Rows.space)
		.accessibilityElement(children: .combine)
	}
}

/// A space's mark: its initials on a rounded tile in the strongest step.
struct SpaceTile: View {
	@Environment(\.tones) private var tones
	let name: String
	var size: CGFloat = 26
	var body: some View {
		let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
		Text((initials.count > 1 ? initials : String(name.prefix(2))).uppercased())
			.font(.system(size: size * 0.4, weight: .bold))
			.foregroundStyle(tones.onStrong)
			.frame(width: size, height: size)
			.background(RoundedRectangle(cornerRadius: size * 0.27).fill(tones.strong))
	}
}

/// A channel inside a space.
struct ChannelRow: View {
	@Environment(\.tones) private var tones
	let c: Conversation
	var selected = false
	var body: some View {
		HStack(spacing: 6) {
			Text("#").font(Theme.font.weight(.medium)).foregroundStyle(tones.secondary).frame(width: Rows.smallFace - 4)
			Text(c.name ?? "").font(Theme.font.weight(c.unread > 0 || selected ? .semibold : .regular)).lineLimit(1)
			Spacer(minLength: 4)
			if c.mentions > 0 { UnreadBadge(count: c.mentions) }
			else if c.unread > 0 { Circle().fill(tones.strong).frame(width: 7, height: 7) }
		}
		.frame(minHeight: Rows.compact)
		.accessibilityElement(children: .combine)
	}
}

/// A person in a space: face and presence, the name they go by here, the
/// identity mark, and how they are reached: a friend, or through the friends we share.
struct SpacePersonRow: View {
	@Environment(\.tones) private var tones
	@Environment(AppModel.self) private var model
	let m: Member
	let conv: ConversationId
	var body: some View {
		HStack(spacing: 8) {
			Avatar(name: m.me ? model.me.name : m.name, hash: m.me ? model.me.avatar : model.contacts.first { $0.user == m.user }?.avatar, size: Rows.smallFace, presence: Mark.presence(m.devices))
			Text(m.me ? model.me.name : model.name(of: m.user)).font(Theme.font).lineLimit(1)
			IdentityMark(member: m)
			Spacer(minLength: 4)
			Text(word).font(Theme.smallFont).foregroundStyle(tones.secondary).lineLimit(1)
		}
		.frame(minHeight: Rows.compact)
		.accessibilityElement(children: .combine)
	}
	private var word: String {
		if m.me { return "this \(AppModel.thisKind)" }
		let through = model.through(m, in: conv)
		if !through.isEmpty { return "through \(list(through))" }
		return presenceWord(m.devices)
	}
}

/// Verified by you, vouched for, or not yet: the mark beside a name, its words on hover. A friend
/// I haven't verified carries none (I added them myself); a stranger always carries one.
struct IdentityMark: View {
	@Environment(\.tones) private var tones
	@Environment(AppModel.self) private var model
	let member: Member
	var body: some View {
		if !member.me, member.verified || !model.isFriend(member.user) {
			let mark: Mark = member.verified ? .verified : .unverified
			MarkView(mark: mark, size: Theme.small + 2, color: member.verified ? tones.text : tones.secondary).help(mark.meaning)
		}
	}
}

/// The Network window's row, and the network picture's legend: a device, whose, how reached.
struct PeerRow: View {
	@Environment(\.tones) private var tones
	let p: Peer
	var body: some View {
		HStack(spacing: 10) {
			DeviceGlyph(shape: DeviceShape(p.device), lit: p.device.online, size: 18)
			VStack(alignment: .leading, spacing: 1) {
				HStack(spacing: 4) {
					Text(p.device.name).font(Theme.font.weight(.medium))
					Text(p.own ? "yours" : p.userName).font(Theme.smallFont).foregroundStyle(tones.secondary)
				}
				Text(p.sentence).font(Theme.smallFont).foregroundStyle(tones.secondary)
			}
			Spacer()
		}
		.frame(minHeight: Theme.row + 6)
	}
}

#if os(macOS)
extension Color { init(_ c: NSColor) { self.init(nsColor: c) } }
extension NSColor { static var windowBackground: NSColor { .windowBackgroundColor } }
#else
extension UIColor { static var windowBackground: UIColor { .systemBackground } }
#endif

/// A tooltip read aloud: its words without the keys in brackets ("Details (⌘I)" is "Details").
func spoken(_ help: String) -> String {
	guard help.hasSuffix(")"), let open = help.lastIndex(of: "(") else { return help }
	return String(help[..<open]).trimmingCharacters(in: .whitespaces)
}
