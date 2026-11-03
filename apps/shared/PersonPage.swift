/// A person, opened: who they are to me, what I can do with them (write, call), whether their key
/// is checked, the groups we share, their devices, and last, on its own, ending it (removing a
/// friend, or removing them from a group). One page wherever a person is tapped: a friend in You, a
/// member in a chat's details, and a chat with one person's own details. On the iPhone it's pushed
/// full height; on the Mac it's a popover, or the details pane.
/// And adding people to a group: a page of friends to tick, with the button that adds them always
/// in reach at the bottom.
import BaudCore
import SwiftUI

/// Where You and a chat's details lead on the iPhone.
struct PersonLink: Hashable { let user: UserId; var conv: ConversationId? = nil }
struct AddPeopleLink: Hashable { let conv: ConversationId }

/// The size of the face at the top of a page: a person, a group, You.
enum Hero {
	#if os(macOS)
	static let face: CGFloat = 64
	#else
	static let face: CGFloat = 88
	#endif
}

struct PersonPage: View {
	@Environment(\.tones) private var tones
	let user: UserId
	/// The chat it was opened from, if any: who carries for them there; removing them from it.
	var conv: ConversationId? = nil
	var body: some View {
		ScrollView {
			PersonSections(user: user, conv: conv) { EmptyView() }
				.padding(.horizontal, Space.side).padding(.vertical, Space.section)
		}
		.background(tones.surface.ignoresSafeArea())
		#if os(iOS)
		.navigationBarTitleDisplayMode(.inline)
		#endif
	}
}

/// A person's sections, top to bottom: who, what to do, `extra` (a chat's own settings), the safety
/// number, their devices, the groups we share, and last, ending it.
struct PersonSections<Extra: View>: View {
	@Environment(\.tones) private var tones
	@Environment(AppModel.self) private var model
	@Environment(\.dismiss) private var dismiss
	let user: UserId
	var conv: ConversationId? = nil
	/// Shown as this person's own chat's details: no Message (it's open), and `done` closes the pane.
	var inChat = false
	var done: (() -> Void)? = nil
	@ViewBuilder var extra: Extra
	@State private var verifying: Contact?

	var body: some View {
		let friend = model.contacts.first { $0.user == user }
		let member = conv.flatMap { c in model.core.members(c).first { $0.user == user } }
		let me = user == model.me.user
		let devices = me ? model.me.devices : friend?.devices ?? member?.devices ?? []
		let name = me ? model.me.name : model.name(of: user)
		VStack(alignment: .leading, spacing: Space.section) {
			hero(name: name, friend: friend, member: member, me: me, devices: devices)
			if let friend, !me { actions(friend) }
			extra
			if !me { safety(friend: friend, member: member, name: name) }
			devicesCard(devices, member: member, me: me)
			shared(name: name)
			danger(friend: friend, member: member, me: me, name: name)
		}
		.sheet(item: $verifying) { VerifySheet(contact: $0) }
	}

	private func finish() { if let done { done() } else { dismiss() } }

	// MARK: pieces

	private func hero(name: String, friend: Contact?, member: Member?, me: Bool, devices: [Device]) -> some View {
		let verified = friend?.verified ?? member?.verified ?? false
		let avatar = me ? model.me.avatar : friend?.avatar
		return VStack(spacing: 8) {
			Avatar(name: name, hash: avatar, size: Hero.face, presence: me || devices.isEmpty ? nil : Mark.presence(devices))
			HStack(spacing: 6) {
				Text(name).font(Theme.titleFont).lineLimit(2).multilineTextAlignment(.center)
				if verified { MarkView(mark: .verified, size: Theme.title * 0.8, color: tones.text).accessibilityLabel("Verified") }
			}
			Text(subtitle(friend: friend, member: member, me: me, devices: devices)).font(Theme.smallFont).foregroundStyle(tones.secondary).multilineTextAlignment(.center)
		}
		.frame(maxWidth: .infinity)
		.padding(.top, 4)
	}

	private func subtitle(friend: Contact?, member: Member?, me: Bool, devices: [Device]) -> String {
		if me { return "You" }
		let presence = presenceWord(devices)
		if let friend {
			let card = member?.name ?? friend.name
			return "Friend · \(presence)" + (card != friend.name ? " · calls themself \(card)" : "")
		}
		let through = member.flatMap { m in conv.map { model.through(m, in: $0) } } ?? []
		return through.isEmpty ? "Not your friend" : "Not your friend · reached through \(list(through))"
	}

	/// Write, call, video: the things a person is for, a tap each. In their own chat, writing is
	/// what's already open.
	private func actions(_ f: Contact) -> some View {
		HStack(spacing: 8) {
			if !inChat { ActionTile(symbol: "bubble.left", title: "Message") { model.message(f.user); finish() } }
			ActionTile(symbol: "phone", title: "Call") { model.call(f.user, video: false) }
			ActionTile(symbol: "video", title: "Video") { model.call(f.user, video: true) }
		}
	}

	@ViewBuilder private func safety(friend: Contact?, member: Member?, name: String) -> some View {
		let verified = friend?.verified ?? member?.verified ?? false
		let first = name.split(separator: " ").first.map(String.init) ?? name
		ListCard(title: "Safety number", footer: verified ? "You compared safety numbers with \(first): nobody is in between." : friend != nil ? "Compare the number with \(first) in person or on a call. If it matches, nobody is in between." : "Only a friend's number can be compared.") {
			if verified {
				ActionRow(symbol: "checkmark.shield", title: "Verified").cardRow()
			} else if let friend {
				Button { verifying = friend } label: { ActionRow(symbol: "shield", title: "Verify \(first)") }.buttonStyle(RowStyle())
			} else {
				ActionRow(symbol: "shield", title: friend?.vouched == true ? "Vouched for" : "Not verified").cardRow()
			}
		}
	}

	@ViewBuilder private func devicesCard(_ devices: [Device], member: Member?, me: Bool) -> some View {
		ListCard(title: devices.count == 1 ? "Device" : "Devices", footer: devices.isEmpty ? "Their devices aren't shared with you: only friends see each other's addresses." : nil) {
			ForEach(devices) { d in DeviceRow(d: d, this: d.id == model.me.thisDevice).cardRow() }
		}
	}

	/// The groups we're both in, besides this one: a tap opens it.
	@ViewBuilder private func shared(name: String) -> some View {
		let groups = model.conversations.filter { $0.kind == .chat && !$0.isDirect && $0.id != conv && $0.members.contains(user) && $0.members.contains(model.me.user) }
		if !groups.isEmpty, user != model.me.user {
			ListCard(title: "Groups with \(name.split(separator: " ").first.map(String.init) ?? name)") {
				ForEach(groups) { g in
					Button {
						model.open(g.id)
						#if os(iOS)
						model.reveal = g.id
						#endif
						finish()
					} label: {
						HStack(spacing: Rows.gap) {
							GroupFace(conversation: g, size: Rows.personFace)
							VStack(alignment: .leading, spacing: 2) {
								Text(model.title(g)).font(Theme.font.weight(.medium)).lineLimit(1)
								Text("\(g.members.count) people").font(Theme.smallFont).foregroundStyle(tones.secondary)
							}
							Spacer(minLength: 8)
						}
						.frame(minHeight: Rows.person)
						.contentShape(Rectangle())
					}
					.buttonStyle(RowStyle())
				}
			}
		}
	}

	@ViewBuilder private func danger(friend: Contact?, member: Member?, me: Bool, name: String) -> some View {
		if !me, let conv, let c = model.conversation(conv), c.kind == .chat, !c.isDirect, c.admins.contains(model.me.user), member != nil {
			DangerCard(symbol: "person.badge.minus", title: "Remove from \(model.title(c))", question: "Remove \(name)?",
				detail: "They'll stop getting new messages here.", answer: "Remove") {
				model.attempt { try model.core.removeMember(conv, user) }
				finish()
			}
		}
		if !me, friend != nil {
			DangerCard(symbol: "person.crop.circle.badge.xmark", title: "Remove friend", question: "Remove \(name)?",
				detail: "You'll stop being friends. Your chat leaves your list.", answer: "Remove") {
				model.unfriend(user)
				finish()
			}
		}
	}
}

/// Adding people to a group chat or a space: every friend not in it yet, a tick each, a search
/// once there are many, and the button that adds them pinned at the bottom.
struct AddPeopleSheet: View {
	@Environment(\.tones) private var tones
	@Environment(AppModel.self) private var model
	@Environment(\.dismiss) private var dismiss
	let conv: ConversationId
	/// Pushed in a chat's details (the bar has the way back), not a sheet of its own.
	var pushed = false
	@State private var picked: Set<UserId> = []

	var body: some View {
		let c = model.conversation(conv)
		let candidates = model.contacts.filter { k in !(c?.members.contains(k.user) ?? true) }
		VStack(spacing: 0) {
			if !pushed { SheetHeader(title: "Add people") }
			ScrollView {
				if candidates.isEmpty {
					VStack(spacing: 8) {
						Image(systemName: "person.2").font(.system(size: 32, weight: .medium)).foregroundStyle(tones.secondary)
						Text(model.contacts.isEmpty ? "Add a friend first" : "Everyone's here").font(Theme.headingFont)
						Text(model.contacts.isEmpty ? "People join a group from your friends." : "All your friends are already in \(c.map(model.title) ?? "it").")
							.font(Theme.font).foregroundStyle(tones.secondary).multilineTextAlignment(.center)
					}
					.frame(maxWidth: .infinity).padding(.top, 64).padding(.horizontal, Space.side)
				} else {
					PeoplePicker(people: candidates, picked: $picked,
						footer: c?.kind == .space ? "Joining a space makes them friends with everyone in it." : "Only friends can be added. Everyone in \(c.map(model.title) ?? "the group") will see who joined.")
						.padding(.vertical, Space.title)
				}
			}
			#if os(iOS)
			.scrollDismissesKeyboard(.immediately)
			#endif
			if !candidates.isEmpty {
				SheetFooter {
					Button {
						for u in picked { model.attempt { try model.core.addMember(conv, u) } }
						model.refreshAll(); dismiss()
					} label: {
						Text(picked.isEmpty ? "Add" : "Add \(picked.count == 1 ? "1 person" : "\(picked.count) people")")
							#if os(iOS)
							.frame(maxWidth: .infinity)
							#endif
					}
					.keyboardShortcut(.defaultAction).buttonStyle(Quiet(strong: true, large: true)).disabled(picked.isEmpty)
				}
			}
		}
		.background(tones.surface.ignoresSafeArea())
		#if os(macOS)
		.frame(width: 420, height: 520)
		#else
		.navigationTitle(pushed ? "Add people" : "")
		.navigationBarTitleDisplayMode(.inline)
		#endif
	}
}
