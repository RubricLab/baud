/// One conversation's rows, ready to draw: pages of events from the core, grouped by sender and
/// day, with the delivery sentence for my last message. Views never compute any of this.
import BaudCore
import Foundation
import Observation

@MainActor
@Observable
final class Timeline {
	let conv: ConversationId
	unowned let model: AppModel
	private(set) var events: [Event] = []
	private(set) var rows: [Row] = []
	private(set) var byId: [EventId: Event] = [:]
	/// Markdown is parsed once per event, the first time its row is drawn.
	private var rendered: [EventId: AttributedString] = [:]
	private(set) var delivery: Delivery?
	private(set) var typing: [String] = []
	private(set) var exhausted = false
	let page = 200

	enum Row: Identifiable, Hashable {
		case day(Date)
		case event(Event, first: Bool, last: Bool)
		var id: String {
			switch self {
			case .day(let d): return "day-\(Int(d.timeIntervalSince1970))"
			case .event(let e, _, _): return e.id
			}
		}
	}

	init(conv: ConversationId, model: AppModel) {
		self.conv = conv; self.model = model
		threadsInline = model.conversation(conv).map { $0.kind != .channel } ?? true
		reload()
	}

	/// Chats have no threads: replies made in one (by older versions, or a channel's habit) show in
	/// the conversation, in time order, each quoting the message it answers. Channels keep theirs.
	let threadsInline: Bool

	/// Members' labels in a group ("organiser"), shown after their names over their messages.
	private(set) var labels: [UserId: String] = [:]

	func reload() {
		let fresh = Dictionary(model.core.members(conv).compactMap { m in m.label.map { (m.user, $0) } }, uniquingKeysWith: { a, _ in a })
		if fresh != labels { labels = fresh }
		let want = max(page, events.count)
		let main = model.core.events(conv, before: nil, limit: want)
		exhausted = main.count < want
		events = withReplies(main)
		build()
		refreshDelivery()
	}

	func loadMore() {
		guard !exhausted, let first = events.first(where: { $0.thread == nil }) else { return }
		let older = model.core.events(conv, before: first.id, limit: page)
		exhausted = older.count < page
		guard !older.isEmpty else { return }
		events = withReplies(older + events.filter { $0.thread == nil })
		build()
	}

	/// Everything, for the scroll measurement.
	func loadAll() {
		events = withReplies(model.core.events(conv, before: nil, limit: 100_000))
		exhausted = true
		build()
	}

	/// The main list with the replies to its threads woven in by time, in a chat; as it is in a channel.
	private func withReplies(_ main: [Event]) -> [Event] {
		guard threadsInline else { return main }
		let replies = main.filter { $0.replies > 0 && $0.thread == nil }.flatMap { root in
			model.core.thread(conv, root.id, before: nil, limit: 500).filter { $0.id != root.id }
		}
		guard !replies.isEmpty else { return main }
		var seen = Set<EventId>()
		return (main + replies).filter { seen.insert($0.id).inserted }.sorted { ($0.lamport, $0.id) < ($1.lamport, $1.id) }
	}

	/// What a message answers, shown over it: its reply, or in a chat the thread it was written in.
	func quoted(_ e: Event) -> Event? {
		if let r = e.reply { return byId[r] }
		if threadsInline, let t = e.thread, t != e.id { return byId[t] }
		return nil
	}

	func refreshDelivery() {
		guard let last = events.last(where: { $0.mine && $0.type == .message }) else { delivery = nil; return }
		delivery = model.core.delivery(conv, last.id)
	}
	/// Under my message while it is the newest, in a few quiet words: "Sending…", "Waiting for Ana",
	/// "Carried by Jo's Mac", "Delivered", "Read". Nil when someone has answered since, or it's only me.
	var status: String? {
		guard let d = delivery, let last = events.last, last.id == d.event, !d.devices.isEmpty else { return nil }
		func level(_ s: DeliveryState) -> Int { switch s { case .read: return 3; case .delivered: return 2; case .carried: return 1; case .sent: return 0 } }
		let people = Dictionary(grouping: d.devices, by: \.personName).mapValues { ds in ds.map { level($0.state) }.max() ?? 0 }
		let one = people.count == 1
		if people.values.allSatisfy({ $0 == 3 }) { return one ? "Read" : "Read by everyone" }
		if people.values.allSatisfy({ $0 >= 2 }) {
			let read = people.filter { $0.value == 3 }.keys.sorted()
			return read.isEmpty ? "Delivered" : "Delivered · read by \(list(read))"
		}
		let behind = people.filter { $0.value < 2 }.keys.sorted()
		let online = Set(d.devices.filter(\.device.online).map(\.personName))
		let carriers = Set(d.devices.flatMap(\.carriers)).sorted()
		let who = behind.count <= 2 ? list(behind) : "\(behind.count) people"
		if behind.allSatisfy(online.contains) { return "Sending…" }
		if let c = carriers.first, carriers.count == 1, one { return "Carried by \(c)" }
		return "Waiting for \(who)"
	}
	/// The mark beside the status: the furthest every one of them has it.
	var statusMark: Mark? {
		guard status != nil, let d = delivery else { return nil }
		if status == "Sending…" { return .sending }
		let worst = d.devices.map(\.state).min { a, b in Self.rank(a) < Self.rank(b) } ?? .sent
		let byPerson = Dictionary(grouping: d.devices, by: \.personName).mapValues { $0.map { Self.rank($0.state) }.max() ?? 0 }
		let floor = byPerson.values.min() ?? Self.rank(worst)
		return [Mark.sending, .carried, .delivered, .read][floor]
	}
	private static func rank(_ s: DeliveryState) -> Int { switch s { case .read: return 3; case .delivered: return 2; case .carried: return 1; case .sent: return 0 } }
	func refreshTyping() {
		typing = model.core.typingNow(conv).map(model.name(of:))
		// The core forgets a typer five seconds after its last frame; nothing else wakes this view,
		// so look again just after that, or "is typing" stays until the next event.
		typingTimer?.cancel()
		if !typing.isEmpty { typingTimer = Task { @MainActor [weak self] in try? await Task.sleep(for: .seconds(5.2)); self?.refreshTyping() } }
	}
	private var typingTimer: Task<Void, Never>?

	func text(for e: Event) -> AttributedString? {
		guard let t = e.text else { return nil }
		if let r = rendered[e.id] { return r }
		let r = styled(t)
		rendered[e.id] = r
		return r
	}

	func markRead() {
		guard model.front else { return }
		if let last = events.last { try? model.core.markRead(conv, last.id) }
	}

	private func build() {
		var out: [Row] = []
		out.reserveCapacity(events.count + 32)
		let cal = Calendar.current
		var lastDay: Date?
		for (i, e) in events.enumerated() {
			let day = cal.startOfDay(for: e.at)
			if lastDay != day { out.append(.day(day)); lastDay = day }
			let prev = i > 0 ? events[i - 1] : nil
			let next = i + 1 < events.count ? events[i + 1] : nil
			let first = !(prev.map { same($0, e) } ?? false)
			let last = !(next.map { same(e, $0) } ?? false)
			out.append(.event(e, first: first, last: last))
		}
		rows = out
		byId = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
		rendered = rendered.filter { entry in byId[entry.key]?.text != nil }
	}

	/// Same sender, same day, within five minutes, both plain messages.
	private func same(_ a: Event, _ b: Event) -> Bool {
		a.user == b.user && a.type == .message && b.type == .message && b.at.timeIntervalSince(a.at) < 300 && Calendar.current.isDate(a.at, inSameDayAs: b.at)
	}
}
