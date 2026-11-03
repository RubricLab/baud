/// ⌘K: one field that jumps to a chat or a person, does something with the open chat, runs a
/// command, or searches every message. In sections, each command with its keys; arrows, ⏎, ⎋.
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

	enum Command: Hashable { case open(ConversationId), person(UserId), hit(Hit), newChat, newGroup, newFriend, newSpace, friends, network, settings, call(ConversationId, video: Bool), details, markRead(ConversationId), pin(ConversationId), mute(ConversationId, TimeInterval?, off: Bool), archive(ConversationId), delete(ConversationId) }
	struct Item: Identifiable { let id: String; let title: String; var detail: String? = nil; var keys: String? = nil; var symbol: String? = nil; let command: Command }
	struct Shelf: Identifiable { let id: String; let items: [Item] }

	private var sections: [Shelf] {
		let q = query.trimmingCharacters(in: .whitespaces).lowercased()
		func hit(_ t: String) -> Bool { q.isEmpty || t.lowercased().contains(q) }
		var out: [Shelf] = []
		// What can be done with the chat that's open.
		if let c = model.selectedConversation.flatMap(model.conversation) {
			let name = model.title(c)
			var here: [Item] = []
			if model.calls.callable(c.id), model.calls.session == nil {
				here.append(Item(id: "x-call", title: "Call \(name)", symbol: "phone", command: .call(c.id, video: false)))
				here.append(Item(id: "x-video", title: "Video call \(name)", symbol: "video", command: .call(c.id, video: true)))
			}
			here.append(Item(id: "x-details", title: model.details ? "Hide details" : "Show details", keys: "⌘I", symbol: "info.circle", command: .details))
			here.append(Item(id: "x-read", title: model.isUnread(c) ? "Mark as read" : "Mark as unread", keys: "⇧⌘U", symbol: model.isUnread(c) ? "checkmark.message" : "message.badge", command: .markRead(c.id)))
			if c.kind != .home {
				here.append(Item(id: "x-pin", title: model.isPinned(c.id) ? "Unpin chat" : "Pin chat", symbol: model.isPinned(c.id) ? "pin.slash" : "pin", command: .pin(c.id)))
				if model.muted(c.id) != nil { here.append(Item(id: "x-unmute", title: "Unmute", symbol: "bell", command: .mute(c.id, nil, off: true))) }
				else { for (t, s) in MuteMenu.choices { here.append(Item(id: "x-mute-\(t)", title: "Mute \(t.lowercased())", symbol: "bell.slash", command: .mute(c.id, s, off: false))) } }
				here.append(Item(id: "x-archive", title: model.isArchived(c) ? "Unarchive" : "Archive", symbol: "archivebox", command: .archive(c.id)))
			}
			here.append(Item(id: "x-delete", title: c.kind == .home ? "Clear…" : c.isDirect ? "Delete chat…" : "Leave and delete…", keys: "⌘⌫", symbol: "trash", command: .delete(c.id)))
			out.append(Shelf(id: "This chat", items: here.filter { hit($0.title) }))
		}
		let chats = model.conversations.filter { (Features.spaces || c($0)) && hit(model.title($0)) }.map { c in
			Item(id: "c-\(c.id)", title: c.kind == .channel ? (c.name ?? "") : model.title(c), detail: c.kind == .channel ? c.space.flatMap(model.conversation)?.name : nil, command: .open(c.id))
		}
		out.append(Shelf(id: "Chats", items: chats))
		if !q.isEmpty {
			out.append(Shelf(id: "People", items: model.contacts.filter { hit($0.name) }.map { Item(id: "p-\($0.user)", title: $0.name, detail: presenceWord($0.devices).capitalizedFirst, command: .person($0.user)) }))
		}
		let actions: [Item] = [
			Item(id: "k-chat", title: "New chat", keys: "⌘N", symbol: "bubble.left", command: .newChat),
			Item(id: "k-group", title: "New group", keys: "⇧⌘N", symbol: "person.2", command: .newGroup),
			Item(id: "k-friend", title: "New friend", keys: "⌥⌘N", symbol: "person.badge.plus", command: .newFriend),
		] + (Features.spaces ? [Item(id: "k-space", title: "New space", keys: "⌃⌥⌘N", symbol: "square.grid.2x2", command: .newSpace)] : []) + [
			Item(id: "k-friends", title: "Friends", keys: "⇧⌘1", symbol: "person.crop.circle", command: .friends),
			Item(id: "k-network", title: "Network", keys: "⇧⌘2", symbol: "point.3.connected.trianglepath.dotted", command: .network),
			Item(id: "k-settings", title: "Settings", keys: "⌘,", symbol: "gearshape", command: .settings),
		]
		out.append(Shelf(id: "Actions", items: actions.filter { hit($0.title) }))
		if q.count >= 2 {
			out.append(Shelf(id: "Messages", items: model.core.search(query, scope: nil).prefix(20).map { h in
				Item(id: "h-\(h.id)", title: "\(model.name(of: h.event.user)): \(h.snippet)", detail: model.title(h.conversation) + " · " + whenShort(h.event.at), command: .hit(h))
			}))
		}
		return out.filter { !$0.items.isEmpty }
	}
	private func c(_ c: Conversation) -> Bool { c.kind == .chat || c.kind == .home }

	var body: some View {
		let sections = self.sections
		let flat = sections.flatMap(\.items)
		VStack(spacing: 0) {
			HStack(spacing: 10) {
				Image(systemName: "magnifyingglass").font(Icon.font(Icon.bar)).foregroundStyle(tones.secondary)
				TextField("", text: $query, prompt: Text("Jump to a chat, a person or a command").foregroundStyle(tones.secondary))
					.textFieldStyle(.plain).font(.system(size: Theme.heading))
					.focused($focused)
					.onSubmit { if flat.indices.contains(index) { go(flat[index].command) } }
					.onChange(of: query) { _, _ in index = 0 }
					.onKeyPress(.downArrow) { index = min(index + 1, flat.count - 1); return .handled }
					.onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
					.onKeyPress(.escape) { shown = false; return .handled }
			}
			.padding(.horizontal, Space.side).frame(height: Theme.header)
			Hairline()
			ScrollViewReader { proxy in
				ScrollView {
					LazyVStack(alignment: .leading, spacing: 0) {
						ForEach(sections) { s in
							SectionTitle(s.id).padding(.top, 8).padding(.bottom, 2)
							ForEach(s.items) { item in
								let i = flat.firstIndex { $0.id == item.id } ?? 0
								Button { go(item.command) } label: { row(item, on: i == index) }
									.buttonStyle(RowStyle(selected: i == index)).id(i)
							}
						}
						if flat.isEmpty { EmptyLine(text: "Nothing matches “\(query)”.").padding(.top, 12) }
					}
					.padding(.bottom, 8)
				}
				.onChange(of: index) { _, i in proxy.scrollTo(i) }
			}
			Hairline()
			HStack(spacing: 12) {
				hint("↑↓", "to move"); hint("⏎", "to open"); hint("esc", "to close")
				Spacer()
			}
			.padding(.horizontal, Space.side).frame(height: 32)
		}
		.frame(width: 560, height: 460)
		.background(tones.surface)
		.onAppear { focused = true }
	}

	private func go(_ c: Command) { run(c); shown = false }

	private func row(_ item: Item, on: Bool) -> some View {
		HStack(spacing: Rows.gap) {
			icon(item).frame(width: 20)
			Text(item.title).font(Theme.font.weight(on ? .semibold : .regular)).lineLimit(1)
			Spacer(minLength: 8)
			if let keys = item.keys { Keycap(keys: keys) }
			else if let d = item.detail { Text(d).font(Theme.smallFont).foregroundStyle(tones.secondary).lineLimit(1) }
		}
		.frame(minHeight: Rows.line)
	}

	private func hint(_ keys: String, _ words: String) -> some View {
		HStack(spacing: 4) { Keycap(keys: keys); Text(words).font(Theme.smallFont).foregroundStyle(tones.secondary) }
	}

	/// What each thing is, at a glance: a face (a group's faces), a channel's #, a space's tile, a
	/// command's glyph.
	@ViewBuilder private func icon(_ item: Item) -> some View {
		if let symbol = item.symbol { Image(systemName: symbol).font(Icon.font(Icon.row)).foregroundStyle(tones.secondary) }
		else {
			switch item.command {
			case .open(let id):
				if let conv = model.conversation(id) {
					switch conv.kind {
					case .channel: Text("#").font(Theme.font.weight(.semibold)).foregroundStyle(tones.secondary)
					case .space: SpaceTile(name: conv.name ?? "", size: 18)
					case .home: Avatar(name: model.me.name, hash: model.me.avatar, size: 20)
					default:
						if conv.isDirect {
							let other = conv.members.first { $0 != model.me.user }
							let friend = other.flatMap { u in model.contacts.first { $0.user == u } }
							Avatar(name: model.title(conv), hash: friend?.avatar, size: 20, presence: friend.map { Mark.presence($0.devices) })
						} else { GroupFace(conversation: conv, size: 20) }
					}
				}
			case .person(let u):
				let k = model.contacts.first { $0.user == u }
				Avatar(name: model.name(of: u), hash: k?.avatar, size: 20, presence: k.map { Mark.presence($0.devices) })
			case .hit: Image(systemName: "text.magnifyingglass").font(Icon.font(Icon.row)).foregroundStyle(tones.secondary)
			default: EmptyView()
			}
		}
	}
}
