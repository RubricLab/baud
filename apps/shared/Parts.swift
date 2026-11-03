/// The parts every page is made of, so a chat's details, You and a sheet read as one app: a
/// section is a heading over a card; a card holds rows; a row is a glyph or a face, words and what
/// it leads to; and anything that can't be undone is last, on its own, in red, and asks first.
/// The numbers they share are here too, and nowhere else (docs/design/system.md).
import BaudCore
import SwiftUI

// MARK: tokens

/// Space, on a 4 pt grid.
enum Space {
	/// The page's side margin.
	static let side: CGFloat = 16
	/// Between the sections of a page.
	#if os(macOS)
	static let section: CGFloat = 16
	#else
	static let section: CGFloat = 24
	#endif
	/// From a section's title to its card.
	static let title: CGFloat = 8
	/// Above a card's first row and under its last.
	static let card: CGFloat = 4
}

/// Four radii on each platform; capsules and circles besides.
enum Radius {
	#if os(macOS)
	static let small: CGFloat = 4, row: CGFloat = 6, card: CGFloat = 10, bubble: CGFloat = 16
	#else
	static let small: CGFloat = 6, row: CGFloat = 10, card: CGFloat = 16, bubble: CGFloat = 20
	#endif
}

/// SF Symbols at three sizes, medium in the chrome (semibold only when small).
enum Icon {
	#if os(macOS)
	static let inline: CGFloat = 11, row: CGFloat = 13, bar: CGFloat = 15
	#else
	static var inline: CGFloat { Theme.scaled(13, .footnote) }
	static var row: CGFloat { Theme.scaled(17, .body) }
	static let bar: CGFloat = 19
	#endif
	static func font(_ size: CGFloat) -> Font { .system(size: size, weight: size <= 11 ? .semibold : .medium) }
}

/// The page's measures under their older names.
enum Parts {
	static var gap: CGFloat { Space.section }
	static let side = Space.side
	static var corner: CGFloat { Radius.card }
}

// MARK: sections and rows

/// A section's name over its card: small, semibold, in the secondary ink, lined up with the words
/// of the rows under it. The cards carry the page; the labels get out of the way.
struct SectionTitle: View {
	@Environment(\.tones) private var tones
	let text: String
	init(_ text: String) { self.text = text }
	var body: some View {
		Text(text).font(Theme.smallFont.weight(.semibold)).foregroundStyle(tones.secondary)
			.padding(.leading, Rows.inset + Rows.pad).accessibilityAddTraits(.isHeader)
	}
}

/// A heading over a card of rows. The rows run edge to edge inside it, each lifting on hover.
struct ListCard<Content: View>: View {
	@Environment(\.tones) private var tones
	var title: String? = nil
	var footer: String? = nil
	@ViewBuilder var content: Content
	var body: some View {
		VStack(alignment: .leading, spacing: Space.title) {
			if let title { SectionTitle(title) }
			VStack(alignment: .leading, spacing: 0) { content }
				.padding(.vertical, Space.card)
				.frame(maxWidth: .infinity, alignment: .leading)
				.glass(corner: Radius.card)
			if let footer { Text(footer).font(Theme.smallFont).foregroundStyle(tones.secondary).padding(.horizontal, Rows.inset + Rows.pad).fixedSize(horizontal: false, vertical: true) }
		}
	}
}

/// One line of a card: a glyph in a slot as wide as a face (so its words line up with a person's),
/// the words, and on the right a value or where it leads. As tall as one line needs.
struct ActionRow: View {
	@Environment(\.tones) private var tones
	let symbol: String
	let title: String
	var value: String? = nil
	var danger = false
	var body: some View {
		HStack(spacing: Rows.gap) {
			Image(systemName: symbol).font(Icon.font(Icon.row))
				.foregroundStyle(danger ? tones.danger : tones.secondary)
				.frame(width: Rows.personFace)
			Text(title).font(Theme.font.weight(.medium)).foregroundStyle(danger ? tones.danger : tones.text)
			Spacer(minLength: 8)
			if let value { Text(value).font(Theme.font).foregroundStyle(tones.secondary).lineLimit(1) }
		}
		.frame(minHeight: Rows.line)
		.contentShape(Rectangle())
	}
}

extension View {
	/// A row in a card that isn't a button: set in from the card's edge as a button row is.
	func cardRow() -> some View { padding(.horizontal, Rows.pad).padding(.horizontal, Rows.inset) }
}

/// A person in a row: their face (and its light when they're online), their name, the identity mark,
/// a small word (admin), one line of how they're reached, and whatever the row ends in (a tick, a
/// device). Presence is said once: the light on the face, the words beside it.
struct PersonRow<Accessory: View>: View {
	@Environment(\.tones) private var tones
	let name: String
	var hash: BlobHash?
	var presence: Mark?
	var detail: String?
	var badge: String?
	/// Someone in a chat: their identity mark (verified, or not a friend).
	var member: Member?
	/// A friend I've verified.
	var verified: Bool
	let accessory: Accessory
	init(name: String, hash: BlobHash? = nil, presence: Mark? = nil, detail: String? = nil, badge: String? = nil, member: Member? = nil, verified: Bool = false, @ViewBuilder accessory: () -> Accessory) {
		self.name = name; self.hash = hash; self.presence = presence; self.detail = detail; self.badge = badge; self.member = member; self.verified = verified; self.accessory = accessory()
	}
	var body: some View {
		HStack(spacing: Rows.gap) {
			Avatar(name: name, hash: hash, size: Rows.personFace, presence: presence)
			VStack(alignment: .leading, spacing: 2) {
				HStack(spacing: 4) {
					Text(name).font(Theme.font.weight(.medium)).lineLimit(1)
					if let member { IdentityMark(member: member) } else if verified { MarkView(mark: .verified, size: Theme.small + 2, color: tones.secondary) }
					if let badge { Text(badge).font(Theme.smallFont).foregroundStyle(tones.secondary) }
				}
				if let detail { Text(detail).font(Theme.smallFont).foregroundStyle(tones.secondary).lineLimit(1) }
			}
			Spacer(minLength: 8)
			accessory
		}
		.frame(minHeight: Rows.person)
		.contentShape(Rectangle())
		.accessibilityElement(children: .combine)
	}
}
extension PersonRow where Accessory == EmptyView {
	init(name: String, hash: BlobHash? = nil, presence: Mark? = nil, detail: String? = nil, badge: String? = nil, member: Member? = nil, verified: Bool = false) {
		self.init(name: name, hash: hash, presence: presence, detail: detail, badge: badge, member: member, verified: verified) { EmptyView() }
	}
}

/// A device in a row: its drawing (quiet while it's away), its name, and one phrase for how it's
/// reached ("Direct, 11 ms", "Away 2 h", "This Mac").
struct DeviceRow: View {
	@Environment(\.tones) private var tones
	let d: Device
	let this: Bool
	var body: some View {
		HStack(spacing: Rows.gap) {
			DeviceGlyph(shape: DeviceShape(d), lit: this || d.online, size: Rows.personFace - 4).frame(width: Rows.personFace)
			VStack(alignment: .leading, spacing: 2) {
				Text(d.name).font(Theme.font.weight(.medium)).lineLimit(1)
				Text(this ? "This \(AppModel.thisKind)" : d.word.capitalizedFirst).font(Theme.smallFont).foregroundStyle(tones.secondary).lineLimit(1)
			}
			Spacer(minLength: 8)
		}
		.frame(minHeight: Rows.person)
		.contentShape(Rectangle())
		.accessibilityElement(children: .combine)
	}
}

// MARK: sheets

/// The top of every sheet and pane: its title, and the way out (✕, and ⎋ in a sheet), over a hairline.
struct SheetHeader: View {
	@Environment(\.tones) private var tones
	@Environment(\.dismiss) private var dismiss
	let title: String
	/// What ✕ does; nil dismisses the sheet. `escape`: ⎋ does it too (a sheet, not a pane).
	var close: (() -> Void)? = nil
	var closes = true
	var escape = true
	var help = "Close"
	var body: some View {
		HStack(spacing: 8) {
			Text(title).font(Theme.headingFont).foregroundStyle(tones.heading).lineLimit(1).accessibilityAddTraits(.isHeader)
			Spacer(minLength: 8)
			if closes {
				let button = IconButton(symbol: "xmark", help: escape ? "\(help) (⎋)" : help, size: Icon.row) { (close ?? { dismiss() })() }
				if escape { button.keyboardShortcut(.cancelAction) } else { button }
			}
		}
		.padding(.leading, Space.side).padding(.trailing, Space.side - IconButton.slack)
		.frame(height: Theme.header)
		.overlay(alignment: .bottom) { Hairline() }
	}
}

/// What a sheet is for, pinned at its foot over a hairline: the one action (and Cancel on the Mac).
struct SheetFooter<Content: View>: View {
	@Environment(\.tones) private var tones
	@ViewBuilder var content: Content
	var body: some View {
		HStack(spacing: 8) { content }
			.padding(.horizontal, Space.side).padding(.vertical, 12)
			.frame(maxWidth: .infinity, alignment: .trailing)
			.background(tones.surface)
			.overlay(alignment: .top) { Hairline() }
	}
}

/// Choosing people from my friends: a search once there are more than six, each friend a row on the
/// ground, and a tick each (several), or a click that goes straight on (one).
struct PeoplePicker: View {
	@Environment(\.tones) private var tones
	let people: [Contact]
	/// Several: the ticked ones. Nil: one click picks one, with `open`.
	var picked: Binding<Set<UserId>>? = nil
	var open: ((Contact) -> Void)? = nil
	var footer: String? = nil
	@State private var query = ""
	var body: some View {
		let q = query.trimmingCharacters(in: .whitespaces)
		let shown = (q.isEmpty ? people : people.filter { $0.name.localizedCaseInsensitiveContains(q) })
			.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
		VStack(alignment: .leading, spacing: Space.title) {
			if people.count > 6 {
				SearchBox(text: $query, prompt: "Search friends") { if picked == nil, let first = shown.first { open?(first) } }
					.padding(.horizontal, Rows.inset).padding(.bottom, 4)
			}
			VStack(spacing: 0) {
				ForEach(shown) { k in
					let on = picked?.wrappedValue.contains(k.user) ?? false
					Button { pick(k) } label: {
						PersonRow(name: k.name, hash: k.avatar, presence: Mark.presence(k.devices), detail: presenceWord(k.devices).capitalizedFirst, verified: k.verified) {
							if picked != nil {
								Image(systemName: on ? "checkmark.circle.fill" : "circle")
									.font(.system(size: Icon.bar, weight: .regular))
									.foregroundStyle(on ? tones.strong : tones.tertiary)
									.contentTransition(.symbolEffect(.replace))
							}
						}
					}
					.buttonStyle(RowStyle())
					.accessibilityAddTraits(on ? .isSelected : [])
				}
				if shown.isEmpty, !q.isEmpty { EmptyLine(text: "No friend called “\(q)”.").padding(.top, 8) }
			}
			if let footer { Text(footer).font(Theme.smallFont).foregroundStyle(tones.secondary).padding(.horizontal, Rows.inset + Rows.pad).padding(.top, 4).fixedSize(horizontal: false, vertical: true) }
		}
		.sensoryFeedback(.selection, trigger: picked?.wrappedValue)
	}
	private func pick(_ k: Contact) {
		if let picked {
			if picked.wrappedValue.contains(k.user) { picked.wrappedValue.remove(k.user) } else { picked.wrappedValue.insert(k.user) }
		} else { open?(k) }
	}
}

/// A search field: the glass, the words, and a clear button once something's typed; on the Mac a
/// keycap for the key that reaches it.
struct SearchBox: View {
	@Environment(\.tones) private var tones
	@Binding var text: String
	var prompt = "Search"
	var keys: String? = nil
	/// The fill; the field's own by default (the sidebar's is a quieter step).
	var fill: Color? = nil
	var focus: FocusState<Bool>.Binding? = nil
	var submit: () -> Void = {}
	var body: some View {
		HStack(spacing: 6) {
			Image(systemName: "magnifyingglass").font(Icon.font(Icon.inline)).foregroundStyle(tones.secondary)
			field
			if !text.isEmpty {
				Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(Icon.font(Icon.inline)) }
					.buttonStyle(.plain).foregroundStyle(tones.secondary).accessibilityLabel("Clear")
			} else if let keys { Keycap(keys: keys) }
		}
		.padding(.horizontal, 8)
		#if os(macOS)
		.frame(height: 28)
		#else
		.frame(minHeight: 40)
		#endif
		.background(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).fill(fill ?? tones.field))
	}
	@ViewBuilder private var field: some View {
		let f = TextField("", text: $text, prompt: Text(prompt).foregroundStyle(tones.secondary)).textFieldStyle(.plain).font(Theme.font).onSubmit(submit)
		if let focus { f.focused(focus) } else { f }
	}
}

/// A shortcut, as the keys are written on them: "⌘K", "⇧⌘N".
struct Keycap: View {
	@Environment(\.tones) private var tones
	let keys: String
	var body: some View {
		Text(keys).font(.system(size: Theme.small, weight: .medium)).monospacedDigit().foregroundStyle(tones.secondary)
			.padding(.horizontal, 5).frame(minHeight: Theme.small + 7)
			.overlay(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).strokeBorder(tones.hairline))
			.accessibilityLabel(keys)
	}
}

/// The one way back on the iPhone: a 44 pt circle at the screen's edge, filled while pressed so you
/// see what you hit, the system's own shape.
struct BackButton: View {
	let action: () -> Void
	var body: some View {
		IconButton(symbol: "chevron.left", help: "Back", size: Icon.bar - 2, action: action)
	}
}

/// One of a few equal tiles side by side, a glyph over a word: what a page is for (message, call,
/// video), a tap each.
struct ActionTile: View {
	@Environment(\.tones) private var tones
	let symbol: String
	let title: String
	let action: () -> Void
	var body: some View {
		Button(action: action) {
			VStack(spacing: 6) {
				Image(systemName: symbol).font(Icon.font(Icon.bar))
				Text(title).font(Theme.smallFont.weight(.semibold))
			}
			.frame(maxWidth: .infinity)
			#if os(macOS)
			.frame(height: 56)
			#else
			.frame(minHeight: 64)
			#endif
		}
		.buttonStyle(TileStyle())
		.accessibilityLabel(title)
	}
}

/// A group's face: the people in it, two or three of their faces gathered in one circle (photos
/// first), so a group never looks like a person and you can see who's in it at a glance.
struct GroupFace: View {
	@Environment(AppModel.self) private var model
	let conversation: Conversation
	var size: CGFloat
	var body: some View {
		let people = faces
		let gap = max(1.5, size / 24)
		ZStack {
			switch people.count {
			case 0: Avatar(name: model.title(conversation), size: size)
			case 1: Avatar(name: people[0].name, hash: people[0].hash, size: size)
			case 2:
				let d = (size * 0.62).rounded()
				let o = (size - d) / 2
				face(people[0], d).offset(x: -o, y: -o)
				Circle().frame(width: d + gap * 2, height: d + gap * 2).offset(x: o, y: o).blendMode(.destinationOut)
				face(people[1], d).offset(x: o, y: o)
			default:
				let d = (size * 0.56).rounded()
				let spots = [CGPoint(x: -0.22, y: 0.17), CGPoint(x: 0.22, y: 0.17), CGPoint(x: 0, y: -0.22)]
				ForEach(0..<3, id: \.self) { i in
					if i > 0 { Circle().frame(width: d + gap * 2, height: d + gap * 2).offset(x: spots[i].x * size, y: spots[i].y * size).blendMode(.destinationOut) }
					face(people[i], d).offset(x: spots[i].x * size, y: spots[i].y * size)
				}
			}
		}
		.compositingGroup()
		.frame(width: size, height: size)
		.accessibilityLabel(model.title(conversation))
	}
	private func face(_ p: (name: String, hash: BlobHash?), _ d: CGFloat) -> some View {
		Avatar(name: p.name, hash: p.hash, size: d)
	}
	/// Everyone but me, photos first, then by name; three at most.
	private var faces: [(name: String, hash: BlobHash?)] {
		let others = conversation.members.filter { $0 != model.me.user }.map { u in (name: model.name(of: u), hash: model.contacts.first { $0.user == u }?.avatar) }
		return Array(others.sorted { ($0.hash != nil) != ($1.hash != nil) ? $0.hash != nil : $0.name < $1.name }.prefix(3))
	}
}

/// What can't be undone (leaving a group, removing someone, erasing this device): its own card, last
/// on the page, in red; the press asks first, saying what will happen, and only the answer does it.
struct DangerCard: View {
	let symbol: String
	let title: String
	let question: String
	let detail: String
	let answer: String
	let action: () -> Void
	@State private var asking = false
	var body: some View {
		ListCard {
			Button { asking = true } label: { ActionRow(symbol: symbol, title: title, danger: true) }
				.buttonStyle(RowStyle())
				.confirmationDialog(question, isPresented: $asking, titleVisibility: .visible) {
					Button(answer, role: .destructive, action: action)
					Button("Cancel", role: .cancel) {}
				} message: { Text(detail) }
		}
	}
}

/// Who reacted, and with what: each emoji, the most given first, and the people who gave it, me
/// first as "You".
struct ReactionsList: View {
	@Environment(\.tones) private var tones
	@Environment(AppModel.self) private var model
	let reactions: [Reaction]
	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Reactions").font(Theme.headingFont)
			ForEach(reactions.sorted { $0.users.count > $1.users.count }, id: \.key) { r in
				HStack(alignment: .top, spacing: 12) {
					Text(r.key).font(.system(size: Theme.body + 9)).frame(width: 32)
					VStack(alignment: .leading, spacing: 8) {
						ForEach(ordered(r.users), id: \.self) { u in
							HStack(spacing: 8) {
								Avatar(name: u == model.me.user ? model.me.name : model.name(of: u), hash: u == model.me.user ? model.me.avatar : model.contacts.first { $0.user == u }?.avatar, size: 24)
								Text(model.name(of: u)).font(Theme.font)
							}
						}
					}
					Spacer(minLength: 0)
				}
			}
		}
		.padding(Space.side)
		.frame(minWidth: 240, maxWidth: .infinity, alignment: .leading)
	}
	private func ordered(_ users: [UserId]) -> [UserId] { users.filter { $0 == model.me.user } + users.filter { $0 != model.me.user } }
}

/// "😂 Ana and Sam": a reaction's people in a line, for a pointer resting on it.
@MainActor func reactors(_ r: Reaction, _ model: AppModel) -> String {
	let names = r.users.filter { $0 == model.me.user }.map { _ in "You" } + r.users.filter { $0 != model.me.user }.map(model.name(of:))
	return "\(r.key) \(list(names))"
}

/// My message, opened: who has it and who has read it, person by person, from the receipts.
struct MessageInfo: View {
	@Environment(\.tones) private var tones
	@Environment(AppModel.self) private var model
	let event: Event
	var body: some View {
		let d = model.core.delivery(event.conv, event.id)
		let people = Dictionary(grouping: d.devices, by: \.personName).map { (name: $0.key, best: $0.value.map(\.state).max { rank($0) < rank($1) } ?? .sent, carriers: Set($0.value.flatMap(\.carriers))) }
			.sorted { rank($0.best) != rank($1.best) ? rank($0.best) > rank($1.best) : $0.name < $1.name }
		VStack(alignment: .leading, spacing: 12) {
			VStack(alignment: .leading, spacing: 2) {
				Text("Message info").font(Theme.headingFont)
				Text("Sent \(event.at.formatted(date: .abbreviated, time: .shortened))").font(Theme.smallFont).foregroundStyle(tones.secondary)
			}
			if people.isEmpty { Text("Only you are here.").font(Theme.font).foregroundStyle(tones.secondary) }
			ForEach(people, id: \.name) { p in
				HStack(spacing: 8) {
					MarkView(mark: mark(p.best), size: Theme.small + 3, color: tones.secondary).frame(width: 20)
					Text(p.name).font(Theme.font)
					Spacer(minLength: 12)
					Text(word(p.best, p.carriers)).font(Theme.smallFont).foregroundStyle(tones.secondary)
				}
			}
		}
		.padding(Space.side)
		.frame(minWidth: 260, maxWidth: .infinity, alignment: .leading)
	}
	private func rank(_ s: DeliveryState) -> Int { switch s { case .read: 3; case .delivered: 2; case .carried: 1; case .sent: 0 } }
	private func mark(_ s: DeliveryState) -> Mark { switch s { case .read: .read; case .delivered: .delivered; case .carried: .carried; case .sent: .sending } }
	private func word(_ s: DeliveryState, _ carriers: Set<String>) -> String {
		switch s {
		case .read: "Read"
		case .delivered: "Delivered"
		case .carried: carriers.count == 1 ? "Carried by \(carriers.first!)" : "Carried while they're away"
		case .sent: "Not yet"
		}
	}
}

/// Deleting a chat from the list, asked first, in the same words everywhere: my notes are cleared,
/// a chat with one person leaves the list until they write, a group is left.
struct DeleteChatQuestion: ViewModifier {
	@Environment(AppModel.self) private var model
	func body(content: Content) -> some View {
		let c = model.deleting
		let other = c.flatMap { c in c.isDirect ? c.members.first { $0 != model.me.user } : nil }
		let name = other.map(model.name(of:)) ?? ""
		content.confirmationDialog(c.map { $0.kind == .home ? "Clear your notes?" : $0.isDirect ? "Delete your chat with \(name)?" : "Leave and delete \(model.title($0))?" } ?? "",
			isPresented: Binding(get: { model.deleting != nil }, set: { if !$0 { model.deleting = nil } }), titleVisibility: .visible) {
			if let c { Button(c.kind == .home ? "Clear" : c.isDirect ? "Delete" : "Leave and delete", role: .destructive) { model.delete(c); model.deleting = nil } }
			Button("Cancel", role: .cancel) { model.deleting = nil }
		} message: {
			if let c {
				Text(c.kind == .home ? "Everything in them goes, on all your devices." : c.isDirect ? "It leaves your list until \(name) writes again." + (other.map(model.isFriend) == true ? " You stay friends." : "") : "You'll stop getting its messages. Someone still in it can add you back.")
			}
		}
	}
}

/// A chat's menu in the list, on a right click or a long press: the same on both platforms.
struct ChatMenu: View {
	@Environment(AppModel.self) private var model
	let c: Conversation
	var body: some View {
		if model.calls.callable(c.id) {
			Button { model.calls.start(c.id, video: false) } label: { Label("Call", systemImage: "phone") }
			Button { model.calls.start(c.id, video: true) } label: { Label("Video call", systemImage: "video") }
		}
		if c.unread > 0 { Button { model.markRead(c) } label: { Label("Mark as read", systemImage: "checkmark.message") } }
		Divider()
		Button(role: .destructive) { model.deleting = c } label: {
			Label(c.kind == .home ? "Clear…" : c.isDirect ? "Delete…" : "Leave and delete…", systemImage: c.kind == .chat && !c.isDirect ? "rectangle.portrait.and.arrow.right" : "trash")
		}
	}
}

/// A friend's menu, wherever a friend is a row: write, call, and last, asked first, no longer friends.
struct FriendMenu: View {
	@Environment(AppModel.self) private var model
	let friend: Contact
	@Binding var removing: Contact?
	var body: some View {
		Button { model.message(friend.user) } label: { Label("Message", systemImage: "bubble.left") }
		Button { model.call(friend.user, video: false) } label: { Label("Call", systemImage: "phone") }
		Button { model.call(friend.user, video: true) } label: { Label("Video call", systemImage: "video") }
		Divider()
		Button(role: .destructive) { removing = friend } label: { Label("Remove friend…", systemImage: "person.crop.circle.badge.xmark") }
	}
}

/// Removing a friend, asked first, in the person page's words.
struct RemoveFriendQuestion: ViewModifier {
	@Environment(AppModel.self) private var model
	@Binding var removing: Contact?
	func body(content: Content) -> some View {
		content.confirmationDialog("Remove \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
			Button("Remove", role: .destructive) { if let f = removing { model.unfriend(f.user) }; removing = nil }
			Button("Cancel", role: .cancel) { removing = nil }
		} message: { Text("You'll stop being friends. Your chat leaves your list.") }
	}
}

// MARK: buttons and fields

/// The app's word buttons: a solid capsule, a card at rest, lifting on hover and settling pressed;
/// `strong` is the one filled action on a surface, `large` the size of a page's main action.
/// Disabled is a flat step with tertiary words, never the same button faded.
struct Quiet: ButtonStyle {
	var strong = false
	var danger = false
	var large = false
	func makeBody(configuration: Configuration) -> some View { Look(configuration: configuration, strong: strong, danger: danger, large: large) }
	struct Look: View {
		@Environment(\.tones) private var tones
		@Environment(\.isEnabled) private var enabled
		@Environment(\.accessibilityReduceMotion) private var still
		@State private var hover = false
		let configuration: Configuration
		let strong: Bool
		let danger: Bool
		let large: Bool
		var body: some View {
			let fill = !enabled ? tones.quiet : strong ? tones.loud : tones.card
			configuration.label
				.font(Theme.font.weight(.semibold))
				.foregroundStyle(!enabled ? tones.tertiary : strong ? tones.onLoud : danger ? tones.danger : tones.text)
				.padding(.horizontal, large ? 20 : 12)
				#if os(macOS)
				.frame(minHeight: large ? 36 : 28)
				#else
				.frame(minHeight: large ? 52 : 44)
				#endif
				.background {
					let shape = Capsule()
					if enabled && !configuration.isPressed { shape.fill(fill).lifted(tones, by: hover ? 1.2 : 0.7) } else { shape.fill(configuration.isPressed && enabled ? tones.pressed : fill) }
				}
				.scaleEffect(configuration.isPressed && !still ? 0.97 : 1)
				.animation(Motion.press, value: configuration.isPressed)
				.contentShape(Capsule())
				.onHover { hover = $0 }
		}
	}
}

/// A small capsule control: lifts on hover, darkens pressed, filled when on.
struct Pill: ButtonStyle {
	var on = false
	func makeBody(configuration: Configuration) -> some View { Look(configuration: configuration, on: on) }
	struct Look: View {
		@Environment(\.tones) private var tones
		@State private var hover = false
		let configuration: Configuration
		let on: Bool
		var body: some View {
			configuration.label
				.foregroundStyle(on ? tones.onLoud : hover ? tones.text : tones.secondary)
				.background(Capsule().fill(configuration.isPressed ? tones.pressed : on ? tones.loud : hover ? tones.hover : .clear))
				.contentShape(Capsule())
				.onHover { hover = $0 }
		}
	}
}

/// A thing you can open: a solid card that lifts further on hover and settles pressed; on, the
/// loud fill; `empty` is the dashed outline of something not made yet; `bare` shows its tile only
/// under the pointer (a thing that is its own picture).
struct TileStyle: ButtonStyle {
	var empty = false
	var on = false
	var bare = false
	func makeBody(configuration: Configuration) -> some View { Look(configuration: configuration, empty: empty, on: on, bare: bare) }
	struct Look: View {
		@Environment(\.tones) private var tones
		@Environment(\.accessibilityReduceMotion) private var still
		@State private var hover = false
		let configuration: Configuration
		let empty: Bool
		let on: Bool
		let bare: Bool
		var body: some View {
			let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
			configuration.label
				.environment(\.tones, on ? tones.onLoudTones : tones)
				.foregroundStyle(on ? tones.onLoud : tones.text)
				.background {
					if bare { shape.fill(configuration.isPressed ? tones.pressed : on || hover ? tones.hover : .clear) }
					else if !empty { shape.fill(on ? tones.loud : tones.card).lifted(tones, by: configuration.isPressed ? 0.3 : hover ? 1.4 : 1) }
				}
				.overlay { if empty && (!bare || hover) { shape.strokeBorder(hover ? tones.text : tones.tertiary, style: StrokeStyle(lineWidth: 1.5, dash: [4, 4])) } }
				.scaleEffect(configuration.isPressed && !still ? 0.97 : 1)
				.contentShape(shape)
				.onHover { hover = $0 }
				.animation(Motion.quick, value: hover)
				.animation(Motion.press, value: configuration.isPressed)
		}
	}
}

/// A text field that looks like the text it holds until you point at it; typing in it, a ring.
struct Field: View {
	@Environment(\.tones) private var tones
	let placeholder: String
	@Binding var text: String
	let commit: () -> Void
	@State private var hover = false
	@FocusState private var focused: Bool
	var body: some View {
		TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(tones.secondary)).textFieldStyle(.plain).font(Theme.font)
			.padding(.horizontal, 8).frame(minHeight: Rows.compact)
			.background(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).fill(focused ? tones.field : hover ? tones.hover : .clear))
			.overlay(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(focused ? tones.text : .clear, lineWidth: 1.5))
			.focused($focused).onHover { hover = $0 }
			.onSubmit(commit)
	}
}

/// A conversation id that can drive `.sheet(item:)`.
struct Adding: Identifiable { let id: ConversationId }
