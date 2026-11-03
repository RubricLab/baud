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
			PersonSections(user: user, conv: conv)
				.padding(.horizontal, Space.side).padding(.vertical, Space.section)
		}
		.background(tones.surface.ignoresSafeArea())
		#if os(iOS)
		.navigationBarTitleDisplayMode(.inline)
		#endif
	}
}

/// A person's sections, top to bottom: their face and name (a tap gives them a nickname only I
/// see), round tiles for what to do (Message or, in our chat, Video, Call, Mute, Search), one card of
/// our chat's settings and who they are (disappearing messages, nickname, notifications, media,
/// links and files, the safety number, their label in the group it was opened from), the groups we
/// share with "Add to a group" first, their devices and how each is reached, and last, ending it.
struct PersonSections: View {
	@Environment(\.tones) private var tones
	@Environment(AppModel.self) private var model
	@Environment(\.dismiss) private var dismiss
	let user: UserId
	var conv: ConversationId? = nil
	/// Shown as this person's own chat's details: no Message (it's open), and `done` closes the pane.
	var inChat = false
	var done: (() -> Void)? = nil
	@State private var verifying: Contact?
	@State private var naming = false
	@State private var labelling = false
	@State private var draft = ""
	@State private var searching = false
	@State private var media = false
	@State private var grouping = false

	var body: some View {
		let friend = model.contacts.first { $0.user == user }
		let member = conv.flatMap { c in model.core.members(c).first { $0.user == user } }
		let me = user == model.me.user
		let devices = me ? model.me.devices : friend?.devices ?? member?.devices ?? []
		let name = me ? model.me.name : model.name(of: user)
		let card = friend?.name ?? member?.name
		// Our chat: the one open, or the one we have.
		let dm = inChat ? conv : model.chat(with: user)?.id
		let group = conv.flatMap(model.conversation).flatMap { $0.kind == .chat && !$0.isDirect ? $0 : nil }
		VStack(alignment: .leading, spacing: Space.section) {
			hero(name: name, card: card, friend: friend, member: member, me: me, devices: devices)
			if let friend, !me { tiles(friend, dm: dm) }
			if !me { settings(friend: friend, member: member, name: name, dm: dm, group: group) }
			if me, let group { labelCard(group, member: member, me: true) }
			if !me { shared(name: name, friend: friend) }
			devicesCard(devices, member: member, me: me)
			danger(friend: friend, member: member, me: me, name: name)
		}
		.sheet(item: $verifying) { VerifySheet(contact: $0) }
		.sheet(isPresented: $searching) { if let dm { ChatSearch(conv: dm, done: { finish() }).environment(model).environment(\.tones, tones) } }
		.sheet(isPresented: $media) { if let dm { MediaPage(conv: dm, done: { finish() }).environment(model).environment(\.tones, tones) } }
		.sheet(isPresented: $grouping) { AddToGroup(user: user).environment(model).environment(\.tones, tones) }
		.alert("Nickname for \(card ?? name)", isPresented: $naming) {
			TextField("Nickname", text: $draft)
			Button("Save") { model.setNickname(user, draft) }
			if model.nickname(user) != nil { Button("Remove nickname", role: .destructive) { model.setNickname(user, nil) } }
			Button("Cancel", role: .cancel) {}
		} message: { Text("Only you see it, on all your devices.") }
		.alert(group.map { "Label in \(model.title($0))" } ?? "Label", isPresented: $labelling) {
			TextField("organiser, plus one…", text: $draft)
			Button("Save") { if let g = group { model.setLabel(g.id, user, String(draft.prefix(24))) } }
			if member?.label != nil { Button("Remove label", role: .destructive) { if let g = group { model.setLabel(g.id, user, nil) } } }
			Button("Cancel", role: .cancel) {}
		} message: { Text("Everyone in the group sees it beside \(me ? "your" : "their") name.") }
	}

	private func finish() { if let done { done() } else { dismiss() } }

	// MARK: pieces

	private func hero(name: String, card: String?, friend: Contact?, member: Member?, me: Bool, devices: [Device]) -> some View {
		let verified = friend?.verified ?? member?.verified ?? false
		let avatar = me ? model.me.avatar : friend?.avatar
		let nick = me ? nil : model.nickname(user)
		return VStack(spacing: 6) {
			Avatar(name: name, hash: avatar, size: Hero.face, presence: me || devices.isEmpty ? nil : Mark.presence(devices))
			Button { if !me { draft = nick ?? ""; naming = true } } label: {
				HStack(spacing: 6) {
					Text(name).font(Theme.titleFont).lineLimit(2).multilineTextAlignment(.center).foregroundStyle(tones.text)
					if verified { MarkView(mark: .verified, size: Theme.title * 0.8, color: tones.text).accessibilityLabel("Verified") }
				}
			}
			.buttonStyle(.plain).disabled(me)
			.help(me ? "" : "Give \(card ?? name) a nickname")
			.accessibilityHint(me ? "" : "Gives them a nickname only you see")
			if let nick, let card, nick != card { Text("Calls themself \(card)").font(Theme.smallFont).foregroundStyle(tones.secondary) }
			Text(subtitle(friend: friend, member: member, me: me, devices: devices)).font(Theme.smallFont).foregroundStyle(tones.secondary).multilineTextAlignment(.center)
		}
		.frame(maxWidth: .infinity)
		.padding(.top, 4)
	}

	private func subtitle(friend: Contact?, member: Member?, me: Bool, devices: [Device]) -> String {
		if me { return "You" }
		let presence = presenceWord(devices)
		if friend != nil { return "Friend · \(presence)" }
		let through = member.flatMap { m in conv.map { model.through(m, in: $0) } } ?? []
		return through.isEmpty ? "Not your friend" : "Not your friend · reached through \(list(through))"
	}

	/// The round tiles: what a person is for, a tap each.
	@ViewBuilder private func tiles(_ f: Contact, dm: ConversationId?) -> some View {
		HStack(spacing: 8) {
			if !inChat { RoundTile(symbol: "bubble.left", title: "Message") { model.message(f.user); finish() } }
			RoundTile(symbol: "video", title: "Video") { model.call(f.user, video: true) }
			RoundTile(symbol: "phone", title: "Call") { model.call(f.user, video: false) }
			if let dm {
				let muted = model.muted(dm) != nil
				Menu {
					if muted { Button { model.unmute(dm) } label: { Label("Unmute", systemImage: "bell") } }
					else { ForEach(MuteMenu.choices, id: \.0) { t, s in Button(t) { model.mute(dm, for: s) } } }
				} label: { RoundTileFace(symbol: muted ? "bell.slash.fill" : "bell.slash", title: muted ? "Muted" : "Mute", on: muted) }
				.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
				.accessibilityLabel(muted ? "Muted" : "Mute")
				if inChat { RoundTile(symbol: "magnifyingglass", title: "Search") { searching = true } }
			}
		}
	}

	/// Our chat's settings and who they are to me, in one card.
	@ViewBuilder private func settings(friend: Contact?, member: Member?, name: String, dm: ConversationId?, group: Conversation?) -> some View {
		let verified = friend?.verified ?? member?.verified ?? false
		let first = name.split(separator: " ").first.map(String.init) ?? name
		ListCard {
			if let dm, let c = model.conversation(dm) { DisappearPicker(conversation: c).cardRow() }
			Button { draft = model.nickname(user) ?? ""; naming = true } label: {
				ActionRow(symbol: "pencil", title: "Nickname", value: model.nickname(user) ?? "None")
			}
			.buttonStyle(RowStyle())
			if let dm {
				Menu {
					if model.muted(dm) != nil { Button { model.unmute(dm) } label: { Label("Unmute", systemImage: "bell") } }
					else { ForEach(MuteMenu.choices, id: \.0) { t, s in Button(t) { model.mute(dm, for: s) } } }
				} label: { ActionRow(symbol: "bell", title: "Notifications", value: muteWords(dm)).cardRow() }
				.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
				Button { media = true } label: { ActionRow(symbol: "photo.on.rectangle", title: "Media, links and files") }.buttonStyle(RowStyle())
			}
			if verified {
				ActionRow(symbol: "checkmark.shield", title: "Safety number", value: "Verified").cardRow()
			} else if let friend {
				Button { verifying = friend } label: { ActionRow(symbol: "shield", title: "Safety number", value: "Verify \(first)") }.buttonStyle(RowStyle())
			} else {
				ActionRow(symbol: "shield", title: "Safety number", value: friend?.vouched == true ? "Vouched for" : "Not verified").cardRow()
			}
			if let group { labelRow(group, member: member, me: false) }
		}
	}

	private func muteWords(_ id: ConversationId) -> String {
		guard let until = model.muted(id) else { return "On" }
		return until == .distantFuture ? "Muted" : "Muted until \(Calendar.current.isDateInToday(until) ? clock(until) : whenShort(until))"
	}

	/// Their label in the group it was opened from: theirs to change, or an admin's.
	@ViewBuilder private func labelRow(_ g: Conversation, member: Member?, me: Bool) -> some View {
		let can = me || g.admins.contains(model.me.user)
		let row = ActionRow(symbol: "tag", title: "Label in \(model.title(g))", value: member?.label ?? (can ? "Add" : "None"))
		if can { Button { draft = member?.label ?? ""; labelling = true } label: { row }.buttonStyle(RowStyle()) }
		else { row.cardRow() }
	}
	private func labelCard(_ g: Conversation, member: Member?, me: Bool) -> some View {
		ListCard(footer: "Everyone in \(model.title(g)) sees it beside your name.") { labelRow(g, member: member, me: me) }
	}

	@ViewBuilder private func devicesCard(_ devices: [Device], member: Member?, me: Bool) -> some View {
		ListCard(title: devices.count == 1 ? "Device" : "Devices", footer: devices.isEmpty ? "Their devices aren't shared with you: only friends see each other's addresses." : nil) {
			ForEach(devices) { d in DeviceRow(d: d, this: d.id == model.me.thisDevice).cardRow() }
		}
	}

	/// The groups we're both in (besides this one), "Add to a group" first: a tap opens one.
	@ViewBuilder private func shared(name: String, friend: Contact?) -> some View {
		let groups = model.conversations.filter { $0.kind == .chat && !$0.isDirect && $0.id != conv && $0.members.contains(user) && $0.members.contains(model.me.user) }
		if friend != nil || !groups.isEmpty {
			ListCard(title: groups.count == 1 ? "1 group in common" : "\(groups.count) groups in common") {
				if friend != nil { Button { grouping = true } label: { ActionRow(symbol: "person.2.badge.plus", title: "Add to a group") }.buttonStyle(RowStyle()) }
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

/// A round tile: a glyph in a disc over its word, for the few things a page is for.
struct RoundTile: View {
	let symbol: String
	let title: String
	var on = false
	let action: () -> Void
	var body: some View {
		Button(action: action) { RoundTileFace(symbol: symbol, title: title, on: on) }
			.buttonStyle(.plain).accessibilityLabel(title)
	}
}
struct RoundTileFace: View {
	@Environment(\.tones) private var tones
	let symbol: String
	let title: String
	var on = false
	#if os(macOS)
	static let disc: CGFloat = 40
	#else
	static let disc: CGFloat = 52
	#endif
	var body: some View {
		VStack(spacing: 6) {
			Image(systemName: symbol).font(Icon.font(Icon.bar))
				.foregroundStyle(on ? tones.onLoud : tones.text)
				.frame(width: Self.disc, height: Self.disc)
				.background(Circle().fill(on ? tones.loud : tones.card).lifted(tones))
			Text(title).font(Theme.smallFont.weight(.medium)).foregroundStyle(tones.text)
		}
		.frame(maxWidth: .infinity)
		.contentShape(Rectangle())
	}
}

/// Opening a message where it is in its chat: the chat, the pages over it closed, the message in view.
@MainActor func jump(_ model: AppModel, to e: Event, then close: () -> Void) {
	model.open(e.conv)
	#if os(iOS)
	model.reveal = e.conv
	#endif
	close()
	Task { try? await Task.sleep(for: .milliseconds(500)); Bench.scrollTo?(e.id, .center) }
}

/// Searching one chat: its messages that match, newest first; one opens where it is.
struct ChatSearch: View {
	@Environment(\.tones) private var tones
	@Environment(AppModel.self) private var model
	@Environment(\.dismiss) private var dismiss
	let conv: ConversationId
	var done: () -> Void = {}
	@State private var query = ""
	@FocusState private var focused: Bool
	var body: some View {
		let q = query.trimmingCharacters(in: .whitespaces)
		let hits = q.count >= 2 ? model.core.search(q, scope: SearchScope(conversation: conv)) : []
		VStack(spacing: 0) {
			SheetHeader(title: "Search in \(model.conversation(conv).map(model.title) ?? "this chat")")
			ScrollView {
				VStack(alignment: .leading, spacing: Space.title) {
					SearchBox(text: $query, prompt: "Search messages", focus: $focused).padding(.horizontal, Rows.inset)
					VStack(spacing: 0) {
						ForEach(hits) { h in
							Button { jump(model, to: h.event) { dismiss(); done() } } label: {
								VStack(alignment: .leading, spacing: 2) {
									Text("\(model.name(of: h.event.user)): \(h.snippet)").font(Theme.font).lineLimit(2)
									Text(whenShort(h.event.at)).font(Theme.smallFont).foregroundStyle(tones.secondary)
								}
								.frame(maxWidth: .infinity, minHeight: Rows.person, alignment: .leading)
							}
							.buttonStyle(RowStyle())
						}
						if q.count >= 2, hits.isEmpty { EmptyLine(text: "Nothing in this chat says “\(q)”.").padding(.top, 8) }
					}
				}
				.padding(.vertical, Space.title)
			}
		}
		.background(tones.surface.ignoresSafeArea())
		.onAppear { focused = true }
		#if os(macOS)
		.frame(width: 420, height: 520)
		#else
		.presentationDetents([.large]).presentationDragIndicator(.visible)
		#endif
	}
}

/// A chat's media, links and files: photos in a grid, files and links as rows, from its messages;
/// each opens where it is in the chat.
struct MediaPage: View {
	@Environment(\.tones) private var tones
	@Environment(AppModel.self) private var model
	@Environment(\.dismiss) private var dismiss
	let conv: ConversationId
	var done: () -> Void = {}
	@State private var events: [Event] = []
	var body: some View {
		let photos = events.flatMap { e in e.attachments.filter(\.isImage).map { (e, $0) } }
		let files = events.flatMap { e in e.attachments.filter { !$0.isImage }.map { (e, $0) } }
		let linksFound = events.flatMap { e -> [(Event, String)] in guard let t = e.text, PlaceText.parse(t) == nil else { return [] }; return links(in: t).map { (e, String(t[$0])) } }
		VStack(spacing: 0) {
			SheetHeader(title: "Media, links and files")
			ScrollView {
				VStack(alignment: .leading, spacing: Space.section) {
					if !photos.isEmpty {
						VStack(alignment: .leading, spacing: Space.title) {
							SectionTitle("Photos")
							LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 4)], spacing: 4) {
								ForEach(Array(photos.enumerated()), id: \.offset) { _, p in
									Button { go(p.0) } label: {
										AttachmentBlock(attachment: p.1).allowsHitTesting(false)
											.frame(height: 96).frame(maxWidth: .infinity).clipped()
											.clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
									}
									.buttonStyle(.plain)
								}
							}
						}
					}
					if !files.isEmpty {
						ListCard(title: "Files") {
							ForEach(Array(files.enumerated()), id: \.offset) { _, f in
								Button { go(f.0) } label: { ActionRow(symbol: "doc", title: f.1.name ?? "File", value: bytesText(f.1.size)) }.buttonStyle(RowStyle())
							}
						}
					}
					if !linksFound.isEmpty {
						ListCard(title: "Links") {
							ForEach(Array(linksFound.enumerated()), id: \.offset) { _, l in
								Button { go(l.0) } label: { ActionRow(symbol: "link", title: URL(string: l.1)?.host ?? l.1, value: whenShort(l.0.at)) }.buttonStyle(RowStyle())
							}
						}
					}
					if photos.isEmpty && files.isEmpty && linksFound.isEmpty {
						EmptyLine(text: "Photos, files and links sent in this chat show up here.").padding(.top, 24)
					}
				}
				.padding(.horizontal, Space.side).padding(.vertical, Space.section)
			}
		}
		.background(tones.surface.ignoresSafeArea())
		.task { events = model.core.events(conv, before: nil, limit: 5000).reversed() }
		#if os(macOS)
		.frame(width: 480, height: 560)
		#else
		.presentationDetents([.large]).presentationDragIndicator(.visible)
		#endif
	}
	private func go(_ e: Event) { jump(model, to: e) { dismiss(); done() } }
}

/// Adding a friend to one of my groups they aren't in yet.
struct AddToGroup: View {
	@Environment(\.tones) private var tones
	@Environment(AppModel.self) private var model
	@Environment(\.dismiss) private var dismiss
	let user: UserId
	var body: some View {
		let groups = model.conversations.filter { $0.kind == .chat && !$0.isDirect && $0.members.contains(model.me.user) && !$0.members.contains(user) }
		VStack(spacing: 0) {
			SheetHeader(title: "Add \(model.name(of: user)) to a group")
			ScrollView {
				VStack(spacing: 0) {
					ForEach(groups) { g in
						Button {
							model.attempt { try model.core.addMember(g.id, user) }
							model.refreshAll(); dismiss()
						} label: {
							HStack(spacing: Rows.gap) {
								GroupFace(conversation: g, size: Rows.personFace)
								VStack(alignment: .leading, spacing: 2) {
									Text(model.title(g)).font(Theme.font.weight(.medium)).lineLimit(1)
									Text("\(g.members.count) people").font(Theme.smallFont).foregroundStyle(tones.secondary)
								}
								Spacer(minLength: 8)
							}
							.frame(minHeight: Rows.person).contentShape(Rectangle())
						}
						.buttonStyle(RowStyle())
					}
					if groups.isEmpty { EmptyLine(text: "They're in every group you're in.").padding(.top, 16) }
				}
				.padding(.vertical, Space.title)
			}
		}
		.background(tones.surface.ignoresSafeArea())
		#if os(macOS)
		.frame(width: 400, height: 440)
		#else
		.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
		#endif
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
