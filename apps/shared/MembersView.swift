/// A conversation's details, the same on the Mac's side pane and the iPhone's sheet: its face and
/// name (a group's renamed with a tap), how long its messages stay, its people (each opens to who
/// they are and how they're reached), and, last and on its own, leaving.
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
			VStack(spacing: 0) {
				HStack(spacing: 6) {
					Text(c.kind == .home ? "Your devices" : group ? "Group info" : c.kind == .channel ? "Channel info" : "Chat info").font(Theme.headingFont)
					Spacer()
					if let close { IconButton(symbol: "xmark", help: "Close (⌘I)", size: 11, action: close) }
				}
				.padding(.horizontal, 16)
				#if os(macOS)
				.frame(height: Theme.header)
				#else
				.frame(height: 52)
				#endif
				.overlay(alignment: .bottom) { Hairline() }
				ScrollView {
					VStack(alignment: .leading, spacing: Parts.gap) {
						hero(c, members: members, group: group)
						if c.kind == .channel {
							ListCard(title: "Topic") { Field(placeholder: "What it's for", text: $topic) { model.attempt { try model.core.setTopic(conv, topic) } }.padding(.horizontal, 10) }
						}
						if c.kind != .space && c.kind != .home {
							ListCard(title: "Disappearing messages") { DisappearPicker(conversation: c).padding(.horizontal, 10) }
						}
						if c.kind != .home {
							ListCard(title: group || c.kind == .channel ? "\(members.count) people" : "People") {
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
						if group {
							DangerCard(symbol: "rectangle.portrait.and.arrow.right", title: "Leave group", question: "Leave \(model.title(c))?",
								detail: "You'll stop getting its messages. Someone still in it can add you back.", answer: "Leave") {
								model.attempt { try model.core.leave(conv); model.open(nil) }
								close?()
							}
						}
					}
					.padding(.horizontal, Parts.side).padding(.vertical, Parts.gap)
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

	/// A person's menu, on a long press or a right click.
	@ViewBuilder private func menu(_ m: Member, _ c: Conversation, admin: Bool) -> some View {
		if !m.me && model.isFriend(m.user) { Button { model.message(m.user) } label: { Label("Message \(model.name(of: m.user))", systemImage: "bubble.left") } }
		if admin && !m.me {
			Divider()
			Button(role: .destructive) { removing = m } label: { Label("Remove from \(model.title(c))", systemImage: "person.badge.minus") }
		}
	}

	/// Its face, its name (a group's is a field once tapped; ⏎ keeps it, ⎋ puts it back) and, under
	/// it, how many are in it or how the one other person is.
	@ViewBuilder private func hero(_ c: Conversation, members: [Member], group: Bool) -> some View {
		let other = c.isDirect ? members.first { !$0.me } : nil
		let canRename = group || (c.kind == .channel && c.admins.contains(model.me.user))
		VStack(spacing: 10) {
			if c.kind == .home { Avatar(name: model.me.name, hash: model.me.avatar, size: 72) }
			else if group { GroupFace(conversation: c, size: 72) }
			else { Avatar(name: model.title(c), hash: other.flatMap { o in model.contacts.first { $0.user == o.user }?.avatar }, size: 72, presence: other.map { Mark.presence($0.devices) }) }
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
						Image(systemName: "pencil").font(.system(size: Theme.small, weight: .semibold)).foregroundStyle(tones.secondary)
					}
				}
				.buttonStyle(.plain)
				.help("Rename")
			} else {
				// A name that can't be changed is just the name: a disabled button dimmed it.
				Text(model.title(c)).font(Theme.titleFont).multilineTextAlignment(.center)
			}
			Text(subtitle(c, members: members, other: other)).font(Theme.smallFont).foregroundStyle(tones.secondary)
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

	private func subtitle(_ c: Conversation, members: [Member], other: Member?) -> String {
		if c.kind == .home { return "\(model.me.devices.count) \(model.me.devices.count == 1 ? "device" : "devices")" }
		if let o = other { return model.isFriend(o.user) ? "Friend · \(presenceWord(o.devices))" : presenceWord(o.devices).capitalizedFirst }
		let online = members.filter { !$0.me && $0.online }.count
		return "\(members.count) people" + (online > 0 ? " · \(online) online" : "")
	}
}

/// One person in the people pane: face and presence, name, identity, and how they are reached.
struct MemberRow: View {
	@Environment(\.tones) private var tones
	@Environment(AppModel.self) private var model
	let m: Member
	let conv: ConversationId
	var body: some View {
		let through = model.through(m, in: conv)
		HStack(spacing: 9) {
			Avatar(name: m.me ? model.me.name : m.name, hash: m.me ? model.me.avatar : model.contacts.first { $0.user == m.user }?.avatar, size: Rows.face, presence: Mark.presence(m.devices))
			VStack(alignment: .leading, spacing: 2) {
				HStack(spacing: 4) {
					Text(m.me ? model.me.name : model.name(of: m.user)).font(Theme.font.weight(.medium)).lineLimit(1)
					IdentityMark(member: m)
					// Admin means something only where there are people to manage.
					if m.admin, model.conversation(conv).map({ !$0.isDirect && $0.kind != .home }) ?? false { Text("admin").font(Theme.smallFont).foregroundStyle(tones.secondary) }
				}
				HStack(spacing: 4) {
					if !through.isEmpty { MarkView(mark: .relayed, size: Theme.small + 1, color: tones.secondary) }
					Text(m.me ? "You" : !through.isEmpty ? "through \(list(through))" : model.isFriend(m.user) ? "friend · \(presenceWord(m.devices))" : presenceWord(m.devices))
						.font(Theme.smallFont).foregroundStyle(tones.secondary).lineLimit(1)
				}
			}
			Spacer(minLength: 4)
			HStack(spacing: 3) { ForEach(m.devices) { d in DeviceGlyph(shape: DeviceShape(d), lit: d.online || d.id == model.me.thisDevice, size: 14, color: tones.secondary) } }
		}
		// At least a row's height; more when the person reads at a larger size.
		.frame(minHeight: Rows.chat)
		.accessibilityElement(children: .combine)
	}
}
