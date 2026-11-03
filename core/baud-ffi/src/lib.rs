//! baud for Kotlin (and Swift later): `Baud` is `CoreSurface` over baud-core, by proc-macro
//! UniFFI. The types are baud-core's own, declared here as remote so nothing is converted twice;
//! the app implements `Keychain` (its keystore) and `Listener` (ids only, re-read on its side).
//! Every time is unix milliseconds. No panic reaches the app: each call that cannot fail answers
//! its fallback, each that can answers `BaudError.Failed`, as peer-uniffi does.

use std::sync::{Arc, Mutex};

use baud_core::types::*;

uniffi::setup_scaffolding!("baud");

/// One case per thing the UI says differently; the message is the sentence to show.
#[derive(Debug, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum BaudError {
    #[error("{0}")]
    NotFound(String),
    #[error("{0}")]
    Expired(String),
    #[error("{0}")]
    Used(String),
    #[error("{0}")]
    BadLink(String),
    #[error("{0}")]
    NotAdmin(String),
    #[error("{0}")]
    NotMember(String),
    /// The other side said no (their gate closed, or my other device declined the link).
    #[error("{0}")]
    Refused(String),
    #[error("{0}")]
    Offline(String),
    #[error("{0}")]
    Unreachable(String),
    #[error("{0}")]
    Store(String),
    #[error("{0}")]
    Failed(String),
}

impl From<baud_core::Error> for BaudError {
    fn from(e: baud_core::Error) -> Self {
        use baud_core::Error as E;
        let m = e.to_string();
        match e {
            E::NotFound => BaudError::NotFound(m),
            E::Expired => BaudError::Expired(m),
            E::Used => BaudError::Used(m),
            E::BadLink => BaudError::BadLink(m),
            E::NotAdmin => BaudError::NotAdmin(m),
            E::NotMember => BaudError::NotMember(m),
            E::Refused(_) => BaudError::Refused(m),
            E::Offline(_) => BaudError::Offline(m),
            E::Unreachable(_) => BaudError::Unreachable(m),
            E::Store(_) => BaudError::Store(m),
            E::Failed(_) => BaudError::Failed(m),
        }
    }
}

fn guard<T>(fallback: impl FnOnce() -> T, f: impl FnOnce() -> T) -> T {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)).unwrap_or_else(|_| fallback())
}

fn fallible<T>(f: impl FnOnce() -> Result<T, baud_core::Error>) -> Result<T, BaudError> {
    guard(panicked, || f().map_err(BaudError::from))
}

async fn fallible_async<T>(f: impl std::future::Future<Output = Result<T, baud_core::Error>>) -> Result<T, BaudError> {
    match Unwinding(Box::pin(f)).await {
        Some(r) => r.map_err(BaudError::from),
        None => panicked(),
    }
}

fn panicked<T>() -> Result<T, BaudError> {
    Err(BaudError::Failed("baud's core panicked: see its trace".into()))
}

/// A future polled inside `catch_unwind`: `None` if it panicked.
struct Unwinding<F>(std::pin::Pin<Box<F>>);

impl<F: std::future::Future> std::future::Future for Unwinding<F> {
    type Output = Option<F::Output>;
    fn poll(mut self: std::pin::Pin<&mut Self>, cx: &mut std::task::Context<'_>) -> std::task::Poll<Self::Output> {
        match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| self.0.as_mut().poll(cx))) {
            Ok(std::task::Poll::Ready(v)) => std::task::Poll::Ready(Some(v)),
            Ok(std::task::Poll::Pending) => std::task::Poll::Pending,
            Err(_) => std::task::Poll::Ready(None),
        }
    }
}

// MARK: the types, baud-core's own

#[uniffi::remote(Enum)]
pub enum DeviceKind {
    Mac,
    Iphone,
    Android,
    Node,
}

#[uniffi::remote(Enum)]
pub enum Path {
    Direct { ms: Option<u32> },
    Relay { device: String, name: String },
    Nearby,
    Waiting,
    Unreachable,
    NotConnected,
}

#[uniffi::remote(Record)]
pub struct Device {
    pub id: String,
    pub name: String,
    pub kind: DeviceKind,
    pub user: String,
    pub added_at: i64,
    pub online: bool,
    pub last_online: Option<i64>,
    pub path: Path,
    pub sentence: String,
}

#[uniffi::remote(Record)]
pub struct Person {
    pub user: String,
    pub name: String,
    pub fingerprint: String,
    pub devices: Vec<Device>,
    pub this_device: String,
    pub avatar: Option<String>,
}

#[uniffi::remote(Enum)]
pub enum LinkKind {
    Friend,
    Device,
    Reply,
}

#[uniffi::remote(Record)]
pub struct Link {
    pub url: String,
    pub kind: LinkKind,
    pub name: String,
    pub expires: i64,
    pub web: String,
    pub code: String,
}

#[uniffi::remote(Record)]
pub struct Contact {
    pub user: String,
    pub name: String,
    pub verified: bool,
    pub fingerprint: String,
    pub devices: Vec<Device>,
    pub met_at: i64,
    pub avatar: Option<String>,
    pub vouched: bool,
    pub online: bool,
    pub last_online: Option<i64>,
    pub sentence: String,
}

#[uniffi::remote(Enum)]
pub enum Kind {
    Chat,
    Channel,
    Space,
    Home,
}

#[uniffi::remote(Record)]
pub struct Conversation {
    pub id: String,
    pub kind: Kind,
    pub name: Option<String>,
    pub topic: Option<String>,
    pub space: Option<String>,
    pub members: Vec<String>,
    pub admins: Vec<String>,
    pub created_at: i64,
    pub last_at: i64,
    pub last_text: Option<String>,
    pub last_user: Option<String>,
    pub last_event: Option<String>,
    pub unread: u32,
    pub mentions: u32,
    pub event_count: u32,
    pub is_default: bool,
    pub pinned: Vec<String>,
    pub is_direct: bool,
    #[uniffi(default = 0)]
    pub disappear: u32,
}

#[uniffi::remote(Record)]
pub struct Attachment {
    pub hash: String,
    pub key: String,
    pub mime: String,
    pub size: u64,
    pub name: Option<String>,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub duration: Option<f64>,
}

#[uniffi::remote(Record)]
pub struct Reaction {
    pub key: String,
    pub users: Vec<String>,
    pub mine: bool,
}

#[uniffi::remote(Enum)]
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

#[uniffi::remote(Enum)]
pub enum Via {
    Direct,
    Relay,
    Carried,
    Waiting,
}

#[uniffi::remote(Record)]
pub struct Event {
    pub id: String,
    pub conv: String,
    pub device: String,
    pub seq: u64,
    pub user: String,
    pub at: i64,
    pub lamport: u64,
    pub kind: EventType,
    pub text: Option<String>,
    pub attachments: Vec<Attachment>,
    pub reply: Option<String>,
    pub thread: Option<String>,
    pub mentions: Vec<String>,
    pub reactions: Vec<Reaction>,
    pub edited: bool,
    pub replies: u32,
    pub last_repliers: Vec<String>,
    pub pinned: bool,
    pub system: Option<String>,
    pub mine: bool,
    pub carried_by: Option<String>,
    pub via: Option<Via>,
}

#[uniffi::remote(Record)]
pub struct Draft {
    pub text: String,
    #[uniffi(default = [])]
    pub attachments: Vec<String>,
    #[uniffi(default = None)]
    pub reply: Option<String>,
    #[uniffi(default = None)]
    pub thread: Option<String>,
    #[uniffi(default = [])]
    pub mentions: Vec<String>,
}

#[uniffi::remote(Enum)]
pub enum DeliveryState {
    Sent,
    Carried { by: String },
    Delivered,
    Read,
}

#[uniffi::remote(Record)]
pub struct DeviceDelivery {
    pub device: Device,
    pub person_name: String,
    pub state: DeliveryState,
    pub carriers: Vec<String>,
}

#[uniffi::remote(Record)]
pub struct Delivery {
    pub event: String,
    pub devices: Vec<DeviceDelivery>,
    pub sentence: String,
    pub best: DeliveryState,
}

#[uniffi::remote(Record)]
pub struct Member {
    pub user: String,
    pub name: String,
    pub admin: bool,
    pub joined_at: i64,
    pub devices: Vec<Device>,
    pub verified: bool,
    pub me: bool,
    pub online: bool,
    pub label: Option<String>,
}

#[uniffi::remote(Enum)]
pub enum FoundBy {
    Cache,
    Push,
    Exchange,
    Nearby,
    Invite,
}

#[uniffi::remote(Record)]
pub struct Peer {
    pub device: Device,
    pub user_name: String,
    pub own: bool,
    pub record_age: Option<i64>,
    pub found_by: Option<FoundBy>,
    pub relaying: bool,
    pub holding_for_me: u32,
    pub i_hold_for_it: u32,
    pub sentence: String,
}

#[uniffi::remote(Record)]
pub struct Held {
    pub device: String,
    pub name: String,
    pub count: u32,
    pub bytes: u64,
}

#[uniffi::remote(Record)]
pub struct Carrying {
    pub envelopes: u32,
    pub bytes: u64,
    pub budget_bytes: u64,
    pub held: Vec<Held>,
    pub sentence: String,
}

#[uniffi::remote(Record)]
pub struct Hit {
    pub event: Event,
    pub conversation: Conversation,
    pub snippet: String,
}

#[uniffi::remote(Enum)]
pub enum NetState {
    Offline,
    Online,
    Through { name: String, own: bool },
    NotReachable { away: Option<String> },
}

#[uniffi::remote(Enum)]
pub enum Change {
    Me,
    Contacts,
    Conversations,
    Peers,
    Carrying,
    Conversation { id: String },
    Delivery { conv: String },
    Typing { conv: String },
    LinkRequest { req: u64, code: String, device: String, name: String, kind: DeviceKind },
    Reached { device: String },
    Removed,
    Network,
    Places { conv: String },
    Replied { user: String },
    ReplyLapsed { user: String },
    Expired { conv: String, events: Vec<String> },
}

#[uniffi::remote(Record)]
pub struct Place {
    pub user: String,
    pub device: String,
    pub lat: f64,
    pub lon: f64,
    pub accuracy: f64,
    pub at: i64,
    pub until: Option<i64>,
}

#[uniffi::remote(Record)]
pub struct Share {
    pub conv: String,
    pub until: Option<i64>,
}

/// How `Baud.open` starts. Only `name`, `device_name` and `device_kind` matter in the app; the
/// switches are for labs and tests (`portmap = false` never asks the router for a port).
#[derive(uniffi::Record)]
pub struct Config {
    /// The name for a brand-new install; empty until the person types one (then `set_name`).
    pub name: String,
    /// "Pixel 9", from the system.
    pub device_name: String,
    pub device_kind: DeviceKind,
    #[uniffi(default = true)]
    pub nearby: bool,
    #[uniffi(default = true)]
    pub portmap: bool,
    #[uniffi(default = false)]
    pub relay: bool,
    #[uniffi(default = false)]
    pub public: bool,
    #[uniffi(default = true)]
    pub vpn: bool,
}

impl From<Config> for baud_core::types::Config {
    fn from(c: Config) -> Self {
        baud_core::types::Config { name: c.name, device_name: c.device_name, device_kind: c.device_kind, nearby: c.nearby, portmap: c.portmap, relay: c.relay, public: c.public, vpn: c.vpn, wake_url: None }
    }
}

// MARK: what the app implements

/// The app's keystore: small secrets by name (the device and user keys live here, never in the
/// store). Android: the Keystore-wrapped preferences, readable after first unlock.
#[uniffi::export(with_foreign)]
pub trait Keychain: Send + Sync {
    fn get(&self, item: String) -> Result<Option<Vec<u8>>, BaudError>;
    fn put(&self, item: String, bytes: Vec<u8>) -> Result<(), BaudError>;
    fn delete(&self, item: String) -> Result<(), BaudError>;
}

struct Keys(Arc<dyn Keychain>);
impl peer::identity::Keychain for Keys {
    fn get(&self, item: &str) -> peer::Result<Option<Vec<u8>>> {
        self.0.get(item.to_owned()).map_err(|e| peer::Error::Keychain(e.to_string()))
    }
    fn put(&self, item: &str, bytes: &[u8]) -> peer::Result<()> {
        self.0.put(item.to_owned(), bytes.to_vec()).map_err(|e| peer::Error::Keychain(e.to_string()))
    }
    fn delete(&self, item: &str) -> peer::Result<()> {
        self.0.delete(item.to_owned()).map_err(|e| peer::Error::Keychain(e.to_string()))
    }
}

/// Ids only, on the core's thread: hop to the main thread and re-read what changed.
#[uniffi::export(with_foreign)]
pub trait Listener: Send + Sync {
    fn on_change(&self, change: Change);
}

/// What `subscribe` returns: keep it while listening, `cancel()` to stop.
#[derive(uniffi::Object)]
pub struct Subscription {
    core: Arc<baud_core::Core>,
    id: Mutex<Option<u64>>,
}

#[uniffi::export]
impl Subscription {
    pub fn cancel(&self) {
        guard(|| (), || {
            if let Some(id) = self.id.lock().unwrap().take() {
                self.core.unsubscribe(id);
            }
        })
    }
}

/// A link or a code someone pasted or scanned, read without opening the core: its kind, whose
/// it is, when it expires. None when it isn't a baud link.
#[uniffi::export]
pub fn parse_link(text: String) -> Option<Link> {
    guard(|| None, || baud_core::link::parse_code(&text))
}

/// The core's version and peer's: "baud-core 0.1.0 · peer 0.1.0".
#[uniffi::export]
pub fn version() -> String {
    guard(String::new, baud_core::version)
}

// MARK: the core

/// One device's baud: `CoreSurface`. Open it once per process and keep it.
#[derive(uniffi::Object)]
pub struct Baud {
    core: Arc<baud_core::Core>,
}

#[uniffi::export(async_runtime = "tokio")]
impl Baud {
    /// Open or create the device in `dir` (the app's files dir), with the app's keystore. Under a
    /// second: the network comes up in the background, and `Change`s say when it has.
    #[uniffi::constructor]
    pub async fn open(dir: String, keychain: Arc<dyn Keychain>, config: Config) -> Result<Arc<Baud>, BaudError> {
        fallible_async(async {
            let core = baud_core::Core::open(dir.into(), Arc::new(Keys(keychain)), config.into()).await?;
            Ok(Arc::new(Baud { core }))
        })
        .await
    }

    // me and my devices

    pub fn me(&self) -> Person {
        guard(|| Person { user: String::new(), name: String::new(), fingerprint: String::new(), devices: vec![], this_device: String::new(), avatar: None }, || self.core.me())
    }
    /// First run: the name makes the person. Later: a new name, told to everyone who knows me.
    pub fn set_name(&self, name: String) -> Result<(), BaudError> {
        fallible(|| self.core.set_name(&name))
    }
    /// A photo (a file path) onto my card.
    pub fn set_avatar(&self, path: String) -> Result<(), BaudError> {
        fallible(|| self.core.set_avatar(&path))
    }
    /// A link for another device of mine, ten minutes: show it as a QR code and as `code`.
    pub fn link_device(&self) -> Result<Link, BaudError> {
        fallible(|| self.core.link_device())
    }
    /// This device becomes the person whose link it is: waits while the other device confirms
    /// the six digits `joining_code` shows here.
    pub async fn link(&self, link: String) -> Result<(), BaudError> {
        fallible_async(self.core.link(&link)).await
    }
    /// The six digits to show while `link` waits; the other device shows the same.
    pub fn joining_code(&self, link: String) -> Option<String> {
        guard(|| None, || self.core.joining_code(&link))
    }
    /// Answer a `Change.LinkRequest`: the codes matched, or not.
    pub fn confirm_link(&self, req: u64, accept: bool) {
        guard(|| (), || self.core.confirm_link(req, accept))
    }
    /// One of my devices leaves my account.
    pub fn revoke(&self, device: String) -> Result<(), BaudError> {
        fallible(|| self.core.revoke(&device))
    }

    // contacts

    /// A friend invite, an hour: QR code, `url` to share, `web` for people without baud.
    pub fn invite(&self) -> Result<Link, BaudError> {
        fallible(|| self.core.invite())
    }
    /// A friend's link that isn't getting through from here: my answer, for them to open (or
    /// scan) while this device keeps dialing theirs. `Change.Replied` when they do, or
    /// `ReplyLapsed`. Errors: BadLink (not a friend link), Expired, Used (already a contact).
    pub fn reply(&self, link: String) -> Result<Link, BaudError> {
        fallible(|| self.core.reply(&link))
    }
    /// Redeem an invite (a URL or a pasted code), or open a reply to one of mine. Both sides
    /// become friends; the inviter (for a reply, me) opens the chat. A reply's errors: Expired,
    /// NotFound (it answers a link from another of my devices), Used (my link went to someone
    /// else), Unreachable.
    pub async fn add(&self, link: String) -> Result<Contact, BaudError> {
        fallible_async(self.core.add(&link)).await
    }
    pub fn contacts(&self) -> Vec<Contact> {
        guard(Vec::new, || self.core.contacts())
    }
    /// True, and marked verified, when the safety number matches.
    pub fn verify(&self, user: String, fingerprint: String) -> Result<bool, BaudError> {
        fallible(|| self.core.verify(&user, &fingerprint))
    }
    /// No longer friends: they and our chat leave this device's lists.
    pub fn unfriend(&self, user: String) -> Result<(), BaudError> {
        fallible(|| self.core.unfriend(&user))
    }

    // conversations

    /// Chats and groups, newest first; `kind` none is everything but my chat with myself.
    pub fn conversations(&self, kind: Option<Kind>) -> Vec<Conversation> {
        guard(Vec::new, || self.core.conversations(kind))
    }
    pub fn conversation(&self, id: String) -> Option<Conversation> {
        guard(|| None, || self.core.conversation(&id))
    }
    /// My chat with myself, on every device of mine: "You" at the top.
    pub fn notes(&self) -> Option<Conversation> {
        guard(|| None, || self.core.notes())
    }
    /// Deleting a chat here: it leaves the list until a newer message arrives. A group is left first.
    pub fn delete(&self, conv: String) -> Result<(), BaudError> {
        fallible(|| self.core.delete(&conv))
    }
    /// A page of the timeline, oldest first, ending before `before` (none: the latest).
    pub fn events(&self, conv: String, before: Option<String>, limit: u32) -> Vec<Event> {
        guard(Vec::new, || self.core.events(&conv, before.as_deref(), limit))
    }
    /// A thread: its root, then its replies.
    pub fn thread(&self, conv: String, root: String, before: Option<String>, limit: u32) -> Vec<Event> {
        guard(Vec::new, || self.core.thread(&conv, &root, before.as_deref(), limit))
    }
    /// Write a message: text and files (paths, copied in). Returns it as the timeline shows it.
    pub fn send(&self, conv: String, draft: Draft) -> Result<Event, BaudError> {
        fallible(|| self.core.send(&conv, draft))
    }
    pub fn react(&self, conv: String, target: String, key: String, on: bool) -> Result<(), BaudError> {
        fallible(|| self.core.react(&conv, &target, &key, on))
    }
    pub fn edit(&self, conv: String, target: String, text: String) -> Result<(), BaudError> {
        fallible(|| self.core.edit(&conv, &target, &text))
    }
    pub fn redact(&self, conv: String, target: String) -> Result<(), BaudError> {
        fallible(|| self.core.redact(&conv, &target))
    }
    pub fn pin(&self, conv: String, target: String, on: bool) -> Result<(), BaudError> {
        fallible(|| self.core.pin(&conv, &target, on))
    }
    /// Read up to this event: unread clears here and on my other devices, and the sender sees "read".
    pub fn mark_read(&self, conv: String, event: String) -> Result<(), BaudError> {
        fallible(|| self.core.mark_read(&conv, &event))
    }
    /// I am typing: call on each keystroke; the others see it for five seconds.
    pub fn typing(&self, conv: String) {
        guard(|| (), || self.core.typing(&conv))
    }
    pub fn typing_now(&self, conv: String) -> Vec<String> {
        guard(Vec::new, || self.core.typing_now(&conv))
    }
    pub fn members(&self, conv: String) -> Vec<Member> {
        guard(Vec::new, || self.core.members(&conv))
    }
    pub fn add_member(&self, conv: String, user: String) -> Result<(), BaudError> {
        fallible(|| self.core.add_member(&conv, &user))
    }
    pub fn remove_member(&self, conv: String, user: String) -> Result<(), BaudError> {
        fallible(|| self.core.remove_member(&conv, &user))
    }
    pub fn leave(&self, conv: String) -> Result<(), BaudError> {
        fallible(|| self.core.leave(&conv))
    }
    /// A group's name.
    pub fn rename(&self, conv: String, name: String) -> Result<(), BaudError> {
        fallible(|| self.core.set_conversation_name(&conv, &name))
    }
    pub fn set_topic(&self, conv: String, topic: String) -> Result<(), BaudError> {
        fallible(|| self.core.set_topic(&conv, &topic))
    }
    /// A member's label in a group, for everyone in it: my own, or anyone's if I'm an admin.
    pub fn set_label(&self, conv: String, user: String, text: Option<String>) -> Result<(), BaudError> {
        fallible(|| self.core.set_label(&conv, &user, text.as_deref()))
    }
    /// Disappearing messages: each message written from now on goes this many seconds after it
    /// is read (mine, after it is sent); 0 turns it off. Anyone in a chat, an admin in a channel.
    pub fn set_disappear(&self, conv: String, seconds: u32) -> Result<(), BaudError> {
        fallible(|| self.core.set_disappear(&conv, seconds))
    }
    /// Per device of everyone else in it: sent, carried by, delivered, read; and the sentence.
    pub fn delivery(&self, conv: String, event: String) -> Delivery {
        guard(|| Delivery { event: event.clone(), devices: vec![], sentence: String::new(), best: DeliveryState::Sent }, || self.core.delivery(&conv, &event))
    }
    /// A chat with these people; with one friend, the chat we already have.
    pub fn create_chat(&self, users: Vec<String>) -> Result<Conversation, BaudError> {
        fallible(|| self.core.create_chat(&users))
    }
    pub fn create_group(&self, name: String, users: Vec<String>) -> Result<Conversation, BaudError> {
        fallible(|| self.core.create_group(&name, &users))
    }
    /// Words, prefix-matched, newest first; `conv` narrows it to one conversation.
    pub fn search(&self, query: String, conv: Option<String>) -> Vec<Hit> {
        guard(Vec::new, || self.core.search(&query, conv.as_deref()))
    }
    /// A file by its hash: here, or fetched from a device that has it. The path to read.
    pub async fn blob(&self, hash: String, key: String) -> Result<String, BaudError> {
        fallible_async(self.core.blob(&hash, &key)).await
    }
    /// A setting that follows me to my other devices (the colour): the latest one set wins.
    pub fn set_profile(&self, key: String, value: String) {
        guard(|| (), || self.core.set_profile(&key, &value))
    }
    pub fn profile(&self, key: String) -> Option<String> {
        guard(|| None, || self.core.profile(&key))
    }

    // places: where I am, for a chat I choose, while I share it

    /// Share my location in this chat until then (unix ms; none: until I stop). The last fix
    /// goes at once; keep calling `moved` while `wantsPlace()`.
    pub fn share_place(&self, conv: String, until: Option<i64>) {
        guard(|| (), || self.core.share_place(&conv, until))
    }
    /// Stop sharing in this chat: everyone in it hears so.
    pub fn stop_sharing(&self, conv: String) {
        guard(|| (), || self.core.stop_sharing(&conv))
    }
    /// The chats I share my location in, and until when.
    pub fn sharing(&self) -> Vec<Share> {
        guard(Vec::new, || self.core.sharing())
    }
    /// Whether any chat wants my location: run the location service only then.
    pub fn wants_place(&self) -> bool {
        guard(|| false, || self.core.wants_place())
    }
    /// A new fix from the location service: to every chat I share in.
    pub fn moved(&self, lat: f64, lon: f64, accuracy: f64) {
        guard(|| (), || self.core.moved(lat, lon, accuracy))
    }
    /// The people sharing their place with me in this chat, newest first; ended shares gone.
    pub fn places(&self, conv: String) -> Vec<Place> {
        guard(Vec::new, || self.core.places(&conv))
    }

    // the network, honestly

    /// Whether I hold an unexpired ticket to wake that device (an iPhone) while it sleeps.
    pub fn can_wake(&self, device: String) -> bool {
        guard(|| false, || self.core.can_wake(&device))
    }
    pub fn peers(&self) -> Vec<Peer> {
        guard(Vec::new, || self.core.peers())
    }
    pub fn carrying(&self) -> Carrying {
        guard(|| Carrying { envelopes: 0, bytes: 0, budget_bytes: 0, held: vec![], sentence: String::new() }, || self.core.carrying())
    }
    /// This device on the network: online, through a meeting device, or not reachable.
    pub fn net_state(&self) -> NetState {
        guard(|| NetState::NotReachable { away: None }, || self.core.net_state())
    }
    /// The app is in front (true) or went to the background (false).
    pub fn set_online(&self, online: bool) {
        guard(|| (), || self.core.set_online(online))
    }
    /// The system's network changed (ConnectivityManager's callback): re-bind and re-probe.
    pub fn network_changed(&self) {
        guard(|| (), || self.core.network_changed())
    }
    /// The timing log, oldest first: peer's JSON lines, then baud's own.
    pub fn trace(&self) -> Vec<String> {
        guard(Vec::new, || self.core.trace())
    }
    pub fn subscribe(&self, listener: Arc<dyn Listener>) -> Arc<Subscription> {
        let id = guard(|| None, || Some(self.core.subscribe(Box::new(move |c| listener.on_change(c)))));
        Arc::new(Subscription { core: self.core.clone(), id: Mutex::new(id) })
    }
    /// Let go of the network, before the process ends. (`close()` is the binding's own: it
    /// frees this object, so the core's is `shutdown`.)
    pub async fn shutdown(&self) {
        let _ = Unwinding(Box::pin(self.core.close())).await;
    }
    /// Forget this device (keys, store, files): open again to start over.
    pub async fn reset(&self) -> Result<(), BaudError> {
        fallible_async(self.core.reset()).await
    }
}
