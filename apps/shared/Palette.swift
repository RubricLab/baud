/// ⌘K: one field that jumps to a conversation or a person, runs a command, or searches every
/// message. Arrows, enter, escape.
import BaudCore
import SwiftUI

struct Palette: View {
	@Environment(\.tones) private var tones
	@Environment(AppModel.self) private var model
	@Binding var shown: Bool
	var run: (Command) -> Void
	@State private var query = ""
	@State private var index = 0
	@FocusState private var focused: Bool

	enum Command: Hashable { case open(ConversationId), person(UserId), hit(Hit), newChat, newGroup, newSpace, network, contacts, settings }
	struct Item: Identifiable { let id: String; let title: String; let detail: String; let command: Command }

	private var items: [Item] {
		let q = query.trimmingCharacters(in: .whitespaces).lowercased()
		var out: [Item] = []
		for c in model.conversations where (Features.spaces || c.kind == .chat) && (q.isEmpty || model.title(c).lowercased().contains(q)) {
			let space = c.space.flatMap(model.conversation)?.name
			out.append(Item(id: "c-\(c.id)", title: c.kind == .channel ? (c.name ?? "") : model.title(c), detail: c.kind == .channel ? "channel in \(space ?? "a space")" : c.kind == .space ? "space" : c.isDirect ? "chat" : "group chat", command: .open(c.id)))
		}
		for k in model.contacts where !q.isEmpty && k.name.lowercased().contains(q) {
			out.append(Item(id: "p-\(k.user)", title: k.name, detail: k.sentence, command: .person(k.user)))
		}
		let commands: [(String, Command)] = [("New chat", .newChat), ("New group", .newGroup)] + (Features.spaces ? [("New space", .newSpace)] : []) + [("Add", .contacts), ("Settings", .settings)]
		for (t, c) in commands where q.isEmpty || t.lowercased().contains(q) { out.append(Item(id: "k-\(t)", title: t, detail: "command", command: c)) }
		if q.count >= 2 {
			for h in model.core.search(query, scope: nil).prefix(20) {
				out.append(Item(id: "h-\(h.id)", title: "\(model.name(of: h.event.user)): \(h.snippet)", detail: model.title(h.conversation) + " · " + whenShort(h.event.at), command: .hit(h)))
			}
		}
		return Array(out.prefix(40))
	}

	var body: some View {
		let list = items
		VStack(spacing: 0) {
			HStack(spacing: 10) {
				Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .medium)).foregroundStyle(tones.secondary)
				TextField("", text: $query, prompt: Text("Search").foregroundStyle(tones.secondary))
					.textFieldStyle(.plain).font(.system(size: Theme.heading))
					.focused($focused)
					.onSubmit { if list.indices.contains(index) { run(list[index].command); shown = false } }
					.onChange(of: query) { _, _ in index = 0 }
					.onKeyPress(.downArrow) { index = min(index + 1, list.count - 1); return .handled }
					.onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
					.onKeyPress(.escape) { shown = false; return .handled }
			}
			.padding(.horizontal, 16).frame(height: 52)
			Hairline()
			ScrollViewReader { proxy in
				ScrollView {
					LazyVStack(spacing: 0) {
						ForEach(Array(list.enumerated()), id: \.element.id) { i, item in
							// The selected row is the loud fill: its quiet words flip with it.
							let t = i == index ? tones.onLoudTones : tones
							Button { run(item.command); shown = false } label: {
								HStack(spacing: 10) {
									icon(item.command, t)
									Text(item.title).font(Theme.font.weight(i == index ? .semibold : .regular)).lineLimit(1)
									Spacer(minLength: 8)
									Text(item.detail).font(Theme.smallFont).foregroundStyle(t.secondary).lineLimit(1)
								}.frame(height: 32)
							}
							.buttonStyle(RowStyle(selected: i == index)).id(i)
						}
						if list.isEmpty { EmptyLine(text: "Nothing matches “\(query)”.").padding(.top, 10) }
					}
					.padding(.vertical, 6)
				}
				.onChange(of: index) { _, i in proxy.scrollTo(i) }
			}
		}
		.frame(width: 560, height: 420)
		.background(tones.surface)
		.onAppear { focused = true }
	}

	/// What each kind of thing is, at a glance: a face, a channel's #, a space's tile, a command's glyph.
	@ViewBuilder private func icon(_ c: Command, _ tones: Tones) -> some View {
		Group {
			switch c {
			case .open(let id):
				if let conv = model.conversation(id) {
					switch conv.kind {
					case .channel: Text("#").font(Theme.font.weight(.semibold)).foregroundStyle(tones.secondary)
					case .space: SpaceTile(name: conv.name ?? "", size: 18)
					default:
						let other = conv.isDirect ? conv.members.first { $0 != model.me.user } : nil
						Avatar(name: model.title(conv), size: 20, presence: other.flatMap { u in model.contacts.first { $0.user == u } }.map { Mark.presence($0.devices) })
					}
				}
			case .person(let u): Avatar(name: model.name(of: u), size: 20, presence: model.contacts.first { $0.user == u }.map { Mark.presence($0.devices) })
			case .hit: Image(systemName: "text.magnifyingglass").font(.system(size: 12)).foregroundStyle(tones.secondary)
			default: Image(systemName: "command").font(.system(size: 11, weight: .semibold)).foregroundStyle(tones.secondary)
			}
		}
		.frame(width: 22)
	}
}
