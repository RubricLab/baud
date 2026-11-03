/// The core baud's apps call and never implement: SPEC.md's "The core and its edge" as a Swift
/// protocol. The crate's `Baud` (UniFFI over `peer` + baud-core) will conform to it; until it
/// ships, `LocalCore` (one device) and `PairCore` (several in one process) stand in. The SPEC
/// writes `conversation.send(draft)`; here that is `core.send(conv, draft)`, because listeners
/// carry ids and views re-read, so there is one object and no handles to keep alive.
/// Zero protocol logic lives in the apps: ids are opaque strings the core hands out.
import Foundation

public typealias DeviceId = String
public typealias UserId = String
public typealias ConversationId = String
public typealias EventId = String
public typealias BlobHash = String

public enum DeviceKind: String, Codable, Sendable {
	case mac, iphone, android, node
	/// A kind this version doesn't know yet (an Android phone, say) reads as a node, so a card
	/// listing one still reads: a strict decode would drop that person's whole card.
	public init(from decoder: Decoder) throws {
		self = DeviceKind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .node
	}
}

/// One install of someone's, with what this device knows about reaching it right now.
public struct Device: Identifiable, Hashable, Sendable {
	public var id: DeviceId
	public var name: String
	public var kind: DeviceKind
	public var user: UserId
	public var addedAt: Date
	public var online: Bool
	public var lastOnline: Date?
	public var path: Path
	public init(id: DeviceId, name: String, kind: DeviceKind, user: UserId, addedAt: Date = Date(), online: Bool = false, lastOnline: Date? = nil, path: Path = .none) {
		self.id = id; self.name = name; self.kind = kind; self.user = user; self.addedAt = addedAt; self.online = online; self.lastOnline = lastOnline; self.path = path
	}
}

public struct Person: Hashable, Sendable {
	public var user: UserId
	public var name: String
	public var fingerprint: String
	public var devices: [Device]
	public var thisDevice: DeviceId
	/// The photo, as a blob hash on the card; nil until one is set.
	public var avatar: BlobHash?
	public init(user: UserId, name: String, fingerprint: String, devices: [Device], thisDevice: DeviceId, avatar: BlobHash? = nil) {
		self.user = user; self.name = name; self.fingerprint = fingerprint; self.devices = devices; self.thisDevice = thisDevice; self.avatar = avatar
	}
	public var otherDevices: [Device] { devices.filter { $0.id != thisDevice } }
}

/// An invite (`f`) or a device link (`m`): `baud://add#…` / `baud://link#…`, everything after `#`.
public struct Link: Hashable, Sendable {
	/// A reply answers a friend link whose maker couldn't be reached: its maker opens it to meet.
	public enum Kind: String, Sendable { case friend = "f", device = "m", reply = "r" }
	public var url: String
	public var kind: Kind
	public var name: String
	public var expires: Date
	public init(url: String, kind: Kind, name: String, expires: Date) { self.url = url; self.kind = kind; self.name = name; self.expires = expires }
	/// The same link as `https://baud.rubric.sh/add#…`, for people who don't have baud yet.
	public var web: String { url.replacingOccurrences(of: "baud://", with: "https://baud.rubric.sh/") }
}

public struct Contact: Identifiable, Hashable, Sendable {
	public var user: UserId
	public var name: String
	public var verified: Bool
	public var fingerprint: String
	public var devices: [Device]
	public var metAt: Date
	public var avatar: BlobHash?
	/// Came by an identity redirect: their old key vouches for this one; not verified.
	public var vouched: Bool = false
	public var id: UserId { user }
	public init(user: UserId, name: String, verified: Bool, fingerprint: String, devices: [Device], metAt: Date, avatar: BlobHash? = nil, vouched: Bool = false) {
		self.user = user; self.name = name; self.verified = verified; self.fingerprint = fingerprint; self.devices = devices; self.metAt = metAt; self.avatar = avatar; self.vouched = vouched
	}
	public var online: Bool { devices.contains { $0.online } }
	public var lastOnline: Date? { devices.compactMap(\.lastOnline).max() }
}

public enum Kind: String, Codable, Sendable { case chat, channel, space, home }

public struct Conversation: Identifiable, Hashable, Sendable {
	public var id: ConversationId
	public var kind: Kind
	public var name: String?
	public var topic: String?
	public var space: ConversationId?
	public var members: [UserId]
	public var admins: [UserId]
	public var createdAt: Date
	public var lastAt: Date
	public var lastText: String?
	public var lastUser: UserId?
	public var lastEvent: EventId?
	public var unread: Int
	public var mentions: Int
	public var eventCount: Int
	public var isDefault: Bool
	public var pinned: [EventId]
	/// Disappearing messages: how many seconds a message written now lasts after it is read; 0 is off.
	public var disappear: Int
	public init(id: ConversationId, kind: Kind, name: String? = nil, topic: String? = nil, space: ConversationId? = nil, members: [UserId], admins: [UserId], createdAt: Date, lastAt: Date, lastText: String? = nil, lastUser: UserId? = nil, lastEvent: EventId? = nil, unread: Int = 0, mentions: Int = 0, eventCount: Int = 0, isDefault: Bool = false, pinned: [EventId] = [], disappear: Int = 0) {
		self.id = id; self.kind = kind; self.name = name; self.topic = topic; self.space = space; self.members = members; self.admins = admins; self.createdAt = createdAt; self.lastAt = lastAt; self.lastText = lastText; self.lastUser = lastUser; self.lastEvent = lastEvent; self.unread = unread; self.mentions = mentions; self.eventCount = eventCount; self.isDefault = isDefault; self.pinned = pinned; self.disappear = disappear
	}
	/// A DM is a chat with exactly two members and no name.
	public var isDirect: Bool { kind == .chat && name == nil && members.count == 2 }
}

public struct Attachment: Hashable, Codable, Sendable {
	public var hash: BlobHash
	public var key: String
	public var mime: String
	public var size: Int
	public var name: String?
	public var width: Int?
	public var height: Int?
	public var duration: Double?
	public init(hash: BlobHash, key: String = "", mime: String, size: Int, name: String? = nil, width: Int? = nil, height: Int? = nil, duration: Double? = nil) {
		self.hash = hash; self.key = key; self.mime = mime; self.size = size; self.name = name; self.width = width; self.height = height; self.duration = duration
	}
	public var isImage: Bool { mime.hasPrefix("image/") }
	public var isVideo: Bool { mime.hasPrefix("video/") }
	public var isAudio: Bool { mime.hasPrefix("audio/") }
}

public struct Reaction: Hashable, Sendable {
	public var key: String
	public var users: [UserId]
	public var mine: Bool
	public init(key: String, users: [UserId], mine: Bool) { self.key = key; self.users = users; self.mine = mine }
}

public enum EventType: String, Codable, Sendable { case message, edit, reaction, redact, receipt, member, card, state, create }

/// One resolved entry of a conversation: edits applied, reactions grouped, redactions gone.
public struct Event: Identifiable, Hashable, Sendable {
	public var id: EventId
	public var conv: ConversationId
	public var device: DeviceId
	public var seq: Int
	public var user: UserId
	public var at: Date
	public var lamport: Int
	public var type: EventType
	public var text: String?
	public var attachments: [Attachment]
	public var reply: EventId?
	public var thread: EventId?
	public var mentions: [UserId]
	public var reactions: [Reaction]
	public var edited: Bool
	public var replies: Int
	public var lastRepliers: [UserId]
	public var pinned: Bool
	/// For `member`, `state`, `create`: the line the timeline shows ("Ana added Jo").
	public var system: String?
	public var mine: Bool
	/// On a received event: the device that held it for this one while it was away.
	public var carriedBy: DeviceId?
	/// How it travelled: straight between the two devices, through a helper, carried by a device
	/// while the other was away, or still waiting (mine, not yet anywhere).
	public var via: Via?
	public enum Via: String, Hashable, Sendable { case direct, relay, carried, waiting }
	public init(id: EventId, conv: ConversationId, device: DeviceId, seq: Int, user: UserId, at: Date, lamport: Int, type: EventType, text: String? = nil, attachments: [Attachment] = [], reply: EventId? = nil, thread: EventId? = nil, mentions: [UserId] = [], reactions: [Reaction] = [], edited: Bool = false, replies: Int = 0, lastRepliers: [UserId] = [], pinned: Bool = false, system: String? = nil, mine: Bool = false, carriedBy: DeviceId? = nil) {
		self.id = id; self.conv = conv; self.device = device; self.seq = seq; self.user = user; self.at = at; self.lamport = lamport; self.type = type; self.text = text; self.attachments = attachments; self.reply = reply; self.thread = thread; self.mentions = mentions; self.reactions = reactions; self.edited = edited; self.replies = replies; self.lastRepliers = lastRepliers; self.pinned = pinned; self.system = system; self.mine = mine; self.carriedBy = carriedBy
	}
}

public struct Draft: Sendable {
	public var text: String
	public var attachments: [URL]
	public var reply: EventId?
	public var thread: EventId?
	public var mentions: [UserId]
	public init(text: String, attachments: [URL] = [], reply: EventId? = nil, thread: EventId? = nil, mentions: [UserId] = []) {
		self.text = text; self.attachments = attachments; self.reply = reply; self.thread = thread; self.mentions = mentions
	}
}

public enum DeliveryState: Hashable, Sendable { case sent, carried(by: DeviceId), delivered, read }

public struct DeviceDelivery: Hashable, Sendable {
	public var device: Device
	public var personName: String
	public var state: DeliveryState
	/// Every device holding an envelope for this one, named: "Ana's Mac", "your Mac".
	public var carriers: [String]
	public init(device: Device, personName: String, state: DeliveryState, carriers: [String] = []) { self.device = device; self.personName = personName; self.state = state; self.carriers = carriers }
}

/// Per device: sent | carried by [device] | delivered | read. Real data, never a guess.
public struct Delivery: Hashable, Sendable {
	public var event: EventId
	public var devices: [DeviceDelivery]
	public init(event: EventId, devices: [DeviceDelivery]) { self.event = event; self.devices = devices }
}

public struct Member: Identifiable, Hashable, Sendable {
	public var user: UserId
	public var name: String
	public var admin: Bool
	public var joinedAt: Date
	public var devices: [Device]
	public var verified: Bool
	public var me: Bool
	/// Their label in this group ("organiser", "plus one"), seen by everyone in it; nil for none.
	public var label: String?
	public var id: UserId { user }
	public init(user: UserId, name: String, admin: Bool, joinedAt: Date, devices: [Device], verified: Bool, me: Bool, label: String? = nil) {
		self.user = user; self.name = name; self.admin = admin; self.joinedAt = joinedAt; self.devices = devices; self.verified = verified; self.me = me; self.label = label
	}
	public var online: Bool { devices.contains { $0.online } }
}

/// How this device reaches another one right now.
public enum Path: Hashable, Sendable {
	case direct(ms: Int?)
	case relay(DeviceId, name: String)
	case nearby
	case waiting
	case unreachable
	case none
}

public enum FoundBy: String, Sendable { case cache, push, exchange, nearby, invite }

public struct Peer: Identifiable, Hashable, Sendable {
	public var device: Device
	public var userName: String
	public var own: Bool
	public var recordAge: TimeInterval?
	public var foundBy: FoundBy?
	public var relaying: Bool
	/// Envelopes that device holds for mine, and mine holds for it.
	public var holdingForMe: Int
	public var iHoldForIt: Int
	public var id: DeviceId { device.id }
	public init(device: Device, userName: String, own: Bool, recordAge: TimeInterval?, foundBy: FoundBy?, relaying: Bool = false, holdingForMe: Int = 0, iHoldForIt: Int = 0) {
		self.device = device; self.userName = userName; self.own = own; self.recordAge = recordAge; self.foundBy = foundBy; self.relaying = relaying; self.holdingForMe = holdingForMe; self.iHoldForIt = iHoldForIt
	}
}

public struct Held: Hashable, Sendable {
	public var device: DeviceId
	public var name: String
	public var count: Int
	public var bytes: Int
	public init(device: DeviceId, name: String, count: Int, bytes: Int) { self.device = device; self.name = name; self.count = count; self.bytes = bytes }
}

public struct Carrying: Hashable, Sendable {
	public var envelopes: Int
	public var bytes: Int
	public var budgetBytes: Int
	public var held: [Held]
	public init(envelopes: Int = 0, bytes: Int = 0, budgetBytes: Int = 200_000_000, held: [Held] = []) { self.envelopes = envelopes; self.bytes = bytes; self.budgetBytes = budgetBytes; self.held = held }
}

public struct Hit: Identifiable, Hashable, Sendable {
	public var event: Event
	public var conversation: Conversation
	public var snippet: String
	public var id: EventId { event.id }
	public init(event: Event, conversation: Conversation, snippet: String) { self.event = event; self.conversation = conversation; self.snippet = snippet }
}

public struct SearchScope: Hashable, Sendable {
	public var conversation: ConversationId?
	public var user: UserId?
	public var space: ConversationId?
	public init(conversation: ConversationId? = nil, user: UserId? = nil, space: ConversationId? = nil) { self.conversation = conversation; self.user = user; self.space = space }
}

public struct Transfer: Identifiable, Hashable, Sendable {
	public enum Direction: Sendable { case up, down }
	public var id: String
	public var blob: BlobHash
	public var name: String
	public var direction: Direction
	public var done: Int
	public var total: Int
	public var rate: Int
	public var paused: Bool
	/// Over 50 MB with the other side offline: "will send when you're both online".
	public var waiting: Bool
	public init(id: String, blob: BlobHash, name: String, direction: Direction, done: Int, total: Int, rate: Int, paused: Bool, waiting: Bool) {
		self.id = id; self.blob = blob; self.name = name; self.direction = direction; self.done = done; self.total = total; self.rate = rate; self.paused = paused; self.waiting = waiting
	}
}

/// A live session between online devices. Protocol only until E11; the stubs never return one.
public protocol Call: AnyObject, Sendable {
	var id: String { get }
	var conversation: ConversationId { get }
	var video: Bool { get }
	func accept() throws
	func decline() throws
	func end() throws
	func mute(_ on: Bool) throws
	func camera(_ on: Bool) throws
	func share(screen: Bool) throws
	func switchCamera() throws
	func participants() -> [Participant]
}

public struct Participant: Identifiable, Hashable, Sendable {
	public var device: DeviceId
	public var user: UserId
	public var tracks: [String]
	public var bandwidth: Int
	public var loss: Double
	public var latency: Int
	public var id: DeviceId { device }
	public init(device: DeviceId, user: UserId, tracks: [String], bandwidth: Int, loss: Double, latency: Int) { self.device = device; self.user = user; self.tracks = tracks; self.bandwidth = bandwidth; self.loss = loss; self.latency = latency }
}

/// Flat errors, each with the sentence the UI shows.
public enum CoreError: Error, Hashable, Sendable {
	case notFound, expired, used, badLink, notAdmin, notMember
	case offline(String)
	case unreachable(String)
	case store(String)
	public var sentence: String {
		switch self {
		case .notFound: return "That doesn't exist here."
		case .expired: return "That link has expired. Ask for a new one."
		case .used: return "That link was already used. Ask for a new one."
		case .badLink: return "That isn't a baud link."
		case .notAdmin: return "Only an admin can do that."
		case .notMember: return "You're not in that conversation."
		case .offline(let s), .unreachable(let s), .store(let s): return s
		}
	}
}

/// Ids only, on the core's thread; the app re-reads what changed.
public enum Change: Sendable {
	case me, contacts, conversations, peers, carrying, incomingCall
	case conversation(ConversationId)
	case delivery(ConversationId)
	case typing(ConversationId)
	/// Someone in this chat started, moved or stopped sharing where they are; or I did.
	case places(ConversationId)
	/// These disappearing messages went from this device: their notifications go too.
	case expired(ConversationId, [EventId])
}

public protocol Subscription: Sendable { func cancel() }

public protocol CoreSurface: AnyObject, Sendable {
	// me and my devices
	func me() -> Person
	func setName(_ name: String) throws
	func setAvatar(_ path: URL) throws
	func linkDevice() throws -> Link
	func link(_ link: Link) async throws
	func revoke(_ device: DeviceId) throws
	// contacts
	func invite() throws -> Link
	func add(_ link: Link) async throws -> Contact
	func contacts() -> [Contact]
	func verify(_ user: UserId, fingerprint: String) throws -> Bool
	// conversations
	func conversations(_ kind: Kind?) -> [Conversation]
	func conversation(_ id: ConversationId) -> Conversation?
	func events(_ conv: ConversationId, before: EventId?, limit: Int) -> [Event]
	func thread(_ conv: ConversationId, _ root: EventId, before: EventId?, limit: Int) -> [Event]
	func send(_ conv: ConversationId, _ draft: Draft) throws -> Event
	func react(_ conv: ConversationId, _ target: EventId, _ key: String, on: Bool) throws
	func edit(_ conv: ConversationId, _ target: EventId, text: String) throws
	func redact(_ conv: ConversationId, _ target: EventId) throws
	func pin(_ conv: ConversationId, _ target: EventId, on: Bool) throws
	func markRead(_ conv: ConversationId, _ event: EventId) throws
	func typing(_ conv: ConversationId)
	func typingNow(_ conv: ConversationId) -> [UserId]
	func members(_ conv: ConversationId) -> [Member]
	func addMember(_ conv: ConversationId, _ user: UserId) throws
	func removeMember(_ conv: ConversationId, _ user: UserId) throws
	func leave(_ conv: ConversationId) throws
	func setName(_ conv: ConversationId, _ name: String) throws
	/// A member's label in a group, for everyone in it: my own, or anyone's if I'm an admin. nil or empty takes it away.
	func setLabel(_ conv: ConversationId, _ user: UserId, _ text: String?) throws
	func setTopic(_ conv: ConversationId, _ topic: String) throws
	/// Messages written from now on disappear this many seconds after they're read; 0 turns it off.
	func setDisappear(_ conv: ConversationId, _ seconds: Int) throws
	func delivery(_ conv: ConversationId, _ event: EventId) -> Delivery
	func createChat(_ users: [UserId]) throws -> Conversation
	func createGroup(_ name: String, users: [UserId]) throws -> Conversation
	func createSpace(_ name: String) throws -> Conversation
	func createChannel(space: ConversationId, name: String) throws -> Conversation
	func join(space: ConversationId, channel: ConversationId) throws
	func channels(space: ConversationId) -> [Conversation]
	func search(_ query: String, scope: SearchScope?) -> [Hit]
	func blob(_ hash: BlobHash, key: String) async throws -> URL
	// the network, honestly
	func peers() -> [Peer]
	func carrying() -> Carrying
	func transfers(_ conv: ConversationId) -> [Transfer]
	func call(_ conv: ConversationId, video: Bool) throws -> Call
	func incoming() -> Call?
	func setOnline(_ online: Bool)
	func subscribe(_ listener: @escaping @Sendable (Change) -> Void) -> Subscription
}
