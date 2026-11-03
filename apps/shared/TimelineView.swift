/// The conversation: a plain list of precomputed rows, anchored at the bottom, paging up. The
/// same cells on the Mac and the iPhone. Grouping, day lines and the delivery sentence come
/// from `Timeline`; this file only draws.
import BaudCore
import ImageIO
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// How far the iPhone's timeline is drawn aside to show each message's time and way.
extension EnvironmentValues { @Entry var reveal: CGFloat = 0 }

struct TimelineView: View {
	@Environment(\.tones) private var tones
	@Environment(AppModel.self) private var model
	let timeline: Timeline
	var onReply: (Event) -> Void
	var onThread: (Event) -> Void
	/// A drag to the left draws every message aside, its time and way beside it, as long as the
	/// finger stays; let go and they spring back.
	@GestureState(resetTransaction: Transaction(animation: .spring(duration: 0.35, bounce: 0.15))) private var reveal: CGFloat = 0
	static let revealWidth: CGFloat = 72
	/// `BAUD_REVEAL=72` (Debug): drawn aside as if dragged, for the pictures.
	#if DEBUG
	static let held = ProcessInfo.processInfo.environment["BAUD_REVEAL"].flatMap(Double.init).map { CGFloat($0) }
	#else
	static let held: CGFloat? = nil
	#endif

	var body: some View {
		Group {
			#if os(macOS)
			MacTimeline(timeline: timeline, onReply: onReply, onThread: onThread)
				.onAppear { timeline.markRead() }
				.onChange(of: timeline.events.count) { _, _ in timeline.markRead() }
			#else
			phone
			#endif
		}
		.onAppear { model.onScreen = timeline.conv }
		.onDisappear { if model.onScreen == timeline.conv { model.onScreen = nil } }
	}

	private var phone: some View {
		ScrollViewReader { proxy in
			// The phone gets a List for its swipe actions; the Mac a lazy stack, which lays rows out
			// several times faster than NSTableView-backed List does.
			container {
				if !timeline.exhausted {
					Color.clear.frame(height: 1).listRowSeparator(.hidden).listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
						.onAppear { timeline.loadMore() }
				}
				ForEach(timeline.rows) { row in
					Group {
						switch row {
						case .day(let d):
							DayRow(date: d)
						case .event(let e, let first, let last):
							if e.type == .message {
								MessageRow(event: e, first: first, last: last, onReply: onReply, onThread: onThread)
									.id(e.id)
							} else {
								SystemRow(event: e)
							}
						}
					}
					.listRowBackground(Color.clear)
				}
				if !timeline.typing.isEmpty {
					TypingRow(names: timeline.typing).listRowBackground(Color.clear)
				}
				Color.clear.frame(height: 4).id("bottom").listRowSeparator(.hidden).listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
			}
			.defaultScrollAnchor(.bottom)
			// Scrolling back through the chat takes the keyboard down with the finger, as Messages does.
			.scrollDismissesKeyboard(.interactively)
			.environment(\.reveal, Self.held ?? reveal)
			.simultaneousGesture(
				DragGesture(minimumDistance: 14)
					.updating($reveal) { v, shown, _ in
						let dx = -v.translation.width
						// Sideways and leftwards only; once it has begun it follows the finger.
						guard dx > 0, shown > 0 || abs(v.translation.width) > abs(v.translation.height) * 1.5 else { return }
						shown = dx < Self.revealWidth ? dx : Self.revealWidth + (dx - Self.revealWidth) * 0.15
					}
			)
			.onChange(of: timeline.events.last?.id) { _, _ in
				if timeline.events.last?.mine == true { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) } }
			}
			.onAppear { timeline.markRead(); Bench.scrollTo = { id, anchor in proxy.scrollTo(id, anchor: anchor) } }
			.onChange(of: timeline.events.count) { _, _ in timeline.markRead() }
			// Open at the newest message: the List's bottom anchor alone left a long chat at its top.
			// Once laid out, and again once late rows (photos, reactions) have their heights.
			.task(id: timeline.conv) {
				for wait in [0, 300] { try? await Task.sleep(for: .milliseconds(wait)); proxy.scrollTo("bottom", anchor: .bottom) }
			}
		}
	}
}

extension TimelineView {
	@ViewBuilder func container<C: View>(@ViewBuilder _ content: () -> C) -> some View {
		List { content().listRowBackground(Color.clear) }.listStyle(.plain).scrollContentBackground(.hidden).background(Ground()).environment(\.defaultMinListRowHeight, 1)
	}
}

/// Someone typing: their bubble, three dots rising and falling in turn, and who, beside it.
struct TypingRow: View {
	@Environment(\.tones) private var tones
	@Environment(\.accessibilityReduceMotion) private var still
	let names: [String]
	var body: some View {
		HStack(spacing: 8) {
			SwiftUI.TimelineView(.animation(minimumInterval: 1 / 30, paused: still)) { ctx in
				let t = ctx.date.timeIntervalSinceReferenceDate
				HStack(spacing: 4) {
					ForEach(0..<3, id: \.self) { i in
						let phase = still ? 0 : max(0, sin((t * 2 * .pi / 1.1) - Double(i) * 0.9))
						Circle().fill(phase > 0.5 ? tones.text : tones.secondary).frame(width: 7, height: 7).offset(y: -3 * phase)
					}
				}
				.padding(.horizontal, 13).frame(height: 32)
				.background(Capsule().fill(tones.card).lifted(tones))
			}
			Text(list(names)).font(Theme.smallFont.weight(.semibold)).foregroundStyle(tones.secondary).lineLimit(1)
			Spacer(minLength: 0)
		}
		.padding(.top, 6).padding(.bottom, 4)
		.listRowSeparator(.hidden).listRowInsets(Theme.rowInsets)
		.accessibilityElement(children: .ignore)
		.accessibilityLabel("\(list(names)) \(names.count == 1 ? "is" : "are") typing")
	}
}

/// The day, centred and set in bold small type: no rules, the gap is the divider.
struct DayRow: View {
	@Environment(\.tones) private var tones
	let date: Date
	var body: some View {
		Text(dayTitle(date)).font(Theme.smallFont.weight(.bold)).foregroundStyle(tones.secondary).fixedSize()
			.frame(maxWidth: .infinity)
			.padding(.top, 14).padding(.bottom, 4)
			.listRowSeparator(.hidden).listRowInsets(Theme.rowInsets)
			.accessibilityAddTraits(.isHeader)
	}
}

struct SystemRow: View {
	@Environment(\.tones) private var tones
	let event: Event
	var body: some View {
		// Centred under the day, like it: what happened, then when, a step quieter.
		(Text(event.system ?? "").foregroundColor(tones.secondary) + Text("  " + clock(event.at)).foregroundColor(tones.tertiary))
			.font(Theme.smallFont).multilineTextAlignment(.center)
			.frame(maxWidth: .infinity).padding(.vertical, 2)
			.listRowSeparator(.hidden).listRowInsets(Theme.rowInsets)
	}
}

/// Under my newest message, on my side: its mark and its few words ("Waiting for Ana", "Carried
/// by Jo's Mac", "Delivered", "Read"). The mark springs as it changes. A typing line sits on theirs.
struct DeliveryRow: View {
	@Environment(\.tones) private var tones
	let text: String
	var mark: Mark? = nil
	var mine = true
	var body: some View {
		HStack(spacing: 5) {
			if let mark {
				MarkView(mark: mark, size: Theme.small + 1, color: mark == .read ? tones.text : tones.secondary)
					.modifier(Turning(on: mark == .sending && text == "Sending…"))
					.id(mark).transition(.scale(scale: 0.4).combined(with: .opacity))
			}
			Text(text).font(Theme.smallFont.weight(.semibold)).foregroundStyle(mark == .read ? tones.text : tones.secondary)
				.contentTransition(.opacity)
		}
		.animation(.spring(duration: 0.35, bounce: 0.4), value: mark)
		.animation(.easeOut(duration: 0.2), value: text)
		.frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
		.padding(.horizontal, 6).padding(.top, 3).padding(.bottom, 4)
		.listRowSeparator(.hidden).listRowInsets(Theme.rowInsets)
		.accessibilityElement(children: .combine)
	}
}

/// One message. The first of a run carries the avatar and the name line; the rest hang under it.
/// What can be done with it is one list everywhere, in one order: Reply, React, Forward, Copy text,
/// Info, Edit, and last, asked first, Delete. On the Mac it's the right click (and the hover's ⋯);
/// on the iPhone a hold lifts the message, the reactions above it and the rest below (`HoldMenu`).
struct MessageRow: View {
	@Environment(AppModel.self) private var model
	@Environment(\.accent) private var accent
	@Environment(\.tones) private var tones
	@Environment(\.reveal) private var reveal
	@Environment(\.hold) private var hold
	@Environment(\.accessibilityReduceMotion) private var still
	let event: Event
	let first: Bool
	let last: Bool
	var onReply: (Event) -> Void
	var onThread: (Event) -> Void
	/// Drawn again, lifted, in the hold menu: no gestures of its own there.
	var lifted = false
	@State private var hover = false
	@State private var editing = false
	@State private var showPath = false
	/// Every emoji, for a reaction (the strip's +, the menu's More…).
	@State private var picking = false
	/// The Mac's hover React: the strip, in a popover.
	@State private var reacting = false
	/// Who reacted with what; how my message got to each person; deleting it, asked first.
	@State private var showReactions = false
	@State private var showInfo = false
	@State private var deleting = false
	@State private var forwarding = false
	/// The reaction a double tap just gave, popping over the bubble.
	@State private var popped: String?
	/// Where the row is on screen, for the hold menu to lift it in place.
	@State private var frame: CGRect = .zero
	static func mark(_ v: Event.Via) -> Mark { switch v { case .direct: return .direct; case .relay: return .relayed; case .carried: return .held; case .waiting: return .waiting } }
	/// How this message travelled, in a few words.
	private func pathSentence(_ v: Event.Via) -> String {
		switch v {
		case .direct: return event.mine ? "Went straight to them" : "Came straight from them"
		case .relay: return "Through a helper"
		case .waiting: return "Waiting for them to come online"
		case .carried:
			if !event.mine, let c = event.carriedBy, let p = model.peers.first(where: { $0.device.id == c }) { return "Carried by \(p.own ? "your" : p.userName + "'s") \(DeviceShape(p.device).word)" }
			return "Carried by a device while one of you was away"
		}
	}
	@State private var editText = ""

	/// Two people, or my chat with myself: no faces, no names, just the two sides.
	private var direct: Bool { model.conversation(event.conv).map { $0.isDirect || $0.kind == .home } ?? true }
	private var mentionsMe: Bool { event.mentions.contains(model.me.user) && !event.mine }
	private var timeline: Timeline { model.timeline(event.conv) }
	/// A run of one person's messages reads as one: its inner corners tighten.
	private var bubble: UnevenRoundedRectangle {
		let big = Radius.bubble, small = Self.inner
		return event.mine
			? UnevenRoundedRectangle(topLeadingRadius: big, bottomLeadingRadius: big, bottomTrailingRadius: last ? big : small, topTrailingRadius: first ? big : small, style: .continuous)
			: UnevenRoundedRectangle(topLeadingRadius: first ? big : small, bottomLeadingRadius: last ? big : small, bottomTrailingRadius: big, topTrailingRadius: big, style: .continuous)
	}

	var body: some View {
		HStack(alignment: .bottom, spacing: 8) {
			if event.mine { gutter }
			else if !direct {
				if last { Avatar(name: model.name(of: event.user), hash: model.contacts.first { $0.user == event.user }?.avatar, size: 28) }
				else { Color.clear.frame(width: 28, height: 1) }
			}
			VStack(alignment: event.mine ? .trailing : .leading, spacing: 4) {
				if first, !event.mine, !direct {
					Text(model.name(of: event.user)).font(Theme.smallFont.weight(.semibold)).foregroundStyle(tones.secondary).padding(.horizontal, 13)
				}
				words
				ForEach(event.attachments, id: \.hash) { AttachmentBlock(attachment: $0) }
				if !event.reactions.isEmpty { reactions }
				// A thread's replies, in a channel; a chat shows them in the conversation instead.
				if event.replies > 0, !timeline.threadsInline {
					Button { onThread(event) } label: {
						Text("\(event.replies) \(event.replies == 1 ? "reply" : "replies") · \(list(event.lastRepliers.map(model.name(of:))))")
							.font(Theme.smallFont).foregroundStyle(tones.secondary)
					}.buttonStyle(.plain).padding(.horizontal, 13)
				}
			}
			.overlay(alignment: event.mine ? .topLeading : .topTrailing) { pop }
			if !event.mine { gutter }
		}
		// Dragged aside (iPhone): every message slides left, its way and time in the space it leaves.
		.offset(x: -min(reveal, Self.asideWidth))
		.overlay(alignment: .trailing) {
			if reveal > 0 {
				aside.offset(x: Self.asideWidth - min(reveal, Self.asideWidth))
					.opacity(Double(min(1, reveal / 40)))
			}
		}
		.padding(.top, first ? Theme.groupGap : Theme.rowGap).padding(.bottom, last ? Theme.groupBottom : Theme.rowGap)
		.listRowSeparator(.hidden)
		.listRowInsets(Theme.rowInsets)
		.onHover { hover = $0 }
		.modifier(HoldOrMenu(lifted: lifted, hold: hold.map { h in { h(Holding(event: event, first: first, last: last, frame: frame)) } }, frame: $frame) { menu })
		.swipeActions(edge: .leading, allowsFullSwipe: true) { Button("Reply") { onReply(event) } }
		// VoiceOver: the same actions, in the same order, on the message itself.
		.accessibilityAction(named: "Reply") { onReply(event) }
		.accessibilityAction(named: "React") { picking = true }
		.accessibilityAction(named: "Forward") { forwarding = true }
		.accessibilityAction(named: "Copy text") { if let t = event.text { copy(t) } }
		.accessibilityAction(named: "Delete") { if event.mine { deleting = true } }
		// The hold menu asks for what only this row can open: its editor, its info, its question.
		.onChange(of: model.messageAsk?.event) { _, id in
			guard id == event.id, let ask = model.messageAsk?.ask else { return }
			model.messageAsk = nil
			switch ask {
			case .edit: editText = event.text ?? ""; editing = true
			case .info: showInfo = true
			case .delete: deleting = true
			case .forward: forwarding = true
			case .react: picking = true
			}
		}
		#if os(iOS)
		.sheet(isPresented: $picking) { EmojiPicker { model.toggleReaction(event, $0) }.environment(\.tones, tones).presentationDetents([.large]).presentationDragIndicator(.visible) }
		.sheet(isPresented: $showReactions) { ScrollView { ReactionsList(reactions: event.reactions) }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible).presentationBackground(tones.surface) }
		.sheet(isPresented: $showInfo) { ScrollView { MessageInfo(event: event) }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible).presentationBackground(tones.surface) }
		.sheet(isPresented: $forwarding) { ForwardSheet(event: event).environment(model).environment(\.tones, tones) }
		#else
		.popover(isPresented: $picking, arrowEdge: .trailing) { EmojiPicker { model.toggleReaction(event, $0) } }
		.popover(isPresented: $showReactions, arrowEdge: event.mine ? .leading : .trailing) { ReactionsList(reactions: event.reactions).frame(width: 280).background(tones.surface) }
		.popover(isPresented: $showInfo, arrowEdge: event.mine ? .leading : .trailing) { MessageInfo(event: event).frame(width: 300).background(tones.surface) }
		.sheet(isPresented: $forwarding) { ForwardSheet(event: event).environment(model).environment(\.tones, tones) }
		#endif
		.confirmationDialog("Delete this message?", isPresented: $deleting, titleVisibility: .visible) {
			Button("Delete for everyone", role: .destructive) { model.attempt { try model.core.redact(event.conv, event.id) } }
			Button("Cancel", role: .cancel) {}
		} message: { Text("It goes for everyone in this chat.") }
		#if DEBUG
		// `BAUD_HOLD=1`: the newest message from someone else held, for pictures of the hold menu.
		.task {
			guard ProcessInfo.processInfo.environment["BAUD_HOLD"] == "1", !lifted, let h = hold,
				timeline.events.last(where: { !$0.mine && $0.type == .message && $0.text != nil })?.id == event.id else { return }
			try? await Task.sleep(for: .milliseconds(1500))
			h(Holding(event: event, first: first, last: last, frame: frame))
		}
		#endif
	}

	/// The empty side of a message. On the Mac it holds the hover's time and actions, inside the
	/// column whatever the window's width (an overlay past the bubble ran off a narrow window).
	@ViewBuilder private var gutter: some View {
		#if os(macOS)
		Color.clear.frame(minWidth: Self.gutter, maxWidth: .infinity, minHeight: 1)
			.overlay(alignment: event.mine ? .trailing : .leading) { beside.padding(event.mine ? .trailing : .leading, 8) }
		#else
		Spacer(minLength: Self.gutter)
		#endif
	}

	/// The reactions under it: a tap gives mine or takes it back; resting on one says who (the
	/// Mac), and a right click or a hold lists them. On the Mac, + while the pointer is on it.
	private var reactions: some View {
		HStack(spacing: 4) {
			ForEach(event.reactions, id: \.key) { r in
				Button { model.toggleReaction(event, r.key) } label: {
					Text("\(r.key) \(r.users.count)").font(Theme.smallFont)
						.padding(.horizontal, 7).padding(.vertical, 3)
						.background { if r.mine { Capsule().fill(tones.mine) } }
						.foregroundStyle(r.mine ? tones.onMine : tones.text)
						.glass(Capsule(), lifted: false)
						.scaleEffect(popped == r.key && !still ? 1.15 : 1)
				}
				.buttonStyle(.plain)
				.help(reactors(r, model))
				.accessibilityLabel(reactors(r, model))
				.contextMenu {
					Text(reactors(r, model))
					Button { showReactions = true } label: { Label("Who reacted", systemImage: "person.2") }
					Button { model.toggleReaction(event, r.key) } label: { Label(r.mine ? "Take mine back" : "React \(r.key) too", systemImage: r.mine ? "minus.circle" : "plus.circle") }
				}
			}
			#if os(macOS)
			Button { reacting = true } label: {
				Image(systemName: "face.smiling").font(Theme.smallFont)
					.padding(.horizontal, 7).padding(.vertical, 3).frame(minHeight: Theme.small + 8)
					.glass(Capsule(), lifted: false)
			}.buttonStyle(.plain).foregroundStyle(tones.secondary).help("React").accessibilityLabel("React")
			.opacity(hover || reacting ? 1 : 0).allowsHitTesting(hover || reacting)
			#endif
		}
	}

	/// A double tap's reaction, popping up off the bubble's corner and away.
	@ViewBuilder private var pop: some View {
		if let k = popped, !still {
			Text(k).font(.system(size: 34)).offset(x: event.mine ? -10 : 10, y: -18)
				.transition(.asymmetric(insertion: .scale(scale: 0.3).combined(with: .opacity), removal: .scale(scale: 1.4).combined(with: .opacity)))
				.allowsHitTesting(false)
		}
	}

	/// Where my message is: on the last bubble of a run of mine, its time and one mark, in the
	/// bubble's quiet ink: ○ on its way, ✓ held by a device for them, ✓✓ on their device, ● read.
	private var delivery: Delivery? {
		guard event.mine, last, !lifted || true else { return nil }
		let d = model.core.delivery(event.conv, event.id)
		return d.devices.isEmpty ? nil : d
	}
	private var stamp: Text {
		guard event.mine, last else { return Text("") }
		let ink = tones.onMineSecondary
		let time = Text("  " + clock(event.at)).font(Theme.smallFont).foregroundColor(ink)
		guard let d = delivery else { return time }
		return time + Text(" ") + Text(MarkImage.image(Mark.delivery(d), size: Theme.small + 1, color: ink)).baselineOffset(-1.5)
	}
	/// The mark's words, for a pointer resting on it and for VoiceOver: "Waiting for Ana", "Read".
	private var sentence: String? { delivery.map { $0.sentence.prefix(1).uppercased() + $0.sentence.dropFirst() } }

	/// A double tap: my most recent reaction, given, or taken back if it's there.
	private func doubleTap() {
		let k = EmojiPicker.strip.first ?? "❤️"
		Haptic.tap()
		model.toggleReaction(event, k)
		guard !still else { return }
		withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { popped = k }
		Task { try? await Task.sleep(for: .milliseconds(650)); withAnimation(Motion.standard) { popped = nil } }
	}

	/// The words, in a bubble: mine the strongest tint, theirs glass; a mention of me edged in the
	/// strong step. What it answers rides at the top: a reply's quote, or in a chat the message a
	/// thread was started on.
	@ViewBuilder private var words: some View {
		let quoted = timeline.quoted(event)
		let text = timeline.text(for: event)
		if editing || text != nil || quoted != nil {
			VStack(alignment: .leading, spacing: 5) {
				if let quoted { Quote(name: model.name(of: quoted.user), text: PlaceText.words(quoted.text) ?? (quoted.attachments.isEmpty ? "" : "attachment"), onMine: event.mine) }
				if editing {
					TextField("", text: $editText, axis: .vertical).textFieldStyle(.plain).font(Theme.font)
						.onSubmit { model.attempt { try model.core.edit(event.conv, event.id, text: editText) }; editing = false }
				} else if let at = PlaceText.parse(event.text) {
					PlaceBubble(event: event, at: at)
				} else if let t = text {
					// Just the words. How it travelled is beside it on a hover (Mac) or a drag to the left
					// (iPhone), the sentence a tap away; whether my newest got there is one line under the
					// conversation (Timeline.status).
					let linked = t.runs.contains { $0.link != nil }
					(Text(t).font(Theme.messageFont) + Text(event.edited ? "  edited" : "").font(Theme.smallFont).foregroundColor(event.mine ? tones.onMineSecondary : tones.secondary) + stamp)
						#if os(macOS)
						.textSelection(.enabled)
						#endif
						.help(sentence ?? event.via.map { pathSentence($0) } ?? "")
						.accessibilityValue(sentence ?? "")
						// A link in the words' own ink, underlined: the accent would vanish on my bubble.
						.tint(event.mine ? tones.onMine : tones.text)
						// A baud link opens here, on Add; any other the system opens.
						.environment(\.openURL, OpenURLAction { url in
							guard Code.parse(url.absoluteString) != nil else { return .systemAction }
							model.open(url: url)
							return .handled
						})
						#if os(iOS)
						// Two taps react; one (once two is ruled out) shows how it travelled, unless
						// there's a link to tap.
						.simultaneousGesture(TapGesture(count: 2).onEnded { if !lifted { doubleTap() } }
							.exclusively(before: TapGesture().onEnded { if !linked, !lifted { showPath.toggle() } }))
						#endif
				}
			}
			.padding(.horizontal, Self.padH).padding(.vertical, Self.padV)
			.foregroundStyle(event.mine ? tones.onMine : tones.text)
			.background { bubble.fill(event.mine ? tones.loud : tones.card).lifted(tones, by: lifted ? 2 : 1) }
			.overlay { if mentionsMe { bubble.strokeBorder(tones.text, lineWidth: 2) } }
			if showPath, let path = event.via.map({ pathSentence($0) }) { Text(path).font(Theme.smallFont).foregroundStyle(tones.secondary).padding(.horizontal, 13) }
		}
	}

	static let asideWidth: CGFloat = 64
	/// `BAUD_ASIDE=1` (Debug): every message's hover line shown, for the pictures.
	#if DEBUG
	static let asides = ProcessInfo.processInfo.environment["BAUD_ASIDE"] == "1"
	#else
	static let asides = false
	#endif
	/// The empty side of a message: on the Mac wide enough for its time and the hover actions.
	/// A bubble's padding, and its corner inside a run of one person's messages.
	#if os(macOS)
	static let gutter: CGFloat = 160
	static let padH: CGFloat = 12, padV: CGFloat = 7, inner: CGFloat = 4
	/// The conversation's column on a wide window: the two sides of a chat stay within reach.
	static let column: CGFloat = 720
	#else
	static let gutter: CGFloat = 56
	static let padH: CGFloat = 14, padV: CGFloat = 9, inner: CGFloat = 6
	#endif
	/// On a hover (Mac): its way and time, then React (the strip), Reply and ⋯ (the right click's
	/// menu), in the empty space beside the bubble, never on it.
	@ViewBuilder private var beside: some View {
		#if os(macOS)
		let shown = hover || picking || reacting || Self.asides
		let actions = HStack(spacing: 0) {
			IconButton(symbol: "face.smiling", help: "React", size: Icon.row) { reacting = true }
				.popover(isPresented: $reacting, arrowEdge: .top) { ReactPopover(event: event) }
			IconButton(symbol: "arrowshape.turn.up.left", help: "Reply", size: Icon.row) { onReply(event) }
			Menu { menu } label: { Image(systemName: "ellipsis").font(Icon.font(Icon.row)).frame(width: 24, height: 24).contentShape(Rectangle()) }
				.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(tones.secondary)
				.help("More").accessibilityLabel("More")
		}
		HStack(spacing: 4) {
			if event.mine { actions; aside } else { aside; actions }
		}
		.fixedSize()
		.opacity(shown ? 1 : 0)
		.allowsHitTesting(shown)
		.animation(Motion.quick, value: hover)
		#endif
	}
	/// Its way, as a mark, and its time: beside it on a hover or a drag, never at rest.
	private var aside: some View {
		HStack(spacing: 5) {
			if let v = event.via { MarkView(mark: Self.mark(v), size: Theme.small + 1, color: tones.secondary) }
			Text(clock(event.at)).font(Theme.smallFont).foregroundStyle(tones.secondary).monospacedDigit()
		}
		.fixedSize()
		.accessibilityHidden(true)
	}

	/// The one list of what can be done with it, in Signal's order: Reply, React ▸, Forward, Copy
	/// text, Info, Edit; then, alone and asked first, Delete.
	@ViewBuilder private var menu: some View {
		Button { onReply(event) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
		Menu {
			ForEach(EmojiPicker.strip, id: \.self) { k in Button(k) { model.toggleReaction(event, k) } }
			Button("More…") { picking = true }
		} label: { Label("React", systemImage: "face.smiling") }
		// A channel keeps its threads.
		if !timeline.threadsInline { Button { onThread(event) } label: { Label("Reply in thread", systemImage: "bubble.left.and.bubble.right") } }
		Button { forwarding = true } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
		if let t = event.text, !t.isEmpty, PlaceText.parse(t) == nil { Button { copy(t) } label: { Label("Copy text", systemImage: "doc.on.doc") } }
		if event.mine {
			Button { showInfo = true } label: { Label("Info", systemImage: "info.circle") }
			if event.text != nil, PlaceText.parse(event.text) == nil { Button { editText = event.text ?? ""; editing = true } label: { Label("Edit", systemImage: "pencil") } }
			Divider()
			Button(role: .destructive) { deleting = true } label: { Label("Delete…", systemImage: "trash") }
		}
	}
}

/// The Mac's React: the strip, and + turning it into every emoji, in one popover.
struct ReactPopover: View {
	@Environment(\.tones) private var tones
	@Environment(\.dismiss) private var dismiss
	@Environment(AppModel.self) private var model
	let event: Event
	@State private var more = false
	var body: some View {
		Group {
			if more { EmojiPicker { model.toggleReaction(event, $0) } }
			else { ReactionStrip(event: event, done: { dismiss() }, more: { more = true }) }
		}
		.background(tones.surface)
	}
}

/// A message held on the iPhone: which, how it sat in its run, and where it is on screen.
struct Holding: Equatable {
	let event: Event
	let first: Bool, last: Bool
	let frame: CGRect
	static func == (a: Holding, b: Holding) -> Bool { a.event.id == b.event.id && a.frame == b.frame }
}
extension EnvironmentValues { @Entry var hold: ((Holding) -> Void)? = nil }

/// A hold where there's a hold menu (the iPhone's conversation); the system's menu elsewhere (the
/// Mac, a thread). Either way the row knows where it is.
private struct HoldOrMenu<M: View>: ViewModifier {
	let lifted: Bool
	let hold: (() -> Void)?
	@Binding var frame: CGRect
	@ViewBuilder var menu: () -> M
	func body(content: Content) -> some View {
		#if os(iOS)
		if lifted { content }
		else if let hold {
			content
				.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
				.onLongPressGesture(minimumDuration: 0.35) { Haptic.tap(); hold() }
		} else { content.contextMenu { menu() } }
		#else
		content.contextMenu { menu() }
		#endif
	}
}

#if os(iOS)
/// The message held: lifted where it was, everything else dimmed in a tone of the colour, my recent
/// reactions above it and what can be done with it below. Near the top of the screen the reactions
/// go under it; near the bottom the actions go over it. A tap anywhere else closes it.
struct HoldMenu: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	@Environment(\.accessibilityReduceMotion) private var still
	let holding: Holding
	let onReply: (Event) -> Void
	let close: () -> Void
	@State private var shown = false
	private var e: Event { holding.event }
	private var actions: [(title: String, symbol: String, danger: Bool, run: () -> Void)] {
		var out: [(String, String, Bool, () -> Void)] = [("Reply", "arrowshape.turn.up.left", false, { onReply(e) })]
		out.append(("Forward", "arrowshape.turn.up.right", false, { ask(.forward) }))
		if let t = e.text, !t.isEmpty, PlaceText.parse(t) == nil { out.append(("Copy text", "doc.on.doc", false, { copy(t) })) }
		if e.mine {
			out.append(("Info", "info.circle", false, { ask(.info) }))
			if e.text != nil, PlaceText.parse(e.text) == nil { out.append(("Edit", "pencil", false, { ask(.edit) })) }
			out.append(("Delete…", "trash", true, { ask(.delete) }))
		}
		return out.map { (title: $0.0, symbol: $0.1, danger: $0.2, run: $0.3) }
	}
	private func ask(_ a: AppModel.MessageAsk) { model.messageAsk = (e.id, a) }

	var body: some View {
		GeometryReader { geo in
			let here = geo.frame(in: .global)
			let row = holding.frame.offsetBy(dx: -here.minX, dy: -here.minY)
			let top = geo.safeAreaInsets.top + 8, bottom = geo.size.height - geo.safeAreaInsets.bottom - 8
			let strip: CGFloat = ReactionStrip.cell + 8, gap: CGFloat = 8
			let cardH = CGFloat(actions.count) * 46 + 8 + (e.mine ? 1 : 0)
			let place = layout(row: row, top: top, bottom: bottom, strip: strip, card: cardH, gap: gap)
			let side: Alignment = e.mine ? .trailing : .leading
			ZStack(alignment: .topLeading) {
				// Everything else, quieter: the ground's own colour over it, not grey.
				tones.surface.opacity(0.88).ignoresSafeArea()
					.contentShape(Rectangle()).onTapGesture { finish() }
				MessageRow(event: e, first: holding.first, last: holding.last, onReply: { _ in }, onThread: { _ in }, lifted: true)
					.environment(\.hold, nil)
					.frame(width: row.width, height: row.height)
					.allowsHitTesting(false)
					.scaleEffect(shown && !still ? 1.02 : 1)
					.offset(x: row.minX, y: place.row)
				ReactionStrip(event: e, done: { finish() }, more: { ask(.react); finish() })
					.background(Capsule().fill(tones.card).lifted(tones, by: 2))
					.frame(width: row.width, alignment: side)
					.offset(x: row.minX, y: place.strip)
				card
					.frame(width: row.width, alignment: side)
					.offset(x: row.minX, y: place.card)
			}
			.opacity(shown ? 1 : 0)
		}
		.ignoresSafeArea()
		.onAppear { withAnimation(Motion.or(Motion.quick, still: still)) { shown = true } }
		.accessibilityAddTraits(.isModal)
	}

	private var card: some View {
		VStack(spacing: 0) {
			ForEach(Array(actions.enumerated()), id: \.offset) { i, a in
				if a.danger { Hairline() }
				Button { a.run(); finish() } label: {
					HStack {
						Text(a.title).font(Theme.font)
						Spacer(minLength: 16)
						Image(systemName: a.symbol).font(Icon.font(Icon.row))
					}
					.foregroundStyle(a.danger ? tones.danger : tones.text)
					.frame(minHeight: 46).contentShape(Rectangle())
				}
				.buttonStyle(RowStyle())
			}
		}
		.padding(.vertical, 4)
		.frame(width: 250)
		.background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(tones.card).lifted(tones, by: 2))
	}

	/// Where the strip, the row and the card go: the strip over the row and the card under it, unless
	/// the screen's edge is too near; then they move to the other side, and the row with them.
	private func layout(row: CGRect, top: CGFloat, bottom: CGFloat, strip: CGFloat, card: CGFloat, gap: CGFloat) -> (strip: CGFloat, row: CGFloat, card: CGFloat) {
		let h = row.height
		var y = row.minY
		if y - strip - gap >= top, y + h + gap + card <= bottom { return (y - gap - strip, y, y + h + gap) }
		if y - strip - gap < top {
			// Near the top: the row, then the strip, then the card, all as high as fits.
			y = max(top, min(y, bottom - h - gap - strip - gap - card))
			return (y + h + gap, y, y + h + gap + strip + gap)
		}
		// Near the bottom: the card, then the strip, then the row, all as low as fits.
		y = min(y, bottom - h)
		let s = y - gap - strip
		let c = max(top, s - gap - card)
		return (s, y, c)
	}

	private func finish() {
		withAnimation(Motion.or(Motion.quick, still: still)) { shown = false }
		Task { try? await Task.sleep(for: .milliseconds(120)); close() }
	}
}
#endif

struct Quote: View {
	@Environment(\.tones) private var tones
	let name: String
	let text: String
	/// Inside my own bubble, in its ink.
	var onMine = false
	var body: some View {
		let ink = onMine ? tones.onMineSecondary : tones.secondary
		HStack(spacing: 6) {
			RoundedRectangle(cornerRadius: 1).fill(ink).frame(width: 2)
			VStack(alignment: .leading, spacing: 1) {
				Text(name).font(Theme.smallFont.weight(.medium)).foregroundStyle(ink)
				Text(text).font(Theme.smallFont).foregroundStyle(ink).lineLimit(2)
			}
		}
		// Its own height: two lines of whatever size the person reads at.
		.fixedSize(horizontal: false, vertical: true)
	}
}

/// Media as a tidy block: a photo at its own shape, any other file as its kind, name and size. A
/// click (a tap on the iPhone) opens it in Quick Look. Until the bytes are here it says so: on its
/// way, or waiting for a device that has it, and it looks again when someone comes online.
struct AttachmentBlock: View {
	@Environment(\.tones) private var tones
	@Environment(AppModel.self) private var model
	let attachment: Attachment
	@State private var url: URL?
	@State private var thumb: Image?
	@State private var missing = false
	@State private var preview: URL?

	/// The photo's box, the Mac timeline's row-height sum assumes the same (MacTimeline.swift).
	static let photoMax: CGFloat = 320

	var body: some View {
		Group {
			if attachment.isImage, let w = attachment.width, let h = attachment.height, w > 0, h > 0 { photo(CGFloat(w), CGFloat(h)) } else { file }
		}
		.contentShape(RoundedRectangle(cornerRadius: 10))
		.onTapGesture { open() }
		.contextMenu {
			Button { open() } label: { Label("Open", systemImage: "eye") }.disabled(url == nil)
			#if os(macOS)
			Button { save() } label: { Label("Save to Downloads", systemImage: "arrow.down.circle") }.disabled(url == nil)
			#else
			if let url { ShareLink(item: viewable(url, name: name)) { Label("Share…", systemImage: "square.and.arrow.up") } }
			#endif
		}
		.quickLookPreview($preview)
		.accessibilityElement(children: .combine)
		.accessibilityLabel("\(attachment.isImage ? "Photo" : "File") \(name), \(bytesText(attachment.size))")
		.accessibilityAddTraits(.isButton)
		// Again whenever the number of devices online changes, while it isn't here.
		.task(id: url == nil ? "\(attachment.hash)-\(model.peers.filter(\.device.online).count)" : attachment.hash) { await load() }
	}

	private var name: String { attachment.name ?? (attachment.isImage ? "Photo" : "File") }

	private func photo(_ w: CGFloat, _ h: CGFloat) -> some View {
		RoundedRectangle(cornerRadius: 10).fill(tones.quiet)
			.aspectRatio(w / h, contentMode: .fit)
			.frame(maxWidth: min(Self.photoMax, w), maxHeight: Self.photoMax)
			.overlay {
				if let thumb { thumb.resizable().scaledToFill() }
				else if missing { Text("Waiting for a device that has it").font(Theme.smallFont).foregroundStyle(tones.secondary).multilineTextAlignment(.center).padding(8) }
				else { ProgressView().controlSize(.small) }
			}
			.clipShape(RoundedRectangle(cornerRadius: 10))
			.overlay(RoundedRectangle(cornerRadius: 10).stroke(tones.hairline, lineWidth: 1))
	}

	private var file: some View {
		HStack(spacing: 10) {
			Image(systemName: symbol).font(.system(size: Theme.body + 4)).foregroundStyle(tones.secondary).frame(width: 26)
			VStack(alignment: .leading, spacing: 1) {
				Text(name).font(Theme.font).lineLimit(1).truncationMode(.middle)
				Text(detail).font(Theme.smallFont).foregroundStyle(tones.secondary).lineLimit(1)
			}
			Spacer(minLength: 0)
		}
		.padding(.horizontal, 10).padding(.vertical, 8)
		.frame(maxWidth: 320, alignment: .leading)
		.background(RoundedRectangle(cornerRadius: 10).fill(tones.raised))
		.overlay(RoundedRectangle(cornerRadius: 10).stroke(tones.hairline, lineWidth: 1))
	}

	private var type: UTType? { UTType(mimeType: attachment.mime) ?? UTType(filenameExtension: (name as NSString).pathExtension) }
	private var symbol: String {
		guard let t = type else { return "doc" }
		if t.conforms(to: .pdf) { return "doc.richtext" }
		if t.conforms(to: .image) { return "photo" }
		if t.conforms(to: .movie) || t.conforms(to: .video) { return "film" }
		if t.conforms(to: .audio) { return "waveform" }
		if t.conforms(to: .archive) { return "doc.zipper" }
		if t.conforms(to: .text) || t.conforms(to: .sourceCode) { return "doc.text" }
		return "doc"
	}
	private var detail: String {
		let size = bytesText(attachment.size)
		if url != nil { return size }
		return size + (missing ? " · waiting for a device that has it" : " · on its way")
	}

	private func load() async {
		if url == nil { url = try? await model.core.blob(attachment.hash, key: attachment.key) }
		missing = url == nil
		if let url, attachment.isImage, thumb == nil { thumb = await model.thumbnail(attachment.hash, url) }
	}

	private func open() {
		guard let url else { return }
		preview = viewable(url, name: name)
	}

	#if os(macOS)
	private func save() {
		guard let url, let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
		let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
		var to = downloads.appendingPathComponent(name), n = 2
		while FileManager.default.fileExists(atPath: to.path) { to = downloads.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"); n += 1 }
		do { try FileManager.default.copyItem(at: url, to: to); NSWorkspace.shared.activateFileViewerSelecting([to]) } catch { model.error = "Couldn't save it to Downloads: \(error.localizedDescription)" }
	}
	#endif
}

/// A stored file under its own name, for Quick Look and sharing: the store keeps bytes by hash
/// with no name, and a viewer needs the extension. A hard link in Caches, a copy if that fails.
func viewable(_ blob: URL, name: String) -> URL {
	let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("baud-open").appendingPathComponent(blob.lastPathComponent)
	let to = dir.appendingPathComponent(name.isEmpty ? "file" : name.replacingOccurrences(of: "/", with: "-"))
	if FileManager.default.fileExists(atPath: to.path) { return to }
	try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
	if (try? FileManager.default.linkItem(at: blob, to: to)) == nil { try? FileManager.default.copyItem(at: blob, to: to) }
	return to
}

/// A photo drawn small enough for a message (and turned the way it was taken), off the main thread.
func downscaled(_ url: URL, maxPixels: Int) -> CGImage? {
	guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
	let o: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels]
	return CGImageSourceCreateThumbnailAtIndex(src, 0, o as CFDictionary)
}

func markdown(_ s: String) -> AttributedString {
	(try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
}

/// A message's words: every link whole, as it was sent, underlined and tappable; Markdown only
/// between links, and only where there's some. Markdown's own autolinks left a link's trailing
/// `_` out, read the underscores in a `baud://` link as emphasis, and missed a link in a message
/// with no `*_`[~` in it at all.
func styled(_ s: String) -> AttributedString {
	var out = AttributedString(), at = s.startIndex
	let words = { (w: Substring) in w.contains(where: { "*_`[~".contains($0) }) ? markdown(String(w)) : AttributedString(w) }
	for r in links(in: s) {
		out += words(s[at..<r.lowerBound])
		var l = AttributedString(s[r])
		l.link = URL(string: String(s[r]))
		l.underlineStyle = .single
		out += l
		at = r.upperBound
	}
	return out + words(s[at...])
}

/// The links in a message: `https://`, `http://` or `baud://` up to the next space, less what a
/// sentence puts after one (a closing bracket only when the link didn't open it). One written as
/// Markdown, `[words](link)`, stays Markdown's.
func links(in s: String) -> [Range<String.Index>] {
	s.ranges(of: /(?i)(?:https?|baud):\/\/\S+/).compactMap { r in
		if s[..<r.lowerBound].hasSuffix("](") { return nil }
		var end = r.upperBound
		while end > r.lowerBound, let c = s[..<end].last {
			let opened = s[r.lowerBound..<end].filter { $0 == "(" }.count, closed = s[r.lowerBound..<end].filter { $0 == ")" }.count
			guard ".,;:!?'\"]}>*".contains(c) || (c == ")" && closed > opened) else { break }
			end = s.index(before: end)
		}
		let link = s[r.lowerBound..<end]
		return URL(string: String(link)) != nil && !link.hasSuffix("://") ? r.lowerBound..<end : nil
	}
}

#if os(macOS)
import AppKit
func loadImage(_ url: URL) -> Image? { NSImage(contentsOf: url).map { Image(nsImage: $0) } }
func copy(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }
func pasteboard() -> String? { NSPasteboard.general.string(forType: .string) }
#else
import UIKit
func loadImage(_ url: URL) -> Image? { UIImage(contentsOfFile: url.path).map { Image(uiImage: $0) } }
func copy(_ s: String) { UIPasteboard.general.string = s }
func pasteboard() -> String? { UIPasteboard.general.string }
#endif
