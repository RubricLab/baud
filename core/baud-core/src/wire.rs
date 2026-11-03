//! What crosses between two devices (`Wire.swift`, `Transport.swift`'s `Packet`): feed entries,
//! receipts, typing, cards, envelopes, clocks, files. JSON in the shape Swift's synthesized
//! `Codable` gives: an enum case is `{"case": {…}}`, its unnamed values `_0`, `_1`; `Data` is
//! base64; an absent optional is no key at all.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::types::{Attachment, BlobHash, ConversationId, DeviceId, DeviceKind, EventId, EventType, Kind, UserId};

/// `Data` as Foundation codes it: standard base64 with padding.
pub mod b64 {
    use base64::Engine;
    use base64::engine::general_purpose::STANDARD;
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(v: &[u8], s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&STANDARD.encode(v))
    }
    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Vec<u8>, D::Error> {
        STANDARD.decode(String::deserialize(d)?).map_err(serde::de::Error::custom)
    }

    pub mod opt {
        use super::*;
        pub fn serialize<S: Serializer>(v: &Option<Vec<u8>>, s: S) -> Result<S::Ok, S::Error> {
            match v {
                Some(b) => super::serialize(b, s),
                None => s.serialize_none(),
            }
        }
        pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Option<Vec<u8>>, D::Error> {
            match Option::<String>::deserialize(d)? {
                Some(t) => STANDARD.decode(t).map(Some).map_err(serde::de::Error::custom),
                None => Ok(None),
            }
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WireDevice {
    pub id: DeviceId,
    pub name: String,
    pub kind: DeviceKind,
    pub added_at: f64,
}

/// `peer_card` is the crate's own signed card for this person, carried so a co-member can admit
/// their devices (`add_member(group, card)`) without ever being their contact.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WireCard {
    pub user: UserId,
    pub name: String,
    pub fingerprint: String,
    pub devices: Vec<WireDevice>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub avatar: Option<BlobHash>,
    #[serde(skip_serializing_if = "Option::is_none", default, with = "b64::opt")]
    pub peer_card: Option<Vec<u8>>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct WireEvent {
    pub id: EventId,
    pub conv: ConversationId,
    pub device: DeviceId,
    pub seq: i64,
    pub user: UserId,
    pub at: f64,
    pub lamport: i64,
    #[serde(rename = "type")]
    pub kind: EventType,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub reply: Option<EventId>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub thread: Option<EventId>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub target: Option<EventId>,
    /// The payload as JSON, by type. Kept as the writer wrote it: it travels on verbatim.
    pub body: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct WireReceipt {
    pub conv: ConversationId,
    pub device: DeviceId,
    pub user: UserId,
    pub event: EventId,
    pub lamport: i64,
    /// delivered | read
    pub kind: String,
    pub at: f64,
}

/// A sealed event in transit (the in-process mesh's carrying; the crate carries its own).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct WireEnvelope {
    pub id: String,
    pub to: DeviceId,
    pub from: DeviceId,
    pub conv: ConversationId,
    pub frame: Frame,
    pub size: i64,
    pub expires: f64,
    pub hops: i64,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Frame {
    Events(Vec<WireEvent>),
    Receipt(WireReceipt),
    Typing(ConversationId, UserId),
    /// Invite: the opener's card (the in-process stub's handshake; the crate meets on its own).
    Hello { secret: String, card: WireCard },
    /// Invite: the inviter answers.
    Welcome { card: WireCard },
    /// A new device of mine asks in.
    Link { secret: String, device: WireDevice },
    /// A newer card for the writer's user.
    Card(WireCard),
    Envelope(Box<WireEnvelope>),
    /// The recipient got the envelope.
    Ack(String),
    /// On connect: what I have per feed; answer with what I lack.
    Clock(ConversationId, BTreeMap<DeviceId, i64>),
    /// The answer's own clock, when it lacks something: never answered.
    ClockReply(ConversationId, BTreeMap<DeviceId, i64>),
    /// A call in this chat and who's in it (`CallWire.swift`): passed through, calls come later.
    InCall(ConversationId, serde_json::Value),
    /// A file I lack, by its hash: who holds it and may give it says so.
    Want(BlobHash),
    /// I hold it: fetch it from my blob store by this id.
    Offer(BlobHash, String),
    /// Pass these sealed bytes on to that device: I hold no card for it, you do.
    Relay(DeviceId, Vec<u8>),
    /// A sealed ticket to wake the sender while it's asleep, and when it expires (unix seconds):
    /// an iPhone's push addresses sealed to the wake relay's key (`Wake.swift`).
    Wake(Vec<u8>, f64),
    /// Where I am, for this chat (`Places.swift`): direct to its online devices only, never carried.
    Place(ConversationId, WirePlace),
}

/// A place on the wire: unix seconds, `until` absent while it runs until stopped; a stop is a
/// place whose `until` has passed.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct WirePlace {
    pub user: UserId,
    pub device: DeviceId,
    pub lat: f64,
    pub lon: f64,
    pub accuracy: f64,
    pub at: f64,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub until: Option<f64>,
}

impl WirePlace {
    pub fn over(&self, now: f64) -> bool {
        self.until.map(|u| u <= now).unwrap_or(false)
    }
}

#[derive(Serialize, Deserialize)]
struct One<A> {
    #[serde(rename = "_0")]
    a: A,
}

#[derive(Serialize, Deserialize)]
struct Two<A, B> {
    #[serde(rename = "_0")]
    a: A,
    #[serde(rename = "_1")]
    b: B,
}

#[derive(Serialize, Deserialize)]
struct Bytes(#[serde(with = "b64")] Vec<u8>);

/// The frame as Swift's synthesized `Codable` lays it out.
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
enum Raw {
    Events(One<Vec<WireEvent>>),
    Receipt(One<WireReceipt>),
    Typing(Two<String, String>),
    Hello { secret: String, card: WireCard },
    Welcome { card: WireCard },
    Link { secret: String, device: WireDevice },
    Card(One<WireCard>),
    Envelope(One<Box<WireEnvelope>>),
    Ack(One<String>),
    Clock(Two<String, BTreeMap<String, i64>>),
    ClockReply(Two<String, BTreeMap<String, i64>>),
    InCall(Two<String, serde_json::Value>),
    Want(One<String>),
    Offer(Two<String, String>),
    Relay(Two<String, Bytes>),
    Wake(Two<Bytes, f64>),
    Place(Two<String, WirePlace>),
}

impl Serialize for Frame {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        let one = |a| One { a };
        let r = match self.clone() {
            Frame::Events(v) => Raw::Events(one(v)),
            Frame::Receipt(r) => Raw::Receipt(One { a: r }),
            Frame::Typing(a, b) => Raw::Typing(Two { a, b }),
            Frame::Hello { secret, card } => Raw::Hello { secret, card },
            Frame::Welcome { card } => Raw::Welcome { card },
            Frame::Link { secret, device } => Raw::Link { secret, device },
            Frame::Card(c) => Raw::Card(One { a: c }),
            Frame::Envelope(e) => Raw::Envelope(One { a: e }),
            Frame::Ack(a) => Raw::Ack(One { a }),
            Frame::Clock(a, b) => Raw::Clock(Two { a, b }),
            Frame::ClockReply(a, b) => Raw::ClockReply(Two { a, b }),
            Frame::InCall(a, b) => Raw::InCall(Two { a, b }),
            Frame::Want(a) => Raw::Want(One { a }),
            Frame::Offer(a, b) => Raw::Offer(Two { a, b }),
            Frame::Relay(a, b) => Raw::Relay(Two { a, b: Bytes(b) }),
            Frame::Wake(t, e) => Raw::Wake(Two { a: Bytes(t), b: e }),
            Frame::Place(c, p) => Raw::Place(Two { a: c, b: p }),
        };
        r.serialize(s)
    }
}

impl<'de> Deserialize<'de> for Frame {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        Ok(match Raw::deserialize(d)? {
            Raw::Events(x) => Frame::Events(x.a),
            Raw::Receipt(x) => Frame::Receipt(x.a),
            Raw::Typing(x) => Frame::Typing(x.a, x.b),
            Raw::Hello { secret, card } => Frame::Hello { secret, card },
            Raw::Welcome { card } => Frame::Welcome { card },
            Raw::Link { secret, device } => Frame::Link { secret, device },
            Raw::Card(x) => Frame::Card(x.a),
            Raw::Envelope(x) => Frame::Envelope(x.a),
            Raw::Ack(x) => Frame::Ack(x.a),
            Raw::Clock(x) => Frame::Clock(x.a, x.b),
            Raw::ClockReply(x) => Frame::ClockReply(x.a, x.b),
            Raw::InCall(x) => Frame::InCall(x.a, x.b),
            Raw::Want(x) => Frame::Want(x.a),
            Raw::Offer(x) => Frame::Offer(x.a, x.b),
            Raw::Relay(x) => Frame::Relay(x.a, x.b.0),
            Raw::Wake(x) => Frame::Wake(x.a.0, x.b),
            Raw::Place(x) => Frame::Place(x.a, x.b),
        })
    }
}

// Payload bodies, one per event type.

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct MessageBody {
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub attachments: Option<Vec<Attachment>>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub reply: Option<EventId>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub thread: Option<EventId>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub mentions: Option<Vec<UserId>>,
    /// Written while the conversation's messages disappear: the seconds this one lasts after it
    /// is read (after it is sent, for its writer). Absent otherwise, so the bytes are as before.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub ttl: Option<i64>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct EditBody {
    pub target: EventId,
    pub text: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ReactionBody {
    pub target: EventId,
    pub key: String,
    pub on: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct RedactBody {
    pub target: EventId,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct MemberBody {
    pub user: UserId,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub card: Option<WireCard>,
    /// add | remove | leave
    pub action: String,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub admin: Option<bool>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct StateBody {
    pub key: String,
    pub value: String,
}

/// A member's label in a group (the "label" state, `LabelBody` in Wire.swift): who, and the
/// words; empty takes it away.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct LabelBody {
    pub user: UserId,
    pub text: String,
}

/// A call that's over, as its line reads: "Video call · 4 min", "Missed call from Ana".
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct CallRecord {
    pub video: bool,
    pub outcome: String,
    pub seconds: i64,
}

impl CallRecord {
    pub fn line(&self, mine: bool, caller: &str) -> String {
        let kind = if self.video { "Video call" } else { "Call" };
        let lower = kind.to_lowercase();
        match self.outcome.as_str() {
            "talked" => format!("{kind} · {}", if self.seconds < 60 { format!("{} s", self.seconds.max(1)) } else { format!("{} min", self.seconds / 60) }),
            "declined" => if mine { format!("{kind} · declined") } else { format!("Declined {lower} from {caller}") },
            "busy" => if mine { format!("{kind} · they were on another call") } else { format!("Missed {lower} from {caller}") },
            "cancelled" => if mine { format!("{kind} · cancelled") } else { format!("Missed {lower} from {caller}") },
            _ => if mine { format!("{kind} · no answer") } else { format!("Missed {lower} from {caller}") },
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateBody {
    #[serde(with = "kind_str")]
    pub kind: Kind,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub space: Option<ConversationId>,
    /// members | shared
    pub history: String,
    pub creator: WireCard,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub is_default: Option<bool>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChannelRef {
    pub conv: ConversationId,
    pub name: String,
    pub is_default: bool,
}

mod kind_str {
    use super::Kind;
    use serde::{Deserialize, Deserializer, Serializer};
    pub fn serialize<S: Serializer>(k: &Kind, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(k.as_str())
    }
    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Kind, D::Error> {
        let s = String::deserialize(d)?;
        Kind::parse(&s).ok_or_else(|| serde::de::Error::custom(format!("kind {s}")))
    }
}

/// The wire's version: packets without it are from before the legacy wipe and are dropped.
pub const WIRE_VERSION: i64 = 2;

/// What crosses the transport: a frame, sealed with its conversation's key when it has one. A
/// membership frame to a joiner (or anything to another device of mine) carries the key; it
/// travels only over the crate's device-to-device encryption.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Packet {
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub v: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub conv: Option<ConversationId>,
    #[serde(skip_serializing_if = "Option::is_none", default, with = "b64::opt")]
    pub key: Option<Vec<u8>>,
    #[serde(skip_serializing_if = "Option::is_none", default, with = "b64::opt")]
    pub nonce: Option<Vec<u8>>,
    #[serde(with = "b64")]
    pub body: Vec<u8>,
}

/// ChaCha20-Poly1305 as CryptoKit's `ChaChaPoly`: a random 12-byte nonce, the tag after the
/// ciphertext, no associated data.
pub fn seal_box(key: &[u8; 32], nonce: &[u8; 12], plain: &[u8]) -> Vec<u8> {
    use chacha20poly1305::aead::{Aead, KeyInit};
    let cipher = chacha20poly1305::ChaCha20Poly1305::new(key.into());
    cipher.encrypt(nonce.into(), plain).unwrap_or_default()
}

pub fn open_box(key: &[u8; 32], nonce: &[u8], sealed: &[u8]) -> Option<Vec<u8>> {
    use chacha20poly1305::aead::{Aead, KeyInit};
    let nonce: &[u8; 12] = nonce.try_into().ok()?;
    let cipher = chacha20poly1305::ChaCha20Poly1305::new(key.into());
    cipher.decrypt(nonce.into(), sealed).ok()
}

/// A frame for the wire: plain when there is no conversation, else sealed with its key (and the
/// key alongside for a joiner).
pub fn seal_packet(frame: &Frame, conv: Option<(&str, &[u8; 32])>, joiner: bool, nonce: [u8; 12]) -> Vec<u8> {
    let plain = crate::json::encode_bytes(frame);
    let p = match conv {
        None => Packet { v: Some(WIRE_VERSION), conv: None, key: None, nonce: None, body: plain },
        Some((c, key)) => Packet {
            v: Some(WIRE_VERSION),
            conv: Some(c.to_owned()),
            key: joiner.then(|| key.to_vec()),
            nonce: Some(nonce.to_vec()),
            body: seal_box(key, &nonce, &plain),
        },
    };
    crate::json::encode_bytes(&p)
}
