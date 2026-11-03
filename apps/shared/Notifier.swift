/// Notifications on the iPhone's lock screen and the Mac's: a new message when its chat isn't in
/// front of you, and a call you missed. Made on this device from what arrived here; nothing is
/// pushed from anywhere, since there is nowhere to push from. On the iPhone what arrives in a
/// background wake (`Refresh`) notifies the same way. Tapping one opens its chat.
import BaudCore
import UserNotifications
#if os(iOS)
import Intents
import UIKit
#else
import AppKit
#endif

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
	static let shared = Notifier()
	private weak var model: AppModel?
	/// Each conversation as last seen: its unread count and newest event.
	private var seen: [ConversationId: (unread: Int, last: EventId?)] = [:]
	private var primed = false
	private var asked = false
	private var center: UNUserNotificationCenter { .current() }
	#if DEBUG
	/// `BAUD_NOTIFY=log` (Debug): say what would notify, never ask for permission or show anything.
	private let dry = ProcessInfo.processInfo.environment["BAUD_NOTIFY"] == "log"
	#else
	private let dry = false
	#endif

	func attach(_ model: AppModel) {
		self.model = model
		center.delegate = self
		askIfNeeded()
	}

	/// Where a person turns them back on: baud's own page in Settings.
	static var settings: URL? {
		#if os(iOS)
		URL(string: UIApplication.openNotificationSettingsURLString)
		#else
		URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")")
		#endif
	}

	/// Asked at the first launch: a messenger is no use if it can't say a message came.
	func askIfNeeded() {
		guard !asked, !dry else { return }
		asked = true
		Task {
			guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
			let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
			Measure.log("notifications: \(granted ? "allowed" : "not allowed")")
		}
	}

	/// The conversations changed: one whose unread count went up, with someone else's message
	/// newest, notifies, unless it's the chat on screen. One read (here or on another of my
	/// devices) takes its notifications away.
	func changed(_ convs: [Conversation]) {
		guard let model else { return }
		let now = Dictionary(convs.map { ($0.id, (unread: $0.unread, last: $0.lastEvent)) }, uniquingKeysWith: { a, _ in a })
		defer { seen = now; badge(model.unread) }
		// What was there at launch was seen when it came, or will be in the list.
		guard primed else { primed = !convs.isEmpty; return }
		var read: [ConversationId] = []
		for c in convs {
			let was = seen[c.id]
			if c.unread == 0, (was?.unread ?? 0) > 0 { read.append(c.id); continue }
			guard c.unread > (was?.unread ?? 0), c.lastEvent != was?.last, let from = c.lastUser, from != model.me.user, !onScreen(c.id) else { continue }
			// Muted: its messages come in quietly.
			if model.muted(c.id) != nil { continue }
			post(c, from: from)
		}
		if !read.isEmpty { clear(read) }
	}

	/// A call that rang here and nobody answered.
	func missedCall(from name: String, conv: ConversationId, video: Bool) {
		guard !onScreen(conv) else { return }
		Measure.log("notify: missed call in \(conv.prefix(8))")
		if dry { return }
		let n = UNMutableNotificationContent()
		n.title = name
		n.body = video ? "Missed video call" : "Missed call"
		n.sound = .default
		n.threadIdentifier = conv
		n.userInfo = ["conversation": conv]
		center.add(UNNotificationRequest(identifier: "call/\(conv)/\(Date().timeIntervalSince1970)", content: n, trigger: nil))
	}

	private func post(_ c: Conversation, from: UserId) {
		guard let model else { return }
		Measure.log("notify: \(c.id.prefix(8)), \(c.unread) unread")
		if dry { return }
		let n = UNMutableNotificationContent()
		let who = model.name(of: from)
		if c.isDirect || c.kind == .home { n.title = who } else { n.title = model.title(c); n.subtitle = who }
		n.body = PlaceText.words(c.lastText).flatMap { $0.isEmpty ? nil : $0 } ?? "New message"
		n.sound = .default
		n.threadIdentifier = c.id
		n.userInfo = ["conversation": c.id]
		let id = "\(c.id)/\(c.lastEvent ?? UUID().uuidString)"
		#if os(iOS)
		n.badge = NSNumber(value: model.unread)
		let center = center
		Task {
			let content = await communication(n, from: from, in: c)
			try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
			// The wake's "New message" stood in for this one: it goes now the real one is here.
			let stand = await center.deliveredNotifications().filter { $0.request.content.threadIdentifier == "wake" }.map(\.request.identifier)
			if !stand.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stand) }
		}
		#else
		center.add(UNNotificationRequest(identifier: id, content: n, trigger: nil))
		#endif
	}

	#if os(iOS)
	/// A communication notification: the sender's face on the lock screen, and a Focus lets
	/// through the people it allows. A message intent, donated as incoming, dresses the content.
	private func communication(_ n: UNMutableNotificationContent, from: UserId, in c: Conversation) async -> UNNotificationContent {
		guard let model else { return n }
		var face: INImage?
		if let h = model.contacts.first(where: { $0.user == from })?.avatar, let url = try? await model.core.blob(h, key: ""), let data = try? Data(contentsOf: url) {
			face = INImage(imageData: data)
		}
		let person = { (user: UserId, name: String, image: INImage?) in
			INPerson(personHandle: INPersonHandle(value: user, type: .unknown), nameComponents: nil, displayName: name, image: image, contactIdentifier: nil, customIdentifier: user)
		}
		let sender = person(from, model.name(of: from), face)
		let group = !(c.isDirect || c.kind == .home)
		let intent = INSendMessageIntent(recipients: group ? [person(model.me.user, model.me.name, nil), sender] : nil, outgoingMessageType: .outgoingMessageText, content: n.body,
			speakableGroupName: group ? INSpeakableString(spokenPhrase: model.title(c)) : nil, conversationIdentifier: c.id, serviceName: "baud", sender: sender, attachments: nil)
		let interaction = INInteraction(intent: intent, response: nil)
		interaction.direction = .incoming
		try? await interaction.donate()
		return (try? n.updating(from: intent)) ?? n
	}
	#endif

	private func clear(_ convs: [ConversationId]) {
		let center = center
		Task {
			let ids = await center.deliveredNotifications().filter { convs.contains($0.request.content.threadIdentifier) }.map(\.request.identifier)
			center.removeDeliveredNotifications(withIdentifiers: ids)
		}
	}

	private func badge(_ n: Int) {
		#if os(iOS)
		center.setBadgeCount(n)
		#endif
	}

	/// Disappearing messages that went from this device: the notification each one made goes too,
	/// whichever chat it was filed under (a merged direct chat files under the one shown).
	func expired(_ conv: ConversationId, _ events: [EventId]) {
		Measure.log("notify: \(events.count) gone from \(conv.prefix(8))")
		if dry { return }
		let gone = Set(events), center = center
		Task {
			let ids = await center.deliveredNotifications().map(\.request.identifier).filter { gone.contains(String($0.split(separator: "/").last ?? "")) }
			if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
		}
	}

	/// The chat is in front of the person: the app is active and that timeline is showing.
	private func onScreen(_ conv: ConversationId) -> Bool {
		guard let model else { return false }
		return model.front && model.onScreen == conv
	}

	// MARK: UNUserNotificationCenterDelegate

	nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
		let conv = notification.request.content.threadIdentifier
		// A wake's "New message" while baud is open: the real one is already here, or coming.
		if conv == "wake" { return [] }
		return await MainActor.run { onScreen(conv) } ? [] : [.banner, .list, .sound]
	}

	nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
		guard let conv = response.notification.request.content.userInfo["conversation"] as? String else { return }
		await MainActor.run {
			guard let model else { return }
			#if os(macOS)
			NSApp.activate(ignoringOtherApps: true)
			#endif
			model.open(conv)
			model.reveal = conv
		}
	}
}
