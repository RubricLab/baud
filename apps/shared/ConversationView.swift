/// A conversation: the header with its honest status line, the timeline, the composer, and the
/// thread beside it on the Mac or pushed on the iPhone. Chats and channels share all of it.
import BaudCore
import SwiftUI

struct ConversationView: View {
	@Environment(\.tones) private var tones
	@Environment(AppModel.self) private var model
	let conv: ConversationId
	@Binding var showMembers: Bool
	@State private var reply: Event?
	@State private var thread: Event?

	var body: some View {
		let timeline = model.timeline(conv)
		if let c = model.conversation(conv) {
			HStack(spacing: 0) {
				VStack(spacing: 0) {
					Header(conversation: c, showMembers: $showMembers)
					LiveBar(conv: conv)
					TimelineView(timeline: timeline, onReply: { reply = $0 }, onThread: { thread = $0 })
					ComposerView(conv: conv, reply: $reply)
				}
				// Files dropped anywhere on the conversation go into the composer, to send.
				.onDrop(of: [.fileURL], isTargeted: Binding(get: { model.dropOver == conv }, set: { model.dropOver = $0 ? conv : (model.dropOver == conv ? nil : model.dropOver) })) { providers in
					for p in providers {
						_ = p.loadObject(ofClass: URL.self) { url, _ in
							guard let url else { return }
							_ = url.startAccessingSecurityScopedResource()
							Task { @MainActor in model.dropped[conv, default: []].append(url) }
						}
					}
					return !providers.isEmpty
				}
				.overlay { if model.dropOver == conv { DropHint(to: model.title(c)) } }
				#if os(macOS)
				if let t = thread {
					Rectangle().fill(tones.hairline).frame(width: 1)
					ThreadView(conv: conv, root: t, close: { thread = nil }).frame(width: 340)
				}
				#endif
			}
			#if os(iOS)
			.navigationDestination(item: $thread) { t in ThreadView(conv: conv, root: t, close: { thread = nil }) }
			.navigationBarTitleDisplayMode(.inline)
			.toolbar(.hidden, for: .navigationBar)
			#endif
			.onChange(of: conv) { _, _ in reply = nil; thread = nil }
			.onChange(of: model.openThread) { _, id in if let id, let e = timeline.byId[id] { thread = e; model.openThread = nil } }
		} else {
			ContentUnavailableView("Pick a conversation", systemImage: "bubble.left.and.bubble.right")
		}
	}
}

/// Who it is and how they're reached: their face, the name, and the status sentence ("Online ·
/// direct, 14 ms", "Last online 2 h ago"); the calls and the details at the end. On the iPhone the
/// one back comes first, then a gap nothing answers to, then the face and the name, which open the
/// details: a thumb meant for one never lands on the other. On the Mac it fills the window's top
/// band, level with the thread's and the details' headers beside it.
struct Header: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	let conversation: Conversation
	@Binding var showMembers: Bool
	@Environment(\.dismiss) private var dismiss
	/// The face before the name; the space between the actions at the end.
	#if os(macOS)
	static let face: CGFloat = 24, actions: CGFloat = 4
	#else
	static let face: CGFloat = 32, actions: CGFloat = 0
	#endif

	var body: some View {
		let members = model.core.members(conversation.id)
		let others = members.filter { !$0.me }
		// My chat with myself calls my other devices.
		let own = conversation.kind == .home
		let live = own ? model.me.devices.contains { $0.online && $0.id != model.me.thisDevice } : others.contains { $0.online }
		// Asleep, but woken by a ring: a sleeping iPhone I hold a wake ticket for can be called.
		let wakeable = (own ? model.me.devices.filter { $0.id != model.me.thisDevice } : others.flatMap(\.devices)).contains { model.local.canWake($0.id) }
		let reachable = live || wakeable
		HStack(spacing: 0) {
			#if os(iOS)
			BackButton { dismiss() }
			// Dead space: a touch between back and the name does nothing.
			Color.clear.frame(width: 12, height: 1).allowsHitTesting(false)
			#endif
			HStack(spacing: Rows.gap) {
				face(others)
				VStack(alignment: .leading, spacing: 1) {
					HStack(alignment: .firstTextBaseline, spacing: 6) {
						Text(model.title(conversation)).font(Theme.headingFont).foregroundStyle(tones.heading).lineLimit(1)
						if conversation.disappear > 0 { DisappearMark(seconds: conversation.disappear) }
						#if os(macOS)
						if let t = conversation.topic, !t.isEmpty { Text(t).font(Theme.smallFont).foregroundStyle(tones.secondary).lineLimit(1) }
						#endif
					}
					HStack(spacing: 4) {
						if let s = conversation.space.flatMap(model.conversation) {
							Text(s.name ?? "").font(Theme.smallFont.weight(.semibold)).foregroundStyle(tones.secondary)
							Text("·").font(Theme.smallFont).foregroundStyle(tones.secondary)
						}
						Text(model.status(conversation)).font(Theme.smallFont).foregroundStyle(live ? tones.text : tones.secondary).lineLimit(1)
							.minimumScaleFactor(0.85)
							.contentTransition(.opacity)
					}
				}
			}
			// The face and the name open the chat's details, as the button at the end does.
			.contentShape(Rectangle())
			.onTapGesture { showMembers.toggle() }
			.help("Details (⌘I)")
			.accessibilityElement(children: .combine)
			.accessibilityAddTraits(.isButton)
			.accessibilityHint("Shows the chat's details")
			Spacer(minLength: 8)
			HStack(spacing: Self.actions) {
			// Calls: two people, or a group of up to eight. A call already going on in the chat shows
			// who's in it and a way in instead.
			if model.calls.callable(conversation.id) {
				let busy = model.calls.session != nil
				if let p = model.calls.ongoing[conversation.id], model.calls.session?.id != p.id {
					CallInProgress(presence: p, conv: conversation.id)
				} else {
					let who = own ? "your other devices" : conversation.isDirect ? others.first.map { $0.name.split(separator: " ").first.map(String.init) ?? $0.name } ?? "" : "everyone"
					let away = own ? "Your other devices aren't online" : conversation.isDirect ? "\(who) isn't online" : "Nobody here is online"
					IconButton(symbol: "phone", help: reachable ? "Call \(who)" : away, size: Icon.bar) { model.calls.start(conversation.id, video: false) }
						.disabled(busy || !reachable)
					IconButton(symbol: "video", help: reachable ? "Video call \(who)" : away, size: Icon.bar) { model.calls.start(conversation.id, video: true) }
						.disabled(busy || !reachable)
				}
			}
			// One other person's details; a group's people and how many.
			Button { showMembers.toggle() } label: {
				HStack(spacing: 4) {
					if conversation.isDirect || own { Image(systemName: "info.circle").font(Icon.font(Icon.bar)) }
					else { Image(systemName: "person.2").font(Icon.font(Icon.row)); Text("\(conversation.members.count)").font(Theme.smallFont.weight(.semibold)).monospacedDigit() }
				}
				.padding(.horizontal, conversation.isDirect || own ? 4 : 8).frame(height: 24)
				#if os(iOS)
				.frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
				#endif
			}
			.buttonStyle(Pill(on: showMembers)).help(conversation.isDirect || own ? "Details (⌘I)" : "People (⌘I)")
			.accessibilityLabel(conversation.isDirect || own ? "Details" : "\(conversation.members.count) people")
			}
		}
		#if os(macOS)
		.padding(.horizontal, Space.side)
		.frame(height: Theme.header)
		.background(tones.surface.contentShape(Rectangle()).modifier(DragsWindow()))
		#else
		.padding(.leading, 8).padding(.trailing, 4)
		.frame(minHeight: Theme.header)
		.background(tones.surface.ignoresSafeArea(edges: .top))
		#endif
		.overlay(alignment: .bottom) { Hairline() }
		.animation(Motion.standard, value: live)
	}

	/// Their face (its light when they're online), the group's faces, mine for my own chat, a
	/// channel's space.
	@ViewBuilder private func face(_ others: [Member]) -> some View {
		let c = conversation
		if c.kind == .home { Avatar(name: model.me.name, hash: model.me.avatar, size: Self.face) }
		else if c.kind == .chat && !c.isDirect { GroupFace(conversation: c, size: Self.face) }
		else if c.kind == .channel { SpaceTile(name: c.space.flatMap(model.conversation)?.name ?? c.name ?? "", size: Self.face) }
		else if let o = others.first {
			Avatar(name: model.title(c), hash: model.contacts.first { $0.user == o.user }?.avatar, size: Self.face, presence: Mark.presence(o.devices))
		}
	}
}

/// Over a conversation while files are dragged onto it: where they'll go.
struct DropHint: View {
	@Environment(\.tones) private var tones
	let to: String
	var body: some View {
		RoundedRectangle(cornerRadius: 18, style: .continuous)
			.strokeBorder(tones.text, style: StrokeStyle(lineWidth: 2.5, dash: [8, 6]))
			.background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(tones.surface.opacity(0.85)))
			.overlay {
				VStack(spacing: 10) {
					Image(systemName: "arrow.down.doc.fill").font(.system(size: 30, weight: .bold))
					Text("Drop to send to \(to)").font(Theme.headingFont)
				}
				.foregroundStyle(tones.text)
			}
			.padding(12)
			.allowsHitTesting(false)
			.transition(.opacity)
	}
}

/// A call going on in this chat that I'm not in: who's in it, and Join. If I'm in it on another
/// device of mine, it says so instead.
struct CallInProgress: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	let presence: CallPresence
	let conv: ConversationId
	var body: some View {
		let me = model.me.user
		let elsewhere = presence.peers.contains { $0.user == me }
		let names = presence.peers.filter { $0.user != me }.map { $0.name.split(separator: " ").first.map(String.init) ?? $0.name }
		HStack(spacing: 7) {
			Circle().fill(CallInk.accept).frame(width: 7, height: 7)
			Text(elsewhere ? "In a call on your other device" : "Call in progress · \(list(names))").font(Theme.smallFont).lineLimit(1)
			if !elsewhere {
				Button { model.calls.join(conv) } label: {
					Text("Join").font(Theme.smallFont.weight(.semibold)).foregroundStyle(.white)
						.padding(.horizontal, 11).frame(height: 22).background(Capsule().fill(CallInk.accept))
				}
				.buttonStyle(.plain).disabled(model.calls.session != nil)
				.help(presence.video ? "Join the video call" : "Join the call")
			}
		}
		.padding(.leading, 10).padding(.trailing, elsewhere ? 10 : 3).frame(height: 28)
		.background(Capsule().fill(tones.raised)).overlay(Capsule().stroke(tones.hairline))
		.accessibilityElement(children: .combine)
	}
}

/// A thread: the root, its replies, a composer that writes into it.
struct ThreadView: View {
	@Environment(\.tones) private var tones
	@Environment(AppModel.self) private var model
	let conv: ConversationId
	let root: Event
	var close: () -> Void
	@State private var reply: Event?
	@State private var events: [Event] = []

	var body: some View {
		VStack(spacing: 0) {
			HStack {
				Text("Thread").font(Theme.headingFont)
				Spacer()
				#if os(macOS)
				IconButton(symbol: "xmark", help: "Close the thread (⎋)", size: 11) { close() }.keyboardShortcut(.escape, modifiers: [])
				#endif
			}
			#if os(macOS)
			.padding(.horizontal, 16).frame(height: Theme.header).overlay(alignment: .bottom) { Hairline() }
			#else
			.padding(.horizontal, 16).frame(minHeight: Theme.row + 16).overlay(alignment: .bottom) { Hairline() }
			#endif
			List {
				ForEach(Array(events.enumerated()), id: \.element.id) { i, e in
					MessageRow(event: e, first: i == 0 || events[i - 1].user != e.user, last: true, onReply: { reply = $0 }, onThread: { _ in })
					if i == 0 { Hairline().listRowSeparator(.hidden).listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16)) }
				}
			}
			.listStyle(.plain).scrollContentBackground(.hidden).environment(\.defaultMinListRowHeight, 1)
			ComposerView(conv: conv, thread: root.id, reply: $reply)
		}
		.task(id: root.id) { load() }
		.onChange(of: model.timeline(conv).events.count) { _, _ in load() }
		.onChange(of: model.timeline(conv).rows.count) { _, _ in load() }
	}
	private func load() { events = model.core.thread(conv, root.id, before: nil, limit: 500) }
}

#if os(macOS)
/// Drag the window by the header band; the gesture exists from macOS 15, so below it the band is
/// plain (the floor is 14 for a friend's older Mac).
struct DragsWindow: ViewModifier {
	func body(content: Content) -> some View {
		if #available(macOS 15, *) { content.gesture(WindowDragGesture()) } else { content }
	}
}
#endif
