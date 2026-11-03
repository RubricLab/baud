/// The parts every page is made of, so a chat's details, You and a sheet read as one app: a
/// section is a heading over a card; a card holds rows; a row is a glyph, words and what it leads
/// to; and anything that can't be undone is last, on its own, in red, and asks first.
import BaudCore
import SwiftUI

enum Parts {
	/// Between sections, around a page, and a card's corner.
	static let gap: CGFloat = 20
	#if os(macOS)
	static let side: CGFloat = 16
	#else
	static let side: CGFloat = 16
	#endif
	static let corner: CGFloat = 16
}

/// A section's name over its card: one size, one weight, one ink, everywhere. Quieter than the
/// page's own title and the card's words, so the cards carry the page.
struct SectionTitle: View {
	@Environment(\.tones) private var tones
	let text: String
	init(_ text: String) { self.text = text }
	var body: some View {
		Text(text).font(Theme.font.weight(.semibold)).foregroundStyle(tones.secondary)
			.padding(.leading, 4).accessibilityAddTraits(.isHeader)
	}
}

/// A heading over a card of rows. The rows run edge to edge inside it, each lifting on hover.
struct ListCard<Content: View>: View {
	@Environment(\.tones) private var tones
	var title: String? = nil
	var footer: String? = nil
	@ViewBuilder var content: Content
	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			if let title { SectionTitle(title) }
			VStack(alignment: .leading, spacing: 0) { content }
				.padding(.vertical, 6)
				.frame(maxWidth: .infinity, alignment: .leading)
				.glass(corner: Parts.corner)
			if let footer { Text(footer).font(Theme.smallFont).foregroundStyle(tones.secondary).padding(.horizontal, 4).fixedSize(horizontal: false, vertical: true) }
		}
	}
}

/// One row of a card: a glyph in a disc the size of a face, its words, and on the right a value
/// or where it leads.
struct ActionRow: View {
	@Environment(\.tones) private var tones
	let symbol: String
	let title: String
	var value: String? = nil
	var danger = false
	var body: some View {
		HStack(spacing: 10) {
			Image(systemName: symbol).font(.system(size: Rows.face * 0.42, weight: .semibold))
				.foregroundStyle(danger ? tones.danger : tones.text)
				.frame(width: Rows.face, height: Rows.face)
				.background(Circle().fill(tones.quiet))
			Text(title).font(Theme.font.weight(.medium)).foregroundStyle(danger ? tones.danger : tones.text)
			Spacer(minLength: 6)
			if let value { Text(value).font(Theme.font).foregroundStyle(tones.secondary).lineLimit(1) }
		}
		.frame(height: Rows.chat)
		.contentShape(Rectangle())
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
				Image(systemName: symbol).font(.system(size: 19, weight: .semibold))
				Text(title).font(Theme.smallFont.weight(.semibold))
			}
			.foregroundStyle(tones.text)
			.frame(maxWidth: .infinity).frame(height: 64)
			.glass(corner: Parts.corner)
			.contentShape(Rectangle())
		}
		.buttonStyle(Pressed())
		.accessibilityLabel(title)
	}
	struct Pressed: ButtonStyle {
		func makeBody(configuration: Configuration) -> some View {
			configuration.label.scaleEffect(configuration.isPressed ? 0.96 : 1).opacity(configuration.isPressed ? 0.8 : 1)
				.animation(.easeOut(duration: 0.12), value: configuration.isPressed)
		}
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
		VStack(alignment: .leading, spacing: 14) {
			Text("Reactions").font(Theme.headingFont)
			ForEach(reactions.sorted { $0.users.count > $1.users.count }, id: \.key) { r in
				HStack(alignment: .top, spacing: 12) {
					Text(r.key).font(.system(size: Theme.body + 9)).frame(width: 30)
					VStack(alignment: .leading, spacing: 6) {
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
		.padding(18)
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
		VStack(alignment: .leading, spacing: 14) {
			VStack(alignment: .leading, spacing: 2) {
				Text("Message info").font(Theme.headingFont)
				Text("Sent \(event.at.formatted(date: .abbreviated, time: .shortened))").font(Theme.smallFont).foregroundStyle(tones.secondary)
			}
			if people.isEmpty { Text("Only you are here.").font(Theme.font).foregroundStyle(tones.secondary) }
			ForEach(people, id: \.name) { p in
				HStack(spacing: 10) {
					MarkView(mark: mark(p.best), size: Theme.small + 3, color: tones.secondary).frame(width: 18)
					Text(p.name).font(Theme.font)
					Spacer(minLength: 12)
					Text(word(p.best, p.carriers)).font(Theme.smallFont).foregroundStyle(tones.secondary)
				}
			}
		}
		.padding(18)
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
				Text(c.kind == .home ? "Everything here goes from this device." : c.isDirect ? "It leaves your list until \(name) writes again." + (other.map(model.isFriend) == true ? " You stay friends." : "") : "You'll stop getting its messages. Someone still in it can add you back.")
			}
		}
	}
}

/// A chat's menu in the list, on a right click or a long press: the same on both platforms.
struct ChatMenu: View {
	@Environment(AppModel.self) private var model
	let c: Conversation
	var body: some View {
		if c.unread > 0 { Button { try? model.core.markRead(c.id, c.lastEvent ?? "") } label: { Label("Mark as read", systemImage: "checkmark.message") } }
		if model.calls.callable(c.id) {
			Button { model.calls.start(c.id, video: false) } label: { Label("Call", systemImage: "phone") }
			Button { model.calls.start(c.id, video: true) } label: { Label("Video call", systemImage: "video") }
		}
		Divider()
		Button(role: .destructive) { model.deleting = c } label: {
			Label(c.kind == .home ? "Clear…" : c.isDirect ? "Delete…" : "Leave and delete…", systemImage: c.kind == .chat && !c.isDirect ? "rectangle.portrait.and.arrow.right" : "trash")
		}
	}
}
