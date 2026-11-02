//! The Swift package `Peer`. Proc-macro UniFFI over the crate; `Keychain` and `Listener` are
//! implemented in Swift (`AppleKeychain` stores with AfterFirstUnlockThisDeviceOnly). Names
//! follow life's `PeerSurface` so `Peer` drops in.

use std::sync::Arc;
use peer::sync::Locked;

uniffi::setup_scaffolding!("peer");

/// One case per crate error, so Swift can say a sentence per case (`Unreachable` after a dial
/// that found nobody, `NotInTheirBook` when their gate closed us) instead of matching words.
/// Each carries the crate's message. `Failed` is the binding's own (bad hex, a wrong length).
#[derive(Debug, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum PeerError {
    #[error("{0}")]
    NotFound(String),
    #[error("{0}")]
    BadKey(String),
    #[error("{0}")]
    BadSignature(String),
    #[error("{0}")]
    Encoding(String),
    #[error("{0}")]
    Expired(String),
    #[error("{0}")]
    Used(String),
    #[error("{0}")]
    NotInTheirBook(String),
    #[error("{0}")]
    Unreachable(String),
    #[error("{0}")]
    PolicyRefused(String),
    #[error("{0}")]
    Budget(String),
    #[error("{0}")]
    Keychain(String),
    #[error("{0}")]
    Store(String),
    #[error("{0}")]
    Net(String),
    #[error("{0}")]
    Failed(String),
}

impl From<peer::Error> for PeerError {
    fn from(e: peer::Error) -> Self {
        use peer::Error as E;
        let m = e.to_string();
        match e {
            E::NotFound => PeerError::NotFound(m),
            E::BadKey => PeerError::BadKey(m),
            E::BadSignature => PeerError::BadSignature(m),
            E::Encoding => PeerError::Encoding(m),
            E::Expired => PeerError::Expired(m),
            E::Used => PeerError::Used(m),
            E::NotInTheirBook => PeerError::NotInTheirBook(m),
            E::Unreachable => PeerError::Unreachable(m),
            E::PolicyRefused(..) => PeerError::PolicyRefused(m),
            E::Budget => PeerError::Budget(m),
            E::Keychain(_) => PeerError::Keychain(m),
            E::Store(_) => PeerError::Store(m),
            E::Net(_) => PeerError::Net(m),
            E::Unimplemented(_) => PeerError::Failed(m),
        }
    }
}

/// No panic reaches Swift. uniffi hands one to the binding as an error, which every call that
/// cannot throw `try!`s: a trap that took the app down (baud 0.2.7, `networkChanged`, after a
/// background task's panic poisoned a lock). Each entry point runs inside `guard`, `fallible` or
/// their async twins: a panic (already in the trace, `peer::trace::record_panics`) answers as
/// `fallback`, or as `Failed` where the call can fail anyway.
fn guard<T>(fallback: impl FnOnce() -> T, f: impl FnOnce() -> T) -> T {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)).unwrap_or_else(|_| fallback())
}

fn fallible<T>(f: impl FnOnce() -> Result<T, PeerError>) -> Result<T, PeerError> {
    guard(panicked, f)
}

async fn guard_async<T>(fallback: impl FnOnce() -> T, f: impl std::future::Future<Output = T>) -> T {
    Unwinding(Box::pin(f)).await.unwrap_or_else(fallback)
}

async fn fallible_async<T>(f: impl std::future::Future<Output = Result<T, PeerError>>) -> Result<T, PeerError> {
    guard_async(panicked, f).await
}

fn panicked<T>() -> Result<T, PeerError> {
    Err(PeerError::Failed("the crate panicked: see its trace".into()))
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

#[derive(uniffi::Record)]
pub struct ParsedLink {
    pub kind: String,
    pub name: String,
    pub user: String,
    pub expires: u64,
    pub meet_device: String,
    pub meet_addrs: Vec<String>,
}

#[uniffi::export]
pub fn version() -> String {
    guard(String::new, || peer::version().to_owned())
}

#[uniffi::export]
pub fn parse_link(link: String) -> Result<ParsedLink, PeerError> {
    fallible(|| {
        let l = peer::link::parse(&link)?;
        Ok(ParsedLink {
            kind: match l.kind {
                peer::link::Kind::Friend => "friend".into(),
                peer::link::Kind::Device => "device".into(),
                peer::link::Kind::Reply => "reply".into(),
            },
            name: l.name,
            user: l.user.to_hex(),
            expires: l.expires,
            meet_device: l.meet.device.to_hex(),
            meet_addrs: l.meet.addrs,
        })
    })
}

#[uniffi::export]
pub fn fingerprint(user: String) -> Result<String, PeerError> {
    fallible(|| {
        let user = peer::identity::UserId::from_hex(&user)?;
        Ok(peer::identity::fingerprint(&user))
    })
}

/// The keychain the app provides. Swift: `AppleKeychain(service:accessGroup:)`.
#[uniffi::export(with_foreign)]
pub trait Keychain: Send + Sync {
    fn get(&self, item: String) -> Result<Option<Vec<u8>>, PeerError>;
    fn put(&self, item: String, bytes: Vec<u8>) -> Result<(), PeerError>;
    fn delete(&self, item: String) -> Result<(), PeerError>;
}

struct Bridge(Arc<dyn Keychain>);
impl peer::identity::Keychain for Bridge {
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

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum Reachable {
    Yes,
    No,
    Unknown,
}

fn reachable_of(r: peer::probe::Reachable) -> Reachable {
    match r {
        peer::probe::Reachable::Yes => Reachable::Yes,
        peer::probe::Reachable::No => Reachable::No,
        peer::probe::Reachable::Unknown => Reachable::Unknown,
    }
}

/// Live: calls, screen, typing. Bulk: blobs, library sync. Small: everything else.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum StreamClass {
    Live,
    Bulk,
    Small,
}

#[derive(uniffi::Enum, Clone)]
pub enum PeerEvent {
    Online { device: String },
    Offline { device: String },
    /// A new connection replaced the held one, or a send was refused on its path: the app's
    /// connections to the device are gone. Compare `PathMoved`.
    PathChanged { device: String },
    /// A dial to a device not connected began ("reaching Ana's Mac…"), or the meeting device of a
    /// link being redeemed.
    Dialing { device: String },
    /// A link being redeemed reached its meeting device: a device link now waits for the code.
    Reached { device: String },
    RecordChanged { device: String },
    Inbound { conn: u64, alpn: String },
    Delivered { envelope: String },
    Inbox { envelope: String },
    ContactsChanged,
    MeChanged,
    LinkRequest { req: u64 },
    /// A contact who had two identities is one now: their old key's contact moved to `to`, with its
    /// petname. Merge the two chats.
    ContactRedirected { from: String, to: String },
    /// Another of my devices removed this one: say so and call `reset()`.
    Removed,
    /// A friend removed me: their devices no longer admit me. Hide the chat.
    ContactRemoved { user: String },
    NetworkChanged,
    ReachabilityChanged { reachable: Reachable },
    /// A reply this device made (`reply`) was opened by the link's maker and the meeting
    /// completed: `user` is a contact now.
    Replied { user: String },
    /// A reply this device made stopped waiting unopened (it ran out, or their invite was spent
    /// on someone else): offer to make another, or to meet through a friend.
    ReplyLapsed { user: String },
    /// The connection to the device is the same and its path moved under it (a punch landed, or
    /// the relay took over): refresh how it is reached, nothing else. Unlike `PathChanged`, no
    /// connection or stream to it was dropped.
    PathMoved { device: String },
}

/// What the gateway last said when asked for a port mapping (`Peer::gateway`).
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum Gateway {
    Unknown,
    /// No UPnP gateway answered.
    None,
    /// A gateway without an internet side (no external address): restart it.
    NoInternet,
    /// It refused, or said yes and held nothing: UPnP off, or broken.
    Refused,
    Mapped,
}

/// Ids only; the app re-reads. Called on the crate's thread.
#[uniffi::export(with_foreign)]
pub trait Listener: Send + Sync {
    fn on(&self, event: PeerEvent);
}

struct Forward(Arc<dyn Listener>);
impl peer::Listener for Forward {
    fn on(&self, e: peer::Event) {
        use peer::Event as E;
        let ev = match e {
            E::Online(d) => PeerEvent::Online { device: d.to_hex() },
            E::Offline(d) => PeerEvent::Offline { device: d.to_hex() },
            E::PathChanged(d) => PeerEvent::PathChanged { device: d.to_hex() },
            E::Dialing(d) => PeerEvent::Dialing { device: d.to_hex() },
            E::Reached(d) => PeerEvent::Reached { device: d.to_hex() },
            E::RecordChanged(d) => PeerEvent::RecordChanged { device: d.to_hex() },
            E::Inbound { conn, alpn } => PeerEvent::Inbound { conn: conn.0, alpn },
            E::Delivered(x) => PeerEvent::Delivered { envelope: peer::identity::hex_of(&x.0) },
            E::Inbox(x) => PeerEvent::Inbox { envelope: peer::identity::hex_of(&x.0) },
            E::ContactsChanged => PeerEvent::ContactsChanged,
            E::MeChanged => PeerEvent::MeChanged,
            E::LinkRequest(r) => PeerEvent::LinkRequest { req: r.0 },
            E::Removed => PeerEvent::Removed,
            E::ContactRemoved(u) => PeerEvent::ContactRemoved { user: u.to_hex() },
            E::ContactRedirected { from, to } => PeerEvent::ContactRedirected { from: from.to_hex(), to: to.to_hex() },
            E::NetworkChanged => PeerEvent::NetworkChanged,
            E::ReachabilityChanged(r) => PeerEvent::ReachabilityChanged { reachable: reachable_of(r) },
            E::Replied(u) => PeerEvent::Replied { user: u.to_hex() },
            E::ReplyLapsed(u) => PeerEvent::ReplyLapsed { user: u.to_hex() },
            E::PathMoved(d) => PeerEvent::PathMoved { device: d.to_hex() },
        };
        self.0.on(ev);
    }
}

#[derive(uniffi::Record)]
pub struct Config {
    pub app: String,
    pub name: String,
    pub device_name: String,
    /// `baud://add`, `health://add`: the app's, never the crate's.
    pub link_scheme: String,
    pub nearby: bool,
    pub alpns: Vec<String>,
    /// "mac" | "iphone" | "ipad" | "windows" | "linux" | "node" | "android"; empty for the build target's.
    pub device_kind: String,
    /// Advertise and dial VPN addresses (default true). A test switch for devices on one tailnet.
    pub vpn: bool,
    /// Ask the gateway for a UDP mapping (default true). False keeps a node unreachable, to force the relay path.
    pub portmap: bool,
    /// Run the embedded relay for cardholders: a computer at home becomes the meeting device of
    /// its person's invites (`inviteMeeting()` says `own`). Advertised only while its TCP port is
    /// mapped on the gateway (confirmed) or `public`; withdrawn when the mapping lapses.
    #[uniffi(default = false)]
    pub relay: bool,
    /// The port is reachable from outside without a mapping (forwarded, or a global address).
    #[uniffi(default = false)]
    pub public: bool,
    /// The port to bind (UDP, and the relay's TCP); none: the one this device used last time.
    #[uniffi(default = None)]
    pub port: Option<u16>,
}

#[derive(uniffi::Record, Default)]
pub struct Person {
    pub user: String,
    pub name: String,
    pub fingerprint: String,
    pub devices: Vec<DeviceEntry>,
    pub this_device: String,
}

#[derive(uniffi::Record)]
pub struct DeviceEntry {
    pub id: String,
    pub name: String,
    /// "mac" | "iphone" | "ipad" | "windows" | "linux" | "node" | "android".
    pub kind: String,
    pub added_at: u64,
}

#[derive(uniffi::Enum, Clone)]
pub enum Path {
    Direct { vpn: bool },
    Relay { device: String },
    Nearby,
    Waiting,
    Unreachable,
}

#[derive(uniffi::Record)]
pub struct PeerStatus {
    pub device: String,
    pub user: String,
    pub name: String,
    pub kind: String,
    pub online: bool,
    pub path: Path,
    pub rtt_ms: Option<u32>,
    /// Unix ms this device was last connected (now, while online).
    pub last_seen: Option<u64>,
    pub record_age_ms: Option<u64>,
    /// cache, push, exchange, nearby, invite.
    pub found_by: Option<String>,
}

/// Whose device the next link names to meet at.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum MeetingKind {
    /// One of mine that runs a relay: "friends reach you through your Mac".
    Own,
    /// A friend's device that runs a relay and holds my card.
    Friend,
    /// None: the link carries raw addresses; "add a friend from a device that can be reached".
    None,
}

/// What `invite()` and `linkDevice()` will carry, before the link is shown.
#[derive(uniffi::Record)]
pub struct Meeting {
    pub kind: MeetingKind,
    pub device: Option<String>,
    pub device_name: String,
    pub user: Option<String>,
    pub user_name: String,
}

/// A space: every member a mutual. A chat: members reached through shared mutuals unless contacts.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum GroupKind {
    Space,
    Chat,
}

#[derive(uniffi::Record)]
pub struct Member {
    pub user: String,
    /// The public name from their card: what a non-contact sees.
    pub name: String,
    pub petname: Option<String>,
    pub contact: bool,
    pub mutual: bool,
    pub card: Vec<u8>,
}

#[derive(uniffi::Record)]
pub struct Contact {
    pub user: String,
    pub name: String,
    pub verified: bool,
    pub relay_only: bool,
    pub met_at: u64,
    pub devices: Vec<PeerStatus>,
    /// The card's device list (id, name, kind, added_at); empty for an adopted placeholder.
    pub entries: Vec<DeviceEntry>,
    /// The signed card bytes, for `add_member`; None for an adopted placeholder.
    pub card: Option<Vec<u8>>,
    /// Their old key, when this contact came by a redirect: vouched for by it, not verified.
    pub redirected_from: Option<String>,
}

/// An old identity that now points to a new one.
#[derive(uniffi::Record)]
pub struct Redirect {
    pub from: String,
    pub to: String,
    /// Unix milliseconds.
    pub at: u64,
}

#[derive(uniffi::Record)]
pub struct AddressRecord {
    pub device: String,
    pub relay: Option<String>,
    pub reachable_udp: bool,
    pub reachable_tcp: bool,
    pub awake: bool,
    pub tags: Vec<String>,
    pub seq: u64,
    pub age_ms: u64,
    pub found_by: String,
}

fn path_of(p: peer::Path) -> Path {
    match p {
        peer::Path::Direct { vpn } => Path::Direct { vpn },
        peer::Path::Relay(d) => Path::Relay { device: d.to_hex() },
        peer::Path::Nearby => Path::Nearby,
        peer::Path::Waiting => Path::Waiting,
        peer::Path::Unreachable => Path::Unreachable,
    }
}

fn status_of(s: peer::PeerStatus) -> PeerStatus {
    PeerStatus {
        device: s.device.to_hex(),
        user: s.user.to_hex(),
        name: s.name,
        kind: s.kind.as_str().to_owned(),
        online: s.online,
        path: path_of(s.path),
        rtt_ms: s.rtt_ms,
        last_seen: s.last_seen,
        record_age_ms: s.record_age_ms,
        found_by: s.found_by.map(|f| f.as_str().to_owned()),
    }
}

#[derive(uniffi::Record)]
pub struct MigratedDevice {
    pub id: String,
    pub name: String,
    pub kind: String,
    pub added_at: u64,
    /// "ip:port", "[v6]:port" or "relay=<url>".
    pub addresses: Vec<String>,
}

/// Computer's existing keys and book, imported once.
#[derive(uniffi::Record)]
pub struct Migration {
    pub device_secret: Vec<u8>,
    pub user_secret: Vec<u8>,
    pub name: String,
    pub devices: Vec<MigratedDevice>,
    pub card_at: u64,
}

#[derive(uniffi::Record)]
pub struct AdoptedDevice {
    pub id: String,
    pub name: String,
    pub addresses: Vec<String>,
}

fn addrs_of(addrs: &[String]) -> Vec<peer::TransportAddr> {
    addrs
        .iter()
        .filter_map(|a| match a.strip_prefix("relay=") {
            Some(u) => u.parse().ok().map(peer::TransportAddr::Relay),
            None => a.parse().ok().map(peer::TransportAddr::Ip),
        })
        .collect()
}

fn key32(v: &[u8]) -> Result<[u8; 32], PeerError> {
    v.try_into().map_err(|_| PeerError::Failed("key must be 32 bytes".into()))
}

fn config_of(config: Config) -> peer::Config {
    let mut c = peer::Config::new(&config.app, &config.name, &config.device_name);
    c.link_scheme = config.link_scheme;
    c.nearby = config.nearby;
    c.alpns = config.alpns.into_iter().map(|a| a.into_bytes()).collect();
    if !config.device_kind.is_empty() {
        c.device_kind = peer::card::DeviceKind::parse(&config.device_kind);
    }
    c.vpn = config.vpn;
    c.portmap = config.portmap;
    c.relay = config.relay;
    c.public = config.public;
    c.port = config.port;
    c
}

#[derive(uniffi::Object)]
pub struct Peer {
    inner: peer::Peer,
}

#[uniffi::export(async_runtime = "tokio")]
impl Peer {
    #[uniffi::constructor]
    pub async fn open(dir: String, keychain: Arc<dyn Keychain>, config: Config) -> Result<Arc<Self>, PeerError> {
        fallible_async(async {
            let inner = peer::Peer::open(dir.into(), Arc::new(Bridge(keychain)), config_of(config)).await?;
            Ok(Arc::new(Peer { inner }))
        }).await
    }

    /// Import existing keys and the old device list, once; later opens use `open`.
    #[uniffi::constructor]
    pub async fn adopt(dir: String, keychain: Arc<dyn Keychain>, config: Config, migration: Migration) -> Result<Arc<Self>, PeerError> {
        fallible_async(async {
            let m = peer::Migration {
                device_secret: key32(&migration.device_secret)?,
                user_secret: key32(&migration.user_secret)?,
                name: migration.name,
                devices: migration.devices.iter().map(|d| Ok(peer::MigratedDevice { id: peer::identity::DeviceId::from_hex(&d.id)?, name: d.name.clone(), kind: peer::card::DeviceKind::parse(&d.kind), added_at: d.added_at, addresses: addrs_of(&d.addresses) })).collect::<Result<Vec<_>, PeerError>>()?,
                card_at: migration.card_at,
            };
            let inner = peer::Peer::adopt(dir.into(), Arc::new(Bridge(keychain)), config_of(config), m).await?;
            Ok(Arc::new(Peer { inner }))
        }).await
    }

    /// A friend from an old card: admitted and dialable now, until their first new-format card.
    pub fn adopt_contact(&self, user: String, petname: String, devices: Vec<AdoptedDevice>, card_at: u64) -> Result<Contact, PeerError> {
        fallible(|| {
            let devices = devices.iter().map(|d| Ok(peer::AdoptedDevice { id: peer::identity::DeviceId::from_hex(&d.id)?, name: d.name.clone(), addresses: addrs_of(&d.addresses) })).collect::<Result<Vec<_>, PeerError>>()?;
            Ok(contact_of(self.inner.adopt_contact(peer::identity::UserId::from_hex(&user)?, &petname, devices, card_at)?))
        })
    }

    /// Who is asking to become my device.
    pub fn link_request(&self, req: u64) -> Result<String, PeerError> {
        fallible(|| {
            Ok(self.inner.link_request(peer::LinkReqId(req))?.to_hex())
        })
    }

    /// The asking device's own name ("iPhone 17 Pro").
    pub fn link_request_name(&self, req: u64) -> Result<String, PeerError> {
        fallible(|| {
            Ok(self.inner.link_request_device(peer::LinkReqId(req))?.0)
        })
    }

    /// The asking device's kind: mac, iphone, ipad, windows, linux, node.
    pub fn link_request_kind(&self, req: u64) -> Result<String, PeerError> {
        fallible(|| {
            Ok(self.inner.link_request_device(peer::LinkReqId(req))?.1.as_str().to_owned())
        })
    }

    /// The joining side's six digits, to show while `link` waits.
    pub fn joining_code(&self, link: String) -> Result<String, PeerError> {
        fallible(|| {
            Ok(self.inner.joining_code(&peer::link::parse(&link)?))
        })
    }

    /// Transition only, on a Peer from `adopt`: sign with the user key for 0.4.x friends.
    pub fn sign_as_user(&self, bytes: Vec<u8>) -> Result<Vec<u8>, PeerError> {
        fallible(|| {
            Ok(self.inner.sign_as_user(&bytes)?.0.to_vec())
        })
    }

    pub fn me(&self) -> Person {
        guard(Person::default, || {
            let me = self.inner.me();
            Person {
                user: me.user.to_hex(),
                name: me.name,
                fingerprint: me.fingerprint,
                devices: me.devices.into_iter().map(|d| DeviceEntry { id: d.id.to_hex(), name: d.name, kind: d.kind.as_str().to_owned(), added_at: d.added_at }).collect(),
                this_device: me.this_device.to_hex(),
            }
        })
    }

    pub fn set_name(&self, name: String) -> Result<(), PeerError> {
        fallible(|| {
            Ok(self.inner.set_name(&name)?)
        })
    }

    pub fn invite(&self) -> Result<String, PeerError> {
        fallible(|| {
            Ok(self.inner.link_url(&self.inner.invite()?))
        })
    }

    pub fn link_device(&self) -> Result<String, PeerError> {
        fallible(|| {
            Ok(self.inner.link_url(&self.inner.link_device()?))
        })
    }

    /// Identities merged: contacts whose old key now points to a new one, and the one this device
    /// issued when it linked into another person.
    pub fn redirects(&self) -> Vec<Redirect> {
        guard(Vec::new, || {
            self.inner.redirects().into_iter().map(|r| Redirect { from: r.from.to_hex(), to: r.to.to_hex(), at: r.at }).collect()
        })
    }

    /// The meeting device the next link will name. Mint the link when it is shown.
    pub fn invite_meeting(&self) -> Meeting {
        guard(|| Meeting { kind: MeetingKind::None, device: None, device_name: String::new(), user: None, user_name: String::new() }, || {
            let m = self.inner.invite_meeting();
            let kind = match m.kind {
                peer::MeetingKind::Own => MeetingKind::Own,
                peer::MeetingKind::Friend => MeetingKind::Friend,
                peer::MeetingKind::None => MeetingKind::None,
            };
            Meeting { kind, device: m.device.map(|d| d.to_hex()), device_name: m.device_name, user: m.user.map(|u| u.to_hex()), user_name: m.user_name }
        })
    }

    /// A reply to a friend link whose maker can't be reached from here, as a link to send back
    /// the way theirs came, or show as a code. Callable while `add(link)` is still trying, which
    /// goes on. This device keeps dialing theirs until they open it (`Replied`), it lapses
    /// (`ReplyLapsed`, at most 15 minutes and never past their link), or the add completes.
    pub fn reply(&self, link: String) -> Result<String, PeerError> {
        fallible(|| {
            let l = peer::link::parse(&link)?;
            Ok(self.inner.link_url(&self.inner.reply(&l)?))
        })
    }

    /// Redeem a friend link, or open a reply to one of mine (made by someone who couldn't reach
    /// me): either way, their contact. A reply from someone already added gives their contact.
    pub async fn add(&self, link: String) -> Result<Contact, PeerError> {
        fallible_async(async {
            let l = peer::link::parse(&link)?;
            let c = self.inner.add(&l).await?;
            Ok(contact_of(c))
        }).await
    }

    pub async fn link(&self, link: String, device_name: String) -> Result<(), PeerError> {
        fallible_async(async {
            let l = peer::link::parse(&link)?;
            Ok(self.inner.link(&l, &device_name).await?)
        }).await
    }

    pub fn confirm_link(&self, req: u64, accept: bool) -> Result<(), PeerError> {
        fallible(|| {
            Ok(self.inner.confirm_link(peer::LinkReqId(req), accept)?)
        })
    }

    pub fn link_code(&self, req: u64) -> Result<String, PeerError> {
        fallible(|| {
            Ok(self.inner.link_code(peer::LinkReqId(req))?)
        })
    }

    pub fn contacts(&self) -> Vec<Contact> {
        guard(Vec::new, || {
            self.inner.contacts().into_iter().map(contact_of).collect()
        })
    }

    /// A co-member's card from a group's membership event: admitted, carried for, exchanged with.
    pub fn add_member(&self, group: String, card: Vec<u8>) -> Result<(), PeerError> {
        fallible(|| {
            Ok(self.inner.add_member(group_of(&group)?, peer::card::Card::from_bytes(&card)?)?)
        })
    }
    pub fn remove_member(&self, group: String, user: String) -> Result<(), PeerError> {
        fallible(|| {
            Ok(self.inner.remove_member(group_of(&group)?, peer::identity::UserId::from_hex(&user)?)?)
        })
    }
    /// Member cards as bytes (`Card::to_bytes`), for the app to carry in its own membership events.
    pub fn members(&self, group: String) -> Result<Vec<Vec<u8>>, PeerError> {
        fallible(|| {
            Ok(self.inner.members(group_of(&group)?).iter().map(|c| c.to_bytes()).collect())
        })
    }
    /// Make (or re-kind) a group before its first member. A space's members are all mutuals; a
    /// chat's are mutuals only when also contacts.
    pub fn create_group(&self, group: String, kind: GroupKind) -> Result<(), PeerError> {
        fallible(|| {
            Ok(self.inner.create_group(group_of(&group)?, match kind {
                GroupKind::Space => peer::GroupKind::Space,
                GroupKind::Chat => peer::GroupKind::Chat,
            })?)
        })
    }
    pub fn group_kind(&self, group: String) -> Result<Option<GroupKind>, PeerError> {
        fallible(|| {
            Ok(self.inner.group_kind(group_of(&group)?).map(|k| match k {
                peer::GroupKind::Space => GroupKind::Space,
                peer::GroupKind::Chat => GroupKind::Chat,
            }))
        })
    }
    /// Members as the app shows them: their public name, my petname for contacts, mutual or not.
    pub fn group_members(&self, group: String) -> Result<Vec<Member>, PeerError> {
        fallible(|| {
            Ok(self
                .inner
                .group_members(group_of(&group)?)
                .into_iter()
                .map(|m| Member { user: m.user.to_hex(), name: m.name, petname: m.petname, contact: m.contact, mutual: m.mutual, card: m.card.to_bytes() })
                .collect())
        })
    }
    pub fn my_card(&self) -> Vec<u8> {
        guard(Vec::new, || {
            self.inner.card().to_bytes()
        })
    }
    pub fn revoke(&self, device: String) -> Result<(), PeerError> {
        fallible(|| {
            Ok(self.inner.revoke(peer::identity::DeviceId::from_hex(&device)?)?)
        })
    }
    /// Remove one of my devices from another: the card stops listing it, mutuals are told, and
    /// the device itself gets `Removed` if it is online.
    pub fn remove_device(&self, device: String) -> Result<(), PeerError> {
        fallible(|| {
            Ok(self.inner.remove_device(peer::identity::DeviceId::from_hex(&device)?)?)
        })
    }
    pub fn set_relay_only(&self, user: String, on: bool) -> Result<(), PeerError> {
        fallible(|| {
            Ok(self.inner.set_relay_only(peer::identity::UserId::from_hex(&user)?, on)?)
        })
    }

    /// Online devices that hold a card for `device`: who could carry for it right now.
    pub fn helpers_for(&self, device: String) -> Result<Vec<String>, PeerError> {
        fallible(|| {
            Ok(self.inner.helpers_for(peer::identity::DeviceId::from_hex(&device)?).into_iter().map(|d| d.to_hex()).collect())
        })
    }

    pub fn rename(&self, user: String, petname: String) -> Result<(), PeerError> {
        fallible(|| {
            Ok(self.inner.rename(peer::identity::UserId::from_hex(&user)?, &petname)?)
        })
    }

    pub fn remove(&self, user: String) -> Result<(), PeerError> {
        fallible(|| {
            Ok(self.inner.remove(peer::identity::UserId::from_hex(&user)?)?)
        })
    }

    pub fn verify(&self, user: String, fingerprint: String) -> Result<bool, PeerError> {
        fallible(|| {
            Ok(self.inner.verify(peer::identity::UserId::from_hex(&user)?, &fingerprint)?)
        })
    }

    pub fn peers(&self) -> Vec<PeerStatus> {
        guard(Vec::new, || {
            self.inner.peers().into_iter().map(status_of).collect()
        })
    }

    pub fn records(&self) -> Vec<AddressRecord> {
        guard(Vec::new, || {
            self.inner
                .records()
                .into_iter()
                .map(|r| AddressRecord {
                    device: r.device.to_hex(),
                    relay: r.relay.map(|d| d.to_hex()),
                    reachable_udp: r.reachable.udp,
                    reachable_tcp: r.reachable.tcp,
                    awake: r.awake,
                    tags: r.tags,
                    seq: r.seq,
                    age_ms: r.age_ms,
                    found_by: r.found_by.as_str().to_owned(),
                })
                .collect()
        })
    }

    pub fn set_online(&self, online: bool) {
        guard(|| (), || {
            self.inner.set_online(online)
        })
    }

    /// The platform's path monitor says the network changed (`NWPathMonitor`): held connections
    /// are checked, dials begun on the old network start over. Harmless when nothing changed.
    pub fn network_changed(&self) {
        guard(|| (), || {
            self.inner.network_changed()
        })
    }

    /// The timing log, oldest first: one JSON line per milestone (open, online, wake, dial,
    /// push, post, net, migrated, redialed, blob). Always on; the newest 1024 lines are kept.
    pub fn trace(&self) -> Vec<String> {
        guard(Vec::new, || {
            self.inner.trace()
        })
    }

    pub fn subscribe(&self, listener: Arc<dyn Listener>) {
        guard(|| (), || {
            self.inner.subscribe(Arc::new(Forward(listener)))
        })
    }

    pub async fn probe(&self) -> Reachable {
        guard_async(|| Reachable::Unknown, async {
            reachable_of(self.inner.probe().await)
        }).await
    }

    /// What the gateway last said when asked for a port mapping.
    pub fn gateway(&self) -> Gateway {
        guard(|| Gateway::Unknown, || {
            match self.inner.gateway() {
                peer::portmap::Gateway::Unknown => Gateway::Unknown,
                peer::portmap::Gateway::None => Gateway::None,
                peer::portmap::Gateway::NoInternet => Gateway::NoInternet,
                peer::portmap::Gateway::Refused => Gateway::Refused,
                peer::portmap::Gateway::Mapped => Gateway::Mapped,
            }
        })
    }

    pub fn reachable(&self) -> Reachable {
        guard(|| Reachable::Unknown, || {
            reachable_of(self.inner.reachable())
        })
    }

    /// The public address a port the router holds for this device opens, if any: "ip:port".
    pub fn mapped(&self) -> Option<String> {
        guard(|| None, || {
            self.inner.mapped().map(|a| a.to_string())
        })
    }

    pub fn sign(&self, bytes: Vec<u8>) -> Vec<u8> {
        guard(Vec::new, || {
            self.inner.sign(&bytes).0.to_vec()
        })
    }

    /// One connection per (device, alpn), cached in the crate; the class decides the paths allowed.
    pub async fn connect(&self, device: String, class: StreamClass, alpn: String) -> Result<Arc<Conn>, PeerError> {
        fallible_async(async {
            let device = peer::identity::DeviceId::from_hex(&device)?;
            let class = match class {
                StreamClass::Live => peer::policy::Class::Live,
                StreamClass::Bulk => peer::policy::Class::Bulk,
                StreamClass::Small => peer::policy::Class::Small,
            };
            let conn = self.inner.connect(device, class, alpn.as_bytes()).await?;
            Ok(Arc::new(Conn { inner: conn }))
        }).await
    }

    /// After `.inbound(conn)`: the connection, identity already verified by the crate.
    pub fn accept(&self, conn: u64) -> Result<Arc<Conn>, PeerError> {
        fallible(|| {
            Ok(Arc::new(Conn { inner: self.inner.accept(peer::ConnId(conn))? }))
        })
    }

    pub async fn post(&self, to: String, bytes: Vec<u8>, ttl_secs: u64) -> Result<String, PeerError> {
        fallible_async(async {
            let to = peer::identity::DeviceId::from_hex(&to)?;
            let id = self.inner.post(to, bytes, std::time::Duration::from_secs(ttl_secs)).await?;
            Ok(peer::identity::hex_of(&id.0))
        }).await
    }

    pub fn inbox(&self) -> Vec<Envelope> {
        guard(Vec::new, || {
            self.inner
                .inbox()
                .into_iter()
                .map(|e| Envelope { id: peer::identity::hex_of(&e.id.0), from: e.from.map(|d| d.to_hex()), bytes: e.bytes, carried_by: e.carried_by.iter().map(|d| d.to_hex()).collect(), received_at: e.received_at })
                .collect()
        })
    }

    pub fn ack(&self, id: String) -> Result<(), PeerError> {
        fallible(|| {
            let id: [u8; 32] = <[u8; 32]>::try_from(data_hex(&id)?.as_slice()).map_err(|_| PeerError::Failed("bad id".into()))?;
            Ok(self.inner.ack(peer::EnvelopeId(id))?)
        })
    }

    /// Not guarded: a clone in an `Arc`, nothing that can panic, and no answer to fall back on.
    pub fn blobs(&self) -> Arc<Blobs> {
        Arc::new(Blobs { peer: self.inner.clone() })
    }

    /// Open the app's catalog at `path` (its own SQLite file) with its synced tables and schema.
    pub fn catalog(&self, path: String, tables: Vec<TableSpec>, schema: String) -> Result<Arc<Catalog>, PeerError> {
        fallible(|| {
            let config = peer::catalog::Config { tables: tables.into_iter().map(|t| peer::catalog::Table { name: t.name, keys: t.keys }).collect(), schema };
            let inner = peer::catalog::Catalog::open(std::path::Path::new(&path), config)?;
            Ok(Arc::new(Catalog { peer: self.inner.clone(), inner: std::sync::Mutex::new(inner) }))
        })
    }

    /// A person's card bytes as I hold them: mine, a contact's or a co-member's.
    pub fn card_of(&self, user: String) -> Result<Option<Vec<u8>>, PeerError> {
        fallible(|| {
            Ok(self.inner.card_of(peer::identity::UserId::from_hex(&user)?).map(|c| c.to_bytes()))
        })
    }

    pub async fn close(&self) {
        guard_async(|| (), async {
            self.inner.close().await
        }).await
    }

    /// Forget this device: close, delete its keys and its directory. Open again to start over.
    pub async fn reset(&self) -> Result<(), PeerError> {
        fallible_async(async {
            Ok(self.inner.reset().await?)
        }).await
    }
}

fn group_of(s: &str) -> Result<peer::identity::GroupId, PeerError> {
    Ok(peer::identity::GroupId(<[u8; 32]>::try_from(data_hex(s)?.as_slice()).map_err(|_| PeerError::Failed("group id must be 32 bytes".into()))?))
}

fn data_hex(s: &str) -> Result<Vec<u8>, PeerError> {
    if s.len() % 2 != 0 {
        return Err(PeerError::Failed("bad hex".into()));
    }
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).map_err(|_| PeerError::Failed("bad hex".into()))).collect()
}

#[derive(uniffi::Record)]
pub struct Envelope {
    pub id: String,
    /// Known only on a direct delivery; otherwise the sender is inside the app's sealed bytes.
    pub from: Option<String>,
    pub bytes: Vec<u8>,
    pub carried_by: Vec<String>,
    pub received_at: u64,
}

#[derive(uniffi::Record, Default)]
pub struct Identity {
    pub user: String,
    pub device: String,
    /// Fingerprint pinned by `verify`; admission is the connection itself.
    pub pinned: bool,
    pub own: bool,
    /// Group ids (hex) whose member list admitted this device; empty for own devices and contacts.
    pub groups: Vec<String>,
}

/// One connection on the app's ALPN: several bi streams, datagrams, an honest path.
#[derive(uniffi::Object)]
pub struct Conn {
    inner: peer::Conn,
}

#[uniffi::export(async_runtime = "tokio")]
impl Conn {
    pub fn identity(&self) -> Identity {
        guard(Identity::default, || {
            let i = self.inner.identity();
            Identity { user: i.user.to_hex(), device: i.device.to_hex(), pinned: i.pinned, own: i.own, groups: i.groups.iter().map(|g| peer::identity::hex_of(&g.0)).collect() }
        })
    }
    pub fn path(&self) -> Path {
        guard(|| Path::Unreachable, || {
            path_of(self.inner.path())
        })
    }
    pub fn rtt_ms(&self) -> Option<u32> {
        guard(|| None, || {
            self.inner.rtt_ms()
        })
    }
    pub fn alpn(&self) -> String {
        guard(String::new, || {
            String::from_utf8_lossy(&self.inner.alpn()).into_owned()
        })
    }
    pub async fn open(&self) -> Result<Arc<Stream>, PeerError> {
        fallible_async(async {
            Ok(Arc::new(Stream::from(self.inner.open().await?)))
        }).await
    }
    pub async fn accept_stream(&self) -> Result<Arc<Stream>, PeerError> {
        fallible_async(async {
            Ok(Arc::new(Stream::from(self.inner.accept_stream().await?)))
        }).await
    }
    pub fn send_datagram(&self, bytes: Vec<u8>) -> Result<(), PeerError> {
        fallible(|| {
            Ok(self.inner.send_datagram(bytes.into())?)
        })
    }
    pub async fn recv_datagram(&self) -> Result<Vec<u8>, PeerError> {
        fallible_async(async {
            Ok(self.inner.recv_datagram().await?.to_vec())
        }).await
    }
    pub fn max_datagram(&self) -> Option<u64> {
        guard(|| None, || {
            self.inner.max_datagram().map(|n| n as u64)
        })
    }
    pub fn close(&self, reason: String) {
        guard(|| (), || {
            self.inner.close(&reason)
        })
    }
}

/// One bi stream. `send` awaits flow control: that is the backpressure. The halves are locked
/// separately: a pending `recv` never blocks a `send`.
#[derive(uniffi::Object)]
pub struct Stream {
    tx: tokio::sync::Mutex<peer::SendHalf>,
    rx: tokio::sync::Mutex<peer::RecvHalf>,
}

impl From<peer::Stream> for Stream {
    fn from(s: peer::Stream) -> Self {
        let (tx, rx) = s.split();
        Stream { tx: tokio::sync::Mutex::new(tx), rx: tokio::sync::Mutex::new(rx) }
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl Stream {
    pub async fn send(&self, bytes: Vec<u8>) -> Result<(), PeerError> {
        fallible_async(async {
            Ok(self.tx.lock().await.send(&bytes).await?)
        }).await
    }
    /// Up to `max` bytes; None at the end of the stream.
    pub async fn recv(&self, max: u64) -> Result<Option<Vec<u8>>, PeerError> {
        fallible_async(async {
            Ok(self.rx.lock().await.recv(max as usize).await?.map(|b| b.to_vec()))
        }).await
    }
    /// The end of the stream, once the far side has every byte; an error if it has not within a
    /// few round trips: not delivered, so carry it some other way (`peer::SendHalf::delivered`).
    pub async fn finish(&self) -> Result<(), PeerError> {
        fallible_async(async {
            Ok(self.tx.lock().await.delivered().await?)
        }).await
    }
    pub async fn set_priority(&self, priority: i32) -> Result<(), PeerError> {
        fallible_async(async {
            Ok(self.tx.lock().await.set_priority(priority)?)
        }).await
    }
    pub async fn reset(&self) -> Result<(), PeerError> {
        fallible_async(async {
            Ok(self.tx.lock().await.reset()?)
        }).await
    }
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum TransferState {
    Running,
    Waiting,
    Paused,
    Done,
    Cancelled,
    Failed,
}

/// A blob fetch in flight. Pause keeps what is verified; resume fetches the rest.
#[derive(uniffi::Object)]
pub struct Transfer {
    inner: peer::blobs::Transfer,
}

#[uniffi::export]
impl Transfer {
    pub fn hash(&self) -> String {
        guard(String::new, || {
            self.inner.hash().to_hex()
        })
    }
    pub fn from(&self) -> String {
        guard(String::new, || {
            self.inner.from().to_hex()
        })
    }
    pub fn state(&self) -> TransferState {
        guard(|| TransferState::Failed, || {
            match self.inner.state() {
                peer::blobs::TransferState::Running => TransferState::Running,
                peer::blobs::TransferState::Waiting => TransferState::Waiting,
                peer::blobs::TransferState::Paused => TransferState::Paused,
                peer::blobs::TransferState::Done => TransferState::Done,
                peer::blobs::TransferState::Cancelled => TransferState::Cancelled,
                peer::blobs::TransferState::Failed => TransferState::Failed,
            }
        })
    }
    /// Why it failed, once it has.
    pub fn error(&self) -> Option<String> {
        guard(|| None, || {
            self.inner.error()
        })
    }
    /// Bytes verified locally, and the total once known (0 before).
    pub fn progress(&self) -> Vec<u64> {
        guard(Vec::new, || {
            let (d, t) = self.inner.progress();
            vec![d, t]
        })
    }
    pub fn pause(&self) {
        guard(|| (), || {
            self.inner.pause()
        })
    }
    pub fn resume(&self) {
        guard(|| (), || {
            self.inner.resume()
        })
    }
    pub fn cancel(&self) {
        guard(|| (), || {
            self.inner.cancel()
        })
    }
}

/// Bulk is a hash and a path: the blob store, bao-verified, always class Bulk.
#[derive(uniffi::Object)]
pub struct Blobs {
    peer: peer::Peer,
}

#[uniffi::export(async_runtime = "tokio")]
impl Blobs {
    /// Import a file (in place when possible); the hash is the file's blake3, as hex.
    pub async fn add_path(&self, path: String) -> Result<String, PeerError> {
        fallible_async(async {
            Ok(self.peer.blobs().add_path(std::path::Path::new(&path)).await?.to_hex())
        }).await
    }
    pub async fn has(&self, hash: String) -> Result<bool, PeerError> {
        fallible_async(async {
            Ok(self.peer.blobs().has(peer::blobs::Hash::from_hex(&hash)?).await)
        }).await
    }
    /// Which connected devices hold it.
    pub async fn have(&self, hash: String) -> Result<Vec<String>, PeerError> {
        fallible_async(async {
            Ok(self.peer.blobs().have(peer::blobs::Hash::from_hex(&hash)?).await.iter().map(|d| d.to_hex()).collect())
        }).await
    }
    /// Fetch from a device into `to`; `range_end` 0 means the whole blob, exported to `to`.
    pub async fn fetch(&self, from: String, hash: String, to: String, range_start: u64, range_end: u64) -> Result<Arc<Transfer>, PeerError> {
        fallible_async(async {
            let range = (range_end > 0).then_some(range_start..range_end);
            let t = self.peer.blobs().fetch(peer::identity::DeviceId::from_hex(&from)?, peer::blobs::Hash::from_hex(&hash)?, std::path::Path::new(&to), range).await?;
            Ok(Arc::new(Transfer { inner: t }))
        }).await
    }
    pub fn transfers(&self) -> Vec<Arc<Transfer>> {
        guard(Vec::new, || {
            self.peer.blobs().transfers().into_iter().map(|t| Arc::new(Transfer { inner: t })).collect()
        })
    }
    /// Stop holding a blob: `has` false at once, `have` stops naming this device, bytes freed by GC.
    pub async fn forget(&self, hash: String) -> Result<(), PeerError> {
        fallible_async(async {
            Ok(self.peer.blobs().forget(peer::blobs::Hash::from_hex(&hash)?).await?)
        }).await
    }
    pub fn local_path(&self, hash: String) -> Result<Option<String>, PeerError> {
        fallible(|| {
            Ok(self.peer.blobs().local_path(peer::blobs::Hash::from_hex(&hash)?).map(|p| p.display().to_string()))
        })
    }
}

/// The app's roles, asked per op: "apply" | "hold" | "reject". `user` is who the crate knows
/// the device belongs to; `sig_ok` says the device signed it.
#[uniffi::export(with_foreign)]
pub trait Verifier: Send + Sync {
    fn verify(&self, op_json: String, device: String, user: Option<String>, group: String, sig_ok: bool) -> String;
}

#[derive(uniffi::Record)]
pub struct TableSpec {
    pub name: String,
    pub keys: Vec<String>,
}

#[derive(uniffi::Record)]
pub struct Applied {
    pub changed: u64,
    pub held: u64,
    pub rejected: u64,
}

/// `peer::catalog`: opaque tables, signed ops, HLC, field-level last-writer-wins, marks and
/// since; ops cross as JSON strings in darkroom's format.
#[derive(uniffi::Object)]
pub struct Catalog {
    peer: peer::Peer,
    inner: std::sync::Mutex<peer::catalog::Catalog>,
}

fn verdict(s: &str) -> peer::catalog::Verdict {
    match s {
        "apply" => peer::catalog::Verdict::Apply,
        "hold" => peer::catalog::Verdict::Hold,
        _ => peer::catalog::Verdict::Reject,
    }
}

#[uniffi::export]
impl Catalog {
    /// One signed op from this device, applied here; the JSON to push to peers.
    pub fn write(&self, group: String, table: String, row: String, field: String, value_json: String, tombstone: bool) -> Result<String, PeerError> {
        fallible(|| {
            let value: serde_json::Value = serde_json::from_str(&value_json).map_err(|e| PeerError::Failed(e.to_string()))?;
            let mut c = self.inner.locked();
            let op = self.peer.catalog_write(&mut c, &group, &table, &row, &field, value, tombstone)?;
            Ok(serde_json::to_string(&op).unwrap_or_default())
        })
    }
    /// Remote ops (a JSON array) through the app's verifier; held ops ride along.
    pub fn apply(&self, ops_json: String, verifier: Arc<dyn Verifier>) -> Result<Applied, PeerError> {
        fallible(|| {
            let ops: Vec<peer::catalog::Op> = serde_json::from_str(&ops_json).map_err(|e| PeerError::Failed(e.to_string()))?;
            let peer = self.peer.clone();
            let r = self.inner.locked().apply(ops, |d| peer.user_of_device(d), |op, w| {
                verdict(&verifier.verify(serde_json::to_string(op).unwrap_or_default(), w.device.to_hex(), w.user.map(|u| u.to_hex()), w.group.clone(), w.sig_ok))
            })?;
            Ok(Applied { changed: r.changed as u64, held: r.held as u64, rejected: r.rejected as u64 })
        })
    }
    /// `{ "<device hex>": "<hlc>" }` as JSON.
    pub fn marks(&self, group: String) -> Result<String, PeerError> {
        fallible(|| {
            Ok(serde_json::to_string(&self.inner.locked().marks(&group)?).unwrap_or_default())
        })
    }
    /// `{ "ops": [...], "more": bool }` as JSON: ops newer than the given marks.
    pub fn since(&self, group: String, marks_json: String, limit: u64) -> Result<String, PeerError> {
        fallible(|| {
            let marks: peer::catalog::Marks = serde_json::from_str(&marks_json).map_err(|e| PeerError::Failed(e.to_string()))?;
            let (ops, more) = self.inner.locked().since(&group, &marks, limit as usize)?;
            Ok(serde_json::json!({ "ops": ops, "more": more }).to_string())
        })
    }
    pub fn held(&self) -> u64 {
        guard(|| 0, || {
            self.inner.locked().held() as u64
        })
    }
}

fn contact_of(c: peer::Contact) -> Contact {
    Contact {
        user: c.user.to_hex(),
        name: c.name,
        verified: c.verified,
        relay_only: c.relay_only,
        met_at: c.met_at,
        devices: c.devices.into_iter().map(status_of).collect(),
        entries: c.card.iter().flat_map(|k| k.body.devices.iter()).map(|d| DeviceEntry { id: d.id.to_hex(), name: d.name.clone(), kind: d.kind.as_str().to_owned(), added_at: d.added_at }).collect(),
        card: c.card.map(|k| k.to_bytes()),
        redirected_from: c.redirected_from.map(|u| u.to_hex()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A panic inside an entry point answers as its fallback, or `Failed`, sync or async: never
    /// as the error uniffi would hand Swift for a call that cannot throw.
    #[tokio::test]
    async fn a_panic_answers_as_the_fallback() {
        let bug = || -> u32 { panic!("a bug") };
        assert_eq!(guard(|| 7, bug), 7);
        assert!(matches!(fallible(|| -> Result<(), PeerError> { panic!("a bug") }), Err(PeerError::Failed(_))));
        let late = async {
            tokio::task::yield_now().await;
            if true {
                panic!("a bug, after a yield");
            }
            1
        };
        assert_eq!(guard_async(|| 3, late).await, 3);
        let failing = async {
            if true {
                panic!("a bug");
            }
            Ok(())
        };
        assert!(matches!(fallible_async(failing).await, Err(PeerError::Failed(_))));
    }
}
