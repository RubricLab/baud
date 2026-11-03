/// A conversation's details, the same on the Mac's side pane and the iPhone's sheet. A chat with one
/// person is that person: their page, with the chat's own settings after what you can do with them.
/// A group is its face and name (renamed with a tap), how long its messages stay, its people (each
/// opens to who they are and how they're reached), and, last and on its own, leaving. My chat with
/// myself is my devices.
import BaudCore
import SwiftUI

struct MembersView: View {
	@Environment(\.tones) private var tones
	@Environment(AppModel.self) private var model
	let conv: ConversationId
	var close: (() -> Void)? = nil
	@State private var name = ""
	@State private var topic = ""
	@State private var renaming = false
	@FocusState private var editing: Bool
	@State private var person: Member?
	@State private var removing: Member?

	var body: some View {
		if let c = model.conversation(conv) {
			let members = model.core.members(conv).sorted { a, b in a.me != b.me ? a.me : (a.online != b.online ? a.online : a.name < b.name) }
			let group = c.kind == .chat && !c.isDirect
			let admin = c.admins.contains(model.me.user)
			let other = c.isDirect ? members.first { !$0.me } : nil
			VStack(spacing: 0) {
				#if os(macOS)
				SheetHeader(title: title(c, group: group), close: close, closes: close != nil, escape: false, help: "Close (⌘I)")
				#else
				SheetHeader(title: title(c, group: group), close: close, closes: close != nil)
				#endif
				ScrollView {
					Group {
						if let other {
							PersonSections(user: other.user, conv: c.id, inChat: true, done: close) { DisappearCard(conversation: c) }
						} else {
							VStack(alignment: .leading, spacing: Space.section) {
								hero(c, members: members, group: group)
								if c.kind == .channel {
									ListCard(title: "Topic") { Field(placeholder: "What it's for", text: $topic) { model.attempt { try model.core.setTopic(conv, topic) } }.cardRow() }
								}
								if c.kind == .home {
									ListCard(title: "Devices") { ForEach(model.me.devices) { d in DeviceRow(d: d, this: d.id == model.me.thisDevice).cardRow() } }
								} else if c.kind != .space {
									DisappearCard(conversation: c)
								}
								if c.kind != .home { people(c, members: members, group: group, admin: admin) }
								if group {
									DangerCard(symbol: "rectangle.portrait.and.arrow.right", title: "Leave group", question: "Leave \(model.title(c))?",
										detail: "You'll stop getting its messages. Someone still in it can add you back.", answer: "Leave") {
										model.attempt { try model.core.leave(conv); model.open(nil) }
										close?()
									}
								}
							}
						}
					}
					.padding(.horizontal, Space.side).padding(.vertical, Space.section)
				}
			}
			.confirmationDialog("Remove \(removing.map { model.name(of: $0.user) } ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
				Button("Remove", role: .destructive) { if let m = removing { model.attempt { try model.core.removeMember(conv, m.user) } }; removing = nil }
				Button("Cancel", role: .cancel) { removing = nil }
			} message: { Text("They'll stop getting new messages here.") }
			.onAppear { name = c.name ?? ""; topic = c.topic ?? "" }
			.onChange(of: conv) { _, _ in renaming = false; name = model.conversation(conv)?.name ?? ""; topic = model.conversation(conv)?.topic ?? "" }
		}
	}

	private func title(_ c: Conversation, group: Bool) -> String {
		c.kind == .home ? "Your devices" : group ? "Group info" : c.kind == .channel ? "Channel info" : "Chat info"
	}

	/// Everyone in it, me first, then who's online; Add people first when I can add.
	@ViewBuilder private func people(_ c: Conversation, members: [Member], group: Bool, admin: Bool) -> some View {
		ListCard(title: "\(members.count) people") {
			if (group && c.kind != .channel) || (admin && c.kind == .channel) {
				#if os(iOS)
				NavigationLink(value: AddPeopleLink(conv: c.id)) { ActionRow(symbol: "plus", title: "Add people") }.buttonStyle(RowStyle())
				#else
				Button { model.addingTo = c.id } label: { ActionRow(symbol: "plus", title: "Add people") }.buttonStyle(RowStyle())
				#endif
			}
			ForEach(members) { m in
				#if os(iOS)
				NavigationLink(value: PersonLink(user: m.user, conv: conv)) { MemberRow(m: m, conv: conv) }
					.buttonStyle(RowStyle())
					.contextMenu { menu(m, c, admin: admin) }
				#else
				Button { person = m } label: { MemberRow(m: m, conv: conv) }
					.buttonStyle(RowStyle())
					.popover(isPresented: Binding(get: { person?.id == m.id }, set: { if !$0 { person = nil } })) { PersonPage(user: m.user, conv: conv).frame(width: 360, height: 560) }
					.contextMenu { menu(m, c, admin: admin) }
				#endif
			}
		}
	}

	/// A person's menu, on a long press or a right click.
	@ViewBuilder private func menu(_ m: Member, _ c: Conversation, admin: Bool) -> some View {
		if !m.me && model.isFriend(m.user) {
			Button { model.message(m.user) } label: { Label("Message \(model.name(of: m.user))", systemImage: "bubble.left") }
			Button { model.call(m.user, video: false) } label: { Label("Call", systemImage: "phone") }
			Button { model.call(m.user, video: true) } label: { Label("Video call", systemImage: "video") }
		}
		if admin && !m.me {
			Divider()
			Button(role: .destructive) { removing = m } label: { Label("Remove from \(model.title(c))…", systemImage: "person.badge.minus") }
		}
	}

	/// Its face, its name (a group's is a field once tapped; ⏎ keeps it, ⎋ puts it back) and, under
	/// it, how many are in it.
	@ViewBuilder private func hero(_ c: Conversation, members: [Member], group: Bool) -> some View {
		let canRename = group || (c.kind == .channel && c.admins.contains(model.me.user))
		VStack(spacing: 8) {
			if c.kind == .home { Avatar(name: model.me.name, hash: model.me.avatar, size: Hero.face) }
			else if group { GroupFace(conversation: c, size: Hero.face) }
			else { SpaceTile(name: c.space.flatMap(model.conversation)?.name ?? c.name ?? "", size: Hero.face) }
			if renaming {
				TextField("", text: $name, prompt: Text("Name").foregroundStyle(tones.secondary))
					.textFieldStyle(.plain).font(Theme.titleFont).multilineTextAlignment(.center)
					.focused($editing)
					.onSubmit { commitName() }
					#if os(macOS)
					.onExitCommand { renaming = false; name = c.name ?? "" }
					#endif
					.onChange(of: editing) { _, on in if !on { commitName() } }
			} else if canRename {
				Button { name = c.name ?? model.title(c); renaming = true; editing = true } label: {
					HStack(spacing: 6) {
						Text(model.title(c)).font(Theme.titleFont).multilineTextAlignment(.center)
						Image(systemName: "pencil").font(Icon.font(Icon.inline)).foregroundStyle(tones.secondary)
					}
				}
				.buttonStyle(.plain)
				.help("Rename")
				.accessibilityHint("Rename")
			} else {
				// A name that can't be changed is just the name: a disabled button dimmed it.
				Text(model.title(c)).font(Theme.titleFont).multilineTextAlignment(.center)
			}
			Text(subtitle(c, members: members)).font(Theme.smallFont).foregroundStyle(tones.secondary)
		}
		.frame(maxWidth: .infinity)
		.padding(.top, 4)
	}

	private func commitName() {
		guard renaming else { return }
		renaming = false
		let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !n.isEmpty, n != model.conversation(conv)?.name else { return }
		model.attempt { try model.core.setName(conv, n) }
	}

	private func subtitle(_ c: Conversation, members: [Member]) -> String {
		if c.kind == .home { return "\(model.me.devices.count) \(model.me.devices.count == 1 ? "device" : "devices")" }
		let online = members.filter { !$0.me && $0.online }.count
		return "\(members.count) people" + (online > 0 ? " · \(online) online" : "")
	}
}

/// One person in a chat's people: face and presence, name, identity, admin, and how they're reached
/// ("Friend · online", "Through Ana"). Their devices are on their page, not drawn small here.
struct MemberRow: View {
	@Environment(AppModel.self) private var model
	let m: Member
	let conv: ConversationId
	var body: some View {
		let through = model.through(m, in: conv)
		let c = model.conversation(conv)
		PersonRow(name: m.me ? model.me.name : model.name(of: m.user),
			hash: m.me ? model.me.avatar : model.contacts.first { $0.user == m.user }?.avatar,
			presence: Mark.presence(m.devices),
			detail: m.me ? "You" : !through.isEmpty ? "Through \(list(through))" : model.isFriend(m.user) ? "Friend · \(presenceWord(m.devices))" : presenceWord(m.devices).capitalizedFirst,
			// Admin means something only where there are people to manage.
			badge: m.admin && c.map { !$0.isDirect && $0.kind != .home } == true ? "admin" : nil,
			member: m)
	}
}
