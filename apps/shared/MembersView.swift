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
				.frame(height: Theme.header + 4)
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
									Button { model.addingTo = c.id } label: { ActionRow(symbol: "plus", title: "Add people") }.buttonStyle(RowStyle())
								}
								ForEach(members) { m in
									Button { person = m } label: { MemberRow(m: m, conv: conv) }
										.buttonStyle(RowStyle())
										.popover(isPresented: Binding(get: { person?.id == m.id }, set: { if !$0 { person = nil } })) { PersonCard(m: m, conv: conv) }
										.contextMenu {
											if !m.me && model.isFriend(m.user) { Button { model.message(m.user) } label: { Label("Message \(model.name(of: m.user))", systemImage: "bubble.left") } }
											if admin && !m.me {
												Divider()
												Button(role: .destructive) { removing = m } label: { Label("Remove from \(model.title(c))", systemImage: "person.badge.minus") }
											}
										}
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

	/// Its face, its name (a group's is a field once tapped; ⏎ keeps it, ⎋ puts it back) and, under
	/// it, how many are in it or how the one other person is.
	@ViewBuilder private func hero(_ c: Conversation, members: [Member], group: Bool) -> some View {
		let other = c.isDirect ? members.first { !$0.me } : nil
		let canRename = group || (c.kind == .channel && c.admins.contains(model.me.user))
		VStack(spacing: 10) {
			if c.kind == .home { Avatar(name: model.me.name, hash: model.me.avatar, size: 72) }
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
			} else {
				Button { if canRename { name = c.name ?? model.title(c); renaming = true; editing = true } } label: {
					HStack(spacing: 6) {
						Text(model.title(c)).font(Theme.titleFont).multilineTextAlignment(.center)
						if canRename { Image(systemName: "pencil").font(.system(size: Theme.small, weight: .semibold)).foregroundStyle(tones.secondary) }
					}
				}
				.buttonStyle(.plain).disabled(!canRename)
				.help(canRename ? "Rename" : "")
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
					if m.admin { Text("admin").font(Theme.smallFont).foregroundStyle(tones.secondary) }
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
		.frame(height: Rows.chat)
		.accessibilityElement(children: .combine)
	}
}

/// A person, opened: who they are to me, whether they're checked, their devices and how each is
/// reached right now, and what I can do: message them, verify them.
struct PersonCard: View {
	@Environment(\.tones) private var tones
	@Environment(AppModel.self) private var model
	@Environment(\.dismiss) private var dismiss
	let m: Member
	let conv: ConversationId
	@State private var verifying: Contact?
	var body: some View {
		let friend = model.contacts.first { $0.user == m.user }
		let through = model.through(m, in: conv)
		VStack(alignment: .leading, spacing: 12) {
			HStack(spacing: 12) {
				Avatar(name: m.me ? model.me.name : m.name, hash: m.me ? model.me.avatar : friend?.avatar, size: 44, presence: Mark.presence(m.devices))
				VStack(alignment: .leading, spacing: 2) {
					Text(m.me ? model.me.name : model.name(of: m.user)).font(Theme.headingFont)
					Text(m.me ? "you" : friend != nil ? (friend!.name != m.name ? "your friend · calls themself \(m.name)" : "your friend") : through.isEmpty ? "not your friend" : "not your friend · reached through \(list(through))")
						.font(Theme.smallFont).foregroundStyle(tones.secondary)
				}
			}
			if !m.me {
				HStack(spacing: 6) {
					MarkView(mark: m.verified ? .verified : .unverified, size: Theme.small + 3, color: m.verified ? tones.text : tones.secondary)
					Text(m.verified ? "Verified by you: you compared safety numbers." : "Not verified: nobody you trust has checked this key yet.").font(Theme.smallFont).foregroundStyle(tones.secondary)
				}
			}
			VStack(alignment: .leading, spacing: 6) {
				ForEach(m.devices) { d in
					HStack(spacing: 8) {
						DeviceGlyph(shape: DeviceShape(d), lit: d.online || d.id == model.me.thisDevice, size: 18)
						Text(d.name).font(Theme.font)
						Spacer(minLength: 12)
						if d.online, let p = Mark.path(d.path) { MarkView(mark: p, size: Theme.small + 2, color: tones.secondary) }
						Text(d.id == model.me.thisDevice ? "this \(AppModel.thisKind)" : d.word).font(Theme.smallFont).foregroundStyle(tones.secondary)
					}
				}
				if m.devices.isEmpty { Text(through.isEmpty ? "No device known yet." : "Their devices aren't shared with you: only friends see each other's addresses.").font(Theme.smallFont).foregroundStyle(tones.secondary) }
			}
			if !m.me {
				HStack(spacing: 8) {
					if let f = friend {
						Button("Message \(f.name)") { model.message(f.user); dismiss() }.buttonStyle(Quiet(strong: true))
						if !f.verified { Button("Verify…") { verifying = f }.buttonStyle(Quiet()) }
					}
				}
			}
		}
		.padding(16).frame(width: 320, alignment: .leading)
		.background(tones.surface)
		.sheet(item: $verifying) { VerifySheet(contact: $0) }
	}
}

/// A text field that looks like the text it holds until you point at it.
struct Field: View {
	@Environment(\.tones) private var tones
	let placeholder: String
	@Binding var text: String
	let commit: () -> Void
	@State private var hover = false
	@FocusState private var focused: Bool
	var body: some View {
		TextField(placeholder, text: $text).textFieldStyle(.plain).font(Theme.font)
			.padding(.horizontal, 6).frame(height: Rows.compact)
			.background(RoundedRectangle(cornerRadius: 6).fill(focused ? tones.field : hover ? tones.hover : .clear))
			.overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? tones.strong : hover ? tones.hairline : .clear))
			.focused($focused).onHover { hover = $0 }
			.onSubmit(commit)
	}
}

/// The app's buttons: a word on a quiet fill with a hairline, lifting on hover and darkening
/// pressed; `strong` is the one filled action on a surface, `large` the linking surfaces' size.
struct Quiet: ButtonStyle {
	var strong = false
	var danger = false
	var large = false
	func makeBody(configuration: Configuration) -> some View { Look(configuration: configuration, strong: strong, danger: danger, large: large) }
	struct Look: View {
		@Environment(\.tones) private var tones
		@Environment(\.isEnabled) private var enabled
		@State private var hover = false
		let configuration: Configuration
		let strong: Bool
		let danger: Bool
		let large: Bool
		var body: some View {
			// Solid pills: the loud one lifted off the page, the quiet one a card; disabled is a flat
			// step with tertiary words, never the same button faded.
			let fill = !enabled ? tones.quiet : strong ? tones.loud : tones.card
			configuration.label
				.font(Theme.font.weight(.bold))
				.foregroundStyle(!enabled ? tones.tertiary : strong ? tones.onLoud : danger ? tones.danger : tones.text)
				.padding(.horizontal, large ? 20 : 14)
				#if os(macOS)
				.frame(minHeight: large ? 38 : 28)
				#else
				.frame(minHeight: large ? 50 : 40)
				#endif
				.background {
					let shape = Capsule()
					if enabled && !configuration.isPressed { shape.fill(fill).lifted(tones, by: hover ? 1.2 : 0.7) } else { shape.fill(fill) }
				}
				.scaleEffect(configuration.isPressed ? 0.97 : 1)
				.animation(.easeOut(duration: 0.12), value: configuration.isPressed)
				.contentShape(Capsule())
				.onHover { hover = $0 }
		}
	}
}

/// Add friends to a group chat or a space; the sentence says what that means in each.
struct AddPeopleSheet: View {
	@Environment(\.tones) private var tones
	@Environment(AppModel.self) private var model
	@Environment(\.dismiss) private var dismiss
	let conv: ConversationId
	@State private var picked: Set<UserId> = []
	var body: some View {
		let c = model.conversation(conv)
		let candidates = model.contacts.filter { k in !(c?.members.contains(k.user) ?? true) }
		VStack(alignment: .leading, spacing: 12) {
			Text("Add people to \(c.map(model.title) ?? "")").font(Theme.headingFont)
			if candidates.isEmpty {
				Text(model.contacts.isEmpty ? "Add a friend first: people join a group from your friends." : "All your friends are already here.")
					.font(Theme.font).foregroundStyle(tones.secondary).frame(maxWidth: .infinity, minHeight: 80)
			}
			ScrollView {
				VStack(spacing: 0) {
					ForEach(candidates) { k in
						let on = picked.contains(k.user)
						Button { if on { picked.remove(k.user) } else { picked.insert(k.user) } } label: {
							HStack { FriendRow(c: k); Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundStyle(on ? tones.strong : tones.secondary) }
						}.buttonStyle(RowStyle(selected: on))
					}
				}
			}.frame(height: 200)
			HStack {
				Spacer()
				Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(Quiet())
				Button("Add \(picked.count == 1 ? "1 person" : "\(picked.count) people")") {
					for u in picked { model.attempt { try model.core.addMember(conv, u) } }
					model.refreshAll(); dismiss()
				}.keyboardShortcut(.defaultAction).buttonStyle(Quiet(strong: true)).disabled(picked.isEmpty)
			}
		}
		.padding(20).frame(width: 380).background(tones.surface)
	}
}
/// A conversation id that can drive `.sheet(item:)`.
struct Adding: Identifiable { let id: ConversationId }
