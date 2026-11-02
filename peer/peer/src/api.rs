//! The app-facing surface, verbatim from SPEC.md, over one `Node`. Real here: open/adopt, me,
//! names, tags, invites and the join handshake, device linking with confirmation, card
//! replication, record push and exchange (mutual cardholders only), the dial loop, honest peers
//! and records, probe, sign/verify, Conn/Stream. Stubs: post/inbox delivery, groups, blobs.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock, RwLock, Weak};
use std::time::{Duration, Instant};

use bytes::Bytes;
use iroh::endpoint::{Connection, RecvStream, SendStream};
use iroh::{EndpointAddr, EndpointId, TransportAddr};
use n0_future::StreamExt;
use n0_watcher::Watcher;
use serde::{Deserialize, Serialize};
use tokio::sync::oneshot;

use crate::blobs::{Blobs, BulkDialer, Hash};
use crate::card::{Card, DeviceEntry, DeviceKind, first_card_of};
use crate::finding;
use crate::helper::{Carrier, CardholdersOnly, Envelope as Sealed, Helping, MAX_HOPS, RelayRole, primary_ip, relay_urls, spawn_relay};
use crate::identity::{DEVICE_KEY, DeviceId, GroupId, Keychain, STORE_KEY, Secret, Sig, USER_KEY, UserId, fingerprint, load_or_make};
use crate::introduce::{self, Introductions};
use crate::link::{self, Link, Meet};
use crate::policy::Class;
use crate::probe::{self, Reachable};
use crate::record::{AddressRecord, FoundBy, Reachability, RecordView, Records, SignedRecord};
use crate::store::Store;
use crate::trace::Trace;
use crate::transport::{self, BookEntry, BoxFuture, Handler, JOIN_ALPN, Msg, Options, Transport, ask};
use crate::card::Redirect;
use crate::{Error, Path, Result, now_ms};
use crate::sync::{Locked, Shared};

const LINK_CONFIRM_WAIT: Duration = Duration::from_secs(600);
/// How long `add` waits for the inviter's answer on one connection before trying a fresh one.
const HELLO_WAIT: Duration = Duration::from_secs(5);

/// How long an answer may take on a connection whose round trip is `rtt`: a few more round
/// trips and a second for the far side's store, at most `HELLO_WAIT`. A connection whose path
/// died without a word (a punch that switched it to a path that does not carry, a relay that
/// froze) is given up on this soon, not after 5 s.
fn answer_wait(rtt: Option<u32>) -> Duration {
    (Duration::from_millis(rtt.unwrap_or(250) as u64) * 4 + Duration::from_secs(1)).clamp(Duration::from_millis(1500), HELLO_WAIT)
}
/// A reply's maker dials the link's device afresh this often while it waits (`Peer::reply`), so
/// its own NAT and firewall stay open toward it; the reply's opener the same, for `REPLY_WINDOW`.
const REPLY_REDIAL: Duration = Duration::from_secs(3);
/// How long the opener of a reply dials its maker (`add`): both dial at once for this long.
const REPLY_WINDOW: Duration = Duration::from_secs(15);

/// How long a held connection's new path must hold before `Event::PathMoved` says so: a path that
/// flaps is said at most twice a second.
const PATH_SETTLE: Duration = Duration::from_millis(500);

/// How long a device whose connection went silent is refused at `connect`, unless a new
/// connection to it forms first.
const SILENT_HOLD: Duration = Duration::from_secs(30);

/// A dial in flight this long when the network changes is started over: its handshake
/// retransmits have backed off past what a fresh one costs (0.3, 0.6, 1.2 s … apart).
const STALE_DIAL: Duration = Duration::from_millis(500);

/// The machine's addresses as the OS lists them, without loopback and link-local, sorted.
fn os_addresses(state: &netwatch::netmon::State) -> Vec<std::net::IpAddr> {
    let mut v: Vec<std::net::IpAddr> = state
        .local_addresses
        .regular
        .iter()
        .copied()
        .filter(|ip| match ip {
            std::net::IpAddr::V4(a) => !a.is_link_local(),
            std::net::IpAddr::V6(a) => !a.is_unicast_link_local(),
        })
        .collect();
    v.sort();
    v.dedup();
    v
}

#[derive(Clone, Debug)]
pub struct Config {
    /// "baud", "computer", "darkroom", "life": names the mDNS service and the data files.
    pub app: String,
    /// The app's own ALPNs, on top of `peer/1`.
    pub alpns: Vec<Vec<u8>>,
    pub nearby: bool,
    pub helper_budget_bytes: u64,
    /// Fixed UDP port for a helper that maps a port; else ephemeral.
    pub port: Option<u16>,
    /// The name to use when this install is brand new.
    pub name: String,
    pub device_name: String,
    /// A helper behind a TLS terminator advertises this URL instead of `http://<ip>:<port>`.
    pub relay_url: Option<String>,
    /// A headless device confirms device links without a person: `peer-node run --confirm-links`.
    pub auto_confirm_links: bool,
    /// Run the embedded relay on `port` for everyone whose card I hold. Offered only when the TCP
    /// port is mapped or `public` says the address is reachable.
    pub relay: bool,
    /// The person says this port is forwarded or the address is global: `reachable` is true
    /// without a probe, for a VPS or a box behind a hand-made port forward.
    pub public: bool,
    /// Ask the gateway for a UDP mapping (default). Off only to test an unreachable node.
    pub portmap: bool,
    /// What a link looks like before `#`: the app's, never the crate's. `baud://add`,
    /// `https://computer.rubric.sh/add`, `health://add`.
    pub link_scheme: String,
    /// What this device is, for sentences like "Jo's iPhone". Defaults to the build target.
    pub device_kind: DeviceKind,
    /// Advertise and dial VPN-interface addresses (Tailscale's ranges). Default true. A test
    /// switch: false lets two devices on one tailnet exercise the public path and the helper.
    pub vpn: bool,
}

impl Config {
    pub fn new(app: &str, name: &str, device_name: &str) -> Self {
        Config {
            app: app.to_owned(),
            alpns: Vec::new(),
            nearby: true,
            helper_budget_bytes: crate::helper::CARRIER_BUDGET_BYTES,
            port: None,
            name: name.to_owned(),
            device_name: device_name.to_owned(),
            relay_url: None,
            auto_confirm_links: false,
            relay: false,
            public: false,
            portmap: true,
            link_scheme: format!("{app}://add"),
            device_kind: DeviceKind::this(),
            vpn: true,
        }
    }
}

/// Computer's existing keys and book, imported once so device ids stay stable and friends need
/// not re-meet. `devices` is the person's whole old device list, so each device migrating alone
/// signs the same first card; `seq` starts at the old card's `at`, and equal-seq own cards merge
/// by union.
pub struct Migration {
    pub device_secret: [u8; 32],
    pub user_secret: [u8; 32],
    pub name: String,
    pub devices: Vec<MigratedDevice>,
    pub card_at: u64,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct MigratedDevice {
    pub id: DeviceId,
    pub name: String,
    pub kind: DeviceKind,
    pub added_at: u64,
    /// Last-known addresses from the old ticket; seeds the record cache as `FoundBy::Cache`.
    pub addresses: Vec<TransportAddr>,
}

/// A friend's device from an old card, adopted until their first new-format card arrives.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AdoptedDevice {
    pub id: DeviceId,
    pub name: String,
    pub addresses: Vec<TransportAddr>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Person {
    pub user: UserId,
    pub name: String,
    pub avatar: Option<Hash>,
    pub fingerprint: String,
    pub devices: Vec<DeviceEntry>,
    pub this_device: DeviceId,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PeerStatus {
    pub device: DeviceId,
    pub user: UserId,
    /// From the card: "Jo's iPhone" needs both.
    pub name: String,
    pub kind: DeviceKind,
    pub online: bool,
    pub path: Path,
    pub rtt_ms: Option<u32>,
    /// Unix ms this device was last connected (now, while online); None if never.
    pub last_seen: Option<u64>,
    /// How old the record I hold for it is, and how I found it.
    pub record_age_ms: Option<u64>,
    pub found_by: Option<FoundBy>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Contact {
    pub user: UserId,
    pub name: String,
    pub card: Option<Card>,
    pub verified: bool,
    pub relay_only: bool,
    pub met_at: u64,
    pub devices: Vec<PeerStatus>,
    /// Their old key, when this contact came by a redirect: vouched for by that key, not verified.
    pub redirected_from: Option<UserId>,
}

/// Who is on the other end of an accepted connection, verified by the crate.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Identity {
    pub user: UserId,
    pub device: DeviceId,
    /// The person's fingerprint was pinned by `verify`. Admission is the connection itself.
    pub pinned: bool,
    pub own: bool,
    /// The groups whose member list admitted this device (empty for own devices and contacts).
    pub groups: Vec<GroupId>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub struct EnvelopeId(pub [u8; 32]);
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ConnId(pub u64);
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct LinkReqId(pub u64);

/// What arrived while away. An envelope says who it is for and nothing else, so `from` is known
/// only when the sender handed it over itself; otherwise the sender is inside the app's sealed
/// `bytes`. `carried_by` is the device that delivered it, or empty for a direct delivery.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Envelope {
    pub id: EnvelopeId,
    pub from: Option<DeviceId>,
    pub bytes: Vec<u8>,
    pub carried_by: Vec<DeviceId>,
    pub received_at: u64,
}

/// What a group is (DESIGN.md, "Three tiers"). In a `Space` every member is a mutual:
/// records shared, always dialed, carried for. In a `Chat` a member is a mutual only if also a
/// contact (or my own device): the group's cards travel so names and keys are known, but no
/// address record goes to a chat-only co-member, nobody dials or admits one, and what I send one
/// is carried by a mutual we share.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum GroupKind {
    #[default]
    Space,
    Chat,
}

/// A group member as the app shows one: the public name from their card, my petname when they are
/// a contact, and whether they are a mutual (connected, dialed, records shared) or reached only
/// through one.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Member {
    pub user: UserId,
    /// The name they chose, from their card: what a non-contact sees.
    pub name: String,
    pub petname: Option<String>,
    pub contact: bool,
    pub mutual: bool,
    pub card: Card,
}

/// Ids only; the app re-reads.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Event {
    Online(DeviceId),
    Offline(DeviceId),
    /// A new connection to the device replaced the one held (it relaunched or moved, or both
    /// sides dialed), or a send was refused on the path it has: the app's connections to it were
    /// dropped with the old one, so it re-reads, reconnects and catches up. Compare `PathMoved`.
    PathChanged(DeviceId),
    /// A dial to a device not connected began: the app can say "reaching Ana's Mac…" until
    /// `Online`, or until the next `Dialing` says it is trying again. Also the meeting device of a
    /// link being redeemed.
    Dialing(DeviceId),
    /// A link being redeemed (`add`, `link`) reached its meeting device: the far side has the
    /// request now. Until this, the joining side has only dialed; after it, a device link waits
    /// for the person to confirm the code.
    Reached(DeviceId),
    RecordChanged(DeviceId),
    /// A connection on one of the app's ALPNs; `accept(conn)` hands it over.
    Inbound { conn: ConnId, alpn: String },
    Delivered(EnvelopeId),
    Inbox(EnvelopeId),
    ContactsChanged,
    MeChanged,
    LinkRequest(LinkReqId),
    /// A contact who had two identities is one now (`Redirect`): their old key's contact moved to
    /// `to`, with its petname. The app merges the two chats.
    ContactRedirected { from: UserId, to: UserId },
    /// A friend removed me (their `remove`): they dropped my card, their devices refuse mine, and
    /// I dropped theirs. The app hides the chat.
    ContactRemoved(UserId),
    /// Another of my devices removed this one (`remove_device`): my card no longer lists it, and
    /// my devices and friends refuse it. The app says so and calls `reset`.
    Removed,
    NetworkChanged,
    ReachabilityChanged(Reachable),
    /// A reply this device made (`Peer::reply`) was opened by the link's maker and the meeting
    /// completed: they are a contact now.
    Replied(UserId),
    /// A reply this device made stopped waiting unopened: it ran out (`link::REPLY_TTL_SECS`, or
    /// the link's own expiry), or the maker's invite was spent on someone else.
    ReplyLapsed(UserId),
    /// The connection held to the device is the same, and its path moved under it: a punch landed
    /// (relayed → direct), a direct path gave way to the relay, IPv4 to IPv6. Only how it is
    /// reached changed; the app's connections and streams to it stand, so it re-reads the label
    /// alone. Said once the new path has held `PATH_SETTLE`, never for a round trip's change.
    PathMoved(DeviceId),
}

pub trait Listener: Send + Sync {
    fn on(&self, event: Event);
}

/// Whose device a link names to meet at (`Peer::invite_meeting`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum MeetingKind {
    /// One of mine that runs a relay (this one, or my Mac): friends reach me through it.
    Own,
    /// A friend's device that runs a relay and holds my card.
    Friend,
    /// No reachable device: the link carries this device's raw addresses, so only someone who
    /// can reach it directly (the same Wi-Fi, a mapped port) can redeem it.
    None,
}

/// What the next link will carry, before it is shown: "friends reach you through your Mac", or
/// "add a friend from a device that can be reached first".
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Meeting {
    pub kind: MeetingKind,
    pub device: Option<DeviceId>,
    pub device_name: String,
    /// Whose device: me for `Own`, the friend for `Friend`.
    pub user: Option<UserId>,
    pub user_name: String,
}

/// A friend link `add` is redeeming, for as long as this lives (`Node::adding`).
struct Adding<'a>(&'a Node, [u8; 32]);
impl Drop for Adding<'_> {
    fn drop(&mut self) {
        self.0.adding.locked().remove(&self.1);
    }
}

/// A reply this device made and waits on (`Peer::reply`): the link it answers, and until when.
#[derive(Clone, Serialize, Deserialize)]
struct Replying {
    theirs: Link,
    until: u64,
}

/// Redirects this node knows: applied to its contacts, and issued by it when it linked into
/// another person (with whom each still has to reach).
#[derive(Default, Serialize, Deserialize)]
struct Redirects {
    known: Vec<Redirect>,
    issued: Vec<(Redirect, Vec<UserId>)>,
    /// Envelopes the crate posted (redirects for devices that were away): not the app's.
    internal: HashSet<[u8; 32]>,
}

impl Redirects {
    fn load(store: &Store) -> Redirects {
        store.meta("redirects").ok().flatten().and_then(|b| postcard::from_bytes(&b).ok()).unwrap_or_default()
    }
    fn save(&self, store: &Store) {
        if let Ok(b) = postcard::to_allocvec(self) {
            let _ = store.set_meta("redirects", &b);
        }
    }
    fn successor(&self, user: &UserId) -> Option<UserId> {
        self.known.iter().find(|r| r.from == *user).map(|r| r.to)
    }
}

/// An envelope the crate opens itself: a redirect for a device that was away.
const REDIRECT_ENVELOPE: &[u8] = b"\0peer\0redirect/1\0";

/// The device a link names and the relay URLs it is reached at (all aliases of one server).
struct MeetHelper {
    meeting: Meeting,
    device: DeviceId,
    urls: Vec<iroh::RelayUrl>,
}

struct ContactMeta {
    petname: String,
    verified: bool,
    relay_only: bool,
    met_at: u64,
}

struct Adopted {
    petname: String,
    devices: Vec<AdoptedDevice>,
    met_at: u64,
}

/// A crate connection to one device, with what that device told us it wants records for.
struct Live {
    conn: Connection,
    wants: Option<(u64, HashSet<[u8; 8]>)>,
}

struct PendingLink {
    secret: [u8; 32],
    device: DeviceId,
    name: String,
    kind: DeviceKind,
    tx: Option<oneshot::Sender<bool>>,
}

struct State {
    user: Secret,
    card: Card,
    cards: HashMap<UserId, Card>,
    contacts: HashMap<UserId, ContactMeta>,
    /// Co-members by group, with each group's kind (absent: `Space`, as groups were before kinds).
    members: HashMap<GroupId, HashSet<UserId>>,
    kinds: HashMap<GroupId, GroupKind>,
    adopted: HashMap<UserId, Adopted>,
    tags: Vec<String>,
    records: Records,
    carrier: Carrier,
    /// Posted by me, not yet delivered: re-handed to every new carrier until acked or expired.
    outbox: HashMap<[u8; 32], Sealed>,
    inbox: Vec<Envelope>,
    /// Acks seen, so each is forwarded once and a late copy is dropped.
    acked: HashSet<[u8; 32]>,
    /// Own devices from `Migration` that have not yet answered `peer/1` (a 0.4.x computer):
    /// dialed straight on the app ALPN at their migrated addresses, no round trip, until they do.
    legacy: HashSet<DeviceId>,
    conns: HashMap<DeviceId, Live>,
    /// Where each device's packets last came from on a direct path (see `Node::saw`).
    seen: HashMap<DeviceId, std::net::SocketAddr>,
    /// When each device's last connection ended (unix ms), kept across restarts.
    last_seen: HashMap<DeviceId, u64>,
    /// One connection per (device, alpn); streams multiplex on it.
    app_conns: HashMap<(DeviceId, Vec<u8>), Connection>,
    inbound: HashMap<u64, Connection>,
    next_conn: u64,
    reachable: Reachable,
    tcp_reachable: bool,
    /// Mappings a dial back from outside did not get through (`probe`): the UDP one is not in my
    /// addresses or links, the relay is not offered on the TCP one, until a later check gets
    /// through or the router maps another port.
    udp_refuted: Option<std::net::SocketAddr>,
    tcp_refuted: Option<std::net::SocketAddr>,
    online: bool,
    record_seq: u64,
    pending: HashMap<u64, PendingLink>,
    next_req: u64,
}

struct Node {
    dir: PathBuf,
    config: Config,
    device: Secret,
    keychain: Arc<dyn Keychain>,
    store: Mutex<Store>,
    transport: OnceLock<Arc<Transport>>,
    allow: Arc<RwLock<HashSet<EndpointId>>>,
    /// Who my relay admitted on a meet token (`helper::Met`).
    met: crate::helper::Met,
    /// The person of each device in `allow`, for my relay (`helper::CardholdersOnly`).
    people: Arc<RwLock<HashMap<EndpointId, UserId>>>,
    blobs: OnceLock<Blobs>,
    state: RwLock<State>,
    listeners: Mutex<Vec<Arc<dyn Listener>>>,
    /// Opened by `adopt`: `sign_as_user` is allowed, for the transition only.
    adopted: bool,
    /// Rule 2: when each mutual is next dialed, and the dials in flight that callers join.
    schedule: Mutex<finding::Schedule>,
    inflight: Mutex<HashMap<DeviceId, InflightDial>>,
    dial_ids: AtomicU64,
    /// The relay URLs iroh may home on: the meeting device's (`steer_home`).
    home_urls: Mutex<Vec<iroh::RelayUrl>>,
    /// Friend links redeemed in this run, by whom: a repeated Hello from that person is answered.
    /// Replies spent here too, by the reply's secret.
    redeemed: Mutex<HashMap<[u8; 32], UserId>>,
    /// Replies this device made and waits on (`Peer::reply`), by the reply's secret. Kept in the
    /// store (`meta "replies"`), so a relaunch keeps waiting.
    replies: Mutex<HashMap<[u8; 32], Replying>>,
    /// Friend links `add` is redeeming now, by secret: a reply to one leaves the dialing to it.
    adding: Mutex<HashSet<[u8; 32]>>,
    /// Identities merged by `Redirect`, kept in the store (`meta "redirects"`).
    redirects: Mutex<Redirects>,
    kick: Arc<tokio::sync::Notify>,
    /// The relay as advertised: present only while its port is reachable (a confirmed mapping,
    /// or `public`). The server itself runs from `start_relay` to `close` either way.
    relay: Mutex<Option<RelayRole>>,
    relay_server: Mutex<Option<iroh_relay::server::Server>>,
    last_probe: Mutex<Option<std::time::Instant>>,
    probing: AtomicBool,
    /// Dial-backs asked of me (`probe::dial_back`): each costs a socket, so once per asker a while.
    checks: introduce::Spacing<DeviceId>,
    trace: Arc<Trace>,
    /// What the next connection completes: `online` (since open began) or `wake` (since
    /// `set_online(true)` after a `set_online(false)`).
    first: Mutex<Option<(&'static str, Instant)>>,
    /// When each envelope I posted left, for `post` lines.
    posted: Mutex<HashMap<[u8; 32], Instant>>,
    /// The last address change, for `migrated` and `redialed` lines.
    net_at: Mutex<Option<Instant>>,
    went_online: AtomicBool,
    closed: AtomicBool,
    /// The content of the record last broadcast: an unchanged record is not sent again.
    last_pushed: Mutex<Option<Vec<u8>>>,
    relay_owners: RwLock<HashMap<iroh::RelayUrl, DeviceId>>,
    /// The UDP mapping of the endpoint's port and the relay's TCP one (`peer::portmap`), held for
    /// the node's life and released on close; with the local address each was made for.
    udp_map: Mutex<Option<(std::net::Ipv4Addr, crate::portmap::Mapping)>>,
    tcp_map: Mutex<Option<crate::portmap::Mapping>>,
    /// Which `map_tcp` is current: an older one's watcher stands down.
    tcp_gen: AtomicU64,
    /// When `remap` last asked the gateway.
    last_remap: Mutex<Option<Instant>>,
    /// Hole punching through a go-between (`introduce`): what was learnt, and the spacing.
    intro: Introductions,
    /// Devices whose held connection went silent (`stalled`), and when, until a new one is held:
    /// `connect` refuses them at once, so a message goes to carriers instead of into a dead path.
    stalled: Mutex<HashMap<DeviceId, Instant>>,
}

/// One node: one device key, one person, one endpoint. Clone is cheap; everything in SPEC.md hangs off it.
#[derive(Clone)]
pub struct Peer {
    node: Arc<Node>,
}

fn want_hash(salt: u64, device: &DeviceId) -> [u8; 8] {
    let h = blake3::Hasher::new().update(&salt.to_le_bytes()).update(&device.0).finalize();
    h.as_bytes()[..8].try_into().unwrap()
}

fn meet_addr(meet: &Meet) -> EndpointAddr {
    let mut addr = EndpointAddr::new(meet.device.into());
    for a in &meet.addrs {
        if let Some(url) = a.strip_prefix("relay=") {
            if let Ok(url) = url.parse::<iroh::RelayUrl>() {
                addr = addr.with_relay_url(url);
            }
        } else if let Ok(sa) = a.parse() {
            addr = addr.with_ip_addr(sa);
        }
    }
    addr
}

/// `url` carrying `token` in its query (`?m=…`), which the relay client keeps on its request.
fn with_meet_token(url: &iroh::RelayUrl, token: &str) -> String {
    let u = url.to_string();
    let sep = if u.contains('?') { '&' } else { '?' };
    format!("{u}{sep}{}={token}", link::MEET_PARAM)
}

impl Peer {
    /// Open or create. Under 300 ms: never waits on a relay.
    pub async fn open(dir: PathBuf, keychain: Arc<dyn Keychain>, config: Config) -> Result<Peer> {
        let t0 = Instant::now();
        std::fs::create_dir_all(&dir)?;
        let device = load_or_make(keychain.as_ref(), DEVICE_KEY)?;
        let user = load_or_make(keychain.as_ref(), USER_KEY)?;
        let store_key = load_or_make(keychain.as_ref(), STORE_KEY)?.to_bytes();
        Self::start(t0, dir, keychain, config, device, user, store_key, None).await
    }

    /// Import existing keys, once. Later opens use `open` with the same keychain.
    pub async fn adopt(dir: PathBuf, keychain: Arc<dyn Keychain>, mut config: Config, m: Migration) -> Result<Peer> {
        let t0 = Instant::now();
        if keychain.get(DEVICE_KEY)?.is_some() {
            return Err(Error::Used);
        }
        keychain.put(DEVICE_KEY, &m.device_secret)?;
        keychain.put(USER_KEY, &m.user_secret)?;
        config.name = m.name.clone();
        std::fs::create_dir_all(&dir)?;
        let device = Secret::from_bytes(&m.device_secret);
        let user = Secret::from_bytes(&m.user_secret);
        let store_key = load_or_make(keychain.as_ref(), STORE_KEY)?.to_bytes();
        Self::start(t0, dir, keychain, config, device, user, store_key, Some(m)).await
    }

    #[allow(clippy::too_many_arguments)]
    async fn start(t0: Instant, dir: PathBuf, keychain: Arc<dyn Keychain>, config: Config, device: Secret, user: Secret, store_key: [u8; 32], migration: Option<Migration>) -> Result<Peer> {
        let store = Store::open(&dir.join("peer.db"), &store_key).map_err(|e| {
            if dir.join("peer.db").exists() {
                Error::Keychain(format!("store {} is sealed under another store-key: another dir is using this keychain service, or the keychain was replaced ({e})", dir.display()))
            } else {
                e
            }
        })?;
        // A store belongs to one device. Two dirs opened against one keychain service would
        // otherwise swap keys under each other silently; say so instead.
        match store.meta("device")? {
            Some(id) if id.as_slice() != device.device_id().0.as_slice() => {
                let other = DeviceId(<[u8; 32]>::try_from(id.as_slice()).unwrap_or([0; 32]));
                return Err(Error::Keychain(format!("store {} belongs to device {}, the keychain holds {}: another dir is using this keychain service", dir.display(), other.short(), device.device_id().short())));
            }
            Some(_) => {}
            None => store.set_meta("device", &device.device_id().0)?,
        }
        let mut records = Records::default();
        // "Adopted from legacy" outlives the adopt launch: sign_as_user must work on every open
        // until the release that drops 0.4.x removes it.
        if migration.is_some() {
            store.set_meta("adopted", &[1])?;
        }
        let adopted = store.meta("adopted")?.is_some();
        let mut legacy: HashSet<DeviceId> = store.meta("legacy")?.and_then(|b| postcard::from_bytes::<Vec<DeviceId>>(&b).ok()).unwrap_or_default().into_iter().collect();
        let card = match (store.meta("card")?, migration) {
            (Some(bytes), _) => match Card::from_bytes(&bytes) {
                Ok(card) => card,
                Err(_) => {
                    // The card format moved under this store: keep the identity (the keys are in the
                    // keychain), rebuild my card, forget everyone's; they re-meet by invite.
                    tracing::warn!("stored card is from an older cut: identity kept, contacts reset");
                    store.reset_book()?;
                    let card = first_card_of(&user, &device, &config.name, &config.device_name, config.device_kind, now_ms());
                    store.set_meta("card", &card.to_bytes())?;
                    card
                }
            },
            (None, Some(m)) => {
                let mut devices: Vec<DeviceEntry> = m.devices.iter().map(|d| DeviceEntry { id: d.id, name: d.name.clone(), kind: d.kind, added_at: d.added_at, app: Vec::new() }).collect();
                if !devices.iter().any(|d| d.id == device.device_id()) {
                    devices.push(DeviceEntry { id: device.device_id(), name: config.device_name.clone(), kind: config.device_kind, added_at: m.card_at, app: Vec::new() });
                }
                devices.sort_by(|x, y| x.id.cmp(&y.id));
                for d in m.devices.iter().filter(|d| d.id != device.device_id()) {
                    records.seed(d.id, d.addresses.clone(), m.card_at);
                    legacy.insert(d.id);
                }
                let _ = store.set_meta("legacy", &postcard::to_allocvec(&legacy.iter().copied().collect::<Vec<_>>()).unwrap_or_default());
                let body = crate::card::CardBody { user: user.user_id(), name: m.name, avatar: None, devices, revoked: Vec::new(), seq: m.card_at };
                let card = Card::sign(body, &user);
                store.set_meta("card", &card.to_bytes())?;
                card
            }
            (None, None) => {
                let card = first_card_of(&user, &device, &config.name, &config.device_name, config.device_kind, now_ms());
                store.set_meta("card", &card.to_bytes())?;
                card
            }
        };
        let mut cards = HashMap::new();
        for c in store.cards()? {
            cards.insert(c.user(), c);
        }
        let mut contacts = HashMap::new();
        for (u, petname, verified, relay_only, met_at) in store.contacts()? {
            contacts.insert(u, ContactMeta { petname, verified, relay_only, met_at });
        }
        let mut members: HashMap<GroupId, HashSet<UserId>> = HashMap::new();
        for (g, u) in store.members()? {
            members.entry(g).or_default().insert(u);
        }
        let kinds: HashMap<GroupId, GroupKind> = store.meta("group_kinds")?.and_then(|b| postcard::from_bytes::<Vec<(GroupId, GroupKind)>>(&b).ok()).unwrap_or_default().into_iter().collect();
        for g in kinds.keys() {
            members.entry(*g).or_default();
        }
        let mut adopted_map: HashMap<UserId, Adopted> = HashMap::new();
        for (u, petname, card_at, devices) in store.adopted()? {
            for d in &devices {
                records.seed(d.id, d.addresses.clone(), card_at);
            }
            adopted_map.insert(u, Adopted { petname, devices, met_at: card_at });
        }
        for (rec, found_by, at) in store.records()? {
            let _ = records.put(rec, found_by, at);
        }
        let seen: HashMap<DeviceId, std::net::SocketAddr> = store.meta("seen")?.and_then(|b| postcard::from_bytes::<Vec<(DeviceId, std::net::SocketAddr)>>(&b).ok()).unwrap_or_default().into_iter().collect();
        let last_seen: HashMap<DeviceId, u64> = store.meta("last_seen")?.and_then(|b| postcard::from_bytes::<Vec<(DeviceId, u64)>>(&b).ok()).unwrap_or_default().into_iter().collect();
        let record_seq = store.meta("record_seq")?.and_then(|b| b.try_into().ok()).map(u64::from_le_bytes).unwrap_or(0);
        let mut carrier = Carrier::default();
        let mut outbox = HashMap::new();
        let mut inbox = Vec::new();
        let now = now_ms();
        for (env, kind, carried_by, at) in store.envelopes()? {
            match kind {
                1 => {
                    outbox.insert(env.id, env);
                }
                2 => {
                    if let Ok(bytes) = crate::helper::open(&device, &env) {
                        inbox.push(Envelope { id: EnvelopeId(env.id), from: None, bytes, carried_by, received_at: at });
                    }
                }
                _ => {
                    let mut e = env;
                    e.hops = e.hops.saturating_sub(1); // hold() counts the hop again
                    let _ = carrier.hold(e, now);
                }
            }
        }

        let redirects_loaded = Redirects::load(&store);
        let replies_loaded: HashMap<[u8; 32], Replying> = store
            .meta("replies")
            .ok()
            .flatten()
            .and_then(|b| postcard::from_bytes::<Vec<Replying>>(&b).ok())
            .unwrap_or_default()
            .into_iter()
            .filter(|r| r.until > now_ms() / 1000)
            .map(|r| (link::reply_secret(&r.theirs.secret), r))
            .collect();
        let node = Arc::new(Node {
            dir: dir.clone(),
            config: config.clone(),
            device: device.clone(),
            keychain,
            store: Mutex::new(store),
            transport: OnceLock::new(),
            allow: Default::default(),
            met: Default::default(),
            people: Default::default(),
            blobs: OnceLock::new(),
            state: RwLock::new(State {
                user,
                card,
                cards,
                contacts,
                members,
                kinds,
                adopted: adopted_map,
                tags: Vec::new(),
                records,
                carrier,
                outbox,
                inbox,
                acked: HashSet::new(),
                legacy,
                conns: HashMap::new(),
                seen,
                last_seen,
                app_conns: HashMap::new(),
                inbound: HashMap::new(),
                next_conn: 1,
                reachable: if config.public { Reachable::Yes } else { Reachable::Unknown },
                tcp_reachable: config.public,
                udp_refuted: None,
                tcp_refuted: None,
                online: false,
                record_seq,
                pending: HashMap::new(),
                next_req: 1,
            }),
            listeners: Mutex::new(Vec::new()),
            adopted,
            schedule: Mutex::new(finding::Schedule::default()),
            inflight: Mutex::new(HashMap::new()),
            dial_ids: AtomicU64::new(0),
            home_urls: Mutex::new(Vec::new()),
            redeemed: Mutex::new(HashMap::new()),
            replies: Mutex::new(replies_loaded),
            adding: Mutex::default(),
            redirects: Mutex::new(redirects_loaded),
            kick: Arc::new(tokio::sync::Notify::new()),
            relay: Mutex::new(None),
            relay_server: Mutex::new(None),
            last_probe: Mutex::new(None),
            probing: AtomicBool::new(false),
            checks: introduce::Spacing::new(Duration::from_secs(10)),
            trace: Arc::new(Trace::new(t0)),
            first: Mutex::new(Some(("online", t0))),
            posted: Mutex::new(HashMap::new()),
            net_at: Mutex::new(None),
            went_online: AtomicBool::new(false),
            closed: AtomicBool::new(false),
            last_pushed: Mutex::new(None),
            relay_owners: RwLock::new(HashMap::new()),
            udp_map: Mutex::new(None),
            tcp_map: Mutex::new(None),
            tcp_gen: AtomicU64::new(0),
            last_remap: Mutex::new(Some(Instant::now())),
            intro: Introductions::default(),
            stalled: Mutex::default(),
        });
        crate::trace::record_panics(&node.trace);
        node.relays_changed();
        let t_store = t0.elapsed();
        // GC sweeps what no tag names: `forget` drops a hash's tags and the bytes go within the interval.
        let blobs_dir = dir.join("blobs");
        let mut opts = iroh_blobs::store::fs::options::Options::new(&blobs_dir);
        opts.gc = Some(iroh_blobs::store::GcConfig { interval: Duration::from_secs(300), add_protected: None });
        let store = iroh_blobs::store::fs::FsStore::load_with_opts(blobs_dir.join("blobs.db"), opts).await.map_err(|e| Error::Store(e.to_string()))?;
        let t_blobs = t0.elapsed();
        let proto = iroh_blobs::BlobsProtocol::new(&store, None);
        // The port we bound last time: cached addresses in friends' records point at it.
        let port_hint = node.store.locked().meta("port")?.and_then(|b| <[u8; 2]>::try_from(b.as_slice()).ok()).map(u16::from_le_bytes);
        let opts = Options { app: config.app.clone(), nearby: config.nearby, alpns: config.alpns.clone(), port: config.port, port_hint, portmap: config.portmap, vpn: config.vpn, blobs: Some(proto), met: config.relay.then(|| node.met.clone()) };
        let handler: Arc<dyn Handler> = Arc::new(NodeHandler(Arc::downgrade(&node)));
        let transport = Arc::new(Transport::open(device.iroh(), opts, handler, node.allow.clone()).await?);
        let _ = node.transport.set(transport.clone());
        if let Some(port) = transport.port() {
            node.store.locked().set_meta("port", &port.to_le_bytes())?;
        }
        if config.portmap && !config.public {
            node.map_udp();
        }
        let _ = node.blobs.set(Blobs::new(store, blobs_dir.clone(), Arc::new(NodeDialer(Arc::downgrade(&node))), transport.rt.clone(), node.trace.clone()));
        let t_bind = t0.elapsed();
        tracing::info!(store_ms = t_store.as_millis() as u64, blobs_ms = (t_blobs - t_store).as_millis() as u64, bind_ms = (t_bind - t_blobs).as_millis() as u64, "peer open");
        node.recompute_allow();
        if config.relay {
            node.start_relay().await?;
        }
        // Home on the meeting device's relay now, from cached records, so iroh connects to it while
        // the app finishes opening and the first relayed dial or redeemed link does not wait.
        for r in node.state.reading().records.signed() {
            if r.record.relay == Some(r.device()) {
                r.record.relay_urls().for_each(|u| transport.note_relay(u.clone()));
            }
        }
        node.steer_home();
        // Replies still waiting from before a relaunch.
        for secret in node.replies.locked().keys().copied().collect::<Vec<_>>() {
            transport.rt.spawn(node.clone().keep_replying(secret));
        }
        if config.nearby {
            let err = transport.nearby_err.clone();
            if let Some(e) = &err {
                tracing::warn!("nearby does nothing here: multicast is blocked ({e}); on iOS that takes the com.apple.developer.networking.multicast entitlement");
            }
            node.trace.emit("nearby", serde_json::json!({ "ok": err.is_none(), "err": err }));
        }
        node.trace.emit(
            "open",
            serde_json::json!({ "ms": crate::trace::ms(t0), "store_ms": t_store.as_millis() as u64, "blobs_ms": (t_blobs - t_store).as_millis() as u64, "bind_ms": (t_bind - t_blobs).as_millis() as u64, "pid": std::process::id() }),
        );

        // Inbound app connections: the gate already verified the device; hand the app an id.
        if let Some(mut rx) = transport.take_inbound() {
            let weak = Arc::downgrade(&node);
            transport.rt.spawn(async move {
                while let Some(conn) = rx.recv().await {
                    let Some(node) = weak.upgrade() else { break };
                    let alpn = String::from_utf8_lossy(conn.alpn()).into_owned();
                    let id = {
                        let mut s = node.state.writing();
                        let id = s.next_conn;
                        s.next_conn += 1;
                        s.inbound.insert(id, conn);
                        id
                    };
                    node.emit(Event::Inbound { conn: ConnId(id), alpn });
                }
            });
        }
        // Push on change: a new network means a new record for every connected cardholder.
        {
            let weak = Arc::downgrade(&node);
            let mut addrs = transport.ep().watch_addr();
            transport.rt.spawn(async move {
                // iroh's address watcher also fires when the home relay moves between a helper's
                // aliases (one server, several URLs), which is not a network change: only a new
                // set of IP addresses is. A moved relay is broadcast only if the record changed.
                let mut ips: Option<Vec<std::net::SocketAddr>> = {
                    let mut now: Vec<std::net::SocketAddr> = addrs.get().ip_addrs().copied().collect();
                    now.sort();
                    Some(now)
                };
                while let Ok(addr) = addrs.updated().await {
                    let Some(node) = weak.upgrade() else { break };
                    if node.closed.load(Ordering::SeqCst) {
                        break;
                    }
                    let mut now: Vec<std::net::SocketAddr> = addr.ip_addrs().copied().collect();
                    now.sort();
                    if ips.as_ref() == Some(&now) {
                        node.push_record();
                        continue;
                    }
                    ips = Some(now.clone());
                    node.trace.emit("net", serde_json::json!({ "addrs": now.iter().map(|a| a.to_string()).collect::<Vec<_>>(), "source": "iroh" }));
                    node.network_changed(false);
                }
            });
        }
        // The OS's word for it, without waiting on iroh: an address that comes or goes (a route
        // socket on macOS, netlink on Linux; nothing on the network). iroh may take seconds to
        // report a returning address, or not report it at all; a network that comes back is
        // acted on the moment it has an address.
        {
            let weak = Arc::downgrade(&node);
            transport.rt.spawn(async move {
                let Ok(monitor) = netwatch::netmon::Monitor::new().await else { return };
                let mut state = monitor.interface_state();
                let mut last = os_addresses(&state.get());
                while let Ok(now) = state.updated().await {
                    let Some(node) = weak.upgrade() else { break };
                    if node.closed.load(Ordering::SeqCst) {
                        break;
                    }
                    let now = os_addresses(&now);
                    if now == last {
                        continue;
                    }
                    last = now;
                    node.trace.emit("net", serde_json::json!({ "addrs": last.iter().map(|a| a.to_string()).collect::<Vec<_>>(), "source": "os" }));
                    node.network_changed(true);
                }
            });
        }
        // Rule 2: the network loop, from open to close, whatever the app does.
        {
            let weak = Arc::downgrade(&node);
            let kick = node.kick.clone();
            transport.rt.spawn(async move {
                loop {
                    let next = {
                        let Some(node) = weak.upgrade() else { break };
                        if node.closed.load(Ordering::SeqCst) {
                            break;
                        }
                        node.tick()
                    };
                    let wait = next.map(|n| n.saturating_duration_since(Instant::now())).unwrap_or(finding::BACKOFF_MAX).min(finding::BACKOFF_MAX);
                    tokio::select! {
                        _ = kick.notified() => {}
                        _ = tokio::time::sleep(wait) => {}
                    }
                }
            });
        }
        Ok(Peer { node })
    }

    pub fn dir(&self) -> &PathBuf {
        &self.node.dir
    }

    pub fn me(&self) -> Person {
        let s = self.node.state.reading();
        Person {
            user: s.user.user_id(),
            name: s.card.body.name.clone(),
            avatar: s.card.body.avatar.map(Hash),
            fingerprint: fingerprint(&s.user.user_id()),
            devices: s.card.body.devices.iter().filter(|d| !s.card.is_revoked(&d.id, u64::MAX)).cloned().collect(),
            this_device: self.node.device.device_id(),
        }
    }

    /// My signed card, as a group's membership event would carry it.
    pub fn card(&self) -> Card {
        self.node.state.reading().card.clone()
    }

    /// Who a device belongs to, as far as my cards say: for the catalog's verification hook.
    pub fn user_of_device(&self, device: &DeviceId) -> Option<UserId> {
        self.node.user_of(device)
    }

    /// A local catalog write signed by this device, applied locally, returned for pushing.
    pub fn catalog_write(&self, catalog: &mut crate::catalog::Catalog, group: &str, table: &str, row: &str, field: &str, value: serde_json::Value, tombstone: bool) -> Result<crate::catalog::Op> {
        catalog.write(&self.node.device, group, table, row, field, value, tombstone, now_ms())
    }

    /// A person's card as I hold it: mine, a contact's, or a co-member's.
    pub fn card_of(&self, user: UserId) -> Option<Card> {
        let s = self.node.state.reading();
        if user == s.user.user_id() { Some(s.card.clone()) } else { s.cards.get(&user).cloned() }
    }

    /// Who a device is to me, as `accept` would say it.
    pub fn identity_of_device(&self, device: DeviceId) -> Identity {
        self.node.identity_of(device)
    }

    /// The address I would dial for a device, from its cached record (tests and diagnostics).
    pub fn record_addr(&self, device: DeviceId) -> Option<EndpointAddr> {
        self.node.state.reading().records.addr(&device)
    }

    pub fn set_name(&self, name: &str) -> Result<()> {
        let card = {
            let mut s = self.node.state.writing();
            let mut body = s.card.next();
            body.name = name.to_owned();
            s.card = Card::sign(body, &s.user);
            s.card.clone()
        };
        self.node.store.locked().set_meta("card", &card.to_bytes())?;
        self.node.push_card(card);
        self.node.emit(Event::MeChanged);
        Ok(())
    }

    pub fn set_avatar(&self, _hash: Hash) -> Result<()> {
        Err(Error::Unimplemented("set_avatar"))
    }

    /// Capability tags on my record; re-signed and pushed on change.
    pub fn set_tags(&self, tags: Vec<String>) -> Result<()> {
        let changed = {
            let mut s = self.node.state.writing();
            let changed = s.tags != tags;
            s.tags = tags;
            changed
        };
        if changed {
            self.node.push_record();
        }
        Ok(())
    }

    pub fn tags(&self) -> Vec<String> {
        self.node.state.reading().tags.clone()
    }

    /// The link as text, under the app's scheme.
    pub fn link_url(&self, link: &Link) -> String {
        link::format(link, &self.node.config.link_scheme)
    }

    /// A "my own device" link: one use, ten minutes, meeting at me.
    pub fn link_device(&self) -> Result<Link> {
        let link = self.node.make_link(link::Kind::Device, link::DEVICE_TTL_SECS);
        self.node.store.locked().add_pending(&link.secret, "m", link.expires)?;
        Ok(link)
    }

    /// This device becomes that person's: dials the link, waits for the person to confirm the
    /// code on their existing device, then takes the user key, the card, the book and the records.
    pub async fn link(&self, link: &Link, device_name: &str) -> Result<()> {
        if link.kind != link::Kind::Device {
            return Err(Error::Encoding);
        }
        if link.expired(now_ms() / 1000) {
            return Err(Error::Expired);
        }
        let addr = self.node.meet_addr_of(link);
        let conn = self.node.join(addr, "link").await?;
        self.node.emit(Event::Reached(link.meet.device));
        let me = self.node.device.device_id();
        // A device that already has a person: its contacts follow it into the new one (its book
        // stays), and the old key, before it is given up, tells them so.
        let (old_user, old_contacts): (Secret, Vec<UserId>) = {
            let s = self.node.state.reading();
            (s.user.clone(), s.contacts.keys().copied().filter(|u| *u != link.user).collect())
        };
        let record = self.node.next_record();
        let reply = ask(&conn, &Msg::Link { secret: link.secret, device: me, name: device_name.to_owned(), kind: self.node.config.device_kind, record }).await?;
        conn.close(0u32.into(), b"done");
        match reply {
            Msg::LinkOk { user_secret, card, book, records } => {
                card.verify()?;
                if card.user() != link.user || !card.has_device(&me) {
                    return Err(Error::BadKey);
                }
                self.node.keychain.put(USER_KEY, &user_secret)?;
                {
                    let mut s = self.node.state.writing();
                    s.user = Secret::from_bytes(&user_secret);
                    s.card = card.clone();
                    let store = self.node.store.locked();
                    store.set_meta("card", &card.to_bytes())?;
                    for e in book {
                        if e.card.verify().is_ok() && e.card.user() == e.user {
                            store.put_card(&e.card)?;
                            store.put_contact(&e.user, &e.petname, e.verified, e.relay_only, e.met_at)?;
                            s.cards.insert(e.user, e.card);
                            s.contacts.insert(e.user, ContactMeta { petname: e.petname, verified: e.verified, relay_only: e.relay_only, met_at: e.met_at });
                        }
                    }
                    let now = now_ms();
                    for r in records {
                        if r.verify().is_ok() && s.records.put(r.clone(), FoundBy::Exchange, now).unwrap_or(false) {
                            store.put_record(&r, FoundBy::Exchange, now)?;
                        }
                    }
                }
                self.node.relays_changed();
                self.node.recompute_allow();
                self.node.emit(Event::MeChanged);
                self.node.emit(Event::ContactsChanged);
                self.node.push_record();
                if old_user.user_id() != link.user && !old_contacts.is_empty() {
                    self.node.issue_redirect(Redirect::sign(&old_user, link.user, now_ms()), old_contacts);
                }
                self.node.dial_known();
                Ok(())
            }
            Msg::No { reason } => Err(no_to_err(&reason)),
            _ => Err(Error::Encoding),
        }
    }

    pub fn confirm_link(&self, req: LinkReqId, accept: bool) -> Result<()> {
        let tx = self.node.state.writing().pending.get_mut(&req.0).and_then(|p| p.tx.take()).ok_or(Error::NotFound)?;
        tx.send(accept).map_err(|_| Error::NotFound)
    }

    pub fn link_code(&self, req: LinkReqId) -> Result<String> {
        let s = self.node.state.reading();
        let p = s.pending.get(&req.0).ok_or(Error::NotFound)?;
        Ok(link::code(&p.secret, &p.device, &self.node.device.device_id()))
    }

    /// Who is asking to become my device, for the confirmation screen.
    pub fn link_request(&self, req: LinkReqId) -> Result<DeviceId> {
        Ok(self.node.state.reading().pending.get(&req.0).ok_or(Error::NotFound)?.device)
    }

    /// What the asking device calls itself and what it is ("iPhone 17 Pro", iphone), so the
    /// confirmation screen can say "Your iPhone 17 Pro wants to join" rather than a hex prefix.
    pub fn link_request_device(&self, req: LinkReqId) -> Result<(String, DeviceKind)> {
        let s = self.node.state.reading();
        let p = s.pending.get(&req.0).ok_or(Error::NotFound)?;
        Ok((p.name.clone(), p.kind))
    }

    /// The joining side's code for a device link, to show while `link` waits: the same six
    /// digits the existing device shows, from the link's secret, this device and the device met.
    pub fn joining_code(&self, link: &Link) -> String {
        link::code(&link.secret, &self.node.device.device_id(), &link.meet.device)
    }

    /// Transition only, for a Peer opened by `adopt`: sign with the user key so a migrated
    /// computer can keep re-signing old-format cards for friends on 0.4.x. Removed when 0.4.x is gone.
    pub fn sign_as_user(&self, bytes: &[u8]) -> Result<Sig> {
        if !self.node.adopted {
            return Err(Error::PolicyRefused(Class::Small, Path::Unreachable));
        }
        Ok(self.node.state.reading().user.sign(bytes))
    }

    /// One of my devices is no longer mine: the card says so, every cardholder refuses it on
    /// their next card, and this node drops it now. Cannot revoke the device you are on.
    pub fn revoke(&self, device: DeviceId) -> Result<()> {
        if device == self.node.device.device_id() {
            return Err(Error::PolicyRefused(Class::Small, Path::Unreachable));
        }
        let card = {
            let mut s = self.node.state.writing();
            if !s.card.has_device(&device) {
                return Err(Error::NotFound);
            }
            let mut body = s.card.next();
            body.revoked.push(crate::card::Revocation { id: device, at: now_ms() });
            s.card = Card::sign(body, &s.user);
            s.records.remove(&device);
            let removed = s.conns.remove(&device).map(|l| l.conn);
            s.app_conns.retain(|(d, _), _| *d != device);
            (s.card.clone(), removed)
        };
        let (card, removed) = card;
        self.node.store.locked().set_meta("card", &card.to_bytes())?;
        self.node.recompute_allow();
        // The removed device hears it first, so its app can say so and reset; then it is cut off.
        if let Some(conn) = removed {
            let card = card.clone();
            self.node.rt().spawn(async move {
                let _ = tokio::time::timeout(Duration::from_secs(2), ask(&conn, &Msg::Card(card))).await;
                conn.close(0u32.into(), b"revoked");
            });
        }
        self.node.push_card(card);
        self.node.emit(Event::MeChanged);
        Ok(())
    }

    /// Remove one of my devices from another (a lost phone, a sold Mac): `revoke` by its surface
    /// name. My card stops listing it, every connected mutual gets the card now and the rest on
    /// their next connection, and the device itself is told (`Event::Removed`) if it is online.
    pub fn remove_device(&self, device: DeviceId) -> Result<()> {
        self.revoke(device)
    }

    /// Forget this device: close (giving the gateway its mappings back and letting go of the
    /// store), then delete its keys from the keychain and everything in its directory. The Peer
    /// is unusable after; opening the directory again starts a new device. My other devices keep
    /// listing this one until one of them removes it (`remove_device`).
    pub async fn reset(&self) -> Result<()> {
        self.close().await;
        for item in [DEVICE_KEY, USER_KEY, STORE_KEY] {
            self.node.keychain.delete(item)?;
        }
        for entry in std::fs::read_dir(&self.node.dir).map_err(|e| Error::Store(e.to_string()))? {
            let p = entry.map_err(|e| Error::Store(e.to_string()))?.path();
            let r = if p.is_dir() { std::fs::remove_dir_all(&p) } else { std::fs::remove_file(&p) };
            r.map_err(|e| Error::Store(format!("{}: {e}", p.display())))?;
        }
        Ok(())
    }

    /// Identities merged: contacts of mine whose old key now points to a new one, and the one I
    /// issued when this device linked into another person.
    pub fn redirects(&self) -> Vec<Redirect> {
        let r = self.node.redirects.locked();
        r.known.iter().cloned().chain(r.issued.iter().map(|(x, _)| x.clone())).collect()
    }

    /// What the next `invite()` or `link_device()` will name as its meeting device, so the app can
    /// say who friends reach me through before it shows the link. Mint the link when it is shown:
    /// a better helper may have appeared since the last one.
    pub fn invite_meeting(&self) -> Meeting {
        let s = self.node.state.reading();
        self.node.meeting_in(&s).map(|h| h.meeting).unwrap_or(Meeting { kind: MeetingKind::None, device: None, device_name: String::new(), user: None, user_name: String::new() })
    }

    /// A friend link: one use, one hour, naming my best meeting device (`invite_meeting`).
    pub fn invite(&self) -> Result<Link> {
        let mut link = self.node.make_link(link::Kind::Friend, link::FRIEND_TTL_SECS);
        match self.node.hand_invite(&link) {
            Some(holder) => link.meet.device = holder,
            None => self.node.store.locked().add_pending(&link.secret, "f", link.expires)?,
        }
        Ok(link)
    }

    /// Redeem a friend link: dial the meeting device, swap cards and records, become contacts. A
    /// reply to a friend link of mine (`reply`) is taken too: I dial its maker while they dial me.
    pub async fn add(&self, link: &Link) -> Result<Contact> {
        if link.kind == link::Kind::Reply {
            return self.open_reply(link).await;
        }
        if link.kind != link::Kind::Friend {
            return Err(Error::Encoding);
        }
        if link.expired(now_ms() / 1000) {
            return Err(Error::Expired);
        }
        self.node.adding.locked().insert(link.secret);
        let _adding = Adding(&self.node, link.secret);
        let addr = self.node.meet_addr_of(link);
        let conn = self.node.join(addr.clone(), "add").await?;
        self.node.emit(Event::Reached(link.meet.device));
        let hello = self.node.hello_for(link.secret);
        let wait = answer_wait(self.node.path_of(&conn).1);
        let reply = match tokio::time::timeout(wait, ask(&conn, &hello)).await {
            Ok(Ok(r)) => r,
            _ => {
                // The join connection lost its path after its handshake (seen on a LAN whose far
                // host has two addresses on one subnet): once more, on a fresh connection. A
                // secret the far side did take answers `used`.
                conn.close(0u32.into(), b"retry");
                let again = self.node.join(addr, "add").await?;
                let r = tokio::time::timeout(HELLO_WAIT, ask(&again, &hello)).await.map_err(|_| Error::Unreachable)?;
                again.close(0u32.into(), b"done");
                r?
            }
        };
        conn.close(0u32.into(), b"done");
        let user = match self.node.welcomed(link, reply) {
            // Met meanwhile another way (a reply made from this link, opened): taken, by me.
            Err(Error::Used) if self.node.state.reading().contacts.contains_key(&link.user) => link.user,
            r => r?,
        };
        // A reply made while this add was trying is spent: opened later, it says so.
        self.node.reply_spent(&link::reply_secret(&link.secret), false);
        self.contacts().into_iter().find(|c| c.user == user).ok_or(Error::NotFound)
    }

    /// A reply to a friend link that cannot reach its maker from here (their network refuses
    /// strangers, and no friend's relay stands between us), for the person who sent it: to send
    /// back the way their link came, or show as a code. It names this device as an invite would
    /// (`invite_meeting`), and only a device of theirs that holds that invite accepts it (`add`).
    /// Until they open it, it lapses (`link::REPLY_TTL_SECS`, never past their link) or the add
    /// completes, this device dials theirs every `REPLY_REDIAL`, so both networks are open toward
    /// each other when they do: `Event::Replied` then, `Event::ReplyLapsed` if it runs out. Made
    /// while `add` of the link is still trying, which goes on; if that add completes, the reply is
    /// spent, and opening it gives them my contact as it is.
    pub fn reply(&self, link: &Link) -> Result<Link> {
        if link.kind != link::Kind::Friend {
            return Err(Error::Encoding);
        }
        let now = now_ms() / 1000;
        if link.expired(now) {
            return Err(Error::Expired);
        }
        if self.node.state.reading().contacts.contains_key(&link.user) {
            return Err(Error::Used);
        }
        let secret = link::reply_secret(&link.secret);
        let mut reply = self.node.make_link(link::Kind::Reply, (link.expires - now).min(link::REPLY_TTL_SECS));
        reply.secret = secret;
        reply.expires = reply.expires.min(link.expires);
        let waiting = self.node.replies.locked().insert(secret, Replying { theirs: link.clone(), until: reply.expires }).is_some();
        self.node.save_replies();
        self.node.trace.emit("reply", serde_json::json!({ "theirs": link.user.short(), "made": true, "addrs": reply.meet.addrs }));
        if !waiting {
            self.node.rt().spawn(self.node.clone().keep_replying(secret));
        }
        Ok(reply)
    }

    /// A reply to one of my friend links: its maker could not reach me. The device that holds the
    /// invite it answers (this one, or one of mine connected now) dials them while they dial me
    /// (`answer_reply`); their contact reaches this one with the book if another did. Someone
    /// already added (opened late, or twice): their contact, as it is.
    async fn open_reply(&self, reply: &Link) -> Result<Contact> {
        let contact = || self.contacts().into_iter().find(|c| c.user == reply.user);
        if let Some(c) = contact() {
            return Ok(c);
        }
        if reply.expired(now_ms() / 1000) {
            return Err(Error::Expired);
        }
        let spent = self.node.redeemed.locked().keys().any(|s| link::reply_secret(s) == reply.secret);
        match self.node.invite_for(&reply.secret) {
            Some(invite) => self.node.answer_reply(reply, invite).await?,
            None if spent => return Err(Error::Used),
            None => {
                if !self.node.forward_reply(reply).await {
                    return Err(Error::NotFound);
                }
                let end = Instant::now() + REPLY_WINDOW + Duration::from_secs(5);
                while contact().is_none() && Instant::now() < end {
                    tokio::time::sleep(Duration::from_millis(200)).await;
                }
            }
        }
        contact().ok_or(Error::Unreachable)
    }

    pub fn contacts(&self) -> Vec<Contact> {
        let via: HashMap<UserId, UserId> = self.node.redirects.locked().known.iter().map(|r| (r.to, r.from)).collect();
        let s = self.node.state.reading();
        let mut out: Vec<Contact> = s
            .contacts
            .iter()
            .map(|(user, m)| {
                let card = s.cards.get(user).cloned();
                let devices = card.iter().flat_map(|c| c.device_ids()).map(|d| self.node.status_of(&s, d, *user)).collect();
                Contact { user: *user, name: m.petname.clone(), card, verified: m.verified, relay_only: m.relay_only, met_at: m.met_at, devices, redirected_from: via.get(user).copied() }
            })
            .collect();
        out.extend(s.adopted.iter().map(|(user, a)| Contact {
            user: *user,
            name: a.petname.clone(),
            card: None,
            verified: false,
            relay_only: false,
            met_at: a.met_at,
            devices: a.devices.iter().map(|d| self.node.status_of(&s, d.id, *user)).collect(),
            redirected_from: None,
        }));
        out.sort_by(|a, b| a.name.cmp(&b.name));
        out
    }

    pub fn rename(&self, user: UserId, petname: &str) -> Result<()> {
        self.node.edit_contact(user, |m| m.petname = petname.to_owned())
    }

    /// Forget them as a contact and tell them. A co-member stays admitted with their card; only
    /// the contact status ends.
    pub fn remove(&self, user: UserId) -> Result<()> {
        let devices: Vec<DeviceId> = {
            let mut s = self.node.state.writing();
            s.contacts.remove(&user).ok_or(Error::NotFound)?;
            let store = self.node.store.locked();
            store.remove_contact(&user, now_ms())?;
            if s.members.values().any(|m| m.contains(&user)) {
                Vec::new()
            } else {
                let card = s.cards.remove(&user);
                let devices: Vec<DeviceId> = card.iter().flat_map(|c| c.device_ids()).collect();
                for d in &devices {
                    s.records.remove(d);
                }
                store.remove_card(&user)?;
                devices
            }
        };
        for d in devices {
            if let Some(conn) = self.node.live_conn(&d) {
                self.node.rt().spawn(async move {
                    let _ = tokio::time::timeout(Duration::from_secs(3), ask(&conn, &Msg::Removed)).await;
                    conn.close(0u32.into(), b"removed");
                });
            }
        }
        self.node.recompute_allow();
        self.node.emit(Event::ContactsChanged);
        self.node.push_book(Vec::new(), vec![(user, now_ms())]);
        Ok(())
    }

    /// Compare a safety number read in person; a match pins the key.
    pub fn verify(&self, user: UserId, fp: &str) -> Result<bool> {
        let ok = fingerprint(&user).replace(' ', "") == fp.replace(' ', "");
        if ok {
            self.node.edit_contact(user, |m| m.verified = true)?;
        }
        Ok(ok)
    }

    pub fn set_relay_only(&self, user: UserId, on: bool) -> Result<()> {
        self.node.edit_contact(user, |m| m.relay_only = on)?;
        // They hold my addresses until told otherwise: the stripped (or full) record goes now.
        self.node.push_record_checked(true);
        Ok(())
    }

    /// Migration: a friend from an old card. Their devices are admitted now, with
    /// `Identity.verified = false`, and their last-known addresses seed the cache as of `card_at`;
    /// the first new-format card from them replaces the placeholder if its user key matches.
    pub fn adopt_contact(&self, user: UserId, petname: &str, devices: Vec<AdoptedDevice>, card_at: u64) -> Result<Contact> {
        {
            let mut s = self.node.state.writing();
            for d in &devices {
                s.records.seed(d.id, d.addresses.clone(), card_at);
            }
            self.node.store.locked().put_adopted(&user, petname, card_at, &devices)?;
            s.adopted.insert(user, Adopted { petname: petname.to_owned(), devices, met_at: card_at });
        }
        self.node.recompute_allow();
        self.node.emit(Event::ContactsChanged);
        self.contacts().into_iter().find(|c| c.user == user).ok_or(Error::NotFound)
    }

    /// A co-member's card (from the group's membership event): their devices are admitted,
    /// carried for and exchanged with, without being a contact. The group is the namespace.
    /// Every connected member then receives the group's cards, so co-members learn each other
    /// without the app shipping cards.
    pub fn add_member(&self, group: GroupId, card: Card) -> Result<()> {
        card.verify()?;
        if self.node.take_member(group, card)? {
            self.node.recompute_allow();
            self.node.push_members(group);
            self.node.dial_known();
        }
        Ok(())
    }

    pub fn remove_member(&self, group: GroupId, user: UserId) -> Result<()> {
        {
            let mut s = self.node.state.writing();
            let Some(set) = s.members.get_mut(&group) else { return Err(Error::NotFound) };
            if !set.remove(&user) {
                return Err(Error::NotFound);
            }
            let still_known = s.contacts.contains_key(&user) || s.members.values().any(|m| m.contains(&user));
            let store = self.node.store.locked();
            store.remove_member(&group, &user)?;
            if !still_known {
                store.remove_card(&user)?;
                let devices: Vec<DeviceId> = s.cards.remove(&user).iter().flat_map(|c| c.device_ids()).collect();
                for d in devices {
                    s.records.remove(&d);
                    if let Some(l) = s.conns.remove(&d) {
                        l.conn.close(0u32.into(), b"left");
                    }
                }
            }
        }
        self.node.recompute_allow();
        Ok(())
    }

    pub fn members(&self, group: GroupId) -> Vec<Card> {
        let s = self.node.state.reading();
        s.members.get(&group).map(|m| m.iter().filter_map(|u| s.cards.get(u).cloned()).collect()).unwrap_or_default()
    }

    /// Make (or re-kind) a group before its first member, as the app's own group event says.
    /// A group's kind decides who in it is a mutual; see `GroupKind`.
    pub fn create_group(&self, group: GroupId, kind: GroupKind) -> Result<()> {
        {
            let mut s = self.node.state.writing();
            s.members.entry(group).or_default();
            s.kinds.insert(group, kind);
            let kinds: Vec<(GroupId, GroupKind)> = s.kinds.iter().map(|(g, k)| (*g, *k)).collect();
            self.node.store.locked().set_meta("group_kinds", &postcard::to_allocvec(&kinds).unwrap_or_default())?;
        }
        self.node.recompute_allow();
        self.node.push_members(group);
        self.node.dial_known();
        Ok(())
    }

    pub fn group_kind(&self, group: GroupId) -> Option<GroupKind> {
        let s = self.node.state.reading();
        s.members.contains_key(&group).then(|| s.kinds.get(&group).copied().unwrap_or_default())
    }

    /// The members of a group as the app shows them: public name, petname for contacts, mutual or not.
    pub fn group_members(&self, group: GroupId) -> Vec<Member> {
        let s = self.node.state.reading();
        let mutual = self.node.mutual_users(&s);
        let mut out: Vec<Member> = s
            .members
            .get(&group)
            .into_iter()
            .flatten()
            .filter_map(|u| s.cards.get(u).map(|c| (u, c)))
            .map(|(u, c)| Member { user: *u, name: c.body.name.clone(), petname: s.contacts.get(u).map(|m| m.petname.clone()), contact: s.contacts.contains_key(u), mutual: mutual.contains(u), card: c.clone() })
            .collect();
        out.sort_by(|a, b| a.name.cmp(&b.name));
        out
    }

    pub fn groups(&self) -> Vec<GroupId> {
        self.node.state.reading().members.keys().copied().collect()
    }

    /// Dial a device by its cached record on the app's ALPN. One connection per (device, alpn)
    /// is cached and streams multiplex on it; a second `connect` returns it, with the class
    /// honoured only if policy allows the current path. A refused path fails before any stream
    /// opens, after `PathChanged` so the app can say why and retry when a direct path returns.
    pub async fn connect(&self, device: DeviceId, class: Class, alpn: &[u8]) -> Result<Conn> {
        if self.node.silent(&device) {
            return Err(Error::Unreachable);
        }
        let key = (device, alpn.to_vec());
        let cached = {
            let mut s = self.node.state.writing();
            match s.app_conns.get(&key) {
                Some(c) if c.close_reason().is_none() && c.paths().iter().next().is_some() => Some(c.clone()),
                // Closed, or open with no path left: its network went away and iroh keeps it,
                // waiting for another. It carries nothing, so it goes and a fresh one is dialed;
                // kept, it refused every send as "Waiting" while the crate's own connection had
                // long since come back (a laptop moved from home Wi-Fi onto a phone's hotspot).
                Some(c) => {
                    c.close(0u32.into(), b"no path");
                    s.app_conns.remove(&key);
                    None
                }
                None => None,
            }
        };
        let conn = match cached {
            Some(c) => c,
            None => {
                // An adopted placeholder (a 0.4.x friend) or a legacy own device speaks no
                // peer/1: dial it straight on the app ALPN at its seeded address. Everyone else:
                // the crate connection first, whose round trip proves we are in their book.
                if !self.node.speaks_app_only(&device) {
                    self.node.clone().dial(device).await?;
                }
                let addr = self.node.dial_addr_of(&device).ok_or(Error::NotFound)?;
                let addr = self.node.prefer_lan(self.node.expand_relays(addr));
                let (t, tried) = (Instant::now(), tried_of(&addr));
                let r = match class {
                    Class::Live => self.node.transport().connect_live(addr, alpn).await,
                    // Over the path the device's own connection holds, a few round trips: a
                    // message that cannot go this way goes to carriers now, not 20 s on. One that
                    // does not connect in that time found the path dead: the device is silent.
                    Class::Small => {
                        let rtt = self.node.live_conn(&device).and_then(|c| self.node.path_of(&c).1);
                        let r = self.node.transport().connect_within(addr, alpn, answer_wait(rtt)).await;
                        if matches!(r, Err(Error::Unreachable)) {
                            self.node.stalled(device);
                        }
                        r
                    }
                    Class::Bulk => self.node.transport().connect(addr, alpn).await,
                };
                let path = r.as_ref().ok().map(|c| self.node.path_label(c).0);
                self.node.trace.emit("connect", serde_json::json!({ "device": device.short(), "alpn": String::from_utf8_lossy(alpn), "ms": crate::trace::ms(t), "ok": r.is_ok(), "path": path, "tried": tried, "err": r.as_ref().err().map(|e| e.to_string()) }));
                let conn = r?;
                self.node.state.writing().app_conns.insert(key.clone(), conn.clone());
                conn
            }
        };
        let (path, rtt) = self.node.path_of(&conn);
        let far = self.node.user_of(&device);
        if !crate::policy::allows(class, &path, |d| self.node.owned_by_endpoints(d, far)) {
            self.node.emit(Event::PathChanged(device));
            if class == Class::Live {
                self.node.state.writing().app_conns.remove(&key);
                conn.close(0u32.into(), b"policy");
            }
            return Err(Error::PolicyRefused(class, path));
        }
        Ok(Conn { inner: conn, identity: self.node.identity_of(device), class, path, rtt, node: Arc::downgrade(&self.node) })
    }

    /// Also how tests and the probe dial: a raw address on `peer/1`, proven admitted by a round
    /// trip, kept as the crate connection to that device, records exchanged.
    pub async fn connect_raw(&self, addr: EndpointAddr) -> Result<()> {
        let device = DeviceId::from(addr.id);
        self.node.clone().dial_addr(device, addr, "raw").await
    }

    /// After `Event::Inbound`. The accepted connection is also the cached one `connect` returns
    /// for that (device, alpn), so an app never dials back what it already holds.
    pub fn accept(&self, id: ConnId) -> Result<Conn> {
        let conn = self.node.state.writing().inbound.remove(&id.0).ok_or(Error::NotFound)?;
        let device = DeviceId::from(conn.remote_id());
        {
            let mut s = self.node.state.writing();
            let key = (device, conn.alpn().to_vec());
            if !s.app_conns.get(&key).is_some_and(|c| c.close_reason().is_none()) {
                s.app_conns.insert(key, conn.clone());
            }
        }
        let (path, rtt) = self.node.path_of(&conn);
        Ok(Conn { inner: conn, identity: self.node.identity_of(device), class: Class::Small, path, rtt, node: Arc::downgrade(&self.node) })
    }

    /// Hand `bytes` to a device: now if it is connected, else to every connected carrier that
    /// holds its card (own devices first), and to each new one until it is delivered or expires.
    /// Returns once the recipient or one carrier has it (bounded 1.5 s), else it is held here.
    pub async fn post(&self, to: DeviceId, bytes: Vec<u8>, ttl: Duration) -> Result<EnvelopeId> {
        if self.node.user_of(&to).is_none() {
            return Err(Error::NotFound);
        }
        let expires = now_ms() + (ttl.as_millis() as u64).min(crate::helper::ENVELOPE_TTL_MS);
        let env = Sealed::new(to, expires, crate::helper::seal(&to, expires, &bytes)?);
        let id = EnvelopeId(env.id);
        self.node.posted.locked().insert(env.id, Instant::now());
        {
            let mut s = self.node.state.writing();
            s.outbox.insert(env.id, env.clone());
            self.node.store.locked().put_envelope(&env, 1, &[], now_ms())?;
        }
        // The handoff goes on past the wait: a silent connection gives way to carriers after it.
        let handed = self.node.rt().spawn(self.node.hand_out(&env));
        let _ = tokio::time::timeout(Duration::from_millis(1500), handed).await;
        Ok(id)
    }

    pub fn inbox(&self) -> Vec<Envelope> {
        self.node.state.reading().inbox.clone()
    }

    /// Done with it: dropped from the inbox. Carriers already dropped their copies on arrival.
    pub fn ack(&self, id: EnvelopeId) -> Result<()> {
        let mut s = self.node.state.writing();
        let before = s.inbox.len();
        s.inbox.retain(|e| e.id != id);
        if s.inbox.len() == before {
            return Err(Error::NotFound);
        }
        self.node.store.locked().delete_envelope(&id.0)?;
        Ok(())
    }

    /// Envelopes posted by me and not yet delivered.
    pub fn outbox(&self) -> Vec<EnvelopeId> {
        let internal = self.node.redirects.locked().internal.clone();
        self.node.state.reading().outbox.keys().filter(|k| !internal.contains(*k)).map(|k| EnvelopeId(*k)).collect()
    }

    pub fn records(&self) -> Vec<RecordView> {
        self.node.state.reading().records.views(now_ms())
    }

    /// Online devices that hold a card for `device`: who could carry for it right now, so the
    /// app can say "carried by Jo's iPhone" before anything is delivered.
    pub fn helpers_for(&self, device: DeviceId) -> Vec<DeviceId> {
        let s = self.node.state.reading();
        self.node.carriers_for(&s, &device).into_iter().map(|(d, _)| d).collect()
    }

    /// Every device I hold a card for, with its honest path.
    pub fn peers(&self) -> Vec<PeerStatus> {
        let s = self.node.state.reading();
        let me = self.node.device.device_id();
        let mut out: Vec<PeerStatus> = self.node.mutual_devices(&s).into_iter().filter(|(d, _)| *d != me).map(|(d, u)| self.node.status_of(&s, d, u)).collect();
        out.sort_by(|a, b| a.device.0.cmp(&b.device.0));
        out
    }

    /// The crate connections themselves, own devices first: what the probe asks.
    pub fn crate_connections(&self) -> Vec<(DeviceId, Connection)> {
        let s = self.node.state.reading();
        let mut v: Vec<_> = s.conns.iter().filter(|(_, l)| l.conn.close_reason().is_none()).map(|(d, l)| (*d, l.conn.clone())).collect();
        v.sort_by_key(|(d, _)| !s.card.has_device(d));
        v
    }

    /// Every live crate connection, whoever it is to: the Network screen's raw truth.
    pub fn connections(&self) -> Vec<PeerStatus> {
        let s = self.node.state.reading();
        s.conns.keys().map(|d| self.node.status_of(&s, *d, self.node.user_of_in(&s, d).unwrap_or(UserId([0; 32])))).filter(|p| p.online).collect()
    }

    pub fn nearby(&self) -> Vec<DeviceId> {
        self.node.transport().nearby().into_iter().map(|(d, _)| d).collect()
    }

    pub fn helping(&self) -> Helping {
        let s = self.node.state.reading();
        let relay = self.node.relay.locked();
        Helping {
            envelopes: s.carrier.count() as u32,
            bytes: s.carrier.bytes(),
            budget_bytes: self.node.config.helper_budget_bytes,
            records_cached: s.records.len() as u32,
            relaying: relay.is_some(),
            relay_url: relay.as_ref().map(|r| r.urls.iter().map(|u| u.to_string()).collect::<Vec<_>>().join(" ")),
        }
    }

    /// Both halves, as the record advertises them.
    pub fn reachability(&self) -> Reachability {
        let s = self.node.state.reading();
        Reachability { udp: s.reachable.advertised(), tcp: s.tcp_reachable }
    }

    /// What the gateway last said when asked for a port mapping: none here, no internet side,
    /// refused, or mapped. Why a device that runs a relay is not offering it.
    pub fn gateway(&self) -> crate::portmap::Gateway {
        crate::portmap::gateway()
    }

    pub fn reachable(&self) -> Reachable {
        self.node.state.reading().reachable
    }

    /// Where the internet reaches this device while its router holds a port for it: the UDP
    /// mapping's external address, when that address is public (a router behind a carrier's
    /// second NAT maps onto a shared one nobody outside can dial). Any device that opens a port,
    /// a phone as much as a Mac, is reachable from anywhere while the node runs.
    pub fn mapped(&self) -> Option<std::net::SocketAddr> {
        let m = public_mapping(self.node.udp_map.locked().as_ref().and_then(|(_, m)| m.current()));
        m.filter(|m| self.node.state.reading().udp_refuted != Some(*m))
    }

    /// Re-run the probe now over the crate connections we hold, own devices first.
    pub async fn probe(&self) -> Reachable {
        self.node.probe().await
    }

    /// `awake` in my record, broadcast. True after false is a wake: every held connection is
    /// redialed (one may be dead with nobody the wiser) and every backoff starts over. The
    /// network loop itself runs from `open` to `close` either way.
    pub fn set_online(&self, online: bool) {
        let was = std::mem::replace(&mut self.node.state.writing().online, online);
        let woke = online && !was && self.node.went_online.swap(true, Ordering::SeqCst);
        if woke {
            *self.node.first.locked() = Some(("wake", Instant::now()));
        }
        self.node.push_record();
        if woke {
            self.node.wake();
        } else if online {
            self.node.dial_known();
        }
    }

    /// The platform says the network changed (iOS `NWPathMonitor`, Android's
    /// `ConnectivityManager`, a desktop's sleep/wake or interface events). The node also watches
    /// the OS itself; calling this costs nothing when it already knew: held connections are
    /// checked, dials begun on the old network start over, everyone not connected is dialed.
    pub fn network_changed(&self) {
        self.node.trace.emit("net", serde_json::json!({ "source": "app" }));
        self.node.network_changed(true);
    }

    /// For tests: a task panics holding the node's locks, as a bug in one would.
    #[doc(hidden)]
    pub async fn poison_locks(&self) {
        let node = self.node.clone();
        let _ = self
            .node
            .rt()
            .spawn(async move {
                let _held = (node.state.write(), node.inflight.lock(), node.net_at.lock(), node.udp_map.lock(), node.schedule.lock(), node.relay.lock(), node.listeners.lock(), node.store.lock());
                panic!("a bug, holding the node's locks");
            })
            .await;
    }

    pub fn subscribe(&self, l: Arc<dyn Listener>) {
        self.node.listeners.locked().push(l);
    }

    pub fn sign(&self, bytes: &[u8]) -> Sig {
        self.node.device.sign(bytes)
    }

    pub fn verify_sig(device: DeviceId, bytes: &[u8], sig: &Sig) -> bool {
        device.verify(bytes, sig).is_ok()
    }

    pub fn blobs(&self) -> &Blobs {
        self.node.blobs.get().expect("blobs set at start")
    }

    pub fn transport(&self) -> &Transport {
        self.node.transport()
    }

    /// The timing log, oldest first: one JSON line per milestone (see `peer::trace`).
    pub fn trace(&self) -> Vec<String> {
        self.node.trace.lines()
    }

    /// Hand every trace line to `sink` as it happens (`peer-node run --trace` prints them).
    pub fn set_trace_sink(&self, sink: Option<crate::trace::Sink>) {
        self.node.trace.set_sink(sink);
    }

    pub fn addr(&self) -> EndpointAddr {
        self.node.transport().addr()
    }

    /// Admit a device for tests until cards replicate.
    pub fn permit(&self, device: DeviceId) {
        self.node.transport().permit(device);
    }

    pub async fn close(&self) {
        if let Some(b) = self.node.blobs.get() {
            b.shutdown().await;
        }
        self.node.state.writing().online = false;
        self.node.closed.store(true, Ordering::SeqCst);
        self.node.kick.notify_one();
        let conns: Vec<Connection> = self.node.state.writing().conns.drain().map(|(_, l)| l.conn).collect();
        for c in conns {
            c.close(0u32.into(), b"bye");
        }
        let app: Vec<Connection> = self.node.state.writing().app_conns.drain().map(|(_, c)| c).collect();
        for c in app {
            c.close(0u32.into(), b"bye");
        }
        self.node.relay.locked().take();
        let server = self.node.relay_server.locked().take();
        if let Some(server) = server {
            let _ = server.shutdown().await;
        }
        // Stop answering first: a closing node that still accepts connections tells a friend who
        // redials it "online" for as long as the rest of the close takes. Then give the gateway
        // its entries back, so a node that restarts all day holds one each.
        let udp = self.node.udp_map.locked().take();
        let tcp = self.node.tcp_map.locked().take();
        let releases = async {
            if let Some((_, m)) = udp {
                m.release().await;
            }
        };
        let tcp_release = async {
            if let Some(m) = tcp {
                m.release().await;
            }
        };
        tokio::join!(self.node.transport().stop(), releases, tcp_release);
        // Last: what the closing connections had to write (when each was last seen) is written.
        self.node.store.locked().close();
    }
}

/// A mapping's external address, when the internet can dial it.
fn public_mapping(m: Option<std::net::SocketAddrV4>) -> Option<std::net::SocketAddr> {
    m.map(std::net::SocketAddr::V4).filter(|a| crate::record::is_global(&a.ip()))
}

/// The same address without its LAN addresses (private, link-local, unique-local), for an app
/// the LAN is refused to: a send to one fails at once with "no route to host", and a dial that
/// mixed them with a VPN address stalled for its whole timeout before the next one got through
/// over the VPN in 0.3 s (0.2.5, two Macs refused local network access, one tailnet).
fn without_lan(addr: EndpointAddr) -> EndpointAddr {
    let kept = addr.addrs.iter().filter(|t| !matches!(t, TransportAddr::Ip(sa) if !crate::record::is_global(&sa.ip()) && !crate::record::is_vpn(&sa.ip()) && !sa.ip().is_loopback())).cloned();
    EndpointAddr::from_parts(addr.id, kept)
}

/// On a network I am on (a /24 or /64 I have an address in, not over a VPN), or this host.
fn on_my_lan(ip: &std::net::IpAddr, mine: &[std::net::IpAddr]) -> bool {
    ip.is_loopback()
        || mine.iter().filter(|m| !crate::record::is_vpn(m)).any(|m| match (ip, m) {
            (std::net::IpAddr::V4(v), std::net::IpAddr::V4(mv)) => mv.octets()[..3] == v.octets()[..3],
            (std::net::IpAddr::V6(v), std::net::IpAddr::V6(mv)) => mv.segments()[..4] == v.segments()[..4],
            _ => false,
        })
}

/// A relay at a private address answers only on its own network. Named from anywhere else it
/// is worse than useless: iroh holds every relay's datagrams behind one still connecting, and a
/// laptop on a phone's hotspot waited ~24 s on the home Mac's LAN relay URLs before its public one.
/// Kept: public URLs and names, a private one on a network I am on, a VPN one while I am on it.
fn relay_reachable(url: &iroh::RelayUrl, mine: &[std::net::IpAddr]) -> bool {
    let Some(ip) = url.host_str().and_then(|h| h.trim_start_matches('[').trim_end_matches(']').parse::<std::net::IpAddr>().ok()) else { return true };
    if crate::record::is_vpn(&ip) {
        return mine.iter().any(crate::record::is_vpn);
    }
    crate::record::is_global(&ip) || on_my_lan(&ip, mine)
}

/// Every address a dial tries, for its trace line. The meet token stays out: it admits whoever
/// holds it until the link expires.
fn tried_of(addr: &EndpointAddr) -> Vec<String> {
    addr.addrs
        .iter()
        .map(|a| match a {
            TransportAddr::Ip(sa) => sa.to_string(),
            TransportAddr::Relay(u) => format!("relay={}", u.as_str().split('?').next().unwrap_or_default()),
            other => format!("{other:?}"),
        })
        .collect()
}

fn no_to_err(reason: &str) -> Error {
    match reason {
        "expired" => Error::Expired,
        "used" => Error::Used,
        "declined" => Error::NotInTheirBook,
        other => Error::Net(other.to_owned()),
    }
}

impl Node {
    fn transport(&self) -> &Arc<Transport> {
        self.transport.get().expect("transport set at start")
    }

    /// Every background task runs on the node's runtime, whatever thread the app called from.
    fn rt(&self) -> &tokio::runtime::Handle {
        &self.transport().rt
    }

    /// The helper's relay job: run the embedded relay (admitting cardholders and meet-token
    /// holders) on the port, and advertise it only while that port is reachable from outside: the
    /// person's word (`public`, `relay_url`), or a TCP mapping the gateway is confirmed to hold
    /// (v0.2.4). A mapping that lapses withdraws the relay from the record; one that comes back
    /// (the router recovers, a later renewal) offers it again. No fixed port: the endpoint's own,
    /// which the store keeps across restarts.
    async fn start_relay(self: &Arc<Self>) -> Result<()> {
        let port = self.config.port.or_else(|| self.transport().port()).ok_or(Error::Net("a relay needs a port".into()))?;
        let server = spawn_relay(port, CardholdersOnly { allow: self.allow.clone(), people: self.people.clone(), met: self.met.clone(), me: self.device.device_id(), trace: self.trace.clone() }).await?;
        *self.relay_server.locked() = Some(server);
        let lan: Vec<std::net::IpAddr> = self.transport().addr().ip_addrs().map(|a| a.ip()).filter(|ip| !crate::record::is_global(ip) && !crate::record::is_vpn(ip)).collect();
        if self.config.public || self.config.relay_url.is_some() {
            let public: Option<std::net::SocketAddr> = match &self.config.relay_url {
                Some(u) => u.parse::<iroh::RelayUrl>().ok().and_then(|u| u.host_str().and_then(|h| h.parse().ok()).map(|ip| std::net::SocketAddr::new(ip, u.port().unwrap_or(port)))),
                None => primary_ip().map(|ip| std::net::SocketAddr::new(ip, port)),
            };
            let mut urls = relay_urls(public, &lan, port)?;
            if let Some(u) = &self.config.relay_url {
                urls.insert(0, u.parse().map_err(|_| Error::Encoding)?);
            }
            self.offer_relay(Some(RelayRole { urls, mapped: None }));
            return Ok(());
        }
        if !self.config.portmap {
            tracing::warn!("relay on tcp {port} not offered: no mapping (portmap off) and not public");
            return Ok(());
        }
        self.map_tcp();
        Ok(())
    }

    /// The relay's TCP port, mapped on the gateway on the external port it had last time; the
    /// relay is offered while the mapping holds and withdrawn when it lapses. Asked again by
    /// `remap` while it holds nothing. A newer call's mapping replaces an older one's, whose
    /// watcher then stands down rather than withdraw what the newer one offered.
    fn map_tcp(self: &Arc<Self>) {
        let Some(port) = self.config.port.or_else(|| self.transport().port()) else { return };
        let Some(std::net::IpAddr::V4(ip)) = primary_ip().filter(|ip| !crate::record::is_vpn(ip)) else { return };
        let preferred = self.store.locked().meta("tcp_ext_port").ok().flatten().and_then(|b| <[u8; 2]>::try_from(b.as_slice()).ok()).map(u16::from_le_bytes);
        let mapping = {
            let _rt = self.rt().enter();
            crate::portmap::Mapping::start(crate::portmap::Proto::Tcp, ip, port, preferred)
        };
        let mut rx = mapping.external.clone();
        let generation = self.tcp_gen.fetch_add(1, Ordering::SeqCst) + 1;
        let old = self.tcp_map.locked().replace(mapping);
        // A port the last network's router held says nothing about this one: the relay it opened
        // is withdrawn now, and offered again only once this network's router confirms a port. A
        // network with no gateway never answers, and the old offer stood for good, naming an
        // address this device had left (a laptop moved from home Wi-Fi onto a phone's hotspot).
        if old.is_some() && self.relay.locked().as_ref().is_some_and(|r| r.mapped.is_some()) {
            self.offer_relay(None);
        }
        let weak = Arc::downgrade(self);
        self.rt().spawn(async move {
            if let Some(m) = old {
                m.release().await;
            }
            let mut held: Option<std::net::SocketAddrV4> = None;
            loop {
                let now = *rx.borrow();
                if now != held {
                    let Some(node) = weak.upgrade() else { break };
                    if node.closed.load(Ordering::SeqCst) || node.tcp_gen.load(Ordering::SeqCst) != generation {
                        break;
                    }
                    match now {
                        Some(a) => {
                            let _ = node.store.locked().set_meta("tcp_ext_port", &a.port().to_le_bytes());
                            node.trace.emit("portmap", serde_json::json!({ "proto": "tcp", "external": a.to_string(), "reused": Some(a.port()) == preferred }));
                            let ext = std::net::SocketAddr::V4(a);
                            if node.state.reading().tcp_refuted != Some(ext) {
                                node.offer_relay(node.mapped_relay(ext));
                            }
                        }
                        None => node.offer_relay(None),
                    }
                    held = now;
                }
                if rx.changed().await.is_err() {
                    break;
                }
            }
        });
    }

    /// A mapping that holds nothing is asked for again: the gateway may have come back (Dexter's
    /// lost its WAN after an outage and answered every request "yes" while holding nothing, and
    /// a node that asked once at open never asked again, so a router restart left it unreachable
    /// until baud was relaunched). At most once a minute from the loop; at once on a network change.
    fn remap(self: &Arc<Self>, now: bool) {
        if !self.config.portmap || self.config.public {
            return;
        }
        {
            let mut last = self.last_remap.locked();
            if !now && last.is_some_and(|t| t.elapsed() < Duration::from_secs(60)) {
                return;
            }
            *last = Some(Instant::now());
        }
        let udp_held = self.udp_map.locked().as_ref().and_then(|(_, m)| m.current()).is_some();
        if !udp_held {
            self.map_udp();
        }
        let relaying = self.relay_server.locked().is_some();
        let tcp_held = self.tcp_map.locked().as_ref().and_then(|m| m.current()).is_some();
        if relaying && self.config.relay_url.is_none() && !tcp_held {
            self.map_tcp();
        }
    }

    /// Advertise the relay (my record carries it, `reachable.tcp`, I am my own meeting device)
    /// or withdraw it.
    fn offer_relay(self: &Arc<Self>, role: Option<RelayRole>) {
        let urls: Vec<String> = role.iter().flat_map(|r| r.urls.iter().map(|u| u.to_string())).collect();
        if !urls.is_empty() {
            tracing::info!("relaying for cardholders at {urls:?}");
        }
        let on = role.is_some();
        *self.relay.locked() = role;
        self.state.writing().tcp_reachable = on;
        self.trace.emit("relay", serde_json::json!({ "offered": on, "urls": urls }));
        self.steer_home();
        self.push_record();
    }

    /// The endpoint's UDP port, mapped on the gateway for this node's life, on the external port it
    /// had last time; the mapped address goes into iroh's addresses (and so into my record).
    /// Confirm the port mappings now rather than at their next check.
    fn check_mappings(&self) {
        if let Some((_, m)) = self.udp_map.locked().as_ref() {
            m.check();
        }
        if let Some(m) = self.tcp_map.locked().as_ref() {
            m.check();
        }
    }

    fn map_udp(self: &Arc<Self>) {
        let Some(port) = self.transport().port() else { return };
        let Some(std::net::IpAddr::V4(ip)) = primary_ip().filter(|ip| !crate::record::is_vpn(ip)) else { return };
        let preferred = self.store.locked().meta("udp_ext_port").ok().flatten().and_then(|b| <[u8; 2]>::try_from(b.as_slice()).ok()).map(u16::from_le_bytes);
        let started = Instant::now();
        let mapping = {
            let _rt = self.rt().enter();
            crate::portmap::Mapping::start(crate::portmap::Proto::Udp, ip, port, preferred)
        };
        let mut rx = mapping.external.clone();
        let old = self.udp_map.locked().replace((ip, mapping));
        let weak = Arc::downgrade(self);
        self.rt().spawn(async move {
            if let Some((_, m)) = old {
                m.release().await;
            }
            let mut held: Option<std::net::SocketAddr> = None;
            loop {
                let now = (*rx.borrow()).map(std::net::SocketAddr::V4);
                if now != held {
                    let Some(node) = weak.upgrade() else { break };
                    let Some(ep) = node.transport().try_ep() else { break };
                    if let Some(h) = held {
                        ep.remove_external_addr(&h).await;
                    }
                    if let Some(a) = now {
                        if node.state.reading().udp_refuted != Some(a) {
                            ep.add_external_addr(a).await;
                        }
                        let _ = node.store.locked().set_meta("udp_ext_port", &a.port().to_le_bytes());
                        node.trace.emit("portmap", serde_json::json!({ "proto": "udp", "external": a.to_string(), "ms": crate::trace::ms(started), "reused": Some(a.port()) == preferred }));
                    }
                    held = now;
                }
                if rx.changed().await.is_err() {
                    break;
                }
            }
        });
    }

    /// Who runs the relay at `url`: me, or a cardholder whose record advertises it.
    fn relay_owner_in(&self, s: &State, url: &iroh::RelayUrl) -> Option<DeviceId> {
        if self.relay.locked().as_ref().is_some_and(|r| r.urls.contains(url)) {
            return Some(self.device.device_id());
        }
        s.records.signed().into_iter().find(|r| r.record.relay == Some(r.device()) && r.record.relay_urls().any(|u| u == url)).map(|r| r.device())
    }

    /// Once there are two direct peers, or on demand, with at least ten seconds between runs.
    fn maybe_probe(self: &Arc<Self>) {
        if self.config.public {
            return;
        }
        let due = self.last_probe.locked().is_none_or(|t| t.elapsed() > Duration::from_secs(10));
        if !due || self.probing.swap(true, Ordering::SeqCst) {
            return;
        }
        let node = self.clone();
        self.rt().spawn(async move {
            node.probe().await;
            node.probing.store(false, Ordering::SeqCst);
        });
    }

    /// The relay's TCP mapping, when the internet could dial it.
    fn relay_mapping(&self) -> Option<std::net::SocketAddr> {
        if self.config.public {
            return None;
        }
        public_mapping(self.tcp_map.locked().as_ref().and_then(|m| m.current()))
    }

    /// What the dial-backs said of my mappings (`probe::verdict`): one that answered nobody is
    /// withdrawn, one that answers again comes back.
    async fn believe(self: &Arc<Self>, udp: Option<std::net::SocketAddr>, udp_check: Option<bool>, tcp: Option<std::net::SocketAddr>, tcp_check: Option<bool>) {
        // A probe that outlived `close`: nothing left to withdraw from.
        let Some(ep) = self.transport().try_ep() else { return };
        if let (Some(a), Some(reached)) = (udp, udp_check) {
            let was = std::mem::replace(&mut self.state.writing().udp_refuted, (!reached).then_some(a));
            if was != Some(a) && !reached {
                ep.remove_external_addr(&a).await;
            } else if was == Some(a) && reached {
                ep.add_external_addr(a).await;
            }
            self.trace.emit("checked", serde_json::json!({ "proto": "udp", "external": a.to_string(), "reached": reached }));
        }
        if let (Some(a), Some(reached)) = (tcp, tcp_check) {
            let was = std::mem::replace(&mut self.state.writing().tcp_refuted, (!reached).then_some(a));
            let offered = self.relay.locked().as_ref().is_some_and(|r| r.mapped == Some(a));
            if !reached && offered {
                self.offer_relay(None);
            } else if reached && was == Some(a) && !offered {
                self.offer_relay(self.mapped_relay(a));
            }
            self.trace.emit("checked", serde_json::json!({ "proto": "tcp", "external": a.to_string(), "reached": reached }));
        }
    }

    /// The relay offered on the router's port `ext`: there first, then at my LAN addresses.
    fn mapped_relay(&self, ext: std::net::SocketAddr) -> Option<RelayRole> {
        let port = self.config.port.or_else(|| self.transport().port())?;
        let lan: Vec<std::net::IpAddr> = self.transport().addr().ip_addrs().map(|a| a.ip()).filter(|ip| !crate::record::is_global(ip) && !crate::record::is_vpn(ip)).collect();
        relay_urls(Some(ext), &lan, port).ok().map(|urls| RelayRole { urls, mapped: Some(ext) })
    }

    async fn probe(self: &Arc<Self>) -> Reachable {
        let conns: Vec<(DeviceId, Connection)> = {
            let s = self.state.reading();
            let mut v: Vec<_> = s.conns.iter().filter(|(_, l)| l.conn.close_reason().is_none()).map(|(d, l)| (*d, l.conn.clone())).collect();
            v.sort_by_key(|(d, _)| !s.card.has_device(d));
            v
        };
        let local: Vec<std::net::SocketAddr> = self.transport().addr().ip_addrs().copied().collect();
        let mapping = self.udp_map.locked().as_ref().and_then(|(_, m)| m.current()).map(std::net::SocketAddr::V4);
        let relay = self.relay_mapping();
        let doubted = self.state.reading().udp_refuted;
        // The hosts of the relays my connections ride, too: met through a friend's relay, a device
        // may hold no direct path to anyone, and without its public address no punch replaces
        // the relay (two home NATs, relayed for good).
        let hosts = self.relay_hosts(&conns).await;
        let asked: Vec<(DeviceId, Connection)> = conns.iter().chain(&hosts).cloned().collect();
        let outcome = probe::run(&asked, mapping, relay, doubted, &local).await;
        for (_, c) in &hosts {
            c.close(0u32.into(), b"bound");
        }
        *self.last_probe.locked() = Some(std::time::Instant::now());
        self.trace.emit("probe", serde_json::json!({ "hosts": hosts.len(), "seen": outcome.observations.iter().map(|o| o.observed.to_string()).collect::<Vec<_>>(), "reachable": format!("{:?}", outcome.reachable), "udp_check": outcome.udp_check, "tcp_check": outcome.tcp_check }));
        self.believe(mapping, outcome.udp_check, relay, outcome.tcp_check).await;
        if let Some(public) = outcome.public {
            if let Some(ep) = self.transport().try_ep() {
                ep.add_external_addr(public).await;
            }
        }
        let changed = {
            let mut s = self.state.writing();
            let changed = s.reachable != outcome.reachable;
            s.reachable = outcome.reachable;
            changed
        };
        if changed {
            self.emit(Event::ReachabilityChanged(outcome.reachable));
            self.push_record();
        }
        outcome.reachable
    }

    /// Rule 4, whoever noticed: the OS (an address came or went), iroh (its addresses moved), or
    /// the app (`Peer::network_changed`, from the platform's path monitor). `tell_iroh` when iroh
    /// did not notice itself.
    fn network_changed(self: &Arc<Self>, tell_iroh: bool) {
        *self.net_at.locked() = Some(Instant::now());
        self.emit(Event::NetworkChanged);
        if tell_iroh && let Some(ep) = self.transport().try_ep() {
            // It re-reads its interfaces and re-checks its paths now, not when it gets to it.
            self.rt().spawn(async move { ep.network_change().await });
        }
        if self.config.portmap && !self.config.public {
            let mapped_for = self.udp_map.locked().as_ref().map(|(ip, _)| std::net::IpAddr::V4(*ip));
            if mapped_for != primary_ip() {
                // A new address here: both mappings point at the old one.
                *self.last_remap.locked() = Some(Instant::now());
                self.map_udp();
                if self.relay_server.locked().is_some() && self.config.relay_url.is_none() {
                    self.map_tcp();
                }
            } else {
                self.remap(true);
            }
        }
        // A dial begun on the old network is retransmitting on a timer backed off to seconds.
        self.restart_stale_dials(STALE_DIAL);
        // Rule 4, then rule 2: broadcast, and dial everyone not connected now. A held
        // connection that cannot carry the broadcast is redialed (`push_record`).
        self.push_record_checked(true);
        self.dial_known();
    }

    /// The last address change, if it was recent enough that a reconnect is its consequence.
    fn net_recent(&self) -> Option<Instant> {
        self.net_at.locked().filter(|at| at.elapsed() < Duration::from_secs(30))
    }

    fn emit(&self, event: Event) {
        let listeners: Vec<Arc<dyn Listener>> = self.listeners.locked().clone();
        for l in listeners {
            l.on(event.clone());
        }
    }

    /// A link names the best meeting device (DESIGN.md, "baud, aggressively simple"): one of
    /// mine that runs a relay, else a friend's, each URL carrying my meet token so the helper
    /// admits the stranger who redeems it; the redeemer dials me through it, the relay coordinates
    /// the punch and carries the connection if the punch fails. No such device: my raw addresses.
    /// Either way the link reaches me (`meet.device`), who holds its secret.
    fn make_link(&self, kind: link::Kind, ttl: u64) -> Link {
        self.first_mapping_settled();
        let mapped = self.udp_map.locked().as_ref().and_then(|(_, m)| public_mapping(m.current()));
        let s = self.state.reading();
        let mapped = mapped.filter(|m| s.udp_refuted != Some(*m));
        let expires = now_ms() / 1000 + ttl;
        let addrs: Vec<String> = match self.meeting_in(&s) {
            Some(h) => {
                let token = link::meet_token(&self.device, &h.device, expires);
                h.urls.iter().map(|u| format!("relay={}", with_meet_token(u, &token))).collect()
            }
            None => {
                let addr = self.transport().addr();
                let mut addrs: Vec<String> = addr.relay_urls().map(|u| format!("relay={u}")).collect();
                // The router's port first: the endpoint may not have heard of it yet.
                addrs.extend(mapped.filter(|m| !addr.ip_addrs().any(|a| a == m)).map(|m| m.to_string()));
                addrs.extend(addr.ip_addrs().filter(|a| self.config.vpn || !crate::record::is_vpn(&a.ip())).map(|a| a.to_string()));
                addrs
            }
        };
        Link { kind, name: s.card.body.name.clone(), user: s.user.user_id(), expires, meet: Meet { device: self.device.device_id(), addrs }, secret: rand::random() }
    }

    /// A friend invite minted here whose meeting device is another of my own (a phone's Mac): that
    /// device holds it and the link names it, so the link is answered while this one sleeps (iOS
    /// suspends a phone's app) and the friend reaches this one through the book. Only one of mine
    /// that I hold a live connection to, and only once it says it holds the invite; else None,
    /// and the link names this device. Waits a few round trips for that answer, never on a
    /// single-threaded runtime, which the wait would stop from answering.
    fn hand_invite(&self, link: &Link) -> Option<DeviceId> {
        if matches!(tokio::runtime::Handle::try_current().map(|h| h.runtime_flavor()), Ok(tokio::runtime::RuntimeFlavor::CurrentThread)) {
            return None;
        }
        let (holder, conn) = {
            let s = self.state.reading();
            let h = self.meeting_in(&s).filter(|h| h.meeting.kind == MeetingKind::Own && h.device != self.device.device_id())?;
            let conn = s.conns.get(&h.device).filter(|l| l.conn.close_reason().is_none())?.conn.clone();
            (h.device, conn)
        };
        let wait = answer_wait(self.path_of(&conn).1);
        let msg = Msg::Invite { secret: link.secret, expires: link.expires };
        let (tx, rx) = std::sync::mpsc::channel();
        self.rt().spawn(async move {
            let _ = tx.send(matches!(tokio::time::timeout(wait, ask(&conn, &msg)).await, Ok(Ok(Msg::Ok))));
        });
        rx.recv_timeout(wait + Duration::from_millis(100)).ok().filter(|held| *held).map(|_| holder)
    }

    /// An invite another of my devices minted, whose link names me (`hand_invite`).
    fn on_invite(&self, from: DeviceId, secret: [u8; 32], expires: u64) -> Msg {
        if !self.state.reading().card.has_device(&from) {
            return Msg::No { reason: "not mine".into() };
        }
        match self.store.locked().add_pending(&secret, "f", expires) {
            Ok(()) => Msg::Ok,
            Err(_) => Msg::No { reason: "store".into() },
        }
    }

    /// My card and record for a link's secret: redeeming it (`add`), or a reply (`answer_reply`).
    fn hello_for(&self, secret: [u8; 32]) -> Msg {
        let s = self.state.reading();
        Msg::Hello { secret, card: s.card.clone(), record: self.my_record_in(&s) }
    }

    /// A Hello answered: theirs becomes a contact under the name the link gave.
    fn welcomed(self: &Arc<Self>, link: &Link, answer: Msg) -> Result<UserId> {
        match answer {
            Msg::HelloOk { card, record } => {
                card.verify()?;
                if card.user() != link.user {
                    return Err(Error::BadKey);
                }
                let user = card.user();
                self.accept_contact(card, &link.name, record, FoundBy::Invite)?;
                self.dial_known();
                Ok(user)
            }
            Msg::No { reason } => Err(no_to_err(&reason)),
            _ => Err(Error::Encoding),
        }
    }

    /// Replies waiting, to the store, so a relaunch keeps waiting.
    fn save_replies(&self) {
        let all: Vec<Replying> = self.replies.locked().values().cloned().collect();
        if let Ok(bytes) = postcard::to_stdvec(&all) {
            let _ = self.store.locked().set_meta("replies", &bytes);
        }
    }

    /// A reply this device made is spent: the link's maker is a contact. Their Hello with it
    /// again (late, on a second connection) is answered as a redeemed link's. `Event::Replied`
    /// when the reply is what met them, not an `add` that got through on its own.
    fn reply_spent(&self, secret: &[u8; 32], replied: bool) {
        let Some(r) = self.replies.locked().remove(secret) else { return };
        self.redeemed.locked().insert(*secret, r.theirs.user);
        self.save_replies();
        self.trace.emit("reply", serde_json::json!({ "theirs": r.theirs.user.short(), "spent": true, "replied": replied }));
        if replied {
            self.emit(Event::Replied(r.theirs.user));
        }
    }

    fn reply_lapsed(&self, secret: &[u8; 32], tries: u32) {
        let Some(r) = self.replies.locked().remove(secret) else { return };
        self.save_replies();
        self.trace.emit("reply", serde_json::json!({ "theirs": r.theirs.user.short(), "lapsed": true, "tries": tries }));
        self.emit(Event::ReplyLapsed(r.theirs.user));
    }

    /// The waiting half of a reply this device made (`Peer::reply`): dial the link's device afresh
    /// every `REPLY_REDIAL`, so this side's NAT and firewall stay open toward it, until the reply
    /// is spent (its maker opened it, or `add` got through) or lapses. A dial that gets through
    /// redeems the link on it, as `add` would.
    async fn keep_replying(self: Arc<Self>, secret: [u8; 32]) {
        let mut tries = 0u32;
        loop {
            let Some(r) = self.replies.locked().get(&secret).cloned() else { return };
            if self.closed.load(Ordering::SeqCst) {
                return;
            }
            if now_ms() / 1000 >= r.until {
                return self.reply_lapsed(&secret, tries);
            }
            let t = Instant::now();
            if self.adding.locked().contains(&r.theirs.secret) {
                // `add` of the link is dialing the same addresses: it keeps this side open.
                tokio::time::sleep(REPLY_REDIAL).await;
                continue;
            }
            tries += 1;
            let addr = self.reachable_relays(self.meet_addr_of(&r.theirs));
            if let Ok(conn) = self.transport().connect_within(addr, JOIN_ALPN, REPLY_REDIAL).await {
                let wait = answer_wait(self.path_of(&conn).1);
                let answer = tokio::time::timeout(wait, ask(&conn, &self.hello_for(r.theirs.secret))).await;
                conn.close(0u32.into(), b"done");
                match answer.map_err(|_| Error::Unreachable).and_then(|a| a).and_then(|a| self.welcomed(&r.theirs, a)) {
                    Ok(_) => return self.reply_spent(&secret, true),
                    Err(Error::Used | Error::Expired | Error::BadKey) => return self.reply_lapsed(&secret, tries),
                    Err(_) => {}
                }
            }
            tokio::time::sleep(REPLY_REDIAL.saturating_sub(t.elapsed())).await;
        }
    }

    /// The friend invite of mine a reply answers (`link::reply_secret`), if this device holds it.
    fn invite_for(&self, reply_secret: &[u8; 32]) -> Option<[u8; 32]> {
        let pending = self.store.locked().pending_of("f", now_ms() / 1000).ok()?;
        pending.into_iter().map(|(s, _)| s).find(|s| link::reply_secret(s) == *reply_secret)
    }

    /// Dial a reply's maker at its addresses for `REPLY_WINDOW`, afresh every `REPLY_REDIAL`,
    /// while they dial me at my link's: both networks open toward each other, and the first dial
    /// through completes the meeting. Mine redeems the reply (my card for theirs); theirs redeems
    /// my invite (`on_hello`). Either way the invite is spent after.
    async fn answer_reply(self: &Arc<Self>, reply: &Link, invite: [u8; 32]) -> Result<()> {
        let addr = self.reachable_relays(self.meet_addr_of(reply));
        let hello = self.hello_for(reply.secret);
        let met = || self.state.reading().contacts.contains_key(&reply.user);
        let (t0, end) = (Instant::now(), Instant::now() + REPLY_WINDOW);
        let (mut tries, mut err) = (0u32, Error::Unreachable);
        self.emit(Event::Dialing(reply.meet.device));
        while !met() && Instant::now() < end {
            let t = Instant::now();
            tries += 1;
            let mine = async {
                let conn = self.transport().connect_within(addr.clone(), JOIN_ALPN, REPLY_REDIAL).await?;
                let wait = answer_wait(self.path_of(&conn).1);
                let answer = tokio::time::timeout(wait, ask(&conn, &hello)).await.map_err(|_| Error::Unreachable);
                conn.close(0u32.into(), b"done");
                self.welcomed(reply, answer??)
            };
            let theirs = async {
                while !met() {
                    tokio::time::sleep(Duration::from_millis(100)).await;
                }
            };
            tokio::select! {
                r = mine => match r {
                    Ok(_) => break,
                    Err(e @ (Error::Used | Error::Expired | Error::BadKey)) => {
                        err = e;
                        break;
                    }
                    Err(e) => err = e,
                },
                () = theirs => break,
            }
            tokio::time::sleep(REPLY_REDIAL.saturating_sub(t.elapsed())).await;
        }
        let ok = met();
        self.trace.emit("reply", serde_json::json!({ "theirs": reply.user.short(), "opened": true, "ok": ok, "ms": crate::trace::ms(t0), "tries": tries }));
        if !ok {
            return Err(err);
        }
        let _ = self.store.locked().take_pending(&invite);
        self.redeemed.locked().insert(invite, reply.user);
        Ok(())
    }

    /// A reply opened on a device that does not hold the invite it answers: my devices connected
    /// now are asked, and the one that holds it dials (`on_reply`). True if one does.
    async fn forward_reply(&self, reply: &Link) -> bool {
        let conns: Vec<Connection> = {
            let s = self.state.reading();
            let me = self.device.device_id();
            s.conns.iter().filter(|(d, l)| **d != me && s.card.has_device(d) && l.conn.close_reason().is_none()).map(|(_, l)| l.conn.clone()).collect()
        };
        let msg = Msg::Reply(reply.clone());
        for conn in conns {
            let wait = answer_wait(self.path_of(&conn).1);
            if matches!(tokio::time::timeout(wait, ask(&conn, &msg)).await, Ok(Ok(Msg::Ok))) {
                return true;
            }
        }
        false
    }

    /// A reply another of my devices was handed, for an invite I hold (`forward_reply`): I dial.
    fn on_reply(self: &Arc<Self>, from: DeviceId, reply: Link) -> Msg {
        if !self.state.reading().card.has_device(&from) {
            return Msg::No { reason: "not mine".into() };
        }
        if reply.kind != link::Kind::Reply || reply.expired(now_ms() / 1000) {
            return Msg::No { reason: "expired".into() };
        }
        let Some(invite) = self.invite_for(&reply.secret) else {
            return Msg::No { reason: "not here".into() };
        };
        let node = self.clone();
        self.rt().spawn(async move {
            let _ = node.answer_reply(&reply, invite).await;
        });
        Msg::Ok
    }

    /// `invite` and `link_device` are synchronous: in the first seconds after a start they wait
    /// here, at most until the first mapping request has its answer (`portmap::FIRST` after it
    /// began), so an early link carries the router's port and not only addresses nobody outside
    /// can dial (the lab's NAT-PMP router answered 3 s after start; the invite left at 0.6 s).
    fn first_mapping_settled(&self) {
        while self.udp_map.locked().as_ref().is_some_and(|(_, m)| !m.settled()) {
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    /// The meeting device, by the directive's order: this device if it runs a relay; else a device
    /// whose record says it runs one: one I hold a live connection to before one I don't (a link
    /// is met only through a relay I am connected to), then mine before a contact's, then the
    /// freshest record.
    fn meeting_in(&self, s: &State) -> Option<MeetHelper> {
        let me = self.device.device_id();
        let my_name = s.card.body.name.clone();
        let name_in = |card: &Card, d: &DeviceId| card.body.devices.iter().find(|e| e.id == *d).map(|e| e.name.clone()).unwrap_or_default();
        if let Some(r) = self.relay.locked().as_ref() {
            let meeting = Meeting { kind: MeetingKind::Own, device: Some(me), device_name: name_in(&s.card, &me), user: Some(s.user.user_id()), user_name: my_name };
            return Some(MeetHelper { meeting, device: me, urls: r.urls.clone() });
        }
        let mut best: Option<((bool, u8, std::cmp::Reverse<u64>), MeetHelper)> = None;
        let own = std::iter::once((s.user.user_id(), &s.card, MeetingKind::Own, my_name.clone()));
        let friends = s.contacts.iter().filter_map(|(u, m)| s.cards.get(u).map(|c| (*u, c, MeetingKind::Friend, m.petname.clone())));
        for (user, card, kind, user_name) in own.chain(friends) {
            for d in card.device_ids().filter(|d| *d != me) {
                let Some(r) = s.records.get(&d) else { continue };
                let urls: Vec<iroh::RelayUrl> = r.record.relay_urls().cloned().collect();
                if r.record.relay != Some(d) || !r.record.reachable.tcp || urls.is_empty() {
                    continue;
                }
                let connected = s.conns.get(&d).is_some_and(|l| l.conn.close_reason().is_none());
                let rank = (!connected, if kind == MeetingKind::Own { 0 } else { 1 }, std::cmp::Reverse(r.record.at));
                if best.as_ref().is_none_or(|(b, _)| rank < *b) {
                    let meeting = Meeting { kind, device: Some(d), device_name: name_in(card, &d), user: Some(user), user_name: user_name.clone() };
                    best = Some((rank, MeetHelper { meeting, device: d, urls }));
                }
            }
        }
        best.map(|(_, h)| h)
    }

    /// iroh homes on the lowest-latency relay it knows, and a link only reaches me through a relay
    /// I am connected to: so the relays iroh may home on are the meeting device's alone. Others'
    /// relays are still dialed by URL when a record or link names them; they are just not home.
    fn steer_home(&self) {
        // Records load before the endpoint binds; `open` steers once it has.
        let Some(transport) = self.transport.get().cloned() else { return };
        let mine = self.my_ips();
        let want: Vec<iroh::RelayUrl> = {
            let s = self.state.reading();
            self.meeting_in(&s).map(|h| h.urls).unwrap_or_default().into_iter().filter(|u| relay_reachable(u, &mine)).collect()
        };
        {
            let mut cur = self.home_urls.locked();
            if *cur == want {
                return;
            }
            *cur = want.clone();
        }
        self.trace.emit("home", serde_json::json!({ "relays": want.iter().map(|u| u.to_string()).collect::<Vec<_>>() }));
        let rt = transport.rt.clone();
        rt.spawn(async move { transport.set_home_relays(want).await });
    }

    /// My current record, signed with the next seq.
    fn my_record_in(&self, s: &State) -> SignedRecord {
        let addr = self.transport().addr();
        let mut addresses: Vec<TransportAddr> = addr.ip_addrs().filter(|a| self.config.vpn || !crate::record::is_vpn(&a.ip())).map(|a| TransportAddr::Ip(*a)).collect();
        let own_relay: Vec<iroh::RelayUrl> = self.relay.locked().iter().flat_map(|r| r.urls.clone()).collect();
        addresses.extend(own_relay.iter().map(|u| TransportAddr::Relay(u.clone())));
        addresses.extend(addr.relay_urls().filter(|u| !own_relay.contains(u)).map(|u| TransportAddr::Relay(u.clone())));
        let relay = if own_relay.is_empty() { addr.relay_urls().next().and_then(|u| self.relay_owner_in(s, u)) } else { Some(self.device.device_id()) };
        let record = AddressRecord {
            device: self.device.device_id(),
            addresses,
            relay,
            reachable: Reachability { udp: s.reachable.advertised(), tcp: s.tcp_reachable },
            awake: s.online,
            tags: s.tags.clone(),
            seq: s.record_seq,
            at: now_ms(),
        };
        SignedRecord::sign(record, &self.device)
    }

    fn next_record(&self) -> SignedRecord {
        let mut s = self.state.writing();
        s.record_seq += 1;
        let _ = self.store.locked().set_meta("record_seq", &s.record_seq.to_le_bytes());
        self.my_record_in(&s)
    }

    /// Push on change: my new record to every connected cardholder, each as they may see it.
    fn push_record(self: &Arc<Self>) {
        self.push_record_checked(false);
    }

    /// `check`: after a network change the push is the liveness check of every held connection,
    /// so it goes out even when the record did not change.
    fn push_record_checked(self: &Arc<Self>, check: bool) {
        let content = {
            let s = self.state.reading();
            let r = self.my_record_in(&s).record;
            let mut addresses: Vec<String> = r.addresses.iter().map(|a| format!("{a:?}")).collect();
            addresses.sort();
            postcard::to_allocvec(&(addresses, r.relay, r.reachable, r.awake, r.tags)).unwrap_or_default()
        };
        {
            let mut last = self.last_pushed.locked();
            if !check && last.as_ref() == Some(&content) {
                return;
            }
            *last = Some(content);
        }
        let _ = self.next_record();
        let targets: Vec<(DeviceId, Connection, SignedRecord)> = {
            let s = self.state.reading();
            s.conns.iter().filter(|(_, l)| l.conn.close_reason().is_none()).map(|(d, l)| (*d, l.conn.clone(), self.my_record_for(&s, d))).collect()
        };
        let net_at = self.net_recent();
        for (device, conn, rec) in targets {
            let node = self.clone();
            self.rt().spawn(async move {
                let t = Instant::now();
                // After a network change the push doubles as the liveness check: a connection that
                // migrated answers within a few round trips; one that did not is redialed now.
                let wait = if net_at.is_some() { Duration::from_millis(1500) } else { Duration::from_secs(5) };
                let ok = matches!(tokio::time::timeout(wait, ask(&conn, &Msg::Records { records: vec![rec], hops: 0 })).await, Ok(Ok(_)));
                node.trace.emit("push", serde_json::json!({ "device": device.short(), "ms": crate::trace::ms(t), "ok": ok }));
                match (ok, net_at) {
                    (true, Some(at)) => node.trace.emit("migrated", serde_json::json!({ "device": device.short(), "ms": crate::trace::ms(at) })),
                    (false, Some(_)) => {
                        let _ = node.dial_now(device, true, "net").await;
                    }
                    _ => {}
                }
            });
        }
        self.emit(Event::RecordChanged(self.device.device_id()));
    }

    /// My new card to every connected device: own devices and contacts alike hold it.
    fn push_card(&self, card: Card) {
        for conn in self.live_conns() {
            let card = card.clone();
            self.rt().spawn(async move {
                let _ = tokio::time::timeout(Duration::from_secs(5), ask(&conn, &Msg::Card(card))).await;
            });
        }
    }

    fn live_conns(&self) -> Vec<Connection> {
        self.state.reading().conns.values().filter(|l| l.conn.close_reason().is_none()).map(|l| l.conn.clone()).collect()
    }

    fn live_conn(&self, device: &DeviceId) -> Option<Connection> {
        self.state.reading().conns.get(device).filter(|l| l.conn.close_reason().is_none()).map(|l| l.conn.clone())
    }

    /// Rule 1: the people whose devices are dialed, admitted and told records: me, my contacts,
    /// adopted contacts, and the members of every `Space` I am in. A `Chat` co-member is not one
    /// unless also a contact.
    fn mutual_users(&self, s: &State) -> HashSet<UserId> {
        let mut out: HashSet<UserId> = s.contacts.keys().copied().collect();
        out.insert(s.user.user_id());
        out.extend(s.adopted.keys().copied());
        for (g, m) in &s.members {
            if s.kinds.get(g).copied().unwrap_or_default() == GroupKind::Space {
                out.extend(m.iter().copied());
            }
        }
        out
    }

    /// The devices of my mutuals, with their person.
    fn mutual_devices(&self, s: &State) -> Vec<(DeviceId, UserId)> {
        let mutual = self.mutual_users(s);
        self.known_devices(s).into_iter().filter(|(_, u)| mutual.contains(u)).collect()
    }

    /// Every device I hold a card for, with its person: own, contacts, co-members, adopted. For
    /// names, identities and sealing; who is dialed and told records is `mutual_devices`.
    fn known_devices(&self, s: &State) -> Vec<(DeviceId, UserId)> {
        let mut out: Vec<(DeviceId, UserId)> = s.card.device_ids().map(|d| (d, s.user.user_id())).collect();
        for (u, c) in &s.cards {
            if s.contacts.contains_key(u) || s.members.values().any(|m| m.contains(u)) {
                out.extend(c.device_ids().map(|d| (d, *u)));
            }
        }
        for (u, a) in &s.adopted {
            out.extend(a.devices.iter().map(|d| (d.id, *u)));
        }
        out
    }

    /// Keep a member's card under a group. True when something changed.
    fn take_member(&self, group: GroupId, card: Card) -> Result<bool> {
        let user = card.user();
        let mut s = self.state.writing();
        let store = self.store.locked();
        let mut changed = false;
        if s.cards.get(&user).is_none_or(|cur| card.body.seq > cur.body.seq) {
            store.put_card(&card)?;
            s.cards.insert(user, card);
            changed = true;
        }
        if s.members.entry(group).or_default().insert(user) {
            store.put_member(&group, &user)?;
            changed = true;
        }
        Ok(changed)
    }

    /// Who, among my live connections, is a member of `group` (or my own device).
    fn member_conns(&self, s: &State, group: GroupId) -> Vec<Connection> {
        let Some(members) = s.members.get(&group) else { return Vec::new() };
        s.conns
            .iter()
            .filter(|(_, l)| l.conn.close_reason().is_none())
            .filter(|(d, _)| self.user_of_in(s, d).is_some_and(|u| members.contains(&u) || u == s.user.user_id()))
            .map(|(_, l)| l.conn.clone())
            .collect()
    }

    fn members_msg(&self, s: &State, group: GroupId) -> Option<Msg> {
        let members = s.members.get(&group)?;
        let mut cards: Vec<Card> = members.iter().filter_map(|u| s.cards.get(u).cloned()).collect();
        cards.push(s.card.clone());
        Some(Msg::Group { group, kind: s.kinds.get(&group).copied().unwrap_or_default() as u8, cards })
    }

    /// The group's cards to every connected member.
    fn push_members(&self, group: GroupId) {
        let (msg, conns) = {
            let s = self.state.reading();
            (self.members_msg(&s, group), self.member_conns(&s, group))
        };
        let Some(msg) = msg else { return };
        for conn in conns {
            let msg = msg.clone();
            self.rt().spawn(async move {
                let _ = tokio::time::timeout(Duration::from_secs(5), ask(&conn, &msg)).await;
            });
        }
    }

    /// On connect: every group we share, with its cards.
    fn send_groups_to(&self, device: DeviceId, conn: &Connection) {
        let msgs: Vec<Msg> = {
            let s = self.state.reading();
            let Some(user) = self.user_of_in(&s, &device) else { return };
            s.members.iter().filter(|(_, m)| m.contains(&user) || user == s.user.user_id()).filter_map(|(g, _)| self.members_msg(&s, *g)).collect()
        };
        for msg in msgs {
            let conn = conn.clone();
            self.rt().spawn(async move {
                let _ = tokio::time::timeout(Duration::from_secs(5), ask(&conn, &msg)).await;
            });
        }
    }

    /// A member sent the group's cards: take what is newer, if I am in that group.
    fn on_members(self: &Arc<Self>, from: DeviceId, group: GroupId, _kind: GroupKind, cards: Vec<Card>) -> Msg {
        let (mine, sender_in) = {
            let s = self.state.reading();
            let members = s.members.get(&group);
            let sender = self.user_of_in(&s, &from);
            (members.is_some(), members.is_some_and(|m| sender.is_some_and(|u| m.contains(&u) || u == s.user.user_id())))
        };
        if !mine || !sender_in {
            return Msg::No { reason: "not my group".into() };
        }
        let theirs: HashSet<UserId> = cards.iter().map(|c| c.user()).collect();
        let mut changed = false;
        for card in cards {
            if card.verify().is_ok() && card.user() != self.state.reading().user.user_id() {
                changed |= self.take_member(group, card).unwrap_or(false);
            }
        }
        if changed {
            self.recompute_allow();
            self.emit(Event::ContactsChanged);
            self.dial_known();
        }
        // Their list lacks members I hold: answer with mine. A list sent before its member kept
        // the group was refused and never sent again; this one reaches them the moment they do
        // (and add anyone), so a late member still learns the others.
        let (missing, msg) = {
            let s = self.state.reading();
            let sender = self.user_of_in(&s, &from);
            let mine = s.members.get(&group).into_iter().flatten().chain(std::iter::once(&s.user.user_id())).any(|u| !theirs.contains(u) && Some(*u) != sender);
            (mine, self.members_msg(&s, group))
        };
        if let (true, Some(msg), Some(conn)) = (missing, msg, self.live_conn(&from)) {
            self.rt().spawn(async move {
                let _ = tokio::time::timeout(Duration::from_secs(5), ask(&conn, &msg)).await;
            });
        }
        Msg::Ok
    }

    /// The allow-list is exactly the devices of every card I hold. A changed book also means
    /// a changed want-list, so every connected peer is told again (and gets records for it).
    fn recompute_allow(self: &Arc<Self>) {
        let devices = {
            let s = self.state.reading();
            self.mutual_devices(&s)
        };
        *self.people.writing() = devices.iter().map(|(d, u)| (EndpointId::from(*d), *u)).collect();
        self.transport().allow(devices.into_iter().map(|(d, _)| d));
        let live: Vec<(DeviceId, Connection)> = self.state.reading().conns.iter().filter(|(_, l)| l.conn.close_reason().is_none()).map(|(d, l)| (*d, l.conn.clone())).collect();
        for (device, conn) in live {
            let node = self.clone();
            self.rt().spawn(async move {
                let _ = node.exchange(device, &conn).await;
            });
        }
    }

    fn user_of_in(&self, s: &State, device: &DeviceId) -> Option<UserId> {
        self.known_devices(s).into_iter().find(|(d, _)| d == device).map(|(_, u)| u)
    }

    fn user_of(&self, device: &DeviceId) -> Option<UserId> {
        self.user_of_in(&self.state.reading(), device)
    }

    fn is_adopted(&self, device: &DeviceId) -> bool {
        self.state.reading().adopted.values().any(|a| a.devices.iter().any(|d| d.id == *device))
    }

    /// No `peer/1` yet on the far side: an adopted contact's device, or an own device still on 0.4.x.
    fn speaks_app_only(&self, device: &DeviceId) -> bool {
        self.is_adopted(device) || self.state.reading().legacy.contains(device)
    }

    /// It answered `peer/1`: no longer legacy.
    fn not_legacy(&self, device: &DeviceId) {
        let mut s = self.state.writing();
        if s.legacy.remove(device) {
            let _ = self.store.locked().set_meta("legacy", &postcard::to_allocvec(&s.legacy.iter().copied().collect::<Vec<_>>()).unwrap_or_default());
        }
    }

    /// Does `relay` belong to me or to the far endpoint's person? Policy for Live and Bulk.
    fn owned_by_endpoints(&self, relay: &DeviceId, far: Option<UserId>) -> bool {
        let s = self.state.reading();
        self.user_of_in(&s, relay).is_some_and(|u| u == s.user.user_id() || Some(u) == far)
    }

    fn identity_of(&self, device: DeviceId) -> Identity {
        let s = self.state.reading();
        let own = s.card.has_device(&device);
        let user = self.user_of_in(&s, &device);
        let pinned = own || user.is_some_and(|u| s.contacts.get(&u).is_some_and(|m| m.verified));
        let groups = match user {
            Some(u) if !own => s.members.iter().filter(|(_, m)| m.contains(&u)).map(|(g, _)| *g).collect(),
            _ => Vec::new(),
        };
        Identity { user: user.unwrap_or(UserId([0; 32])), device, pinned, own, groups }
    }

    fn path_of(&self, conn: &Connection) -> (Path, Option<u32>) {
        transport::path_of(conn, |url| {
            // Called with the state lock possibly held by the caller: records are read without it.
            let mine = self.relay.locked().as_ref().map(|r| r.urls.clone()).unwrap_or_default();
            relay_owner(url, &mine, self.device.device_id(), &self.relay_owners())
        })
    }

    /// A connection's path as a trace line says it. A relay whose owner I hold no record of (a
    /// friend's, met through their link) carrying us is not "unreachable": it is named by
    /// `relay_host`, else it is the meeting device. The UI's `Path` and the stream policy stay as
    /// they were.
    fn path_label(&self, conn: &Connection) -> (String, Option<u32>) {
        let (path, rtt) = self.path_of(conn);
        match transport::relayed_by(conn).filter(|_| path == Path::Unreachable) {
            Some(url) => match self.relay_host(&url) {
                Some(host) => (Path::Relay(host).to_string(), rtt),
                None => ("relayed by the meeting device".to_owned(), rtt),
            },
            None => (path.to_string(), rtt),
        }
    }

    /// Who runs the relay at `url`, its meet token aside (a path a link opened carries it): me, a
    /// device whose record offers it, else the one a device homed on it names (a friend's
    /// helper, met through their link, whose own record I do not hold).
    fn relay_host(&self, url: &iroh::RelayUrl) -> Option<DeviceId> {
        let mine = self.relay.locked().as_ref().map(|r| r.urls.clone()).unwrap_or_default();
        if let Some(host) = relay_owner(url, &mine, self.device.device_id(), &self.relay_owners()) {
            return Some(host);
        }
        let s = self.state.reading();
        s.records.signed().into_iter().find(|r| r.record.relay.is_some() && r.record.relay_urls().any(|u| bare_relay(u) == bare_relay(url))).and_then(|r| r.record.relay)
    }

    /// Connections on `transport::BIND_ALPN` to the hosts of the relays `conns` ride, but me and
    /// those among `conns`: each host answers the devices its relay admits.
    async fn relay_hosts(&self, conns: &[(DeviceId, Connection)]) -> Vec<(DeviceId, Connection)> {
        let me = self.device.device_id();
        let mut hosts: Vec<(DeviceId, iroh::RelayUrl)> = Vec::new();
        for url in conns.iter().filter_map(|(_, c)| transport::relayed_by(c)) {
            if let Some(host) = self.relay_host(&url).filter(|h| *h != me && !conns.iter().any(|(d, _)| d == h) && !hosts.iter().any(|(x, _)| x == h)) {
                hosts.push((host, url));
            }
        }
        let dials: Vec<_> = hosts
            .into_iter()
            .map(|(host, url)| {
                let transport = self.transport().clone();
                self.rt().spawn(async move { transport.bind_conn(EndpointAddr::new(host.into()).with_relay_url(url)).await.map(|c| (host, c)) })
            })
            .collect();
        let mut out = Vec::new();
        for d in dials {
            if let Ok(Some(hc)) = d.await {
                out.push(hc);
            }
        }
        out
    }

    /// Which helper runs each relay URL I know of. Its own small lock, so a path can be named
    /// while the state lock is held or wanted (a `try_read` that lost to a writer used to say
    /// "unreachable" for a perfectly good relayed connection).
    fn relay_owners(&self) -> HashMap<iroh::RelayUrl, DeviceId> {
        self.relay_owners.reading().clone()
    }

    /// Recompute `relay_owners` from the records, after any record arrives.
    fn relays_changed(&self) {
        let out: HashMap<iroh::RelayUrl, DeviceId> = {
            let s = self.state.reading();
            s.records.signed().into_iter().filter(|r| r.record.relay == Some(r.device())).flat_map(|r| r.record.relay_urls().map(|u| (u.clone(), r.device())).collect::<Vec<_>>()).collect()
        };
        *self.relay_owners.writing() = out;
        self.steer_home();
    }

    fn status_of(&self, s: &State, device: DeviceId, user: UserId) -> PeerStatus {
        let entry = std::iter::once(&s.card)
            .chain(s.cards.get(&user))
            .flat_map(|c| c.body.devices.iter())
            .find(|d| d.id == device)
            .map(|d| (d.name.clone(), d.kind))
            .or_else(|| s.adopted.get(&user).and_then(|a| a.devices.iter().find(|d| d.id == device)).map(|d| (d.name.clone(), DeviceKind::Node)))
            .unwrap_or_default();
        let (name, kind) = entry;
        let now = now_ms();
        let record = s.records.get(&device);
        let record_age_ms = record.map(|r| now.saturating_sub(r.received_at));
        let found_by = record.map(|r| r.found_by);
        match s.conns.get(&device).filter(|l| l.conn.close_reason().is_none()) {
            Some(l) => {
                let (path, rtt_ms) = self.path_of(&l.conn);
                PeerStatus { device, user, name, kind, online: true, path, rtt_ms, last_seen: Some(now), record_age_ms, found_by }
            }
            None => {
                let path = if record.is_some() { Path::Waiting } else { Path::Unreachable };
                PeerStatus { device, user, name, kind, online: false, path, rtt_ms: None, last_seen: s.last_seen.get(&device).copied(), record_age_ms, found_by }
            }
        }
    }

    fn edit_contact(self: &Arc<Self>, user: UserId, f: impl FnOnce(&mut ContactMeta)) -> Result<()> {
        {
            let mut s = self.state.writing();
            let m = s.contacts.get_mut(&user).ok_or(Error::NotFound)?;
            f(m);
            self.store.locked().put_contact(&user, &m.petname, m.verified, m.relay_only, m.met_at)?;
        }
        self.emit(Event::ContactsChanged);
        self.push_book(vec![user], Vec::new());
        Ok(())
    }

    /// A verified card and record from a redeemed invite, either side.
    fn accept_contact(self: &Arc<Self>, card: Card, petname: &str, record: SignedRecord, found_by: FoundBy) -> Result<()> {
        let user = card.user();
        // An old key that now points to a new one is not a person to add any more.
        if self.redirects.locked().successor(&user).is_some() {
            return Err(Error::BadKey);
        }
        let now = now_ms();
        {
            let mut s = self.state.writing();
            let store = self.store.locked();
            // A real card replaces an adopted placeholder; the petname the person chose stays.
            let petname = match s.adopted.remove(&user) {
                Some(a) => {
                    store.remove_adopted(&user)?;
                    a.petname
                }
                None => petname.to_owned(),
            };
            let petname = petname.as_str();
            store.put_card(&card)?;
            store.put_contact(&user, petname, false, false, now)?;
            s.cards.insert(user, card.clone());
            s.contacts.entry(user).or_insert(ContactMeta { petname: petname.to_owned(), verified: false, relay_only: false, met_at: now });
            if record.verify().is_ok() && card.has_device(&record.device()) && s.records.put(record.clone(), found_by, now).unwrap_or(false) {
                store.put_record(&record, found_by, now)?;
            }
        }
        self.relays_changed();
        self.recompute_allow();
        self.trace.emit("contact", serde_json::json!({ "user": user.short(), "via": found_by.as_str() }));
        self.emit(Event::ContactsChanged);
        self.push_book(vec![user], Vec::new());
        Ok(())
    }

    /// Records from a peer: keep those for devices I hold a card for, newer seq only.
    /// Returns the ones that were new, for forwarding.
    fn take_records(&self, records: Vec<SignedRecord>, found_by: FoundBy) -> Vec<SignedRecord> {
        let now = now_ms();
        let mut fresh = Vec::new();
        let mut s = self.state.writing();
        let known: HashSet<DeviceId> = self.mutual_devices(&s).into_iter().map(|(d, _)| d).collect();
        for r in records {
            if !known.contains(&r.device()) || r.device() == self.device.device_id() {
                continue;
            }
            if s.records.put(r.clone(), found_by, now).unwrap_or(false) {
                let _ = self.store.locked().put_record(&r, found_by, now);
                fresh.push(r);
            }
        }
        drop(s);
        if !fresh.is_empty() {
            self.relays_changed();
        }
        // A helper's relay URL changes with its mapping; a fresh record is the only way to learn it.
        for r in fresh.iter().filter(|r| r.record.relay == Some(r.device())) {
            r.record.relay_urls().for_each(|u| self.transport().note_relay(u.clone()));
        }
        for r in &fresh {
            self.trace.emit("record", serde_json::json!({ "device": r.device().short(), "seq": r.record.seq, "via": found_by.as_str() }));
            self.emit(Event::RecordChanged(r.device()));
            // Rule 5: a fresher record for a device not connected is a reason to dial it now.
            self.redial(r.device());
        }
        fresh
    }

    /// `want` for every device I hold a card for, under a fresh salt.
    fn want_list(&self, s: &State) -> (u64, Vec<[u8; 8]>) {
        let salt: u64 = rand::random();
        let want = self.mutual_devices(s).into_iter().map(|(d, _)| want_hash(salt, &d)).collect();
        (salt, want)
    }

    /// The signed records I hold that match a peer's want list, plus my own (as that peer may see it).
    fn records_for(&self, s: &State, peer: &DeviceId, salt: u64, want: &[[u8; 8]]) -> Vec<SignedRecord> {
        let want: HashSet<[u8; 8]> = want.iter().copied().collect();
        let mut out: Vec<SignedRecord> = s.records.signed().into_iter().filter(|r| want.contains(&want_hash(salt, &r.device()))).collect();
        out.push(self.my_record_for(s, peer));
        out
    }

    /// My record as `peer` may see it: a `relay_only` contact gets no direct addresses, only
    /// relays, so they never learn my IP. Same seq, same signature key, a different body.
    fn my_record_for(&self, s: &State, peer: &DeviceId) -> SignedRecord {
        let full = self.my_record_in(s);
        let relay_only = self.user_of_in(s, peer).and_then(|u| s.contacts.get(&u)).is_some_and(|m| m.relay_only);
        if relay_only { SignedRecord::sign(full.record.relay_only(), &self.device) } else { full }
    }

    fn peer_wants(&self, s: &State, peer: &DeviceId, device: &DeviceId) -> bool {
        s.conns.get(peer).and_then(|l| l.wants.as_ref()).is_some_and(|(salt, want)| want.contains(&want_hash(*salt, device)))
    }

    /// Forward fresh records to connected peers that hold the device's card, within hops.
    fn forward(&self, from: DeviceId, fresh: Vec<SignedRecord>, hops: u8) {
        let s = self.state.reading();
        let connected: Vec<DeviceId> = s.conns.iter().filter(|(_, l)| l.conn.close_reason().is_none()).map(|(d, _)| *d).collect();
        for r in fresh {
            let targets = finding::forward_to(&r, from, hops, &connected, |peer, device| self.peer_wants(&s, peer, device));
            for t in targets {
                let conn = s.conns[&t].conn.clone();
                let r = r.clone();
                self.rt().spawn(async move {
                    let _ = tokio::time::timeout(Duration::from_secs(5), ask(&conn, &Msg::Records { records: vec![r], hops: hops + 1 })).await;
                });
            }
        }
    }

    /// Who may carry for `to` right now: connected own devices first, then connected devices
    /// that told us they hold `to`'s card. Never the recipient itself.
    fn carriers_for(&self, s: &State, to: &DeviceId) -> Vec<(DeviceId, Connection)> {
        let mut v: Vec<(DeviceId, Connection)> = s
            .conns
            .iter()
            .filter(|(d, l)| **d != *to && l.conn.close_reason().is_none() && (s.card.has_device(d) || self.peer_wants(s, d, to)))
            .map(|(d, l)| (*d, l.conn.clone()))
            .collect();
        v.sort_by_key(|(d, _)| !s.card.has_device(d));
        v
    }

    /// Deliver an envelope to its recipient if connected, else copy it to every carrier.
    /// Resolves when the first of them has acknowledged it.
    fn hand_out(self: &Arc<Self>, env: &Sealed) -> impl std::future::Future<Output = bool> + Send + 'static {
        let silent = self.silent(&env.to);
        let (direct, mut carriers) = {
            let s = self.state.reading();
            let direct = s.conns.get(&env.to).filter(|l| !silent && l.conn.close_reason().is_none()).map(|l| l.conn.clone());
            (direct.clone(), if direct.is_some() { Vec::new() } else { self.carriers_for(&s, &env.to) })
        };
        self.trace.emit("handoff", serde_json::json!({ "id": crate::identity::hex_of(&env.id[..4]), "to": env.to.short(), "direct": direct.is_some(), "carriers": carriers.iter().map(|(d, _)| d.short()).collect::<Vec<_>>() }));
        let node = self.clone();
        let env = env.clone();
        async move {
            if let Some(mut conn) = direct {
                // Twice at most: a connection replaced while the envelope was on it (both sides
                // redialing after a restart) fails the ask, and the one held now takes it at once.
                for _ in 0..2 {
                    let wait = answer_wait(node.path_of(&conn).1);
                    if matches!(tokio::time::timeout(wait, ask(&conn, &Msg::Envelopes(vec![env.clone()]))).await, Ok(Ok(Msg::Ok))) {
                        node.delivered(&env.id, "direct");
                        return true;
                    }
                    match node.live_conn(&env.to) {
                        Some(now) if now.stable_id() != conn.stable_id() => conn = now,
                        _ => break,
                    }
                }
                // Held and silent: its path died without a word (a relay frozen, the far side
                // asleep or off its network). It is dialed afresh, and carriers take the envelope.
                node.stalled(env.to);
                carriers = {
                    let s = node.state.reading();
                    node.carriers_for(&s, &env.to)
                };
            }
            let (tx, mut rx) = tokio::sync::mpsc::channel::<bool>(8);
            let n = carriers.len();
            for (_, conn) in carriers {
                let (env, tx) = (env.clone(), tx.clone());
                node.rt().spawn(async move {
                    let ok = matches!(tokio::time::timeout(Duration::from_secs(5), ask(&conn, &Msg::Envelopes(vec![env]))).await, Ok(Ok(Msg::Ok)));
                    let _ = tx.send(ok).await;
                });
            }
            drop(tx);
            for _ in 0..n {
                if rx.recv().await == Some(true) {
                    return true;
                }
            }
            false
        }
    }

    /// A held connection to `device` left an ask unanswered: dial it afresh now, from its freshest
    /// record, and the new connection replaces the silent one if it forms.
    fn stalled(self: &Arc<Self>, device: DeviceId) {
        self.stalled.locked().insert(device, Instant::now());
        self.trace.emit("stalled", serde_json::json!({ "device": device.short() }));
        let node = self.clone();
        self.rt().spawn(async move {
            let _ = node.dial_now(device, true, "stalled").await;
        });
    }

    /// Its held connection went silent lately and no new one has formed (`stalled`).
    fn silent(&self, device: &DeviceId) -> bool {
        let mut stalled = self.stalled.locked();
        stalled.retain(|_, at| at.elapsed() < SILENT_HOLD);
        stalled.contains_key(device)
    }

    /// My envelope reached its recipient: forget it and say so.
    fn delivered(&self, id: &[u8; 32], via: &str) {
        let was_mine = self.state.writing().outbox.remove(id).is_some();
        if let Some(at) = self.posted.locked().remove(id) {
            self.trace.emit("post", serde_json::json!({ "ms": crate::trace::ms(at), "via": via }));
        }
        if was_mine {
            let _ = self.store.locked().delete_envelope(id);
            self.trace.emit("delivered", serde_json::json!({ "id": crate::identity::hex_of(&id[..4]), "via": via }));
            let internal = {
                let mut r = self.redirects.locked();
                let was = r.internal.remove(id);
                if was {
                    r.save(&self.store.locked());
                }
                was
            };
            if !internal {
                self.emit(Event::Delivered(EnvelopeId(*id)));
            }
        }
    }

    /// A new connection to `device`: deliver what is held for it, and, `onward`, hand on copies of
    /// what is held for devices it holds a card for (hops permitting).
    fn carry_to(self: &Arc<Self>, device: DeviceId, onward: bool) {
        let (conn, for_it, hand_on): (Connection, Vec<Sealed>, Vec<Sealed>) = {
            let s = self.state.reading();
            let Some(l) = s.conns.get(&device).filter(|l| l.conn.close_reason().is_none()) else { return };
            let mut for_it: Vec<Sealed> = s.carrier.for_device(&device).into_iter().cloned().collect();
            for_it.extend(s.outbox.values().filter(|e| e.to == device).cloned());
            let mut hand_on: Vec<Sealed> = Vec::new();
            if onward {
                hand_on.extend(s.carrier.all().into_iter().filter(|e| e.to != device && e.hops < MAX_HOPS && self.peer_wants(&s, &device, &e.to)).cloned());
                hand_on.extend(s.outbox.values().filter(|e| e.to != device && (s.card.has_device(&device) || self.peer_wants(&s, &device, &e.to))).cloned());
            }
            (l.conn.clone(), for_it, hand_on)
        };
        if for_it.is_empty() && hand_on.is_empty() {
            return;
        }
        let node = self.clone();
        self.rt().spawn(async move {
            if !for_it.is_empty()
                && matches!(tokio::time::timeout(Duration::from_secs(10), ask(&conn, &Msg::Envelopes(for_it.clone()))).await, Ok(Ok(Msg::Ok)))
            {
                for e in &for_it {
                    node.drop_held(&e.id);
                    node.delivered(&e.id, "carry");
                }
            }
            if !hand_on.is_empty() {
                let _ = tokio::time::timeout(Duration::from_secs(10), ask(&conn, &Msg::Envelopes(hand_on))).await;
            }
        });
    }

    fn drop_held(&self, id: &[u8; 32]) {
        if self.state.writing().carrier.ack(id) {
            let _ = self.store.locked().delete_envelope(id);
        }
    }

    /// An ack reached me: drop my copy, forget my outbox entry, pass it on once.
    fn on_acks(self: &Arc<Self>, from: DeviceId, ids: Vec<[u8; 32]>) {
        let fresh: Vec<[u8; 32]> = {
            let mut s = self.state.writing();
            ids.into_iter().filter(|id| s.acked.insert(*id)).collect()
        };
        for id in &fresh {
            self.drop_held(id);
            self.delivered(id, "ack");
        }
        if fresh.is_empty() {
            return;
        }
        let targets: Vec<Connection> = self.state.reading().conns.iter().filter(|(d, l)| **d != from && l.conn.close_reason().is_none()).map(|(_, l)| l.conn.clone()).collect();
        for conn in targets {
            let fresh = fresh.clone();
            self.rt().spawn(async move {
                let _ = tokio::time::timeout(Duration::from_secs(5), ask(&conn, &Msg::Acks(fresh))).await;
            });
        }
    }

    /// Envelopes handed to me: mine go to the inbox (and an ack goes out), others are held.
    fn on_envelopes(self: &Arc<Self>, from: DeviceId, envs: Vec<Sealed>) -> Msg {
        let me = self.device.device_id();
        let now = now_ms();
        let mut arrived = Vec::new();
        let mut already = Vec::new();
        // The crate's own envelopes (a redirect for a device that was away): acked, applied, never
        // the app's inbox.
        let mut internal: Vec<(Redirect, Card)> = Vec::new();
        let mut internal_ids: HashSet<[u8; 32]> = HashSet::new();
        let mut held_for: HashSet<DeviceId> = HashSet::new();
        {
            let mut s = self.state.writing();
            let known: HashSet<DeviceId> = self.known_devices(&s).into_iter().map(|(d, _)| d).collect();
            for e in envs {
                if e.expires <= now {
                    continue;
                }
                if s.acked.contains(&e.id) {
                    already.push(e.id);
                    continue;
                }
                if e.to == me {
                    if s.inbox.iter().any(|x| x.id.0 == e.id) {
                        continue;
                    }
                    // Sealed to this device: a carrier's copy, or a forgery, opens to nothing.
                    let Ok(bytes) = crate::helper::open(&self.device, &e) else { continue };
                    if let Some(rest) = bytes.strip_prefix(REDIRECT_ENVELOPE) {
                        if let Ok(x) = postcard::from_bytes::<(Redirect, Card)>(rest) {
                            internal.push(x);
                        }
                        s.acked.insert(e.id);
                        internal_ids.insert(e.id);
                        arrived.push(e.id);
                        continue;
                    }
                    let direct = e.hops == 0;
                    let env = Envelope { id: EnvelopeId(e.id), from: direct.then_some(from), bytes, carried_by: if direct { Vec::new() } else { vec![from] }, received_at: now };
                    let _ = self.store.locked().put_envelope(&e, 2, &env.carried_by, now);
                    s.inbox.push(env);
                    s.acked.insert(e.id);
                    arrived.push(e.id);
                } else if s.outbox.contains_key(&e.id) {
                    // My own envelope handed back by a carrier: it is in my outbox already, and
                    // holding it as carried would overwrite that row in the store.
                    continue;
                } else if known.contains(&e.to) {
                    let hops = e.hops;
                    let res = s.carrier.hold(e.clone(), now);
                    let held = matches!(res, Ok(true));
                    self.trace.emit("held", serde_json::json!({ "id": crate::identity::hex_of(&e.id[..4]), "for": e.to.short(), "from": from.short(), "new": held, "err": res.err().map(|e| e.to_string()) }));
                    if held {
                        held_for.insert(e.to);
                        let mut stored = e.clone();
                        stored.hops = hops + 1;
                        let _ = self.store.locked().put_envelope(&stored, 0, &[], now);
                    }
                }
            }
        }
        for (redirect, card) in internal {
            if redirect.verify().is_ok() && card.verify().is_ok() && card.user() == redirect.to {
                self.apply_redirect(&redirect, card, false);
            }
        }
        for id in arrived.iter().filter(|id| !internal_ids.contains(*id)) {
            let carried = self.state.reading().inbox.iter().find(|e| e.id.0 == *id).map(|e| !e.carried_by.is_empty()).unwrap_or(false);
            self.trace.emit("inbox", serde_json::json!({ "id": crate::identity::hex_of(&id[..4]), "from": from.short(), "via": if carried { "carried" } else { "direct" } }));
            self.emit(Event::Inbox(EnvelopeId(*id)));
        }
        // A sender back from being away re-hands what it still holds: tell it what was delivered.
        if !already.is_empty()
            && let Some(conn) = self.live_conn(&from)
        {
            self.rt().spawn(async move {
                let _ = tokio::time::timeout(Duration::from_secs(5), ask(&conn, &Msg::Acks(already))).await;
            });
        }
        if !arrived.is_empty() {
            // Tell everyone connected (carriers among them) so copies are dropped; one hop onward.
            self.on_acks(me, arrived);
        }
        // Forward on sight: what was just held, to its recipient if that device is connected right
        // now, and to nobody else. Handing it on to the other carriers here made each forward to
        // all but its sender, and three carriers connected to each other passed the same envelopes
        // round without end (a mini, a MacBook and an iPhone, 2026-10-16: 15 GB). Carriers get
        // their copies once, when they connect (`exchange`).
        for d in held_for {
            if d != from {
                self.carry_to(d, false);
            }
        }
        Msg::Ok
    }

    /// Keep a crate connection to a device and say so; drop it and say so when it closes.
    ///
    /// A second connection to a device already held: one dialed from the same side means that
    /// side dialed again (it restarted, woke, or moved), so the newest wins. One from the other
    /// side is two devices dialing each other at once: both keep the one the lower device id
    /// dialed, so they agree, unless the one they would keep no longer answers a `Bind` (its far
    /// end is a process that is gone), and then the new one wins.
    fn attach(self: &Arc<Self>, device: DeviceId, conn: Connection) -> Attach {
        self.not_legacy(&device);
        let i_dial = self.device.device_id() < device;
        let preferred = |c: &Connection| matches!(c.side(), iroh::endpoint::Side::Client) == i_dial;
        // Decided and recorded under one lock: two connections finishing at once must not both
        // see "nothing held" and the second silently orphan the first.
        let check = {
            let mut s = self.state.writing();
            let held = s.conns.get(&device).filter(|l| l.conn.close_reason().is_none()).map(|l| l.conn.clone());
            match held {
                Some(old) if old.stable_id() == conn.stable_id() => return Attach::Kept,
                Some(old) if !(old.side() == conn.side() || preferred(&conn)) => old,
                held => {
                    let wants = s.conns.get(&device).and_then(|l| l.wants.clone());
                    s.conns.insert(device, Live { conn: conn.clone(), wants });
                    drop(s);
                    self.installed(device, conn, held);
                    return Attach::Kept;
                }
            }
        };
        let node = self.clone();
        self.rt().spawn(async move {
            let old = check;
            let rtt = node.path_of(&old).1.unwrap_or(100) as u64;
            let wait = Duration::from_millis((rtt * 4 + 200).min(1500));
            if matches!(tokio::time::timeout(wait, ask(&old, &Msg::Bind)).await, Ok(Ok(_))) {
                conn.close(0u32.into(), b"duplicate");
                return;
            }
            let replaced = {
                let mut s = node.state.writing();
                match s.conns.get(&device).filter(|l| l.conn.close_reason().is_none()) {
                    Some(l) if l.conn.stable_id() != old.stable_id() => None,
                    _ => {
                        let wants = s.conns.get(&device).and_then(|l| l.wants.clone());
                        s.conns.insert(device, Live { conn: conn.clone(), wants });
                        Some(old)
                    }
                }
            };
            let Some(old) = replaced else {
                conn.close(0u32.into(), b"duplicate");
                return;
            };
            node.trace.emit("stale", serde_json::json!({ "device": device.short(), "ms": wait.as_millis() as u64 }));
            let ours = matches!(conn.side(), iroh::endpoint::Side::Client);
            node.installed(device, conn.clone(), Some(old));
            if ours {
                let _ = node.exchange(device, &conn).await;
            }
        });
        Attach::Checking
    }

    /// What follows a connection becoming the held one: the old one closed, serving, the trace,
    /// the event, and the watch that says offline and redials when it closes.
    /// The app's connections to a device whose crate connection was replaced or closed went the
    /// same way (the far side relaunched, moved, or left): QUIC notices only at its idle timeout,
    /// and until then `connect` handed out a dead one whose streams went nowhere. baud's sync on
    /// reconnect was lost that way (0.2.5's journey across two Macs).
    fn drop_app_conns(&self, device: DeviceId, why: &[u8]) {
        let dead: Vec<Connection> = {
            let mut s = self.state.writing();
            let keys: Vec<(DeviceId, Vec<u8>)> = s.app_conns.keys().filter(|(d, _)| *d == device).cloned().collect();
            keys.into_iter().filter_map(|k| s.app_conns.remove(&k)).collect()
        };
        for c in dead {
            c.close(0u32.into(), why);
        }
    }

    /// `Event::PathMoved` while `conn` is the one held to `device`: its selected path's label,
    /// once it has held `PATH_SETTLE` (`moved`). Ends with the connection, or once replaced.
    fn watch_path(self: &Arc<Self>, device: DeviceId, conn: Connection) {
        let weak = Arc::downgrade(self);
        let mut said = self.path_of(&conn).0;
        self.rt().spawn(async move {
            let mut paths = conn.paths_stream();
            while paths.next().await.is_some() {
                tokio::time::sleep(PATH_SETTLE).await;
                let Some(node) = weak.upgrade() else { return };
                if node.state.reading().conns.get(&device).is_none_or(|l| l.conn.stable_id() != conn.stable_id()) {
                    return;
                }
                let now = node.path_of(&conn).0;
                if moved(&mut said, now) {
                    node.trace.emit("moved", serde_json::json!({ "device": device.short(), "path": node.path_label(&conn).0 }));
                    node.emit(Event::PathMoved(device));
                }
            }
        });
    }

    fn installed(self: &Arc<Self>, device: DeviceId, conn: Connection, old: Option<Connection>) {
        self.stalled.locked().remove(&device);
        if let Some(old) = &old {
            old.close(0u32.into(), b"replaced");
            self.drop_app_conns(device, b"replaced");
        }
        if matches!(conn.side(), iroh::endpoint::Side::Client) {
            self.transport().serve(conn.clone());
        }
        let (path, rtt) = self.path_label(&conn);
        if let Some(seen) = transport::observed(&conn) {
            self.saw(device, seen);
        }
        let side = if matches!(conn.side(), iroh::endpoint::Side::Client) { "out" } else { "in" };
        self.trace.emit("attach", serde_json::json!({ "device": device.short(), "side": side, "path": path, "rtt": rtt, "replaced": old.is_some() }));
        if let Some((kind, at)) = self.first.locked().take() {
            self.trace.emit(kind, serde_json::json!({ "ms": crate::trace::ms(at), "device": device.short(), "path": path }));
        }
        if let Some(at) = self.net_recent() {
            self.trace.emit("redialed", serde_json::json!({ "device": device.short(), "ms": crate::trace::ms(at) }));
        }
        self.emit(if old.is_some() { Event::PathChanged(device) } else { Event::Online(device) });
        // My card on every connection: one that changed while this device was away (a device
        // removed, a name changed) reaches it now. The far side keeps it only if it is newer.
        {
            let card = self.state.reading().card.clone();
            // A contact of my old identity that was away when this device linked into me hears
            // of it now (and once it answers, no more).
            let user = self.user_of(&device);
            let pending = user.map(|u| self.redirects_for(&u)).unwrap_or_default();
            let (node, conn) = (self.clone(), conn.clone());
            self.rt().spawn(async move {
                let _ = tokio::time::timeout(Duration::from_secs(5), ask(&conn, &Msg::Card(card.clone()))).await;
                for redirect in pending {
                    let msg = Msg::Redirect { redirect: redirect.clone(), card: card.clone() };
                    if let (Ok(Ok(Msg::Ok)), Some(u)) = (tokio::time::timeout(Duration::from_secs(5), ask(&conn, &msg)).await, user) {
                        node.redirect_reached(&redirect, u);
                    }
                }
            });
        }
        self.watch_path(device, conn.clone());
        let weak = Arc::downgrade(self);
        let born = Instant::now();
        self.rt().spawn(async move {
            let reason = conn.closed().await;
            let Some(node) = weak.upgrade() else { return };
            let gone = {
                let mut s = node.state.writing();
                match s.conns.get(&device) {
                    Some(l) if l.conn.stable_id() == conn.stable_id() => {
                        s.conns.remove(&device);
                        true
                    }
                    _ => false,
                }
            };
            if gone {
                let seen: Vec<(DeviceId, u64)> = {
                    let mut s = node.state.writing();
                    s.last_seen.insert(device, now_ms());
                    s.last_seen.iter().map(|(d, t)| (*d, *t)).collect()
                };
                let _ = node.store.locked().set_meta("last_seen", &postcard::to_allocvec(&seen).unwrap_or_default());
                node.trace.emit("detach", serde_json::json!({ "device": device.short(), "lived_ms": crate::trace::ms(born), "reason": reason.to_string() }));
                // Silence, not a goodbye: the router may have restarted and forgotten our ports.
                if matches!(reason, iroh::endpoint::ConnectionError::TimedOut) {
                    node.check_mappings();
                }
                node.drop_app_conns(device, b"gone");
                node.emit(Event::Offline(device));
                // Rule 2: the dial schedule resumes at once.
                node.redial(device);
            }
        });
    }

    /// The address a device's packets came from on a direct path: kept, so a dial after either
    /// side restarts can go back through the far NAT's mapping toward us (a symmetric-NAT
    /// laptop is reachable at exactly that address, from exactly our port, while it keeps dialing).
    fn saw(&self, device: DeviceId, addr: std::net::SocketAddr) {
        let changed = self.state.writing().seen.insert(device, addr) != Some(addr);
        if changed {
            let seen: Vec<(DeviceId, std::net::SocketAddr)> = self.state.reading().seen.iter().map(|(d, a)| (*d, *a)).collect();
            let _ = self.store.locked().set_meta("seen", &postcard::to_allocvec(&seen).unwrap_or_default());
        }
    }

    /// Exchange on connect: my own record and what we both hold cards for, both ways.
    async fn exchange(self: &Arc<Self>, device: DeviceId, conn: &Connection) -> Result<()> {
        let r = self.exchange_inner(device, conn).await;
        self.send_groups_to(device, conn);
        self.send_book_to(device, conn);
        self.carry_to(device, true);
        r
    }

    /// The book as my own devices hold it: these contacts (all when `users` is None), their
    /// cards, the records I hold for their devices, and the removals.
    fn book_msg(&self, users: Option<&[UserId]>, removed: Vec<(UserId, u64)>, fresh: bool) -> Msg {
        let s = self.state.reading();
        let entries: Vec<BookEntry> = s
            .contacts
            .iter()
            .filter(|(u, _)| users.is_none_or(|us| us.contains(u)))
            .filter_map(|(u, m)| s.cards.get(u).map(|c| BookEntry { user: *u, card: c.clone(), petname: m.petname.clone(), verified: m.verified, relay_only: m.relay_only, met_at: m.met_at }))
            .collect();
        let devices: HashSet<DeviceId> = entries.iter().flat_map(|e| e.card.device_ids()).collect();
        let records = s.records.signed().into_iter().filter(|r| devices.contains(&r.device())).collect();
        Msg::Book { entries, removed, records, fresh }
    }

    /// Rule 5 for the book: an edit goes to every connected own device at once.
    fn push_book(self: &Arc<Self>, users: Vec<UserId>, removed: Vec<(UserId, u64)>) {
        let own: Vec<Connection> = {
            let s = self.state.reading();
            let me = self.device.device_id();
            s.conns.iter().filter(|(d, l)| **d != me && s.card.has_device(d) && l.conn.close_reason().is_none()).map(|(_, l)| l.conn.clone()).collect()
        };
        if own.is_empty() || (users.is_empty() && removed.is_empty()) {
            return;
        }
        let msg = self.book_msg(Some(&users), removed, true);
        for conn in own {
            let msg = msg.clone();
            self.rt().spawn(async move {
                let _ = tokio::time::timeout(Duration::from_secs(5), ask(&conn, &msg)).await;
            });
        }
    }

    /// On connect with an own device: the whole book, so what was added while apart arrives.
    fn send_book_to(self: &Arc<Self>, device: DeviceId, conn: &Connection) {
        if device == self.device.device_id() || !self.state.reading().card.has_device(&device) {
            return;
        }
        let removed = self.store.locked().removed_contacts().unwrap_or_default();
        let msg = self.book_msg(None, removed, false);
        let conn = conn.clone();
        self.rt().spawn(async move {
            let _ = tokio::time::timeout(Duration::from_secs(10), ask(&conn, &msg)).await;
        });
    }

    /// A book from one of my own devices: contacts I lack are added (unless I removed them after
    /// they were met), newer cards taken, removals applied; then the new devices are dialed.
    fn on_book(self: &Arc<Self>, from: DeviceId, entries: Vec<BookEntry>, removed: Vec<(UserId, u64)>, records: Vec<SignedRecord>, fresh: bool) -> Msg {
        let me_user = {
            let s = self.state.reading();
            if !s.card.has_device(&from) || from == self.device.device_id() {
                return Msg::No { reason: "not my device".into() };
            }
            s.user.user_id()
        };
        let mut added = Vec::new();
        let mut changed = false;
        {
            let mut s = self.state.writing();
            let store = self.store.locked();
            let gone: HashMap<UserId, u64> = store.removed_contacts().unwrap_or_default().into_iter().collect();
            let redirected: HashSet<UserId> = self.redirects.locked().known.iter().map(|r| r.from).collect();
            for e in entries {
                if e.user == me_user || e.card.verify().is_err() || e.card.user() != e.user || redirected.contains(&e.user) {
                    continue;
                }
                if s.cards.get(&e.user).is_none_or(|c| e.card.body.seq > c.body.seq) {
                    let _ = store.put_card(&e.card);
                    s.cards.insert(e.user, e.card.clone());
                    changed = true;
                }
                match s.contacts.get_mut(&e.user) {
                    Some(m) => {
                        if fresh && (m.petname != e.petname || m.verified != e.verified || m.relay_only != e.relay_only) {
                            m.petname = e.petname.clone();
                            m.verified = e.verified;
                            m.relay_only = e.relay_only;
                            let _ = store.put_contact(&e.user, &m.petname, m.verified, m.relay_only, m.met_at);
                            changed = true;
                        }
                    }
                    None => {
                        if gone.get(&e.user).is_some_and(|at| *at >= e.met_at) {
                            continue;
                        }
                        let _ = store.put_contact(&e.user, &e.petname, e.verified, e.relay_only, e.met_at);
                        s.contacts.insert(e.user, ContactMeta { petname: e.petname, verified: e.verified, relay_only: e.relay_only, met_at: e.met_at });
                        added.push(e.user);
                        changed = true;
                    }
                }
            }
            for (user, at) in removed {
                if s.contacts.get(&user).is_some_and(|m| m.met_at <= at) {
                    s.contacts.remove(&user);
                    let _ = store.remove_contact(&user, at);
                    if !s.members.values().any(|m| m.contains(&user)) {
                        for d in s.cards.remove(&user).iter().flat_map(|c| c.device_ids()).collect::<Vec<_>>() {
                            s.records.remove(&d);
                            if let Some(l) = s.conns.remove(&d) {
                                l.conn.close(0u32.into(), b"removed");
                            }
                        }
                        let _ = store.remove_card(&user);
                    }
                    changed = true;
                }
            }
        }
        if changed {
            self.recompute_allow();
            for u in &added {
                self.trace.emit("contact", serde_json::json!({ "user": u.short(), "via": "book" }));
            }
            self.emit(Event::ContactsChanged);
        }
        self.take_records(records, FoundBy::Exchange);
        if !added.is_empty() {
            self.dial_known();
        }
        Msg::Ok
    }

    async fn exchange_inner(&self, device: DeviceId, conn: &Connection) -> Result<()> {
        let (salt, want, mine) = {
            let s = self.state.reading();
            let (salt, want) = self.want_list(&s);
            (salt, want, self.my_record_for(&s, &device))
        };
        let reply = tokio::time::timeout(Duration::from_secs(10), ask(conn, &Msg::Exchange { salt, want, records: vec![mine] })).await.map_err(|_| Error::Unreachable)??;
        if let Msg::Exchange { salt: their_salt, want: their_want, records } = reply {
            self.take_records(records, FoundBy::Exchange);
            let theirs = {
                let mut s = self.state.writing();
                if let Some(l) = s.conns.get_mut(&device) {
                    l.wants = Some((their_salt, their_want.iter().copied().collect()));
                }
                self.records_for(&s, &device, their_salt, &their_want)
            };
            let _ = tokio::time::timeout(Duration::from_secs(5), ask(conn, &Msg::Records { records: theirs, hops: MAX_HOPS })).await;
        }
        Ok(())
    }

    /// A crate connection to `device`, joining a dial already in flight. `force` dials even when
    /// a connection is held (a wake: the held one may be dead and nobody has noticed).
    async fn dial_now(self: Arc<Self>, device: DeviceId, force: bool, why: &'static str) -> Result<()> {
        let (tx, mut joined, restart) = {
            let mut inflight = self.inflight.locked();
            // A connection held answers an unforced dial at once, even while a forced one is out
            // (a redial of a silent path): `connect` must not wait on that dial's timeout.
            if !force && self.live_conn(&device).is_some() {
                return Ok(());
            }
            match inflight.get(&device) {
                Some(d) => (None, Some(d.rx.clone()), None),
                None => {
                    let (tx, rx) = tokio::sync::watch::channel(None);
                    let id = self.dial_ids.fetch_add(1, Ordering::Relaxed);
                    let restart = Arc::new(tokio::sync::Notify::new());
                    inflight.insert(device, InflightDial { rx, id, started: Instant::now(), restart: restart.clone() });
                    (Some(tx), None, Some((id, restart)))
                }
            }
        };
        if let Some(rx) = joined.as_mut() {
            return match rx.wait_for(|v| v.is_some()).await {
                Ok(v) => v.clone().unwrap_or(Err(Error::Unreachable)),
                Err(_) => Err(Error::Unreachable),
            };
        }
        let (id, restart) = restart.expect("a dial of our own");
        // Whoever began the dial may be cancelled (an app dropping its `connect`): the entry goes
        // with it either way, so the next dial starts afresh instead of joining a dead one.
        let _guard = Inflight { node: &self, device, id };
        // Nobody holds a connection to it here: ask the devices connected to me to introduce us.
        // It races this dial, and starts it over if it learns where the device is (`introduce`).
        // Not for a device whose own record says its app is closed (nothing there to dial back),
        // and a dial that answers an introduction never asks for one.
        let awake = self.state.reading().records.get(&device).is_none_or(|r| r.record.awake);
        if why != "punch" && awake && self.live_conn(&device).is_none() && self.intro.asked.allow(device) {
            self.intro.begin(device);
            self.rt().spawn(self.clone().introduce(device));
        }
        let addr = self.dial_addr_of(&device);
        let t = Instant::now();
        let r = tokio::select! {
            r = async {
                match addr {
                    Some(addr) => self.clone().dial_addr(device, addr, why).await,
                    None => Err(Error::NotFound),
                }
            } => r,
            // The network changed under this dial (`restart_stale_dials`): its handshake has been
            // retransmitting on a timer that backed off to seconds, toward a network that is gone.
            // Start over on the new one, or join whoever already did; our waiters get that result.
            _ = restart.notified() => {
                self.trace.emit("dial", serde_json::json!({ "device": device.short(), "ms": crate::trace::ms(t), "ok": false, "why": why, "err": "restarted: the network changed" }));
                Box::pin(self.clone().dial_now(device, force, why)).await
            }
        };
        if let Some(tx) = tx {
            let _ = tx.send(Some(r.clone()));
        }
        r
    }

    /// Dials begun before a network change and still in flight for longer than `older_than` are
    /// started over: their entries go now (so the next dial is fresh, not joined to them) and
    /// their leaders redial. A dial younger than that is retransmitting quickly enough already.
    fn restart_stale_dials(&self, older_than: Duration) {
        let now = Instant::now();
        self.inflight.locked().retain(|_, d| {
            if now.duration_since(d.started) < older_than {
                return true;
            }
            d.restart.notify_one();
            false
        });
    }

    /// One device's dial in flight starts over, as `restart_stale_dials` does for all: its waiters
    /// get the new dial's result. False when none was in flight.
    fn restart_dial(&self, device: DeviceId) -> bool {
        match self.inflight.locked().remove(&device) {
            Some(d) => {
                d.restart.notify_one();
                true
            }
            None => false,
        }
    }

    async fn dial(self: Arc<Self>, device: DeviceId) -> Result<()> {
        self.dial_now(device, false, "connect").await
    }

    /// The asker's half of an introduction (`introduce`): the devices connected to me, own first,
    /// are asked to introduce me to `device`. Each that can has already told it to dial me; where
    /// they see it is dialed beside its record, starting my dial over if that is news.
    /// Boxed, with its type declared: a dial asks for introductions, and an introduction may dial.
    fn introduce(self: Arc<Self>, device: DeviceId) -> BoxFuture<'static, ()> {
        Box::pin(async move {
            let asks: Vec<Connection> = {
                let s = self.state.reading();
                // Never toward a contact I keep relay-only: an introduction hands each side the other's address.
                if self.user_of_in(&s, &device).and_then(|u| s.contacts.get(&u)).is_some_and(|m| m.relay_only) {
                    drop(s);
                    self.introduced(device, &[]);
                    return;
                }
                let mutual = self.mutual_users(&s);
                let mut v: Vec<(bool, Connection)> = s
                    .conns
                    .iter()
                    .filter(|(d, l)| **d != device && l.conn.close_reason().is_none() && !s.legacy.contains(d) && self.user_of_in(&s, d).is_some_and(|u| mutual.contains(&u)))
                    .map(|(d, l)| (!s.card.has_device(d), l.conn.clone()))
                    .collect();
                v.sort_by_key(|(friend, _)| *friend);
                v.into_iter().take(introduce::INTRODUCERS).map(|(_, c)| c).collect()
            };
            if asks.is_empty() {
                self.introduced(device, &[]);
                return;
            }
            let t = Instant::now();
            let asked = asks.len();
            let (mut introduced, mut at) = (0, Vec::new());
            for attempt in 0..2 {
                if attempt > 0 {
                    tokio::time::sleep(introduce::ASK_AGAIN).await;
                    if self.live_conn(&device).is_some() {
                        break;
                    }
                }
                let salt: u64 = rand::random();
                let msg = Msg::Introduce { salt, want: want_hash(salt, &device) };
                let pending: Vec<_> = asks
                    .iter()
                    .map(|c| {
                        let (c, msg) = (c.clone(), msg.clone());
                        self.rt().spawn(async move { tokio::time::timeout(introduce::ANSWER_WAIT, ask(&c, &msg)).await })
                    })
                    .collect();
                for p in pending {
                    if let Ok(Ok(Ok(Msg::Introduced { at: a }))) = p.await {
                        introduced += 1;
                        at.extend(a.into_iter().filter(introduce::worth_passing));
                    }
                }
                if introduced > 0 {
                    break;
                }
            }
            self.trace.emit("introduce", serde_json::json!({ "device": device.short(), "asked": asked, "introduced": introduced, "at": at.len(), "ms": crate::trace::ms(t) }));
            self.introduced(device, &at);
        })
    }

    /// The introduction to `device` is over (`at`: where go-betweens see it): the dial gets its
    /// punch targets back, and starts over with them now, when the far side starts too.
    fn introduced(self: &Arc<Self>, device: DeviceId, at: &[std::net::SocketAddr]) {
        let held_back = self.intro.end(&device);
        let news = self.intro.hints.add(device, at);
        if self.live_conn(&device).is_some() || !(held_back || news) || self.restart_dial(device) {
            return;
        }
        let node = self.clone();
        self.rt().spawn(async move {
            let _ = node.dial_now(device, false, "introduced").await;
        });
    }

    /// The go-between's half: `from` asks to be introduced to the device `want` names. Only
    /// between two mutuals, both connected here; the far one is asked first, and its address goes
    /// to `from` only once it agrees (`on_punch`).
    async fn on_introduce(self: &Arc<Self>, from: DeviceId, salt: u64, want: [u8; 8]) -> Msg {
        let found = {
            let s = self.state.reading();
            let mutual = self.mutual_users(&s);
            let is_mutual = |d: &DeviceId| self.user_of_in(&s, d).is_some_and(|u| mutual.contains(&u));
            if !is_mutual(&from) {
                return Msg::No { reason: "not a mutual".into() };
            }
            s.conns
                .iter()
                .find(|(d, l)| **d != from && want_hash(salt, d) == want && l.conn.close_reason().is_none() && !s.legacy.contains(d) && is_mutual(d))
                .map(|(d, l)| (*d, l.conn.clone()))
        };
        let Some((to, to_conn)) = found else { return Msg::No { reason: "not connected to it".into() } };
        if !self.intro.forwarded.allow((from, to)) {
            return Msg::No { reason: "introduced a moment ago".into() };
        }
        let from_conn = self.live_conn(&from);
        let from_at: Vec<std::net::SocketAddr> = from_conn.as_ref().and_then(transport::observed).filter(introduce::worth_passing).into_iter().collect();
        let rtt = |c: &Connection| self.path_of(c).1.unwrap_or(0);
        let wait_ms = introduce::start_wait(from_conn.as_ref().map(rtt).unwrap_or(0), rtt(&to_conn));
        let agreed = matches!(tokio::time::timeout(introduce::ANSWER_WAIT, ask(&to_conn, &Msg::Punch { from, at: from_at, wait_ms })).await, Ok(Ok(Msg::Ok)));
        self.trace.emit("introducing", serde_json::json!({ "from": from.short(), "to": to.short(), "agreed": agreed }));
        if !agreed {
            return Msg::No { reason: "it keeps its address".into() };
        }
        Msg::Introduced { at: transport::observed(&to_conn).filter(introduce::worth_passing).into_iter().collect() }
    }

    /// The far device's half: through a go-between, `from` is dialing me and is seen at `at`.
    /// Dial it back after `wait_ms`, when the asker starts too, so each side's packets open its
    /// own NAT to the other. A mutual only, and never one I keep relay-only.
    fn on_punch(self: &Arc<Self>, via: DeviceId, from: DeviceId, at: Vec<std::net::SocketAddr>, wait_ms: u32) -> Msg {
        {
            let s = self.state.reading();
            let user = self.user_of_in(&s, &from);
            if from == self.device.device_id() || !user.is_some_and(|u| self.mutual_users(&s).contains(&u)) {
                return Msg::No { reason: "not a mutual".into() };
            }
            if user.and_then(|u| s.contacts.get(&u)).is_some_and(|m| m.relay_only) {
                return Msg::No { reason: "relay only".into() };
            }
        }
        if self.live_conn(&from).is_some() || !self.intro.answered.allow(from) {
            return Msg::Ok;
        }
        let at: Vec<std::net::SocketAddr> = at.into_iter().filter(introduce::worth_passing).collect();
        self.intro.hints.add(from, &at);
        // This is the coordinated moment: the dial back takes its punch targets.
        self.intro.end(&from);
        self.trace.emit("punch", serde_json::json!({ "from": from.short(), "via": via.short(), "at": at.len(), "wait_ms": wait_ms }));
        let node = self.clone();
        self.rt().spawn(async move {
            tokio::time::sleep(Duration::from_millis(wait_ms as u64)).await;
            if node.live_conn(&from).is_none() && !node.restart_dial(from) {
                let _ = node.dial_now(from, false, "punch").await;
            }
        });
        Msg::Ok
    }

    /// Where to dial a link: its meeting device at the link's relay URLs (each carrying the
    /// inviter's meet token, so the helper admits me) and any raw addresses it carries. Dialing
    /// connects to that relay first; iroh punches through it and keeps it if the punch fails.
    fn meet_addr_of(&self, link: &Link) -> EndpointAddr {
        let addr = meet_addr(&link.meet);
        for u in addr.relay_urls() {
            self.transport().note_relay(u.clone());
        }
        let addr = self.expand_relays(addr);
        if self.lan_refused(&addr) { without_lan(addr) } else { addr }
    }

    /// Where to dial a device: its record, the address we last saw it at, where a go-between sees
    /// it, and (rule 2) the relay of every connected own device that runs one.
    fn dial_addr_of(&self, device: &DeviceId) -> Option<EndpointAddr> {
        let s = self.state.reading();
        let mut addr = s.records.addr(device)?;
        // While an introduction to it is out, not where a punch will aim (its public IPv4
        // addresses: in its record, where I saw it, where a go-between sees it): an uncoordinated
        // packet there spoils the punch. Unless its record says they answer unasked (a mapping).
        let punching = self.intro.pending(device) && !s.records.get(device).is_some_and(|r| r.record.reachable.udp);
        if punching {
            addr = EndpointAddr::from_parts(addr.id, addr.addrs.iter().filter(|t| !matches!(t, TransportAddr::Ip(sa) if introduce::punch_target(sa))).cloned());
        }
        // A record with no IP addresses is relay-only toward me: its owner chose not to be dialed
        // directly, so the address I once saw it at is not dialed either.
        if let Some(seen) = s.seen.get(device)
            && addr.ip_addrs().next().is_some()
            && !addr.ip_addrs().any(|a| a == seen)
            && !(punching && introduce::punch_target(seen))
        {
            addr = addr.with_ip_addr(*seen);
        }
        // Once answered, where a go-between sees it, while fresh (`introduce`).
        if !punching {
            for a in self.intro.hints.fresh(device) {
                if !addr.ip_addrs().any(|x| *x == a) {
                    addr = addr.with_ip_addr(a);
                }
            }
        }
        for r in s.records.signed() {
            if r.record.relay == Some(r.device()) && s.card.has_device(&r.device()) && s.conns.get(&r.device()).is_some_and(|l| l.conn.close_reason().is_none()) {
                for u in r.record.relay_urls() {
                    if !addr.relay_urls().any(|x| x == u) {
                        addr = addr.with_relay_url(u.clone());
                    }
                }
            }
        }
        Some(addr)
    }

    /// A helper's relay has several URLs (public, LAN); a peer homed on one is reachable through
    /// any, since the server is one. Dial with all of them so a LAN device need not hairpin.
    fn expand_relays(&self, addr: EndpointAddr) -> EndpointAddr {
        let owners = self.relay_owners();
        let by_owner: HashMap<DeviceId, Vec<iroh::RelayUrl>> = {
            let s = self.state.reading();
            let mut m: HashMap<DeviceId, Vec<iroh::RelayUrl>> = HashMap::new();
            for r in s.records.signed() {
                if r.record.relay == Some(r.device()) {
                    m.entry(r.device()).or_default().extend(r.record.relay_urls().cloned());
                }
            }
            if let Some(role) = self.relay.locked().as_ref() {
                m.entry(self.device.device_id()).or_default().extend(role.urls.clone());
            }
            m
        };
        let extra: Vec<iroh::RelayUrl> = addr.relay_urls().filter_map(|u| owners.get(u)).flat_map(|d| by_owner.get(d).cloned().unwrap_or_default()).collect();
        let mut addr = addr;
        for u in extra {
            addr = addr.with_relay_url(u);
        }
        addr
    }

    /// macOS refuses this app local network access (Privacy & Security → Local Network): a
    /// multicast send fails with "no route to host". Then no LAN address ever answers, and a dial
    /// cut to the LAN (`prefer_lan`) waits out its timeout every time while the VPN would have
    /// reached: baud 0.2.4 on two Macs on one LAN and one tailnet never met. Asked at each dial
    /// (one datagram), not once at open: a Mac opened with no network fails the send too, and a
    /// person may turn the permission on while the app runs. On iOS multicast needs an entitlement
    /// whatever the permission says, so there the dial's own LAN address is asked instead.
    fn lan_refused(&self, addr: &EndpointAddr) -> bool {
        if cfg!(target_os = "macos") && transport::multicast_blocked().is_some() {
            return true;
        }
        // Everywhere (iOS above all, where multicast says nothing): the first LAN address this
        // dial would try, asked directly.
        addr.ip_addrs().find(|a| !crate::record::is_global(&a.ip()) && !crate::record::is_vpn(&a.ip()) && !a.ip().is_loopback()).is_some_and(|a| transport::unicast_refused(*a))
    }

    fn my_ips(&self) -> Vec<std::net::IpAddr> {
        self.transport().addr().ip_addrs().map(|a| a.ip()).collect()
    }

    /// Without the relay URLs that cannot answer from where I am (`relay_reachable`).
    fn reachable_relays(&self, addr: EndpointAddr) -> EndpointAddr {
        let mine = self.my_ips();
        let kept = addr.addrs.iter().filter(|t| !matches!(t, TransportAddr::Relay(u) if !relay_reachable(u, &mine))).cloned();
        EndpointAddr::from_parts(addr.id, kept)
    }

    /// On the same LAN (or host), dial without VPN addresses first, so a direct LAN path is what
    /// forms and "over your VPN" is said only when the VPN is the way. The redial loop falls back.
    fn prefer_lan(&self, addr: EndpointAddr) -> EndpointAddr {
        if !self.config.vpn {
            let kept = addr.addrs.iter().filter(|t| !matches!(t, TransportAddr::Ip(sa) if crate::record::is_vpn(&sa.ip()))).cloned();
            return EndpointAddr::from_parts(addr.id, kept);
        }
        // The LAN is refused to this app: its addresses go, the VPN's and the public ones stay.
        if self.lan_refused(&addr) {
            return without_lan(addr);
        }
        let mine = self.my_ips();
        let has_lan = addr.ip_addrs().any(|a| on_my_lan(&a.ip(), &mine));
        if !has_lan || !addr.ip_addrs().any(|a| crate::record::is_vpn(&a.ip())) {
            return addr;
        }
        let kept = addr.addrs.iter().filter(|t| !matches!(t, TransportAddr::Ip(sa) if crate::record::is_vpn(&sa.ip()))).cloned();
        EndpointAddr::from_parts(addr.id, kept)
    }

    async fn dial_addr(self: Arc<Self>, device: DeviceId, addr: EndpointAddr, why: &'static str) -> Result<()> {
        let first_try = self.live_conn(&device).is_none() && !self.state.reading().conns.contains_key(&device);
        let addr = self.reachable_relays(self.expand_relays(addr));
        let addr = if first_try || !self.config.vpn { self.prefer_lan(addr) } else { addr };
        for url in addr.relay_urls() {
            self.transport().note_relay(url.clone());
        }
        if self.live_conn(&device).is_none() {
            self.emit(Event::Dialing(device));
        }
        let t = Instant::now();
        let tried = tried_of(&addr);
        let (conn, handshake) = match self.transport().connect_proven_timed(addr).await {
            Ok(c) => c,
            Err(e) => {
                self.trace.emit("dial", serde_json::json!({ "device": device.short(), "ms": crate::trace::ms(t), "ok": false, "why": why, "tried": tried, "err": e.to_string() }));
                return Err(e);
            }
        };
        let (path, rtt) = self.path_label(&conn);
        self.trace.emit("dial", serde_json::json!({ "device": device.short(), "ms": crate::trace::ms(t), "handshake_ms": handshake.as_millis() as u64, "ok": true, "why": why, "path": path, "rtt": rtt }));
        match self.attach(device, conn.clone()) {
            Attach::Kept => {
                let _ = self.exchange(device, &conn).await;
                self.maybe_probe();
            }
            Attach::Checking => {}
        }
        Ok(())
    }

    /// The redeem dial for `add` and `link`, traced with every address tried.
    async fn join(&self, addr: EndpointAddr, why: &'static str) -> Result<Connection> {
        let addr = self.reachable_relays(addr);
        let tried = tried_of(&addr);
        let device = DeviceId::from(addr.id);
        self.emit(Event::Dialing(device));
        let t = Instant::now();
        let r = self.transport().connect_within(addr, JOIN_ALPN, transport::JOIN_TIMEOUT).await;
        let (path, rtt) = r.as_ref().map(|c| self.path_label(c)).map(|(p, r)| (Some(p), r)).unwrap_or((None, None));
        self.trace.emit("dial", serde_json::json!({ "device": device.short(), "ms": crate::trace::ms(t), "ok": r.is_ok(), "why": why, "path": path, "rtt": rtt, "tried": tried, "err": r.as_ref().err().map(|e| e.to_string()) }));
        r
    }

    /// Rule 2, the always-on half: what is due, dialed now; returns when the next falls due.
    fn tick(self: &Arc<Self>) -> Option<Instant> {
        // A helper that connected or went away changes the meeting device, and with it home.
        self.steer_home();
        self.remap(false);
        let mutuals: Vec<(DeviceId, bool)> = {
            let s = self.state.reading();
            let me = self.device.device_id();
            self.mutual_devices(&s)
                .into_iter()
                .map(|(d, _)| d)
                .filter(|d| *d != me && !s.legacy.contains(d) && s.records.get(d).is_some())
                .map(|d| (d, s.conns.get(&d).is_some_and(|l| l.conn.close_reason().is_none())))
                .collect()
        };
        let (due, next) = self.schedule.locked().due(Instant::now(), mutuals);
        for d in due {
            let node = self.clone();
            self.rt().spawn(async move {
                let ok = node.clone().dial_now(d, false, "loop").await.is_ok();
                node.schedule.locked().finished(d, ok, Instant::now());
                node.kick.notify_one();
            });
        }
        next
    }

    /// Dial this device now and start its backoff over: a fresh record arrived, or its
    /// connection closed.
    fn redial(&self, device: DeviceId) {
        self.schedule.locked().reset(device, Instant::now());
        self.kick.notify_one();
    }

    /// Every mutual not connected, now: the network changed, `set_online(true)`, the book grew.
    fn dial_known(&self) {
        self.schedule.locked().reset_all(Instant::now());
        self.kick.notify_one();
    }

    /// A wake: every held connection may be dead with nobody yet the wiser (a suspended app,
    /// a laptop lid). Dial every mutual afresh, in parallel; a new connection from our side
    /// replaces the held one, so a live one costs a handshake and a dead one is gone at once.
    fn wake(self: &Arc<Self>) {
        let devices: Vec<DeviceId> = {
            let s = self.state.reading();
            let me = self.device.device_id();
            self.mutual_devices(&s).into_iter().map(|(d, _)| d).filter(|d| *d != me && !s.legacy.contains(d) && s.records.get(d).is_some()).collect()
        };
        for d in devices {
            let node = self.clone();
            self.rt().spawn(async move {
                let _ = node.dial_now(d, true, "wake").await;
            });
        }
        self.dial_known();
    }
}

/// One dial in flight to a device: later callers join it.
struct InflightDial {
    rx: tokio::sync::watch::Receiver<Option<Result<()>>>,
    id: u64,
    started: Instant,
    /// Told to start over: the network changed under it.
    restart: Arc<tokio::sync::Notify>,
}

struct Inflight<'a> {
    node: &'a Node,
    device: DeviceId,
    id: u64,
}

impl Drop for Inflight<'_> {
    fn drop(&mut self) {
        // Only our own entry: a restarted dial's entry was already replaced by a fresh one.
        let mut inflight = self.node.inflight.locked();
        if inflight.get(&self.device).is_some_and(|d| d.id == self.id) {
            inflight.remove(&self.device);
        }
    }
}

enum Attach {
    /// Held now; the caller exchanges records on it.
    Kept,
    /// The held one is being asked whether it still answers; the check settles it.
    Checking,
}

/// The node's end of `peer/1` and `peer/join/1`.
struct NodeHandler(Weak<Node>);

/// What the blob store asks of the node: a Bulk-class connection, the policy check, who has what.
struct NodeDialer(Weak<Node>);

impl BulkDialer for NodeDialer {
    fn dial(&self, device: DeviceId) -> BoxFuture<'static, Result<Connection>> {
        let weak = self.0.clone();
        Box::pin(async move {
            let node = weak.upgrade().ok_or(Error::Unreachable)?;
            if !node.speaks_app_only(&device) {
                node.clone().dial(device).await?;
            }
            let addr = node.dial_addr_of(&device).ok_or(Error::NotFound)?;
            let addr = node.prefer_lan(node.expand_relays(addr));
            let conn = node.transport().connect(addr, iroh_blobs::ALPN).await?;
            let (path, _) = node.path_of(&conn);
            let far = node.user_of(&device);
            if !crate::policy::allows(Class::Bulk, &path, |d| node.owned_by_endpoints(d, far)) {
                node.emit(Event::PathChanged(device));
                conn.close(0u32.into(), b"policy");
                return Err(Error::PolicyRefused(Class::Bulk, path));
            }
            Ok(conn)
        })
    }

    fn allowed(&self, conn: &Connection, device: DeviceId) -> bool {
        let Some(node) = self.0.upgrade() else { return false };
        let (path, _) = node.path_of(conn);
        let far = node.user_of(&device);
        crate::policy::allows(Class::Bulk, &path, |d| node.owned_by_endpoints(d, far))
    }

    fn ask_have(&self, hash: Hash) -> BoxFuture<'static, Vec<DeviceId>> {
        let weak = self.0.clone();
        Box::pin(async move {
            let Some(node) = weak.upgrade() else { return Vec::new() };
            let conns: Vec<(DeviceId, Connection)> = node.state.reading().conns.iter().filter(|(_, l)| l.conn.close_reason().is_none()).map(|(d, l)| (*d, l.conn.clone())).collect();
            let mut out = Vec::new();
            for (d, c) in conns {
                if let Ok(Ok(Msg::Has(true))) = tokio::time::timeout(Duration::from_secs(5), ask(&c, &Msg::Have(hash.0))).await {
                    out.push(d);
                }
            }
            out
        })
    }
}

impl Handler for NodeHandler {
    fn connected(&self, conn: Connection) {
        if let Some(node) = self.0.upgrade() {
            let device = DeviceId::from(conn.remote_id());
            let _ = node.attach(device, conn);
            node.maybe_probe();
        }
    }

    fn handle(&self, from: DeviceId, alpn: Vec<u8>, msg: Msg) -> BoxFuture<'_, Msg> {
        Box::pin(async move {
            let Some(node) = self.0.upgrade() else { return Msg::No { reason: "closing".into() } };
            let join = alpn == JOIN_ALPN;
            match msg {
                Msg::Hello { secret, card, record } if join => node.on_hello(secret, card, record),
                Msg::Link { secret, device, name, kind, record } if join => node.on_link(secret, device, name, kind, record).await,
                Msg::Exchange { salt, want, records } if !join => {
                    node.take_records(records, FoundBy::Exchange);
                    let (my_salt, my_want, theirs) = {
                        let mut s = node.state.writing();
                        if let Some(l) = s.conns.get_mut(&from) {
                            l.wants = Some((salt, want.iter().copied().collect()));
                        }
                        let (my_salt, my_want) = node.want_list(&s);
                        (my_salt, my_want, node.records_for(&s, &from, salt, &want))
                    };
                    node.carry_to(from, true);
                    if let Some(conn) = node.live_conn(&from) {
                        node.send_book_to(from, &conn);
                    }
                    Msg::Exchange { salt: my_salt, want: my_want, records: theirs }
                }
                Msg::Records { records, hops } if !join => {
                    let fresh = node.take_records(records, FoundBy::Push);
                    if !fresh.is_empty() {
                        node.forward(from, fresh, hops);
                    }
                    Msg::Ok
                }
                Msg::Card(card) if !join => node.on_card(from, card),
                Msg::Redirect { redirect, card } if !join => node.on_redirect(from, redirect, card),
                Msg::Members { group, cards } if !join => node.on_members(from, group, GroupKind::Space, cards),
                Msg::Group { group, kind, cards } if !join => node.on_members(from, group, if kind == 1 { GroupKind::Chat } else { GroupKind::Space }, cards),
                Msg::Removed if !join => {
                    if let Some(user) = node.user_of(&from)
                        && (Peer { node: node.clone() }).remove(user).is_ok()
                    {
                        node.emit(Event::ContactRemoved(user));
                    }
                    Msg::Ok
                }
                Msg::Envelopes(envs) if !join => node.on_envelopes(from, envs),
                Msg::Book { entries, removed, records, fresh } if !join => node.on_book(from, entries, removed, records, fresh),
                Msg::Acks(ids) if !join => {
                    node.on_acks(from, ids);
                    Msg::Ok
                }
                Msg::Introduce { salt, want } if !join => node.on_introduce(from, salt, want).await,
                Msg::Punch { from: asker, at, wait_ms } if !join => node.on_punch(from, asker, at, wait_ms),
                Msg::Invite { secret, expires } if !join => node.on_invite(from, secret, expires),
                Msg::Reply(reply) if !join => node.on_reply(from, reply),
                Msg::Check { udp, tcp } if !join => match node.live_conn(&from).filter(|_| node.checks.allow(from)) {
                    Some(conn) => {
                        let (udp, tcp) = probe::dial_back(&conn, udp, tcp).await;
                        Msg::Checked { udp, tcp }
                    }
                    None => Msg::Checked { udp: None, tcp: None },
                },
                Msg::Have(h) if !join => Msg::Has(match node.blobs.get() {
                    Some(b) => b.has(Hash(h)).await,
                    None => false,
                }),
                _ => Msg::No { reason: "not here".into() },
            }
        })
    }
}

impl Node {
    fn on_hello(self: &Arc<Self>, secret: [u8; 32], card: Card, record: SignedRecord) -> Msg {
        if card.verify().is_err() {
            return Msg::No { reason: "bad card".into() };
        }
        let user = card.user();
        // A reply this device made (`Peer::reply`), opened by the link's maker: theirs alone.
        let replying = self.replies.locked().get(&secret).cloned();
        if let Some(r) = replying {
            if user != r.theirs.user {
                return Msg::No { reason: "used".into() };
            }
            if now_ms() / 1000 >= r.until {
                return Msg::No { reason: "expired".into() };
            }
            if self.accept_contact(card, &r.theirs.name, record, FoundBy::Invite).is_err() {
                return Msg::No { reason: "store".into() };
            }
            self.reply_spent(&secret, true);
            self.dial_known();
            let s = self.state.reading();
            return Msg::HelloOk { card: s.card.clone(), record: self.my_record_in(&s) };
        }
        match self.store.locked().take_pending(&secret) {
            Ok(Some((kind, expires))) if kind == "f" => {
                if now_ms() / 1000 >= expires {
                    return Msg::No { reason: "expired".into() };
                }
                // Theirs from the moment it is taken: their Hello on a second connection, racing
                // this one (an add and a reply dialing at once), is answered too.
                self.redeemed.locked().insert(secret, user);
            }
            // The same person again: their first Hello was taken and its answer lost with its
            // path, so they asked on a fresh connection. They get the same answer; anyone else
            // holding the link is still refused.
            _ if self.redeemed.locked().get(&secret) == Some(&user) => {}
            _ => return Msg::No { reason: "used".into() },
        }
        let petname = card.body.name.clone();
        if self.accept_contact(card, &petname, record, FoundBy::Invite).is_err() {
            return Msg::No { reason: "store".into() };
        }
        self.redeemed.locked().insert(secret, user);
        let (card, record) = {
            let s = self.state.reading();
            (s.card.clone(), self.my_record_in(&s))
        };
        Msg::HelloOk { card, record }
    }

    async fn on_link(self: &Arc<Self>, secret: [u8; 32], device: DeviceId, name: String, kind: DeviceKind, record: SignedRecord) -> Msg {
        match self.store.locked().take_pending(&secret) {
            Ok(Some((kind, expires))) if kind == "m" => {
                if now_ms() / 1000 >= expires {
                    return Msg::No { reason: "expired".into() };
                }
            }
            _ => return Msg::No { reason: "used".into() },
        }
        let (id, rx) = {
            let mut s = self.state.writing();
            let id = s.next_req;
            s.next_req += 1;
            let (tx, rx) = oneshot::channel();
            s.pending.insert(id, PendingLink { secret, device, name: name.clone(), kind, tx: Some(tx) });
            (id, rx)
        };
        self.emit(Event::LinkRequest(LinkReqId(id)));
        if self.config.auto_confirm_links {
            let _ = Peer { node: self.clone() }.confirm_link(LinkReqId(id), true);
        }
        let accepted = matches!(tokio::time::timeout(LINK_CONFIRM_WAIT, rx).await, Ok(Ok(true)));
        self.state.writing().pending.remove(&id);
        if !accepted {
            return Msg::No { reason: "declined".into() };
        }
        let (user_secret, card, book, records) = {
            let mut s = self.state.writing();
            let mut body = s.card.next();
            if !body.devices.iter().any(|d| d.id == device) {
                body.devices.push(DeviceEntry { id: device, name, kind, added_at: now_ms(), app: Vec::new() });
            }
            s.card = Card::sign(body, &s.user);
            let _ = self.store.locked().set_meta("card", &s.card.to_bytes());
            let book = s
                .contacts
                .iter()
                .filter_map(|(u, m)| s.cards.get(u).map(|c| BookEntry { user: *u, card: c.clone(), petname: m.petname.clone(), verified: m.verified, relay_only: m.relay_only, met_at: m.met_at }))
                .collect();
            // Every record I hold, and my own: the new device must be able to dial me.
            let mut records = s.records.signed();
            records.push(self.my_record_in(&s));
            (s.user.to_bytes(), s.card.clone(), book, records)
        };
        self.recompute_allow();
        // The joiner's record: now that the card lists it, it is a known device worth dialing.
        if record.device() == device {
            self.take_records(vec![record], FoundBy::Invite);
        }
        self.push_card(card.clone());
        self.emit(Event::MeChanged);
        self.dial_known();
        Msg::LinkOk { user_secret, card, book, records }
    }

    /// A newer card for a person I know: mine (from another of my devices) or a contact's.
    /// This device linked into another person: the old key's contacts are told, each on its own
    /// devices (connected now, else sealed to it and carried), never anyone else.
    fn issue_redirect(self: &Arc<Self>, redirect: Redirect, audience: Vec<UserId>) {
        {
            let mut r = self.redirects.locked();
            r.issued.push((redirect.clone(), audience.clone()));
            r.save(&self.store.locked());
        }
        self.trace.emit("redirect", serde_json::json!({ "from": redirect.from.short(), "to": redirect.to.short(), "contacts": audience.len() }));
        self.send_redirect(&redirect, &audience, true);
    }

    /// `redirect` to every device of `users`: over a live connection, or (`post_away`) sealed to a
    /// device that is not connected. The new card goes with it.
    fn send_redirect(self: &Arc<Self>, redirect: &Redirect, users: &[UserId], post_away: bool) {
        let (card, targets) = {
            let s = self.state.reading();
            let targets: Vec<(DeviceId, UserId, Option<Connection>)> = users
                .iter()
                .filter_map(|u| s.cards.get(u).map(|c| (u, c)))
                .flat_map(|(u, c)| c.device_ids().map(|d| (d, *u, s.conns.get(&d).filter(|l| l.conn.close_reason().is_none()).map(|l| l.conn.clone()))).collect::<Vec<_>>())
                .collect();
            (s.card.clone(), targets)
        };
        for (device, user, conn) in targets {
            match conn {
                Some(conn) => {
                    let (node, msg, r) = (self.clone(), Msg::Redirect { redirect: redirect.clone(), card: card.clone() }, redirect.clone());
                    self.rt().spawn(async move {
                        if let Ok(Ok(Msg::Ok)) = tokio::time::timeout(Duration::from_secs(5), ask(&conn, &msg)).await {
                            node.redirect_reached(&r, user);
                        }
                    });
                }
                None if post_away => {
                    let mut bytes = REDIRECT_ENVELOPE.to_vec();
                    bytes.extend(postcard::to_allocvec(&(redirect, &card)).unwrap_or_default());
                    let _ = self.post_internal(device, bytes);
                }
                None => {}
            }
        }
    }

    /// One of the old key's contacts has it: stop sending it to them.
    fn redirect_reached(&self, redirect: &Redirect, user: UserId) {
        let mut r = self.redirects.locked();
        let mut changed = false;
        for (x, audience) in r.issued.iter_mut() {
            if x == redirect && audience.contains(&user) {
                audience.retain(|u| *u != user);
                changed = true;
            }
        }
        if changed {
            r.save(&self.store.locked());
        }
    }

    /// The issued redirects a device of `user` should still get.
    fn redirects_for(&self, user: &UserId) -> Vec<Redirect> {
        self.redirects.locked().issued.iter().filter(|(_, a)| a.contains(user)).map(|(r, _)| r.clone()).collect()
    }

    /// An envelope of the crate's own: sealed and carried like `post`, kept out of the app's
    /// outbox and `Delivered`.
    fn post_internal(self: &Arc<Self>, to: DeviceId, bytes: Vec<u8>) -> Result<()> {
        let expires = now_ms() + crate::helper::ENVELOPE_TTL_MS;
        let env = Sealed::new(to, expires, crate::helper::seal(&to, expires, &bytes)?);
        {
            let mut r = self.redirects.locked();
            r.internal.insert(env.id);
            r.save(&self.store.locked());
        }
        {
            let mut s = self.state.writing();
            s.outbox.insert(env.id, env.clone());
            self.store.locked().put_envelope(&env, 1, &[], now_ms())?;
        }
        let handed = self.hand_out(&env);
        self.rt().spawn(handed);
        Ok(())
    }

    fn on_redirect(self: &Arc<Self>, from: DeviceId, redirect: Redirect, card: Card) -> Msg {
        if redirect.verify().is_err() || card.verify().is_err() || card.user() != redirect.to {
            return Msg::No { reason: "bad redirect".into() };
        }
        let own = from != self.device.device_id() && self.state.reading().card.has_device(&from);
        self.apply_redirect(&redirect, card, own);
        Msg::Ok
    }

    /// A contact's old key now points to a new one: the contact moves to the new key with its
    /// petname (vouched for by the old key, not verified), its chats with it, and the old key is
    /// refused from now on. Only if the old key is a contact here, or one of my own devices says
    /// so (it moved the contact already); anyone else learns nothing from it and keeps nothing.
    fn apply_redirect(self: &Arc<Self>, redirect: &Redirect, card: Card, from_own_device: bool) -> bool {
        let (from, to) = (redirect.from, redirect.to);
        if self.redirects.locked().known.iter().any(|r| r.from == from) {
            return false;
        }
        let now = now_ms();
        {
            let mut s = self.state.writing();
            let me = s.user.user_id();
            if from == me || to == me {
                return false;
            }
            let old = s.contacts.remove(&from);
            if old.is_none() && !from_own_device {
                return false;
            }
            let store = self.store.locked();
            s.cards.remove(&from);
            let _ = store.remove_card(&from);
            let _ = store.remove_contact(&from, now);
            if s.cards.get(&to).is_none_or(|c| card.body.seq > c.body.seq) {
                let _ = store.put_card(&card);
                s.cards.insert(to, card.clone());
            }
            if let Some(m) = old
                && !s.contacts.contains_key(&to)
            {
                let _ = store.put_contact(&to, &m.petname, false, m.relay_only, m.met_at);
                s.contacts.insert(to, ContactMeta { petname: m.petname, verified: false, relay_only: m.relay_only, met_at: m.met_at });
            }
            let groups: Vec<GroupId> = s.members.iter().filter(|(_, m)| m.contains(&from)).map(|(g, _)| *g).collect();
            for g in groups {
                if let Some(m) = s.members.get_mut(&g) {
                    m.remove(&from);
                    m.insert(to);
                }
                let _ = store.remove_member(&g, &from);
                let _ = store.put_member(&g, &to);
            }
        }
        {
            let mut r = self.redirects.locked();
            r.known.push(redirect.clone());
            r.save(&self.store.locked());
        }
        self.trace.emit("redirected", serde_json::json!({ "from": from.short(), "to": to.short() }));
        self.recompute_allow();
        self.emit(Event::ContactRedirected { from, to });
        self.emit(Event::ContactsChanged);
        // My other devices move the contact too.
        let me = self.state.reading().user.user_id();
        self.send_redirect_to_own(redirect, &card, me);
        self.dial_known();
        true
    }

    /// Forward a redirect I applied to my other devices: connected now, else sealed and carried.
    fn send_redirect_to_own(self: &Arc<Self>, redirect: &Redirect, card: &Card, me: UserId) {
        let mine = self.device.device_id();
        let (devices, conns): (Vec<DeviceId>, HashMap<DeviceId, Connection>) = {
            let s = self.state.reading();
            debug_assert_eq!(s.user.user_id(), me);
            let devices: Vec<DeviceId> = s.card.device_ids().filter(|d| *d != mine).collect();
            let conns = devices.iter().filter_map(|d| s.conns.get(d).filter(|l| l.conn.close_reason().is_none()).map(|l| (*d, l.conn.clone()))).collect();
            (devices, conns)
        };
        for d in devices {
            match conns.get(&d) {
                Some(conn) => {
                    let (conn, msg) = (conn.clone(), Msg::Redirect { redirect: redirect.clone(), card: card.clone() });
                    self.rt().spawn(async move {
                        let _ = tokio::time::timeout(Duration::from_secs(5), ask(&conn, &msg)).await;
                    });
                }
                None => {
                    let mut bytes = REDIRECT_ENVELOPE.to_vec();
                    bytes.extend(postcard::to_allocvec(&(redirect, card)).unwrap_or_default());
                    let _ = self.post_internal(d, bytes);
                }
            }
        }
    }

    fn on_card(self: &Arc<Self>, from: DeviceId, card: Card) -> Msg {
        if card.verify().is_err() {
            return Msg::No { reason: "bad card".into() };
        }
        if self.redirects.locked().successor(&card.user()).is_some() {
            return Msg::No { reason: "redirected".into() };
        }
        let user = card.user();
        let (mine, changed) = {
            let mut s = self.state.writing();
            if user == s.user.user_id() {
                if card.body.seq > s.card.body.seq && card.has_device(&from) {
                    s.card = card.clone();
                    let _ = self.store.locked().set_meta("card", &card.to_bytes());
                    (true, true)
                } else {
                    (true, false)
                }
            } else if let Some(cur) = s.cards.get(&user) {
                if card.body.seq > cur.body.seq && cur.has_device(&from) {
                    let _ = self.store.locked().put_card(&card);
                    s.cards.insert(user, card);
                    (false, true)
                } else {
                    (false, false)
                }
            } else {
                return Msg::No { reason: "unknown person".into() };
            }
        };
        if changed {
            self.recompute_allow();
            self.emit(if mine { Event::MeChanged } else { Event::ContactsChanged });
            if mine && !self.state.reading().card.has_device(&self.device.device_id()) {
                self.emit(Event::Removed);
            }
        }
        Msg::Ok
    }
}

/// One connection on the app's ALPN: several bi streams, datagrams, an honest path.
pub struct Conn {
    inner: Connection,
    identity: Identity,
    class: Class,
    path: Path,
    rtt: Option<u32>,
    node: Weak<Node>,
}

impl Conn {
    pub fn identity(&self) -> Identity {
        self.identity.clone()
    }
    /// The path now, its relay named as the node names it: a relayed call says whose relay
    /// carries it, not "unreachable".
    pub fn path(&self) -> Path {
        self.path_now().0
    }
    pub fn rtt_ms(&self) -> Option<u32> {
        self.path_now().1.or(self.rtt)
    }
    fn path_now(&self) -> (Path, Option<u32>) {
        match self.node.upgrade() {
            Some(node) => node.path_of(&self.inner),
            None => transport::path_of(&self.inner, |_| None),
        }
    }
    pub fn class(&self) -> Class {
        self.class
    }
    pub fn alpn(&self) -> Vec<u8> {
        self.inner.alpn().to_vec()
    }
    pub fn initial_path(&self) -> Path {
        self.path
    }
    pub async fn open(&self) -> Result<Stream> {
        let (tx, rx) = self.inner.open_bi().await.map_err(|e| transport::stream_err(&self.inner, e))?;
        Ok(Stream { tx, rx, watch: self.watch() })
    }
    pub async fn accept_stream(&self) -> Result<Stream> {
        let (tx, rx) = self.inner.accept_bi().await.map_err(|e| transport::stream_err(&self.inner, e))?;
        Ok(Stream { tx, rx, watch: self.watch() })
    }
    fn watch(&self) -> Watch {
        Watch { conn: self.inner.clone(), node: self.node.clone(), device: self.identity.device }
    }
    pub fn send_datagram(&self, bytes: Bytes) -> Result<()> {
        self.inner.send_datagram(bytes).map_err(transport::net)
    }
    pub async fn recv_datagram(&self) -> Result<Bytes> {
        self.inner.read_datagram().await.map_err(transport::net)
    }
    pub fn max_datagram(&self) -> Option<usize> {
        self.inner.max_datagram_size()
    }
    pub fn close(&self, reason: &str) {
        self.inner.close(0u32.into(), reason.as_bytes());
    }
}

/// One bi stream. `send` awaits QUIC flow control: that is the backpressure. The two halves
/// are independent: a pending `recv` never blocks a `send` (`split`).
pub struct Stream {
    tx: SendStream,
    rx: RecvStream,
    watch: Watch,
}

/// The sending half of a stream, usable while the other half is waiting in `recv`.
pub struct SendHalf {
    tx: SendStream,
    watch: Watch,
}

/// A stream's connection, and whose it is: for `delivered`.
#[derive(Clone)]
struct Watch {
    conn: Connection,
    node: Weak<Node>,
    device: DeviceId,
}

impl Watch {
    /// Finished, and the far side has every byte: its QUIC stack acknowledged them all. `send`
    /// and `finish` only queue: on a connection dead in all but name (its relay froze, the far
    /// side slept or moved) they succeed and the bytes are lost when it times out. One that has
    /// said nothing for a few round trips is closed and its device dialed afresh, and the send is
    /// an error: not delivered, so the app carries it some other way. A far side still talking
    /// (a long stream still being acknowledged on a slow link) is waited for.
    async fn delivered(&self, tx: &mut SendStream) -> Result<()> {
        let _ = tx.finish();
        let heard = || self.conn.stats().udp_rx.datagrams;
        let wait = answer_wait(transport::path_of(&self.conn, |_| None).1);
        let stopped = tx.stopped();
        tokio::pin!(stopped);
        let mut last = heard();
        loop {
            match tokio::time::timeout(wait, &mut stopped).await {
                Ok(Ok(None)) => return Ok(()),
                Ok(Ok(Some(code))) => return Err(Error::Net(format!("stopped by the far side ({code})"))),
                Ok(Err(e)) => return Err(transport::stream_err(&self.conn, e)),
                Err(_) if heard() != last => last = heard(),
                Err(_) => break,
            }
        }
        self.conn.close(0u32.into(), b"unacknowledged");
        if let Some(node) = self.node.upgrade() {
            node.stalled(self.device);
        }
        Err(Error::Unreachable)
    }
}

/// The receiving half of a stream.
pub struct RecvHalf {
    rx: RecvStream,
}

impl SendHalf {
    pub async fn send(&mut self, bytes: &[u8]) -> Result<()> {
        self.tx.write_all(bytes).await.map_err(transport::net)
    }
    pub fn finish(&mut self) -> Result<()> {
        self.tx.finish().map_err(transport::net)
    }
    /// Finish, then wait until the far side has every byte (`Watch::delivered`).
    pub async fn delivered(&mut self) -> Result<()> {
        self.watch.delivered(&mut self.tx).await
    }
    pub fn set_priority(&mut self, priority: i32) -> Result<()> {
        self.tx.set_priority(priority).map_err(transport::net)
    }
    pub fn reset(&mut self) -> Result<()> {
        self.tx.reset(0u32.into()).map_err(transport::net)
    }
}

impl RecvHalf {
    pub async fn recv(&mut self, max: usize) -> Result<Option<Bytes>> {
        let mut buf = vec![0u8; max];
        match self.rx.read(&mut buf).await.map_err(transport::net)? {
            Some(n) => {
                buf.truncate(n);
                Ok(Some(Bytes::from(buf)))
            }
            None => Ok(None),
        }
    }
}

impl Stream {
    /// Independent halves, so bindings can lock each on its own.
    pub fn split(self) -> (SendHalf, RecvHalf) {
        (SendHalf { tx: self.tx, watch: self.watch }, RecvHalf { rx: self.rx })
    }

    pub async fn send(&mut self, bytes: &[u8]) -> Result<()> {
        self.tx.write_all(bytes).await.map_err(transport::net)
    }
    pub async fn recv(&mut self, max: usize) -> Result<Option<Bytes>> {
        let mut buf = vec![0u8; max];
        match self.rx.read(&mut buf).await.map_err(transport::net)? {
            Some(n) => {
                buf.truncate(n);
                Ok(Some(Bytes::from(buf)))
            }
            None => Ok(None),
        }
    }
    pub fn finish(&mut self) -> Result<()> {
        self.tx.finish().map_err(transport::net)
    }
    /// Finish, then wait until the far side has every byte (`Watch::delivered`).
    pub async fn delivered(&mut self) -> Result<()> {
        self.watch.delivered(&mut self.tx).await
    }
    /// Relative priority among this connection's streams: video above metadata.
    pub fn set_priority(&mut self, priority: i32) -> Result<()> {
        self.tx.set_priority(priority).map_err(transport::net)
    }
    /// Abandon the stream; the far side sees a reset, not a clean finish.
    pub fn reset(&mut self) -> Result<()> {
        self.tx.reset(0u32.into()).map_err(transport::net)
    }
}

/// The label said for a held connection, `said`, against its path `now`: true, and `said` is
/// `now`, when it moved. A path still settling (`Waiting`) is no move.
fn moved(said: &mut Path, now: Path) -> bool {
    if now == *said || now == Path::Waiting {
        return false;
    }
    *said = now;
    true
}

#[cfg(test)]
mod moved_tests {
    use super::{DeviceId, Path, moved};

    /// Relayed → direct when a punch lands, direct → relayed on a failover that keeps the
    /// connection: each said once; the same label again, or a path still settling, never.
    #[test]
    fn a_label_is_said_once_per_change() {
        let rex = Path::Relay(DeviceId([2; 32]));
        let direct = Path::Direct { vpn: false };
        let mut said = rex;
        let seen: Vec<bool> = [rex, direct, direct, Path::Waiting, direct, rex, rex, direct].into_iter().map(|now| moved(&mut said, now)).collect();
        assert_eq!(seen, [false, true, false, false, false, true, false, true]);
        assert_eq!(said, direct);
    }
}

/// A relay URL as its host is known by: without its query. A link's carries the inviter's meet
/// token (`?m=…`), and a connection made through the link rides that URL.
fn bare_relay(u: &iroh::RelayUrl) -> &str {
    u.as_str().split('?').next().unwrap_or_default()
}

/// Who runs the relay at `url`: me (`mine`, my relay's URLs), else a helper in `owners`
/// (`relay_owners`), whatever query the URL carries.
fn relay_owner(url: &iroh::RelayUrl, mine: &[iroh::RelayUrl], me: DeviceId, owners: &HashMap<iroh::RelayUrl, DeviceId>) -> Option<DeviceId> {
    let url = bare_relay(url);
    if mine.iter().any(|u| bare_relay(u) == url) {
        return Some(me);
    }
    owners.iter().find(|(u, _)| bare_relay(u) == url).map(|(_, d)| *d)
}

#[cfg(test)]
mod relay_owner_tests {
    use std::collections::HashMap;

    use super::{DeviceId, relay_owner};

    /// A connection made through a friend's link rides the helper's URL with the inviter's meet
    /// token on it: still that helper's relay, not "unreachable".
    #[test]
    fn a_relay_is_its_hosts_whatever_its_query() {
        let url = |s: &str| s.parse::<iroh::RelayUrl>().unwrap();
        let (me, rex) = (DeviceId([1; 32]), DeviceId([2; 32]));
        let owners = HashMap::from([(url("http://7.7.7.10:443/"), rex)]);
        let mine = [url("http://10.0.0.5:4101/")];
        assert_eq!(relay_owner(&url("http://7.7.7.10:443/?m=AAAA"), &mine, me, &owners), Some(rex));
        assert_eq!(relay_owner(&url("http://7.7.7.10:443/"), &mine, me, &owners), Some(rex));
        assert_eq!(relay_owner(&url("http://10.0.0.5:4101/?m=BBBB"), &mine, me, &owners), Some(me));
        assert_eq!(relay_owner(&url("http://7.7.7.11:443/?m=AAAA"), &mine, me, &owners), None);
    }
}

#[cfg(test)]
mod mapped_tests {
    use super::public_mapping;

    /// Only a public external address is a port the internet reaches: a router behind a
    /// carrier's NAT maps onto a shared address, and one that lost its WAN onto nothing usable.
    #[test]
    fn only_public_mappings_count() {
        let a = |s: &str| Some(s.parse::<std::net::SocketAddrV4>().unwrap());
        assert_eq!(public_mapping(a("203.0.113.53:47658")).map(|x| x.to_string()), Some("203.0.113.53:47658".into()));
        assert_eq!(public_mapping(a("100.72.1.9:47658")), None);
        assert_eq!(public_mapping(a("192.168.1.1:47658")), None);
        assert_eq!(public_mapping(a("10.0.0.2:47658")), None);
        assert_eq!(public_mapping(None), None);
    }
}

#[cfg(test)]
mod relay_url_tests {
    use super::relay_reachable;

    /// A laptop on a phone's hotspot, dialing through the Mac at home: its public URL
    /// and a named one, never its LAN ones; at home, the LAN ones too.
    #[test]
    fn a_private_relay_url_only_on_its_own_network() {
        let url = |s: &str| s.parse::<iroh::RelayUrl>().unwrap();
        let ips = |v: &[&str]| v.iter().map(|s| s.parse::<std::net::IpAddr>().unwrap()).collect::<Vec<_>>();
        let hotspot = ips(&["172.20.10.3", "2001:db8:aa::3"]);
        let home = ips(&["192.168.1.30", "fd00:1::30"]);
        assert!(relay_reachable(&url("http://203.0.113.53:443"), &hotspot));
        assert!(relay_reachable(&url("https://relay.example.com"), &hotspot));
        assert!(!relay_reachable(&url("http://192.168.1.5:443"), &hotspot));
        assert!(!relay_reachable(&url("http://[fd00:1::5]:443"), &hotspot));
        assert!(relay_reachable(&url("http://192.168.1.5:443"), &home));
        assert!(relay_reachable(&url("http://[fd00:1::5]:443"), &home));
        assert!(!relay_reachable(&url("http://192.168.0.5:443"), &home), "another 192.168 network");
        assert!(relay_reachable(&url("http://127.0.0.1:443"), &hotspot));
        assert!(!relay_reachable(&url("http://100.101.7.2:443"), &home), "off the tailnet");
        assert!(relay_reachable(&url("http://100.101.7.2:443"), &ips(&["192.168.1.30", "100.90.1.4"])));
    }
}

/// Introductions between real nodes on loopback. Nothing on loopback blocks a direct dial, so
/// what is proven here is the protocol: who may ask, consent, relay-only, strangers, spacing,
/// and the asker's whole path. The punch itself is a NAT's business (`introduce`).
#[cfg(test)]
mod introduce_tests {
    use std::sync::Arc;
    use std::time::Duration;

    use super::{Msg, Peer, want_hash};
    use crate::Config;
    use crate::identity::MemoryKeychain;

    async fn node(name: &str) -> (Peer, tempfile::TempDir) {
        let dir = tempfile::tempdir().unwrap();
        let mut c = Config::new("introduce-test", name, &format!("{name}-dev"));
        c.nearby = false;
        c.portmap = false; // tests never map a port on the developer's router
        let p = Peer::open(dir.path().to_path_buf(), Arc::new(MemoryKeychain::default()), c).await.unwrap();
        p.set_online(true);
        (p, dir)
    }

    async fn until(what: &str, mut f: impl FnMut() -> bool) {
        for _ in 0..200 {
            if f() {
                return;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        panic!("timed out waiting for {what}");
    }

    fn online(p: &Peer, name: &str) -> bool {
        p.contacts().iter().find(|c| c.name == name).is_some_and(|c| c.devices.iter().any(|d| d.online))
    }

    fn traced(p: &Peer, ev: &str) -> Vec<String> {
        p.trace().into_iter().filter(|l| l.contains(&format!("\"ev\":\"{ev}\""))).collect()
    }

    #[tokio::test]
    async fn a_go_between_introduces_only_mutuals_with_consent() {
        let ((ana, _da), (jo, _dj), (sam, _ds), (eve, _de)) = (node("ana").await, node("jo").await, node("sam").await, node("eve").await);
        // Jo is the go-between, everyone's friend; ana and sam are each other's. Eve is only jo's
        // contact and nobody else's.
        sam.add(&ana.invite().unwrap()).await.unwrap();
        jo.add(&ana.invite().unwrap()).await.unwrap();
        jo.add(&sam.invite().unwrap()).await.unwrap();
        until("all connected", || online(&jo, "ana") && online(&jo, "sam") && online(&ana, "sam")).await;
        let (a, s, e) = (ana.me().this_device, sam.me().this_device, eve.me().this_device);
        let j = jo.me().this_device;

        // Ana asks jo to introduce her to sam: sam agrees, and loopback is not worth passing on.
        let r = jo.node.on_introduce(a, 7, want_hash(7, &s)).await;
        assert!(matches!(&r, Msg::Introduced { at } if at.is_empty()), "{r:?}");
        assert!(traced(&jo, "introducing").iter().any(|l| l.contains("\"agreed\":true")), "{:?}", jo.trace());
        // Spaced: the same pair again at once is refused, whatever the salt.
        assert!(matches!(jo.node.on_introduce(a, 8, want_hash(8, &s)).await, Msg::No { .. }));
        // A hash that names nobody connected to jo is no introduction.
        assert!(matches!(jo.node.on_introduce(a, 9, want_hash(9, &e)).await, Msg::No { .. }));
        // A device jo holds no card for asks nothing of jo.
        assert!(matches!(jo.node.on_introduce(e, 10, want_hash(10, &s)).await, Msg::No { .. }));

        // The far side: a mutual already connected is just agreed to; a stranger is refused; a
        // contact kept relay-only keeps sam's address to sam.
        assert!(matches!(sam.node.on_punch(j, a, Vec::new(), 0), Msg::Ok));
        assert!(matches!(sam.node.on_punch(j, e, Vec::new(), 0), Msg::No { .. }));
        sam.set_relay_only(ana.me().user, true).unwrap();
        assert!(matches!(sam.node.on_punch(j, a, Vec::new(), 0), Msg::No { .. }));
        sam.set_relay_only(ana.me().user, false).unwrap();

        // The asker's whole path: ana asks the devices connected to her (jo and sam himself are
        // the only ones; sam is the target, so jo alone), and hears jo's answer.
        ana.node.clone().introduce(s).await;
        let lines = traced(&ana, "introduce");
        assert!(lines.iter().any(|l| l.contains("\"asked\":1")), "{lines:?}");
        // Jo introduced ana to sam a moment ago: spaced, so this one is declined, and said so.
        assert!(lines.iter().any(|l| l.contains("\"introduced\":0")), "{lines:?}");

        for p in [ana, jo, sam, eve] {
            p.close().await;
        }
    }

    #[tokio::test]
    async fn the_asker_hears_an_introduction() {
        let ((ana, _da), (jo, _dj), (sam, _ds)) = (node("ana").await, node("jo").await, node("sam").await);
        sam.add(&ana.invite().unwrap()).await.unwrap();
        jo.add(&ana.invite().unwrap()).await.unwrap();
        jo.add(&sam.invite().unwrap()).await.unwrap();
        until("all connected", || online(&jo, "ana") && online(&jo, "sam")).await;
        let s = sam.me().this_device;
        ana.node.clone().introduce(s).await;
        let lines = traced(&ana, "introduce");
        assert!(lines.iter().any(|l| l.contains("\"introduced\":1")), "{lines:?}");
        assert!(traced(&jo, "introducing").iter().any(|l| l.contains("\"agreed\":true")), "{:?}", jo.trace());
        for p in [ana, jo, sam] {
            p.close().await;
        }
    }
}
