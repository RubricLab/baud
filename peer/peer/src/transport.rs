//! The iroh endpoint on `presets::Minimal`: no DNS, no pkarr, no n0 relay map. mDNS on the LAN,
//! the gate after the handshake (a node accepts a connection only from a device in a card it
//! holds, or one speaking the join ALPN with a live secret), the crate's two ALPNs, and the
//! app's own on top. Framing on every crate stream is `u32 be length | postcard`.

use std::collections::{HashMap, HashSet};
use std::future::Future;
use std::net::SocketAddr;
use std::pin::Pin;
use std::sync::{Arc, Mutex, RwLock};
use std::time::Duration;

use iroh::endpoint::{AfterHandshakeOutcome, Connection, EndpointHooks, RecvStream, SendStream, Side, presets};
use iroh::protocol::{AcceptError, ProtocolHandler, Router};
use iroh::{Endpoint, EndpointAddr, EndpointId, RelayMap, RelayMode, RelayUrl, TransportAddr, Watcher};
use iroh_mdns_address_lookup::{DiscoveryEvent, MdnsAddressLookup};
use n0_future::StreamExt;
use serde::{Deserialize, Serialize};
use tokio::sync::mpsc;

use crate::card::Card;
use crate::helper::Envelope;
use crate::identity::{DeviceId, UserId};
use crate::record::{SignedRecord, is_vpn};
use crate::{Error, Path, Result};
use crate::sync::{Locked, Shared};

/// Records, envelopes, probes, membership, removal: the crate's own traffic.
pub const ALPN: &[u8] = b"peer/1";
/// The only ALPN a stranger may open: redeeming an invite or a device link.
pub const JOIN_ALPN: &[u8] = b"peer/join/1";
/// A relay host's one answer to the devices its relay admits (cardholders, and strangers on a
/// live meet token: `helper::Met`): `Bind`, the address it sees them at. Served only by a node
/// that runs a relay; it tells each asker its own address and nothing else.
pub const BIND_ALPN: &[u8] = b"peer/bind/1";
/// How long an asker gives the relay host to connect, then to form a direct path (a relayed one
/// says nothing of the asker's NAT).
const BIND_CONNECT: Duration = Duration::from_secs(5);
const BIND_DIRECT_WAIT: Duration = Duration::from_secs(3);
pub const MAX_MSG: u32 = 16 * 1024 * 1024;
const CONNECT_TIMEOUT: Duration = Duration::from_secs(20);
/// Redeeming a link: the meeting device answers within a second or two when it can be reached
/// at all; a person waiting on `add` hears `Unreachable` after this, not after 20 s.
pub const JOIN_TIMEOUT: Duration = Duration::from_secs(10);
/// Rule 3 of the network loop: a dead peer is offline within a minute. The connection is kept
/// alive every `KEEP_ALIVE`, as its selected path is (vendor/iroh, `peer:`): just under the
/// shortest idle pinhole the lab measured, a carrier's 30 s. Battery outranks how soon a peer that
/// vanished without a word is seen gone; a message to it does not wait for this (`delivered`,
/// `stalled`). QUIC restarts the idle timer on the first keepalive after the last packet heard,
/// so a peer that vanished is let go 40 to 60 s later (the lab: 67 s at 50).
pub const IDLE_TIMEOUT: Duration = Duration::from_secs(40);
pub const KEEP_ALIVE: Duration = Duration::from_secs(20);
/// The round trip assumed before one is measured. QUIC's default (333 ms) sets the first
/// handshake retransmit near 1 s and holds `close` for ~3 s while a dial to a vanished peer
/// drains; the loop always has such dials, and a peer coming back is answered on the next one.
pub const INITIAL_RTT: Duration = Duration::from_millis(100);
/// A Live connection (a call) is given up after this long without a word from the far side,
/// on both sides (QUIC's idle timeout is the lower of the two ends'), kept alive every second
/// meanwhile: a call whose path died (a phone frozen or killed, a hang-up lost with its network)
/// ends on both sides within seconds, never on one. It is offered this long to connect.
pub const LIVE_IDLE: Duration = Duration::from_secs(4);
const LIVE_KEEPALIVE: Duration = Duration::from_secs(1);
pub const LIVE_CONNECT: Duration = Duration::from_secs(5);

/// Every message on `peer/1` and `peer/join/1`. One request and one reply per stream.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub enum Msg {
    /// Probe: what address do you see me at? Costs the responder one frame.
    Bind,
    /// The direct path's remote address, or None when this connection is relayed.
    Bound(Option<SocketAddr>),
    /// Address gossip, forwarded `hops` times already (three at most).
    Records { records: Vec<SignedRecord>, hops: u8 },
    /// Exchange on connect. `want` is `blake3(salt ‖ device)[..8]` for every device the sender
    /// holds a card for, so the other side can answer with records for mutual cardholders only,
    /// learning nothing about devices it does not already know. `records` are the sender's own.
    Exchange { salt: u64, want: Vec<[u8; 8]>, records: Vec<SignedRecord> },
    /// A newer card for the sender's person, or one it holds for a person the receiver knows.
    Card(Card),
    /// A group's member cards, from a member to a member: how co-members learn each other.
    Members { group: crate::identity::GroupId, cards: Vec<Card> },
    /// Sealed payloads for devices I cannot reach: hold or forward.
    Envelopes(Vec<Envelope>),
    /// Envelope ids delivered to their recipient, so carriers drop them.
    Acks(Vec<[u8; 32]>),
    /// I removed you as a contact; stop trying and say so.
    Removed,
    /// Do you hold this blob? (asked of connected peers before a bulk fetch)
    Have([u8; 32]),
    Has(bool),
    /// Join: redeem a friend invite with the secret from the link, my card and my record.
    Hello { secret: [u8; 32], card: Card, record: SignedRecord },
    HelloOk { card: Card, record: SignedRecord },
    /// Join: become one of your devices, with my record so you can dial me. Answered after the
    /// person confirms the code.
    Link { secret: [u8; 32], device: DeviceId, name: String, kind: crate::card::DeviceKind, record: SignedRecord },
    /// The person's secret, the card with the new device, the whole book and every record held.
    LinkOk { user_secret: [u8; 32], card: Card, book: Vec<BookEntry>, records: Vec<SignedRecord> },
    No { reason: String },
    Ok,
    /// Between a person's own devices: contacts (with cards and the records held for their
    /// devices) and removals. `fresh` is an edit just made (petnames and flags win); otherwise it
    /// is the whole book on connect (only what is missing is taken). Appended last, so older
    /// readers still decode everything before it.
    Book { entries: Vec<BookEntry>, removed: Vec<(UserId, u64)>, records: Vec<SignedRecord>, fresh: bool },
    /// A group's cards with its kind (0 space, 1 chat), from a member to a member. Replaces
    /// `Members`, which is still read (as a space) for one release.
    Group { group: crate::identity::GroupId, kind: u8, cards: Vec<Card> },
    /// A person who started on two devices is now one: `redirect` signed by the old user key,
    /// `card` the person's card under the new one. Sent only to the old identity's contacts.
    Redirect { redirect: crate::card::Redirect, card: Card },
    /// Introduce me to the device `want` names (`blake3(salt ‖ device)[..8]`, as in `Exchange`),
    /// one we both hold that you are connected to (`introduce`). Answered `Introduced` with where
    /// you see it once it has agreed to dial me, else `No`.
    Introduce { salt: u64, want: [u8; 8] },
    Introduced { at: Vec<SocketAddr> },
    /// From a go-between we both hold: `from` is dialing me and is seen at `at`. Dial it back
    /// after `wait_ms`, which the go-between sets so both dials start together (`introduce`).
    /// `Ok` is consent to be introduced; `No` keeps my address to myself.
    Punch { from: DeviceId, at: Vec<SocketAddr>, wait_ms: u32 },
    /// Probe: dial back to my port mappings, the UDP one and my relay's TCP one, at the address
    /// you see me at (`probe::dial_back`). Answered `Checked`, `None` for what you cannot check.
    Check { udp: Option<u16>, tcp: Option<u16> },
    Checked { udp: Option<bool>, tcp: Option<bool> },
    /// From another of my devices: a friend invite it minted for a link that names me, its
    /// meeting device, so I answer the redeemer whether it is awake or not. `Ok` once I hold it.
    Invite { secret: [u8; 32], expires: u64 },
    /// From another of my devices: a reply to a friend link it was handed (`Peer::add`), for an
    /// invite it does not hold. `Ok` if I hold it: I dial the reply's maker (`answer_reply`).
    Reply(crate::link::Link),
}

/// One contact as replicated between a person's own devices.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct BookEntry {
    pub user: UserId,
    pub card: Card,
    pub petname: String,
    pub verified: bool,
    pub relay_only: bool,
    pub met_at: u64,
}

pub async fn send(tx: &mut SendStream, msg: &Msg) -> Result<()> {
    let bytes = postcard::to_allocvec(msg).map_err(|_| Error::Encoding)?;
    let len = bytes.len() as u32;
    if len > MAX_MSG {
        return Err(Error::Encoding);
    }
    tx.write_all(&len.to_be_bytes()).await.map_err(net)?;
    tx.write_all(&bytes).await.map_err(net)?;
    Ok(())
}

pub async fn recv(rx: &mut RecvStream) -> Result<Msg> {
    let mut len = [0u8; 4];
    rx.read_exact(&mut len).await.map_err(net)?;
    let len = u32::from_be_bytes(len);
    if len > MAX_MSG {
        return Err(Error::Encoding);
    }
    let mut buf = vec![0u8; len as usize];
    rx.read_exact(&mut buf).await.map_err(net)?;
    postcard::from_bytes(&buf).map_err(|_| Error::Encoding)
}

/// Requests in flight on one connection, either way, at most. Past it an `ask` waits up to
/// `ASK_SLOT_WAIT` for one to end, then fails (`Budget`) rather than queue for stream credit; and
/// `serve` takes no new request until one is answered. A burst (200 envelopes handed to a
/// carrier at once) flows through as answers come back; a loop that asks faster than its peer
/// answers (three carriers passing envelopes round, 3ad457b: a mini at 15 GB) is refused.
pub const MAX_ASKS: usize = 64;
const ASK_SLOT_WAIT: Duration = Duration::from_secs(1);

static ASKING: std::sync::LazyLock<Mutex<HashMap<usize, Arc<tokio::sync::Semaphore>>>> = std::sync::LazyLock::new(Mutex::default);

/// One of a connection's `MAX_ASKS`, given back when the ask ends or is dropped.
struct Asking {
    id: usize,
    slots: Arc<tokio::sync::Semaphore>,
    slot: Option<tokio::sync::OwnedSemaphorePermit>,
}

impl Asking {
    async fn take(conn: &Connection) -> Result<Asking> {
        let id = conn.stable_id();
        let slots = ASKING.locked().entry(id).or_insert_with(|| Arc::new(tokio::sync::Semaphore::new(MAX_ASKS))).clone();
        match tokio::time::timeout(ASK_SLOT_WAIT, slots.clone().acquire_owned()).await {
            Ok(Ok(slot)) => Ok(Asking { id, slots, slot: Some(slot) }),
            _ => Err(Error::Budget),
        }
    }
}

impl Drop for Asking {
    fn drop(&mut self) {
        drop(self.slot.take());
        // The last ask on a connection takes its slots with it.
        let mut asking = ASKING.locked();
        if self.slots.available_permits() == MAX_ASKS && Arc::strong_count(&self.slots) == 2 {
            asking.remove(&self.id);
        }
    }
}

/// One round trip on a fresh stream.
pub async fn ask(conn: &Connection, msg: &Msg) -> Result<Msg> {
    let _slot = Asking::take(conn).await?;
    let (mut tx, mut rx) = conn.open_bi().await.map_err(net)?;
    send(&mut tx, msg).await?;
    tx.finish().map_err(net)?;
    recv(&mut rx).await
}

pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// What the node does with crate messages that are not the probe, and with each inbound
/// crate connection. A reply may wait (a device link waits for the person to confirm).
pub trait Handler: Send + Sync + 'static {
    fn handle(&self, from: DeviceId, alpn: Vec<u8>, msg: Msg) -> BoxFuture<'_, Msg>;
    fn connected(&self, conn: Connection);
}

pub struct NoHandler;
impl Handler for NoHandler {
    fn handle(&self, _from: DeviceId, _alpn: Vec<u8>, _msg: Msg) -> BoxFuture<'_, Msg> {
        Box::pin(async { Msg::No { reason: "not implemented".into() } })
    }
    fn connected(&self, _conn: Connection) {}
}

pub struct Options {
    /// The app name, for the mDNS service `_peer-<app>._udp`.
    pub app: String,
    pub nearby: bool,
    /// The app's own ALPNs. Inbound connections on them are handed to the app via `inbound()`.
    pub alpns: Vec<Vec<u8>>,
    /// Bind a fixed UDP port (a helper that maps a port), else ephemeral.
    pub port: Option<u16>,
    /// The port bound last time: asked for again so cached addresses stay valid across restarts;
    /// ephemeral if it is taken.
    pub port_hint: Option<u16>,
    /// Let iroh ask the gateway for a UDP mapping (UPnP, NAT-PMP, PCP). Off for tests that
    /// need an unreachable node.
    pub portmap: bool,
    /// false: bind only the primary non-VPN interface (and loopback), never `0.0.0.0`, so a VPN
    /// interface is not a candidate for iroh's own path discovery either. A test switch.
    pub vpn: bool,
    /// The blob store's protocol, served behind the same gate.
    pub blobs: Option<iroh_blobs::BlobsProtocol>,
    /// A relay host's meet-token admissions: `BIND_ALPN` is served, to them and cardholders.
    pub met: Option<crate::helper::Met>,
}

type Lan = Arc<Mutex<HashMap<EndpointId, Vec<SocketAddr>>>>;

pub struct Transport {
    /// Taken by `stop`: the UDP port is released only when the last clone is dropped.
    endpoint: RwLock<Option<Endpoint>>,
    /// The endpoint's id, which outlives it: a task finishing after `stop` still asks who we are.
    id: EndpointId,
    router: Mutex<Option<Router>>,
    handler: Arc<dyn Handler>,
    /// The runtime the node lives on: bindings call sync methods from threads that have none.
    pub rt: tokio::runtime::Handle,
    allow: Arc<RwLock<HashSet<EndpointId>>>,
    lan: Lan,
    relays: Mutex<Vec<RelayUrl>>,
    home_want: Mutex<Vec<RelayUrl>>,
    /// What is in iroh's relay map: only this transport puts anything there.
    home_have: tokio::sync::Mutex<Vec<RelayUrl>>,
    inbound: Mutex<Option<mpsc::UnboundedReceiver<Connection>>>,
    mdns_task: Mutex<Option<tokio::task::JoinHandle<()>>>,
    /// Why mDNS cannot work here, when a send to its group fails (an iOS app without Apple's
    /// multicast entitlement: the sockets open, every send fails, nothing arrives).
    pub nearby_err: Option<String>,
}

impl Transport {
    pub async fn open(secret: iroh::SecretKey, opts: Options, handler: Arc<dyn Handler>, allow: Arc<RwLock<HashSet<EndpointId>>>) -> Result<Transport> {
        // Minimal: no DNS lookup, no pkarr publishing, no relay map. Relays are inserted later,
        // one per helper whose record names it, and never from a default.
        let build = |port: Option<u16>| -> Result<iroh::endpoint::Builder> {
            let quic = iroh::endpoint::QuicTransportConfig::builder().max_idle_timeout(Some(IDLE_TIMEOUT.try_into().map_err(net)?)).keep_alive_interval(KEEP_ALIVE).initial_rtt(INITIAL_RTT).build();
            let mut builder = Endpoint::builder(presets::Minimal)
                .transport_config(quic)
                .secret_key(secret.clone())
                .relay_mode(RelayMode::Custom(RelayMap::empty()))
                .hooks(Gate { allow: allow.clone(), met: opts.met.clone() });
            use iroh::endpoint::BindOpts;
            if !opts.vpn {
                // Only the interfaces the default routes leave through, bound by their own
                // addresses: sends to anywhere from them (prefix 0, default route), and nothing
                // from a VPN. IPv6 beside IPv4, on the same port, where this network has it.
                let primary = crate::helper::primary_ip().filter(|ip| !crate::record::is_vpn(ip)).unwrap_or(std::net::Ipv4Addr::LOCALHOST.into());
                let p = port.unwrap_or(0);
                // Loopback first, non-default: iroh refuses any bind after a default one exists.
                builder = builder.clear_ip_transports();
                if !primary.is_loopback() {
                    builder = builder.bind_addr_with_opts(SocketAddr::new(std::net::Ipv4Addr::LOCALHOST.into(), p), BindOpts::default().set_prefix_len(8).set_is_default_route(false)).map_err(net)?;
                }
                builder = builder
                    .bind_addr_with_opts(SocketAddr::new(primary, p), BindOpts::default().set_prefix_len(0).set_is_default_route(true))
                    .map_err(net)?;
                if let Some(v6) = crate::helper::primary_ip_v6().filter(|ip| !crate::record::is_vpn(ip)) {
                    builder = builder.bind_addr_with_opts(SocketAddr::new(v6, p), BindOpts::default().set_prefix_len(0).set_is_default_route(true).set_is_required(false)).map_err(net)?;
                }
            } else if let Some(port) = port {
                // Both families on the one port, so an address a peer cached for either stays good
                // across restarts. IPv6 only where the port is free on it: iroh's own `[::]:0`
                // (any port, never required) stays otherwise, so IPv6 is never lost to a clash.
                builder = builder.bind_addr(SocketAddr::from(([0, 0, 0, 0], port))).map_err(net)?;
                if port_free_v6(port) {
                    builder = builder.bind_addr_with_opts(SocketAddr::from((std::net::Ipv6Addr::UNSPECIFIED, port)), BindOpts::default().set_is_required(false)).map_err(net)?;
                }
            }
            // Port mappings are the node's (`peer::portmap`): iroh's would take a new external port
            // on every start and never give the old one back.
            builder = builder.portmapper_config(iroh::endpoint::PortmapperConfig::Disabled);
            Ok(builder)
        };
        // No port asked for and none from last time (a first launch): one free on both families,
        // so IPv4 and IPv6 share it from the start and nothing a peer caches moves on the second.
        let endpoint = match opts.port.or(opts.port_hint).or_else(free_port_both) {
            Some(port) => {
                // A port from last time may still be held for a moment by the endpoint that just
                // closed in this process; give it two seconds before settling for an ephemeral one.
                let mut last = None;
                let mut bound = None;
                for _ in 0..10 {
                    match build(Some(port))?.bind().await {
                        Ok(e) => {
                            bound = Some(e);
                            break;
                        }
                        Err(e) => {
                            last = Some(e);
                            tokio::time::sleep(Duration::from_millis(200)).await;
                        }
                    }
                }
                match (bound, opts.port) {
                    (Some(e), _) => e,
                    (None, Some(_)) => return Err(net(last.map(|e| e.to_string()).unwrap_or_default())),
                    (None, None) => {
                        tracing::warn!("port {port} from last time is taken ({}); binding an ephemeral one", last.map(|e| e.to_string()).unwrap_or_default());
                        build(None)?.bind().await.map_err(net)?
                    }
                }
            }
            None => build(None)?.bind().await.map_err(net)?,
        };

        let lan: Lan = Default::default();
        let mut mdns_task = None;
        let mut nearby_err = None;
        if opts.nearby {
            nearby_err = multicast_blocked();
            let mdns = MdnsAddressLookup::builder().service_name(format!("peer-{}", opts.app)).build(endpoint.id()).map_err(net)?;
            endpoint.address_lookup().map_err(net)?.add(mdns.clone());
            mdns_task = Some(tokio::spawn(watch_lan(mdns, lan.clone())));
        }

        let (tx, rx) = mpsc::unbounded_channel();
        let proto = Proto { handler: handler.clone() };
        let mut router = Router::builder(endpoint.clone()).accept(ALPN, proto.clone()).accept(JOIN_ALPN, proto.clone());
        if opts.met.is_some() {
            router = router.accept(BIND_ALPN, proto);
        }
        for alpn in &opts.alpns {
            router = router.accept(alpn.clone(), AppProto { tx: tx.clone() });
        }
        if let Some(blobs) = opts.blobs {
            router = router.accept(iroh_blobs::ALPN, blobs);
        }
        let router = router.spawn();

        // Direct addresses appear once the sockets are up. Never wait on a relay here.
        let mut addrs = endpoint.watch_addr();
        let _ = tokio::time::timeout(Duration::from_millis(300), async {
            while addrs.get().ip_addrs().next().is_none() {
                if addrs.updated().await.is_err() {
                    break;
                }
            }
        })
        .await;
        let rt = tokio::runtime::Handle::current();
        Ok(Transport { id: endpoint.id(), endpoint: RwLock::new(Some(endpoint)), router: Mutex::new(Some(router)), handler, rt, allow, lan, relays: Mutex::new(Vec::new()), home_want: Mutex::new(Vec::new()), home_have: tokio::sync::Mutex::new(Vec::new()), inbound: Mutex::new(Some(rx)), mdns_task: Mutex::new(mdns_task), nearby_err })
    }

    /// The endpoint, or None once `stop` ran (for tasks that may outlive the node's close).
    pub fn try_ep(&self) -> Option<Endpoint> {
        self.endpoint.reading().clone()
    }

    /// The endpoint; panics after `stop`. Only for setup, before `stop` can run: anything that
    /// may finish after it (a probe, a push, a binding call) takes `try_ep`.
    pub fn ep(&self) -> Endpoint {
        self.endpoint.reading().clone().expect("transport stopped")
    }

    pub fn id(&self) -> DeviceId {
        self.id.into()
    }

    /// Where I can be reached; after `stop`, nowhere (my id alone).
    pub fn addr(&self) -> EndpointAddr {
        self.try_ep().map(|ep| ep.addr()).unwrap_or_else(|| EndpointAddr::new(self.id))
    }

    /// The UDP port the endpoint is bound on, what a gateway mapping forwards to and a relay
    /// listens on. Not the first of `addr()`: that may be a public address learnt since, whose
    /// port is the gateway's (a remap took it once and mapped the router to a port nobody held).
    pub fn port(&self) -> Option<u16> {
        let bound = self.try_ep()?.bound_sockets();
        bound.iter().find(|a| a.is_ipv4() && !a.ip().is_loopback() && a.port() != 0).or_else(|| bound.iter().find(|a| a.port() != 0)).map(|a| a.port())
    }

    /// Replace the allow-list: every device of every card I hold.
    pub fn allow(&self, ids: impl IntoIterator<Item = DeviceId>) {
        let mut allow = self.allow.writing();
        allow.clear();
        allow.extend(ids.into_iter().map(EndpointId::from));
    }

    pub fn permit(&self, id: DeviceId) {
        self.allow.writing().insert(id.into());
    }

    pub fn is_allowed(&self, id: DeviceId) -> bool {
        self.allow.reading().contains(&EndpointId::from(id))
    }

    /// A relay a record or a link names: dialed by URL (iroh connects to any), and listed for the
    /// release gate. Not a home candidate: `set_home_relays` decides those.
    pub fn note_relay(&self, url: RelayUrl) {
        let mut relays = self.relays.locked();
        if !relays.contains(&url) {
            relays.push(url);
        }
    }

    /// The relays iroh may home on (its relay map), replacing the last set: the meeting device's
    /// URLs. Concurrent calls converge on the latest set.
    pub async fn set_home_relays(&self, want: Vec<RelayUrl>) {
        for u in &want {
            self.note_relay(u.clone());
        }
        *self.home_want.locked() = want;
        let mut have = self.home_have.lock().await;
        let Some(ep) = self.try_ep() else { return };
        let want = self.home_want.locked().clone();
        for u in have.iter().filter(|u| !want.contains(u)) {
            ep.remove_relay(u).await;
        }
        for u in want.iter().filter(|u| !have.contains(u)) {
            // Our relays serve HTTP only: no QUIC address discovery to wait out before homing.
            ep.insert_relay(u.clone(), Arc::new({ let mut c: iroh::RelayConfig = u.clone().into(); c.quic = None; c })).await;
        }
        *have = want;
    }

    pub fn peer_relays(&self) -> Vec<RelayUrl> {
        self.relays.locked().clone()
    }

    /// The release gate's question: every non-peer host this endpoint could talk to.
    pub fn hosts(&self) -> Vec<String> {
        self.try_ep().map(|ep| crate::policy::hosts(&ep, &self.peer_relays())).unwrap_or_default()
    }

    pub async fn connect(&self, addr: EndpointAddr, alpn: &[u8]) -> Result<Connection> {
        self.connect_within(addr, alpn, CONNECT_TIMEOUT).await
    }

    pub async fn connect_within(&self, addr: EndpointAddr, alpn: &[u8], limit: Duration) -> Result<Connection> {
        // A dial racing `close` finds no endpoint: unreachable, not a panic.
        let ep = self.endpoint.reading().clone().ok_or(Error::Unreachable)?;
        // A relay is the only way in: if every one refuses us, say so now. iroh keeps retrying a
        // relay that denied us, and the dial waited out its whole timeout (a link whose meeting
        // device no longer admits it; a friend homed on a relay whose owner holds no card of ours).
        let relays: Vec<RelayUrl> = if addr.ip_addrs().next().is_none() { addr.relay_urls().cloned().collect() } else { Vec::new() };
        let refused = async {
            if relays.is_empty() || !relays_refuse(&ep, relays).await {
                std::future::pending::<()>().await;
            }
        };
        tokio::select! {
            r = tokio::time::timeout(limit, ep.connect(addr, alpn)) => match r {
                Ok(Ok(conn)) => Ok(conn),
                Ok(Err(e)) => Err(connect_err(e)),
                Err(_) => Err(Error::Unreachable),
            },
            _ = refused => Err(Error::NotInTheirBook),
        }
    }

    /// A Live connection (`LIVE_IDLE`).
    pub async fn connect_live(&self, addr: EndpointAddr, alpn: &[u8]) -> Result<Connection> {
        let ep = self.endpoint.reading().clone().ok_or(Error::Unreachable)?;
        let quic = iroh::endpoint::QuicTransportConfig::builder().max_idle_timeout(Some(LIVE_IDLE.try_into().map_err(net)?)).keep_alive_interval(LIVE_KEEPALIVE).initial_rtt(INITIAL_RTT).build();
        let opts = iroh::endpoint::ConnectOptions::new().with_transport_config(quic);
        let connecting = async { ep.connect_with_opts(addr, alpn, opts).await.map_err(connect_err)?.await.map_err(connect_err) };
        match tokio::time::timeout(LIVE_CONNECT, connecting).await {
            Ok(r) => r,
            Err(_) => Err(Error::Unreachable),
        }
    }

    /// A `peer/1` connection proven admitted: the far gate runs after the handshake, so only a
    /// round trip tells us we are in their book. A 403 close is `NotInTheirBook`, not a timeout.
    pub async fn connect_proven(&self, addr: EndpointAddr) -> Result<Connection> {
        self.connect_proven_timed(addr).await.map(|(c, _)| c)
    }

    /// As `connect_proven`, with how long the handshake alone took.
    pub async fn connect_proven_timed(&self, addr: EndpointAddr) -> Result<(Connection, Duration)> {
        let t = std::time::Instant::now();
        let conn = self.connect(addr, ALPN).await?;
        let handshake = t.elapsed();
        // The handshake measured the round trip: the admission answer is due within a few more.
        // A fixed 5 s let a connection whose path died right after the handshake hold a dial
        // (and the loop's redial behind it) for 5 s.
        let wait = (handshake * 4 + Duration::from_millis(500)).clamp(Duration::from_secs(1), Duration::from_secs(5));
        match tokio::time::timeout(wait, ask(&conn, &Msg::Bind)).await {
            Ok(Ok(_)) => Ok((conn, handshake)),
            Ok(Err(e)) => Err(match conn.close_reason() {
                Some(reason) => connect_err(reason),
                None => e,
            }),
            Err(_) => Err(Error::Unreachable),
        }
    }

    /// A connection to a relay host on `BIND_ALPN`, once it has a direct path (`probe` asks it
    /// `Bind`). None if the host will not have us or no direct path forms in time.
    pub async fn bind_conn(&self, addr: EndpointAddr) -> Option<Connection> {
        let conn = self.connect_within(addr, BIND_ALPN, BIND_CONNECT).await.ok()?;
        let t = std::time::Instant::now();
        while t.elapsed() < BIND_DIRECT_WAIT && conn.close_reason().is_none() {
            if observed(&conn).is_some() {
                return Some(conn);
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        conn.close(0u32.into(), b"no direct path");
        None
    }

    /// Serve `peer/1` on a connection we dialed: the router only serves inbound ones, and the far
    /// side pushes records, cards and envelopes down whichever connection exists.
    pub fn serve(&self, conn: Connection) {
        let handler = self.handler.clone();
        self.rt.spawn(async move { serve(conn, handler).await });
    }

    /// The queue of inbound connections on the app's ALPNs, taken once by the node.
    pub fn take_inbound(&self) -> Option<mpsc::UnboundedReceiver<Connection>> {
        self.inbound.locked().take()
    }

    pub fn nearby(&self) -> Vec<(DeviceId, Vec<SocketAddr>)> {
        self.lan.locked().iter().map(|(id, a)| (DeviceId::from(*id), a.clone())).collect()
    }

    /// Stop serving and release the socket: the mDNS task, the router (and its endpoint clone),
    /// then the endpoint. After this the UDP port is free for the next open.
    pub async fn stop(&self) {
        if let Some(t) = self.mdns_task.locked().take() {
            t.abort();
        }
        let router = self.router.locked().take();
        if let Some(r) = router {
            r.shutdown().await.ok();
            drop(r);
        }
        let ep = self.endpoint.writing().take();
        if let Some(ep) = ep {
            ep.close().await;
            drop(ep);
        }
    }

    pub async fn shutdown(self) {
        self.stop().await;
    }
}

/// The selected path in words, with its round trip. `relay_owner` maps a relay URL to the
/// helper device that advertised it.
pub fn path_of(conn: &Connection, relay_owner: impl Fn(&RelayUrl) -> Option<DeviceId>) -> (Path, Option<u32>) {
    let paths = conn.paths();
    // Right after the handshake no path may be marked selected yet; any open path is the truth then.
    let chosen = paths.iter().find(|p| p.is_selected()).or_else(|| paths.iter().next());
    if let Some(p) = chosen {
        let rtt = Some(p.rtt().as_millis() as u32);
        let path = match p.remote_addr() {
            TransportAddr::Ip(sa) => Path::Direct { vpn: is_vpn(&sa.ip()) },
            TransportAddr::Relay(url) => match relay_owner(url) {
                Some(d) => Path::Relay(d),
                None => Path::Unreachable, // a relay we did not insert cannot exist; say so loudly
            },
            _ => Path::Direct { vpn: false },
        };
        return (path, rtt);
    }
    (Path::Waiting, None)
}

/// The relay URL this connection's chosen path rides, when it is relayed.
pub fn relayed_by(conn: &Connection) -> Option<RelayUrl> {
    let paths = conn.paths();
    match paths.iter().find(|p| p.is_selected()).or_else(|| paths.iter().next())?.remote_addr() {
        TransportAddr::Relay(url) => Some(url.clone()),
        _ => None,
    }
}

/// The address the far side reaches us at on this connection's direct path, if it has one.
pub fn observed(conn: &Connection) -> Option<SocketAddr> {
    let paths = conn.paths();
    let ip = |p: &iroh::endpoint::Path<'_>| match p.remote_addr() {
        TransportAddr::Ip(sa) => Some(*sa),
        _ => None,
    };
    paths.iter().find(|p| p.is_selected()).and_then(|p| ip(&p)).or_else(|| paths.iter().find_map(|p| ip(&p)))
}

fn connect_err(e: impl std::fmt::Display) -> Error {
    let msg = e.to_string();
    if msg.contains("403") || msg.contains("denied") { Error::NotInTheirBook } else { Error::Net(msg) }
}

/// `Conn::open` on an app ALPN maps the same 403 close the same way.
pub(crate) fn stream_err(conn: &Connection, e: impl std::fmt::Display) -> Error {
    match conn.close_reason() {
        Some(reason) => connect_err(reason),
        None => Error::Net(e.to_string()),
    }
}

pub(crate) fn net(e: impl std::fmt::Display) -> Error {
    Error::Net(e.to_string())
}

/// One empty mDNS query (a bare header: no questions, nothing to answer) to the group from a
/// throwaway socket: whether this process may send multicast at all. On iOS that takes
/// `com.apple.developer.networking.multicast`; without it the send fails and mDNS does nothing.
/// One datagram to a peer's LAN address, from a socket of its own: the OS refuses it at once
/// ("no route to host") when this app may not use the local network (iOS asks for it; macOS since
/// 15). Any other answer, an error that is not that or none, is not this app's refusal. Sent only
/// to an address in a record or link of a device we are about to dial, never a stranger's.
pub(crate) fn unicast_refused(to: std::net::SocketAddr) -> bool {
    let bind = if to.is_ipv4() { "0.0.0.0:0" } else { "[::]:0" };
    let Ok(socket) = std::net::UdpSocket::bind(bind) else { return false };
    matches!(socket.send_to(&[0u8], to), Err(e) if e.kind() == std::io::ErrorKind::HostUnreachable)
}

pub(crate) fn multicast_blocked() -> Option<String> {
    let socket = match std::net::UdpSocket::bind("0.0.0.0:0") {
        Ok(s) => s,
        Err(e) => return Some(e.to_string()),
    };
    socket.send_to(&[0u8; 12], ("224.0.0.251", 5353)).err().map(|e| e.to_string())
}

async fn watch_lan(mdns: MdnsAddressLookup, lan: Lan) {
    let mut events = mdns.subscribe().await;
    while let Some(ev) = events.next().await {
        match ev {
            DiscoveryEvent::Discovered { endpoint_info, .. } => {
                let addrs = endpoint_info.data.ip_addrs().copied().collect();
                lan.locked().insert(endpoint_info.endpoint_id, addrs);
            }
            DiscoveryEvent::Expired { endpoint_id } => {
                lan.locked().remove(&endpoint_id);
            }
            _ => {}
        }
    }
}

/// Runs after the TLS handshake: an incoming connection from a device not in the allow-list is
/// closed with 403 unless it speaks the join ALPN. The dialer sees `NotInTheirBook`, not a timeout.
#[derive(Debug)]
struct Gate {
    allow: Arc<RwLock<HashSet<EndpointId>>>,
    met: Option<crate::helper::Met>,
}

impl EndpointHooks for Gate {
    async fn after_handshake(&self, conn: &Connection) -> AfterHandshakeOutcome {
        let incoming = matches!(conn.side(), Side::Server);
        let id = conn.remote_id();
        let admitted = || self.allow.reading().contains(&id) || (conn.alpn() == BIND_ALPN && self.met.as_ref().is_some_and(|m| m.holds(&id)));
        if incoming && conn.alpn() != JOIN_ALPN && !admitted() {
            return AfterHandshakeOutcome::Reject { error_code: 403u32.into(), reason: b"denied".to_vec() };
        }
        AfterHandshakeOutcome::Accept
    }
}

/// `peer/1` and `peer/join/1`: one request and one reply per stream; Bind answered here, the
/// rest by the node's handler.
#[derive(Clone)]
struct Proto {
    handler: Arc<dyn Handler>,
}

impl std::fmt::Debug for Proto {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Proto")
    }
}

impl ProtocolHandler for Proto {
    async fn accept(&self, conn: Connection) -> std::result::Result<(), AcceptError> {
        if conn.alpn() == BIND_ALPN {
            answer_binds(conn).await;
            return Ok(());
        }
        if conn.alpn() == ALPN {
            self.handler.connected(conn.clone());
        }
        serve(conn, self.handler.clone()).await;
        Ok(())
    }
}

/// `peer/bind/1`: `Bind` and nothing else, never the node's handler.
async fn answer_binds(conn: Connection) {
    while let Ok((mut tx, mut rx)) = conn.accept_bi().await {
        let reply = match recv(&mut rx).await {
            Ok(Msg::Bind) => Msg::Bound(observed(&conn)),
            Ok(_) => Msg::No { reason: "bind only".into() },
            Err(_) => continue,
        };
        if send(&mut tx, &reply).await.is_ok() {
            let _ = tx.finish();
        }
    }
}

/// One request and one reply per stream, each on its own task so a waiting reply (a device link
/// confirmation) never blocks the next stream. Runs on both sides of a crate connection.
async fn serve(conn: Connection, handler: Arc<dyn Handler>) {
    let from = DeviceId::from(conn.remote_id());
    let alpn = conn.alpn().to_vec();
    let slots = Arc::new(tokio::sync::Semaphore::new(MAX_ASKS));
    loop {
        let Ok(slot) = slots.clone().acquire_owned().await else { return };
        let (mut tx, mut rx) = match conn.accept_bi().await {
            Ok(s) => s,
            Err(_) => return,
        };
        let msg = match recv(&mut rx).await {
            Ok(m) => m,
            Err(_) => continue,
        };
        let handler = handler.clone();
        let (alpn, conn2) = (alpn.clone(), conn.clone());
        tokio::spawn(async move {
            let _slot = slot;
            let reply = match msg {
                Msg::Bind => Msg::Bound(observed(&conn2)),
                other => handler.handle(from, alpn, other).await,
            };
            if send(&mut tx, &reply).await.is_ok() {
                let _ = tx.finish();
            }
        });
    }
}

/// An endpoint with a fresh key on its own socket, for a dial that must not ride a path the
/// node's endpoint already has to the same device (`probe::dial_back`): no relays, no mapping.
pub async fn throwaway() -> Result<Endpoint> {
    Endpoint::builder(presets::Minimal).relay_mode(RelayMode::Disabled).portmapper_config(iroh::endpoint::PortmapperConfig::Disabled).bind().await.map_err(net)
}

/// Whether a handshake with `id` completes at `at` and nowhere else. Its gate refusing a
/// stranger after the handshake counts: the packets reached its key.
pub async fn handshakes(ep: &Endpoint, id: EndpointId, at: SocketAddr, limit: Duration) -> bool {
    match tokio::time::timeout(limit, ep.connect(EndpointAddr::new(id).with_ip_addr(at), ALPN)).await {
        Ok(Ok(conn)) => {
            conn.close(0u32.into(), b"checked");
            true
        }
        Ok(Err(e)) => matches!(connect_err(e), Error::NotInTheirBook),
        Err(_) => false,
    }
}

/// Whether a relay answers at `url`, admitting `ep`'s key or refusing it.
pub async fn relay_answers(ep: &Endpoint, url: RelayUrl, limit: Duration) -> bool {
    let Ok(dns) = ep.dns_resolver().cloned() else { return false };
    let client = iroh_relay::client::ClientBuilder::new(url, ep.secret_key().clone(), dns).tls_client_config(ep.tls_config().clone());
    match tokio::time::timeout(limit, client.connect()).await {
        Ok(Ok(_)) => true,
        Ok(Err(e)) => denied(&e),
        Err(_) => false,
    }
}

/// How long a relay may take to say whether it admits us.
const REFUSAL_WAIT: Duration = Duration::from_secs(5);

/// Whether every relay refuses us: each is asked once, as iroh asks, and a denial is the relay's
/// answer to who we are, which no retry changes. Unreachable or slow is not a refusal.
async fn relays_refuse(ep: &Endpoint, urls: Vec<RelayUrl>) -> bool {
    let Ok(dns) = ep.dns_resolver().cloned() else { return false };
    let asks: Vec<_> = urls
        .into_iter()
        .map(|url| {
            let client = iroh_relay::client::ClientBuilder::new(url, ep.secret_key().clone(), dns.clone()).tls_client_config(ep.tls_config().clone());
            tokio::spawn(async move { matches!(tokio::time::timeout(REFUSAL_WAIT, client.connect()).await, Ok(Err(e)) if denied(&e)) })
        })
        .collect();
    let mut all = true;
    for a in asks {
        all &= a.await.unwrap_or(false);
    }
    all
}

fn denied(e: &iroh_relay::client::ConnectError) -> bool {
    matches!(e, iroh_relay::client::ConnectError::Handshake { source: iroh_relay::protos::handshake::Error::ServerDeniedAuth { .. }, .. })
}

/// Whether `[::]:port` can be bound now (IPv6 here, and the port not taken on it).
fn port_free_v6(port: u16) -> bool {
    std::net::UdpSocket::bind(SocketAddr::from((std::net::Ipv6Addr::UNSPECIFIED, port))).is_ok()
}

/// A UDP port free on IPv4 and, where this host has IPv6, on IPv6 too. None when no IPv4 port
/// can be had at all (the bind then fails on its own terms).
fn free_port_both() -> Option<u16> {
    let v6_here = std::net::UdpSocket::bind("[::]:0").is_ok();
    let mut last = None;
    for _ in 0..16 {
        let v4 = std::net::UdpSocket::bind("0.0.0.0:0").ok()?;
        let port = v4.local_addr().ok()?.port();
        if !v6_here || port_free_v6(port) {
            return Some(port);
        }
        last = Some(port);
    }
    last
}

/// An app ALPN: the connection goes to the app, identity already verified by the gate.
#[derive(Debug)]
struct AppProto {
    tx: mpsc::UnboundedSender<Connection>,
}

impl ProtocolHandler for AppProto {
    async fn accept(&self, conn: Connection) -> std::result::Result<(), AcceptError> {
        let watch = conn.clone();
        let _ = self.tx.send(conn);
        watch.closed().await;
        Ok(())
    }
}
