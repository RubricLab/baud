/// What crosses between two devices in the stub: feed entries, receipts, typing, the invite and
/// link handshakes. JSON here; postcard and ciphertext in the crate. Cards ride inside `create`
/// and `member` events, as in SPEC.md, so a device can verify membership before it has keys.
import Foundation

struct WireDevice: Codable, Hashable { var id: DeviceId; var name: String; var kind: DeviceKind; var addedAt: Double }
/// `peerCard` is the crate's own signed card for this person, carried so a co-member can admit
/// their devices (`addMember(group:card:)`) without ever being their contact.
struct WireCard: Codable, Hashable { var user: UserId; var name: String; var fingerprint: String; var devices: [WireDevice]; var avatar: BlobHash?; var peerCard: Data? }

struct WireEvent: Codable, Hashable {
	var id: EventId
	var conv: ConversationId
	var device: DeviceId
	var seq: Int
	var user: UserId
	var at: Double
	var lamport: Int
	var type: EventType
	var text: String?
	var reply: EventId?
	var thread: EventId?
	var target: EventId?
	var body: String   // the payload as JSON, by type
}

struct WireReceipt: Codable, Hashable {
	var conv: ConversationId
	var device: DeviceId
	var user: UserId
	var event: EventId
	var lamport: Int
	var kind: String   // delivered | read
	var at: Double
}

/// A sealed event in transit: who it's for and nothing else a carrier can read.
struct WireEnvelope: Codable, Hashable {
	var id: String
	var to: DeviceId
	var from: DeviceId
	var conv: ConversationId
	var frame: Frame
	var size: Int
	var expires: Double
	var hops: Int
}

indirect enum Frame: Codable, Hashable {
	case events([WireEvent])
	case receipt(WireReceipt)
	case typing(ConversationId, UserId)
	case hello(secret: String, card: WireCard)       // invite: the opener's card
	case welcome(card: WireCard)                      // invite: the inviter answers
	case link(secret: String, device: WireDevice)     // a new device of mine asks in
	case card(WireCard)                               // a newer card for the writer's user
	case envelope(WireEnvelope)                       // handed to a carrier
	case ack(String)                                  // the recipient got the envelope
	case clock(ConversationId, [DeviceId: Int])       // on connect: what I have per feed; answer with what I lack
	case clockReply(ConversationId, [DeviceId: Int])  // the answer's own clock, when it lacks something: never answered
	case inCall(ConversationId, CallPresence)         // a call in this chat, and who's in it (CallWire.swift)
	case want(BlobHash)                               // a file I lack, by its hash: who holds it and may give it says so
	case offer(BlobHash, String)                      // I hold it: fetch it from my blob store by this id
	case relay(DeviceId, Data)                        // pass these sealed bytes on to that device: I hold no card for it, you do
	case wake(Data, Double)                           // a sealed ticket to wake me while I'm asleep, and when it expires (Wake.swift)
	case place(ConversationId, Place)                 // where I am, for this chat (Places.swift): direct only, never carried
}

// Payload bodies, one per event type.
/// `ttl`: written while the conversation's messages disappear, the seconds this one lasts after
/// it is read (after it is sent, for its writer); absent otherwise.
struct MessageBody: Codable { var text: String?; var attachments: [Attachment]?; var reply: EventId?; var thread: EventId?; var mentions: [UserId]?; var ttl: Int? }
struct EditBody: Codable { var target: EventId; var text: String }
struct ReactionBody: Codable { var target: EventId; var key: String; var on: Bool }
struct RedactBody: Codable { var target: EventId }
struct MemberBody: Codable { var user: UserId; var card: WireCard?; var action: String; var admin: Bool? }
struct StateBody: Codable { var key: String; var value: String }
/// A member's label in a group ("label" state): who, and the words; empty takes it away.
struct LabelBody: Codable { var user: String; var text: String }
/// A call that's over, as its line reads: "Video call · 4 min", "Missed call from Ana", "Call · no answer".
struct CallRecord: Codable {
	var video: Bool; var outcome: String; var seconds: Int
	func line(mine: Bool, caller: String) -> String {
		let kind = video ? "Video call" : "Call"
		switch outcome {
		case "talked": return "\(kind) · \(seconds < 60 ? "\(max(1, seconds)) s" : "\(seconds / 60) min")"
		case "declined": return mine ? "\(kind) · declined" : "Declined \(kind.lowercased()) from \(caller)"
		case "busy": return mine ? "\(kind) · they were on another call" : "Missed \(kind.lowercased()) from \(caller)"
		case "cancelled": return mine ? "\(kind) · cancelled" : "Missed \(kind.lowercased()) from \(caller)"
		default: return mine ? "\(kind) · no answer" : "Missed \(kind.lowercased()) from \(caller)"
		}
	}
}
struct CreateBody: Codable { var kind: Kind; var name: String?; var space: ConversationId?; var history: String; var creator: WireCard; var isDefault: Bool? }

let json = JSONEncoder()
let unjson = JSONDecoder()
func encode<T: Encodable>(_ v: T) -> String { String(decoding: (try? json.encode(v)) ?? Data(), as: UTF8.self) }
func decode<T: Decodable>(_ t: T.Type, _ s: String?) -> T? { s.flatMap { try? unjson.decode(t, from: Data($0.utf8)) } }
