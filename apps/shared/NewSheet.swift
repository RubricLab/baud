/// Making things: a chat, a group chat, a space, a channel. One sheet, four shapes, built from the
/// same parts as Add people: a chat is a friend picked with one click; a group is a name and the
/// friends ticked; a space or a channel, a name.
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

	var body: some View {
		VStack(spacing: 0) {
			SheetHeader(title: title)
			ScrollView {
				VStack(alignment: .leading, spacing: Space.section) {
					if what != .chat {
						VStack(alignment: .leading, spacing: 4) {
							Field(placeholder: what == .channel ? "channel-name" : what == .group ? "Group name" : "Name", text: $name, boxed: true, autofocus: true, commit: make)
								.padding(.horizontal, Rows.inset)
							if let explain { Text(explain).font(Theme.smallFont).foregroundStyle(tones.secondary).padding(.horizontal, Rows.inset + Rows.pad).fixedSize(horizontal: false, vertical: true) }
						}
					}
					if what == .chat || what == .group {
						if model.contacts.isEmpty {
							EmptyLine(text: "Your friends show up here. Add one with New friend.")
						} else {
							VStack(alignment: .leading, spacing: Space.title) {
								if what == .group { SectionTitle("People") }
								PeoplePicker(people: model.contacts, picked: what == .group ? $picked : nil, open: { k in model.message(k.user); dismiss() })
							}
						}
					}
				}
				.padding(.vertical, Space.section)
			}
			#if os(iOS)
			.scrollDismissesKeyboard(.immediately)
			#endif
			if what != .chat {
				SheetFooter {
					Button(action: make) {
						Text("Create")
							#if os(iOS)
							.frame(maxWidth: .infinity)
							#endif
					}
					.keyboardShortcut(.defaultAction).buttonStyle(Quiet(strong: true, large: true)).disabled(!valid)
				}
			}
		}
		.background(tones.surface.ignoresSafeArea())
		#if os(macOS)
		.frame(width: 420, height: what == .chat || what == .group ? 520 : 260)
		#endif
	}
	private var title: String {
		switch what {
		case .chat: return "New chat"
		case .group: return "New group"
		case .space: return "New space"
		case .channel: return "New channel in \(space.flatMap(model.conversation)?.name ?? "the space")"
		}
	}
	/// What it makes, said once, under its name: only where it isn't plain.
	private var explain: String? {
		switch what {
		case .chat, .group: return nil
		case .space: return "A closed circle: everyone you add becomes friends with everyone in it, every channel has every member, and only its members carry its messages."
		case .channel: return "Every channel has every member of the space."
		}
	}
	private var valid: Bool {
		switch what {
		case .chat: return picked.count == 1
		case .group: return !name.trimmingCharacters(in: .whitespaces).isEmpty && !picked.isEmpty
		case .space, .channel: return !name.trimmingCharacters(in: .whitespaces).isEmpty
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
			#if os(iOS)
			if what == .group { model.reveal = c.id }
			#endif
			// A new space is empty: the next thing is its people.
			if what == .space { Task { try? await Task.sleep(for: .milliseconds(400)); model.addingTo = c.id } }
		}
		dismiss()
	}
}
