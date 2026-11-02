//! Every type an app reads: `Surface.swift` in Rust. Ids are opaque strings the core hands out;
//! times are unix milliseconds. Listeners carry ids and views re-read, so there is one object
//! (`Core`) and no handles to keep alive.

use serde::{Deserialize, Serialize};

pub type DeviceId = String;
pub type UserId = String;
pub type ConversationId = String;
pub type EventId = String;
pub type BlobHash = String;

/// What a device is, for "Jo's iPhone". On the wire `mac`, `iphone`, `android`, `node`; a kind
/// this version doesn't know reads as a node, so a card listing one still reads.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum DeviceKind {
    Mac,
    Iphone,
    Android,
    #[default]
    Node,
}

impl DeviceKind {
    pub fn as_str(self) -> &'static str {
        match self {
            DeviceKind::Mac => "mac",
            DeviceKind::Iphone => "iphone",
            DeviceKind::Android => "android",
            DeviceKind::Node => "node",
        }
    }
    pub fn parse(s: &str) -> DeviceKind {
        match s {
            "mac" => DeviceKind::Mac,
            "iphone" | "ipad" => DeviceKind::Iphone,
            "android" => DeviceKind::Android,
            _ => DeviceKind::Node,
        }
    }
    /// "Mac", "iPhone", "phone", "device": the word after "Ana's", as `Device.possessive` says it.
    pub fn word(self) -> &'static str {
        match self {
            DeviceKind::Mac => "Mac",
            DeviceKind::Iphone => "iPhone",
            DeviceKind::Android => "phone",
            DeviceKind::Node => "device",
        }
    }
}

impl Serialize for DeviceKind {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(self.as_str())
    }
}
impl<'de> Deserialize<'de> for DeviceKind {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        Ok(DeviceKind::parse(&String::deserialize(d)?))
    }
}

/// How this device reaches another one right now.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum Path {
    Direct { ms: Option<u32> },
    Relay { device: DeviceId, name: String },
    Nearby,
    Waiting,
    Unreachable,
    NotConnected,
}

/// One install of someone's, with what this device knows about reaching it right now.
#[derive(Clone, Debug, PartialEq)]
pub struct Device {
    pub id: DeviceId,
    pub name: String,
    pub kind: DeviceKind,
    pub user: UserId,
    pub added_at: i64,
    pub online: bool,
    pub last_online: Option<i64>,
    pub path: Path,
    /// "online, direct, 14 ms" · "last online 2 h ago" · "never online".
    pub sentence: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Person {
    pub user: UserId,
    pub name: String,
    pub fingerprint: String,
    pub devices: Vec<Device>,
    pub this_device: DeviceId,
    /// The photo, as a blob hash on the card; none until one is set.
    pub avatar: Option<BlobHash>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum LinkKind {
    Friend,
    Device,
    /// An answer to my friend link, from someone who couldn't reach me: opening it meets them.
    Reply,
}

/// An invite or a device link: `baud://add#…` / `baud://link#…`.
#[derive(Clone, Debug, PartialEq)]
pub struct Link {
    pub url: String,
    pub kind: LinkKind,
    /// Whose it is: the inviter's name.
    pub name: String,
    pub expires: i64,
    /// The same link as `https://baud.rubric.sh/add#…`, for people who don't have baud yet.
    pub web: String,
    /// What people copy or read: everything after the `#`.
    pub code: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Contact {
    pub user: UserId,
    pub name: String,
    pub verified: bool,
    pub fingerprint: String,
    pub devices: Vec<Device>,
    pub met_at: i64,
    pub avatar: Option<BlobHash>,
    /// Came by an identity redirect: their old key vouches for this one; not verified.
    pub vouched: bool,
    pub online: bool,
    pub last_online: Option<i64>,
    /// "online on their Mac" · "last online 3 h ago" · "never online".
    pub sentence: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Kind {
    Chat,
    Channel,
    Space,
    Home,
}

impl Kind {
    pub fn as_str(self) -> &'static str {
        match self {
            Kind::Chat => "chat",
            Kind::Channel => "channel",
            Kind::Space => "space",
            Kind::Home => "home",
        }
    }
    pub fn parse(s: &str) -> Option<Kind> {
        Some(match s {
            "chat" => Kind::Chat,
            "channel" => Kind::Channel,
            "space" => Kind::Space,
            "home" => Kind::Home,
            _ => return None,
        })
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Conversation {
    pub id: ConversationId,
    pub kind: Kind,
    pub name: Option<String>,
    pub topic: Option<String>,
    pub space: Option<ConversationId>,
    pub members: Vec<UserId>,
    pub admins: Vec<UserId>,
    pub created_at: i64,
    pub last_at: i64,
    pub last_text: Option<String>,
    pub last_user: Option<UserId>,
    pub last_event: Option<EventId>,
    pub unread: u32,
    pub mentions: u32,
    pub event_count: u32,
    pub is_default: bool,
    pub pinned: Vec<EventId>,
    /// A chat with exactly two members and no name.
    pub is_direct: bool,
    /// Disappearing messages: how many seconds a message written now lasts after it is read; 0 is off.
    pub disappear: u32,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Attachment {
    pub hash: BlobHash,
    #[serde(default)]
    pub key: String,
    pub mime: String,
    pub size: u64,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub width: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub height: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub duration: Option<f64>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Reaction {
    pub key: String,
    pub users: Vec<UserId>,
    pub mine: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum EventType {
    Message,
    Edit,
    Reaction,
    Redact,
    Receipt,
    Member,
    Card,
    State,
    Create,
}

impl EventType {
    pub fn as_str(self) -> &'static str {
        match self {
            EventType::Message => "message",
            EventType::Edit => "edit",
            EventType::Reaction => "reaction",
            EventType::Redact => "redact",
            EventType::Receipt => "receipt",
            EventType::Member => "member",
            EventType::Card => "card",
            EventType::State => "state",
            EventType::Create => "create",
        }
    }
    pub fn parse(s: &str) -> EventType {
        match s {
            "edit" => EventType::Edit,
            "reaction" => EventType::Reaction,
            "redact" => EventType::Redact,
            "receipt" => EventType::Receipt,
            "member" => EventType::Member,
            "card" => EventType::Card,
            "state" => EventType::State,
            "create" => EventType::Create,
            _ => EventType::Message,
        }
    }
}

/// How a message travelled: straight between the two devices, through a helper, carried by a
/// device while the other was away, or still waiting (mine, not yet anywhere).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Via {
    Direct,
    Relay,
    Carried,
    Waiting,
}

impl Via {
    pub fn parse(s: &str) -> Option<Via> {
        Some(match s {
            "direct" => Via::Direct,
            "relay" => Via::Relay,
            "carried" => Via::Carried,
            "waiting" => Via::Waiting,
            _ => return None,
        })
    }
}

/// One resolved entry of a conversation: edits applied, reactions grouped, redactions gone.
#[derive(Clone, Debug, PartialEq)]
pub struct Event {
    pub id: EventId,
    pub conv: ConversationId,
    pub device: DeviceId,
    pub seq: u64,
    pub user: UserId,
    pub at: i64,
    pub lamport: u64,
    pub kind: EventType,
    pub text: Option<String>,
    pub attachments: Vec<Attachment>,
    pub reply: Option<EventId>,
    pub thread: Option<EventId>,
    pub mentions: Vec<UserId>,
    pub reactions: Vec<Reaction>,
    pub edited: bool,
    pub replies: u32,
    pub last_repliers: Vec<UserId>,
    pub pinned: bool,
    /// For `member`, `state`, `create`: the line the timeline shows ("Ana added Jo").
    pub system: Option<String>,
    pub mine: bool,
    /// On a received event: the device that held it for this one while it was away.
    pub carried_by: Option<DeviceId>,
    pub via: Option<Via>,
}

/// What `send` takes: text, files by path, a reply, a thread root, mentions.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Draft {
    pub text: String,
    pub attachments: Vec<String>,
    pub reply: Option<EventId>,
    pub thread: Option<EventId>,
    pub mentions: Vec<UserId>,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum DeliveryState {
    Sent,
    Carried { by: DeviceId },
    Delivered,
    Read,
}

#[derive(Clone, Debug, PartialEq)]
pub struct DeviceDelivery {
    pub device: Device,
    pub person_name: String,
    pub state: DeliveryState,
    /// Every device holding an envelope for this one, named: "Ana's Mac", "your Mac".
    pub carriers: Vec<String>,
}

/// Per device: sent | carried by [device] | delivered | read. Real data, never a guess.
#[derive(Clone, Debug, PartialEq)]
pub struct Delivery {
    pub event: EventId,
    pub devices: Vec<DeviceDelivery>,
    /// "read" · "delivered to Ana's iPhone" · "carried by Jo's Mac · waiting for Ana's iPhone".
    pub sentence: String,
    /// One word for the row: read > delivered > carried > sent.
    pub best: DeliveryState,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Member {
    pub user: UserId,
    pub name: String,
    pub admin: bool,
    pub joined_at: i64,
    pub devices: Vec<Device>,
    pub verified: bool,
    pub me: bool,
    pub online: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum FoundBy {
    Cache,
    Push,
    Exchange,
    Nearby,
    Invite,
}

impl FoundBy {
    pub fn parse(s: &str) -> Option<FoundBy> {
        Some(match s {
            "cache" => FoundBy::Cache,
            "push" => FoundBy::Push,
            "exchange" => FoundBy::Exchange,
            "nearby" => FoundBy::Nearby,
            "invite" => FoundBy::Invite,
            _ => return None,
        })
    }
    pub fn as_str(self) -> &'static str {
        match self {
            FoundBy::Cache => "cache",
            FoundBy::Push => "push",
            FoundBy::Exchange => "exchange",
            FoundBy::Nearby => "nearby",
            FoundBy::Invite => "invite",
        }
    }
}

/// A device on the Network screen.
#[derive(Clone, Debug, PartialEq)]
pub struct Peer {
    pub device: Device,
    pub user_name: String,
    pub own: bool,
    /// How old the address record for it is, in ms.
    pub record_age: Option<i64>,
    pub found_by: Option<FoundBy>,
    pub relaying: bool,
    /// Envelopes that device holds for mine, and mine holds for it.
    pub holding_for_me: u32,
    pub i_hold_for_it: u32,
    pub sentence: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Held {
    pub device: DeviceId,
    pub name: String,
    pub count: u32,
    pub bytes: u64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Carrying {
    pub envelopes: u32,
    pub bytes: u64,
    pub budget_bytes: u64,
    pub held: Vec<Held>,
    pub sentence: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Hit {
    pub event: Event,
    pub conversation: Conversation,
    pub snippet: String,
}

/// This device on the network, in the words the status line uses.
#[derive(Clone, Debug, PartialEq)]
pub enum NetState {
    /// `setOnline(false)`.
    Offline,
    /// Reached from outside: it runs the relay, its router holds a port, or a punch gets through.
    Online,
    /// Reached through the meeting device, one of mine (`own`) or a friend's, held live.
    Through { name: String, own: bool },
    /// Nobody can reach this device right now; `away` names the meeting device that is away.
    NotReachable { away: Option<String> },
}

/// Ids only, on the core's thread; the app re-reads what changed.
#[derive(Clone, Debug, PartialEq)]
pub enum Change {
    Me,
    Contacts,
    Conversations,
    Peers,
    Carrying,
    Conversation { id: ConversationId },
    Delivery { conv: ConversationId },
    Typing { conv: ConversationId },
    /// A device asks to become mine: show `code` and the device, then `confirm_link(req, …)`.
    LinkRequest { req: u64, code: String, device: DeviceId, name: String, kind: DeviceKind },
    /// A link being redeemed here reached the device it names: the other side has the request.
    Reached { device: DeviceId },
    /// Another of my devices removed this one: say so, then `reset()`.
    Removed,
    /// Reachability or the meeting device changed: re-read `net_state()`.
    Network,
    /// Someone's place in this chat changed, or my share in it did: re-read `places(conv)`.
    Places { conv: ConversationId },
    /// A reply I made (`reply`) was opened by its link's maker: we met, they're a contact.
    Replied { user: UserId },
    /// A reply I made stopped waiting unopened (it ran out, or their link went to someone else).
    ReplyLapsed { user: UserId },
    /// These disappearing messages went from this device: their notifications go too.
    Expired { conv: ConversationId, events: Vec<EventId> },
}

/// Where someone in a chat is, while they share it (`Places.swift`). Times in ms.
#[derive(Clone, Debug, PartialEq)]
pub struct Place {
    pub user: UserId,
    pub device: DeviceId,
    pub lat: f64,
    pub lon: f64,
    /// Metres either way.
    pub accuracy: f64,
    /// When the fix was taken.
    pub at: i64,
    /// When the share ends; none: until they stop.
    pub until: Option<i64>,
}

/// A chat I share my location in, and until when (none: until I stop).
#[derive(Clone, Debug, PartialEq)]
pub struct Share {
    pub conv: ConversationId,
    pub until: Option<i64>,
}

/// How the core opens. `device_kind` is this device's; the switches are peer's.
#[derive(Clone, Debug)]
pub struct Config {
    pub name: String,
    pub device_name: String,
    pub device_kind: DeviceKind,
    /// Announce and find devices on the local network.
    pub nearby: bool,
    /// Ask the router for a port. Tests and labs turn it off.
    pub portmap: bool,
    /// Run the relay for my people while the router holds its port (a computer at home).
    pub relay: bool,
    /// The port is reachable without a mapping (a server); lab use.
    pub public: bool,
    /// Advertise and dial VPN addresses.
    pub vpn: bool,
    /// The wake relay; none: `BAUD_WAKE_URL`, else https://wake.baud.rubric.sh.
    pub wake_url: Option<String>,
}

impl Config {
    pub fn new(name: &str, device_name: &str, device_kind: DeviceKind) -> Config {
        Config { name: name.into(), device_name: device_name.into(), device_kind, nearby: true, portmap: true, relay: false, public: false, vpn: true, wake_url: None }
    }
}
