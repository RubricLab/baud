/// Making things: a chat, a group chat, a space, a channel. One sheet, four shapes, each saying
/// honestly what it makes: a group chat makes no new friends; a space makes everyone in it friends.
import BaudCore
import SwiftUI

struct NewSheet: View {
	@Environment(\.tones) private var tones
	@Environment(AppModel.self) private var model
	@Environment(\.dismiss) private var dismiss
	enum What: String, Identifiable { case chat, group, space, channel; var id: String { rawValue } }
	let what: What
	var space: ConversationId? = nil
	@State private var name = ""
	@State private var picked: Set<UserId> = []
	@FocusState private var focused: Bool

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text(title).font(Theme.headingFont)
			if what != .chat {
				TextField(what == .channel ? "channel-name" : "Name", text: $name).textFieldStyle(.plain).font(Theme.font)
					.padding(8).overlay(RoundedRectangle(cornerRadius: Radius.row).stroke(tones.hairline)).focused($focused)
					.onSubmit(make)
			}
			if what == .chat || what == .group {
				List(model.contacts, selection: $picked) { c in
					HStack { Avatar(name: c.name, hash: c.avatar, size: 18, presence: Mark.presence(c.devices)); Text(c.name).font(Theme.font); Spacer(); Text(c.sentence).font(Theme.smallFont).foregroundStyle(tones.secondary) }.tag(c.user)
				}
				.frame(height: 200)
				#if os(macOS)
				.listStyle(.inset)
				#else
				.environment(\.editMode, .constant(.active))
				#endif
			}
			HStack {
				Spacer()
				Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(Quiet())
				Button(action: make) { Text(what == .chat ? "Open chat" : "Create") }.keyboardShortcut(.defaultAction).buttonStyle(Quiet(strong: true)).disabled(!valid)
			}
		}
		.padding(20).frame(width: 380).background(tones.surface)
		.onAppear { focused = true }
	}
	private var title: String {
		switch what {
		case .chat: return "New chat"
		case .group: return "New group chat"
		case .space: return "New space"
		case .channel: return "New channel in \(space.flatMap(model.conversation)?.name ?? "the space")"
		}
	}
	private var explain: String {
		switch what {
		case .chat: return "You and one friend, carried by any device you both trust."
		case .group: return "Everyone holds the whole chat; nobody becomes friends. People who aren't friends see each other's chosen names and are reached through the friends they share."
		case .space: return "A closed circle: everyone you add becomes friends with everyone in it, every channel has every member, and only its members carry its messages. Name it, then add people."
		case .channel: return "Every channel has every member of the space."
		}
	}
	private var valid: Bool {
		switch what {
		case .chat: return picked.count == 1
		case .group: return !name.isEmpty && !picked.isEmpty
		case .space, .channel: return !name.isEmpty
		}
	}
	private func make() {
		guard valid else { return }
		model.attempt {
			let c: Conversation
			switch what {
			case .chat: c = try model.core.createChat(Array(picked))
			case .group: c = try model.core.createGroup(name, users: Array(picked))
			case .space: c = try model.core.createSpace(name)
			case .channel: c = try model.core.createChannel(space: space ?? "", name: name.lowercased().replacingOccurrences(of: " ", with: "-"))
			}
			model.refreshAll()
			model.open(c.id)
			// A new space is empty: the next thing is its people.
			if what == .space { Task { try? await Task.sleep(for: .milliseconds(400)); model.addingTo = c.id } }
		}
		dismiss()
	}
}
