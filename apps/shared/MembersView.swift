/// The people of a conversation: who is here, how each is reached (a friend, or through the friends
/// we share), whether anyone I trust has checked them, and each of their devices with its light.
/// Name, topic and the actions (add someone, leave) under them.
import BaudCore
import SwiftUI

struct MembersView: View {
	@Environment(\.tones) private var tones
	@Environment(AppModel.self) private var model
	let conv: ConversationId
	var close: (() -> Void)? = nil
	@State private var name = ""
	@State private var topic = ""
	@State private var person: Member?

	var body: some View {
		if let c = model.conversation(conv) {
			let members = model.core.members(conv).sorted { a, b in a.me != b.me ? a.me : (a.online != b.online ? a.online : a.name < b.name) }
			let strangers = members.filter { !$0.me && !model.isFriend($0.user) }
			VStack(spacing: 0) {
				HStack(spacing: 6) {
					Text("People").font(Theme.headingFont)
					Text("\(members.count)").font(Theme.font).foregroundStyle(tones.secondary).monospacedDigit()
					Spacer()
					if let close { IconButton(symbol: "xmark", help: "Close (⌘I)", size: 11, action: close) }
				}
				.padding(.horizontal, 16)
				#if os(macOS)
				.frame(height: Theme.header + 4).padding(.top, 0)
				#else
				.frame(height: 52)
				#endif
				.overlay(alignment: .bottom) { Hairline() }
				ScrollView {
					VStack(alignment: .leading, spacing: 0) {
						ForEach(members) { m in
							Button { person = m } label: { MemberRow(m: m, conv: conv) }
								.buttonStyle(RowStyle())
								.popover(isPresented: Binding(get: { person?.id == m.id }, set: { if !$0 { person = nil } })) { PersonCard(m: m, conv: conv) }
								.contextMenu {
									if c.admins.contains(model.me.user) && !m.me { Button("Remove from \(model.title(c))", role: .destructive) { model.attempt { try model.core.removeMember(conv, m.user) } } }
									if !m.me && model.isFriend(m.user) { Button("Message \(m.name)") { model.message(m.user) } }
								}
						}
						if c.kind == .channel || (c.kind == .chat && !c.isDirect) {
							SectionHeading(title: "About")
							VStack(alignment: .leading, spacing: 6) {
								Field(placeholder: "Name", text: $name) { model.attempt { try model.core.setName(conv, name) } }
								if c.kind == .channel { Field(placeholder: "Topic", text: $topic) { model.attempt { try model.core.setTopic(conv, topic) } } }
							}
							.padding(.horizontal, Rows.inset + Rows.pad - 6)
						}
						let canAdd = (c.kind == .chat && !c.isDirect) || c.admins.contains(model.me.user)
						HStack(spacing: 8) {
							if canAdd && c.kind != .channel { Button("Add someone") { model.addingTo = c.id }.buttonStyle(Quiet()) }
							if !c.isDirect && c.kind == .chat { Button("Leave") { model.attempt { try model.core.leave(conv); model.open(nil) } }.buttonStyle(Quiet(danger: true)) }
						}
						.padding(.horizontal, Rows.inset + Rows.pad).padding(.top, Theme.sectionGap)
					}
					.padding(.vertical, 6)
				}
			}
			.onAppear { name = c.name ?? ""; topic = c.topic ?? "" }
			.onChange(of: conv) { _, _ in name = model.conversation(conv)?.name ?? ""; topic = model.conversation(conv)?.topic ?? "" }
		}
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
					Text(m.me ? "\(model.me.name) (you)" : model.name(of: m.user)).font(Theme.font.weight(.medium)).lineLimit(1)
					IdentityMark(member: m)
					if m.admin { Text("admin").font(Theme.smallFont).foregroundStyle(tones.secondary) }
				}
				HStack(spacing: 4) {
					if !through.isEmpty { MarkView(mark: .relayed, size: Theme.small + 1, color: tones.secondary) }
					Text(m.me ? "you" : !through.isEmpty ? "through \(list(through))" : model.isFriend(m.user) ? "friend · \(presenceWord(m.devices))" : presenceWord(m.devices))
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
				.foregroundStyle(!enabled ? tones.tertiary : strong ? tones.onLoud : tones.text)
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
				.overlay { if danger { Capsule().strokeBorder(tones.text, lineWidth: 1.5) } }
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
			Text("Add someone to \(c.map(model.title) ?? "")").font(Theme.headingFont)
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
