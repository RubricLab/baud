//! baud on peer (`Crate.swift` and `Baud.swift`'s event handling): peer opened with baud's
//! ALPN, one connection per device with a stream per frame, peer's envelopes for devices that
//! are away, its blob store for files, and its events turned into the core's.

use std::collections::{HashMap, HashSet};
use std::path::Path as FsPath;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use tokio::sync::mpsc;

use crate::core::{Core, short};
use crate::error::{Error, Result};
use crate::types::*;

/// baud's own protocol on peer's connections. 2 since the wipe: a 0.2.4 device speaks 1, and
/// the two never exchange a frame.
pub const ALPN: &str = "baud/2";

/// Catching a device up after its connection was replaced: at most once per this.
const SETTLE: Duration = Duration::from_secs(10);

pub(crate) struct Net {
    pub peer: peer::Peer,
    conns: Mutex<HashMap<DeviceId, Arc<peer::Conn>>>,
}

/// The app's keystore as peer reads it, its items under `peer-`, as on the Apple apps.
struct Prefixed(Arc<dyn peer::identity::Keychain>);
impl peer::identity::Keychain for Prefixed {
    fn get(&self, item: &str) -> peer::Result<Option<Vec<u8>>> {
        self.0.get(&format!("peer-{item}"))
    }
    fn put(&self, item: &str, bytes: &[u8]) -> peer::Result<()> {
        self.0.put(&format!("peer-{item}"), bytes)
    }
    fn delete(&self, item: &str) -> peer::Result<()> {
        self.0.delete(&format!("peer-{item}"))
    }
}

struct Forward(mpsc::UnboundedSender<peer::Event>);
impl peer::Listener for Forward {
    fn on(&self, e: peer::Event) {
        let _ = self.0.send(e);
    }
}

impl Net {
    pub async fn open(dir: &FsPath, keychain: Arc<dyn peer::identity::Keychain>, c: &Config) -> Result<(Net, mpsc::UnboundedReceiver<peer::Event>)> {
        let mut pc = peer::Config::new("baud", &c.name, &c.device_name);
        pc.link_scheme = "baud://add".into();
        pc.alpns = vec![ALPN.as_bytes().to_vec()];
        pc.nearby = c.nearby;
        pc.portmap = c.portmap;
        pc.relay = c.relay;
        pc.public = c.public;
        pc.vpn = c.vpn;
        pc.device_kind = peer::card::DeviceKind::parse(c.device_kind.as_str());
        let p = peer::Peer::open(dir.join("peer"), Arc::new(Prefixed(keychain)), pc).await.map_err(|e| Error::Failed(format!("peer didn't open: {e}")))?;
        let (tx, rx) = mpsc::unbounded_channel();
        p.subscribe(Arc::new(Forward(tx)));
        Ok((Net { peer: p, conns: Mutex::new(HashMap::new()) }, rx))
    }

    fn status(&self, d: &str) -> Option<peer::PeerStatus> {
        let id = peer::identity::DeviceId::from_hex(d).ok()?;
        self.peer.peers().into_iter().find(|s| s.device == id)
    }
    pub fn is_online(&self, d: &str) -> bool {
        self.status(d).map(|s| s.online).unwrap_or(false)
    }
    pub fn rtt(&self, d: &str) -> Option<u32> {
        self.status(d).and_then(|s| s.rtt_ms)
    }
    /// A device went away: its connection is dead, dial afresh next time.
    pub fn forget(&self, d: &str) {
        self.conns.lock().unwrap().remove(d);
    }

    /// The file into peer's blob store, by reference where it can: its blake3 is the id.
    pub async fn provide(&self, file: &FsPath) -> Option<String> {
        self.peer.blobs().add_path(file).await.ok().map(|h| h.to_hex())
    }

    /// peer fetches, verifies as it goes, retries on its own budget, and exports to `to`.
    pub async fn fetch(&self, id: &str, from: &str, to: &FsPath) -> bool {
        let (Ok(d), Ok(h)) = (peer::identity::DeviceId::from_hex(from), peer::blobs::Hash::from_hex(id)) else { return false };
        let Ok(t) = self.peer.blobs().fetch(d, h, to, None).await else { return false };
        let started = Instant::now();
        loop {
            match t.state() {
                peer::blobs::TransferState::Done => return to.exists(),
                peer::blobs::TransferState::Cancelled | peer::blobs::TransferState::Failed => return false,
                _ if started.elapsed() > Duration::from_secs(600) => {
                    t.cancel();
                    return false;
                }
                _ => tokio::time::sleep(Duration::from_millis(150)).await,
            }
        }
    }
}

impl Core {
    /// Over a live connection, now: a stream per frame, length-prefixed, delivered or not.
    pub(crate) async fn send_to(&self, bytes: &[u8], d: &str) -> bool {
        if self.is_closed() {
            return false;
        }
        let r: peer::Result<()> = async {
            let cached = self.net.conns.lock().unwrap().get(d).cloned();
            let c = match cached {
                Some(c) => c,
                None => {
                    let id = peer::identity::DeviceId::from_hex(d)?;
                    let c = Arc::new(self.net.peer.connect(id, peer::policy::Class::Small, ALPN.as_bytes()).await?);
                    self.net.conns.lock().unwrap().insert(d.to_owned(), c.clone());
                    self.serve(c.clone(), d.to_owned());
                    c
                }
            };
            let mut s = c.open().await?;
            let mut framed = (bytes.len() as u32).to_be_bytes().to_vec();
            framed.extend_from_slice(bytes);
            s.send(&framed).await?;
            s.delivered().await
        }
        .await;
        match r {
            Ok(()) => true,
            Err(e) => {
                self.log(format!("send to {} failed: {e}", short(d)));
                self.net.forget(d);
                false
            }
        }
    }

    /// An inbound connection: keep it, either side opens streams on it from here on.
    fn accept(&self, conn: peer::ConnId) {
        let Ok(c) = self.net.peer.accept(conn) else {
            self.log(format!("accept {} failed", conn.0));
            return;
        };
        let from = c.identity().device.to_hex();
        self.log(format!("inbound from {}", short(&from)));
        let c = Arc::new(c);
        self.net.conns.lock().unwrap().insert(from.clone(), c.clone());
        self.serve(c, from);
    }

    /// Read every stream the other side opens on a connection, dialed or accepted, in order,
    /// until it closes.
    fn serve(&self, c: Arc<peer::Conn>, from: String) {
        let core = self.arc();
        self.spawn(async move {
            while let Ok(mut s) = c.accept_stream().await {
                let mut buf: Vec<u8> = vec![];
                let read = tokio::time::timeout(Duration::from_secs(60), async {
                    while let Ok(Some(d)) = s.recv(1 << 20).await {
                        buf.extend_from_slice(&d);
                    }
                })
                .await;
                if read.is_err() {
                    core.log(format!("a stream from {} stalled", short(&from)));
                }
                let mut off = 0;
                while buf.len() - off >= 4 {
                    let n = u32::from_be_bytes(buf[off..off + 4].try_into().unwrap()) as usize;
                    if buf.len() - off - 4 < n {
                        break;
                    }
                    core.receive_bytes(&buf[off + 4..off + 4 + n], &from, None);
                    off += 4 + n;
                }
            }
            let mut conns = core.net.conns.lock().unwrap();
            if conns.get(&from).map(|x| Arc::ptr_eq(x, &c)).unwrap_or(false) {
                conns.remove(&from);
            }
        });
    }

    /// Every minute, my clocks to every device I hold a live connection to: a frame that was
    /// sent and never opened (a key not there yet, a stream cut short) is sent again.
    pub(crate) fn resync_loop(&self) {
        let weak = self.this.clone();
        self.spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(60)).await;
                let Some(core) = weak.upgrade().filter(|c| !c.is_closed()) else { return };
                for s in core.net.peer.peers() {
                    if s.online {
                        core.connected(&s.device.to_hex());
                    }
                }
            }
        });
    }

    fn resync_due(&self, d: &str) -> bool {
        let mut st = self.st();
        if st.resynced.get(d).map(|t| t.elapsed() < SETTLE).unwrap_or(false) {
            return false;
        }
        st.resynced.insert(d.to_owned(), Instant::now());
        true
    }

    fn set_live(&self, d: &str) {
        let Some(s) = self.net.status(d) else { return };
        let p = self.path_of(&s.path, s.rtt_ms);
        self.st().live.insert(d.to_owned(), (s.online, p));
        if !s.online {
            self.store.run("update devices set last_online=? where id=?", &[&crate::store::now(), &d]);
        }
        self.emit(Change::Peers);
        self.emit(Change::Contacts);
        self.emit(Change::Conversations);
    }

    /// One of peer's events, in order, off peer's thread.
    fn on(&self, e: peer::Event) {
        use peer::Event as E;
        match e {
            E::Dialing(d) => {
                // A dial began to a device not connected: it is being reached, not away.
                let d = d.to_hex();
                if !self.net.is_online(&d) {
                    self.st().live.insert(d, (false, Path::Waiting));
                    self.emit(Change::Peers);
                }
            }
            E::Reached(d) => {
                self.log(format!("reached {}", short(&d.to_hex())));
                self.emit(Change::Reached { device: d.to_hex() });
            }
            E::Online(d) => {
                let d = d.to_hex();
                self.set_live(&d);
                self.log(format!("online {}", short(&d)));
                self.connected(&d);
                // The chats I share my location in that it's part of get my latest fix now.
                self.places_on_connect(&d);
            }
            E::Offline(d) => {
                let d = d.to_hex();
                self.set_live(&d);
                self.log(format!("offline {}", short(&d)));
                self.net.forget(&d);
            }
            E::PathChanged(d) => {
                // A new connection replaced the held one (the other side relaunched, woke,
                // moved): what went down the old one in the gap may never have arrived. A fresh
                // connection for the next frame, and the clocks, at most once per settle.
                let d = d.to_hex();
                self.set_live(&d);
                self.net.forget(&d);
                if self.net.is_online(&d) && self.resync_due(&d) {
                    self.log(format!("reconnected {}", short(&d)));
                    self.connected(&d);
                    self.places_on_connect(&d);
                }
            }
            // The same connection, a new path (a punch landed, or a failover kept it): only how
            // they're reached changes; nothing was lost, so no fresh connection and no resync.
            E::PathMoved(d) => self.set_live(&d.to_hex()),
            E::ContactsChanged => {
                let before: HashSet<String> = self.contacts().into_iter().map(|c| c.user).collect();
                self.adopt_contacts();
                self.emit(Change::Contacts);
                let fresh: Vec<Contact> = self.contacts().into_iter().filter(|c| !before.contains(&c.user)).collect();
                // A new contact gets my card with peer's card inside (and sends theirs), so either
                // of us can later admit the other into a group for a third person.
                for c in &fresh {
                    self.announce(&c.user);
                }
                // The inviter opens the chat; the other side receives it. I'm the inviter of whoever
                // redeemed my invite, and of whoever answered my link with a reply I opened.
                for c in &fresh {
                    let mine = {
                        let mut st = self.st();
                        let answered = st.answered.remove(&c.user);
                        let invited = !answered && std::mem::take(&mut st.invited);
                        answered || invited
                    };
                    if mine {
                        self.log(format!("inviter opens a chat with {}", c.name));
                        let _ = self.create_chat(&[c.user.clone()]);
                    }
                }
            }
            E::MeChanged => {
                let before: HashSet<String> = self.me().devices.into_iter().map(|d| d.id).collect();
                self.adopt_identity();
                self.emit(Change::Me);
                // A device just became mine: offer it my clocks now.
                let me = self.me();
                for d in me.devices {
                    if !before.contains(&d.id) && d.id != me.this_device && self.net.is_online(&d.id) {
                        self.connected(&d.id);
                    }
                }
            }
            E::Inbound { conn, alpn } => {
                if alpn == ALPN {
                    self.accept(conn);
                }
            }
            E::Inbox(_) => {
                self.drain_inbox();
                self.emit(Change::Carrying);
            }
            E::Delivered(_) => {
                self.emit(Change::Peers);
                self.emit(Change::Carrying);
            }
            E::LinkRequest(r) => {
                let (Ok(code), Ok(device), Ok((name, kind))) = (self.net.peer.link_code(r), self.net.peer.link_request(r), self.net.peer.link_request_device(r)) else { return };
                self.emit(Change::LinkRequest { req: r.0, code, device: device.to_hex(), name, kind: DeviceKind::parse(kind.as_str()) });
            }
            E::NetworkChanged | E::ReachabilityChanged(_) => {
                self.emit(Change::Network);
                self.emit(Change::Peers);
            }
            E::RecordChanged(_) => self.emit(Change::Peers),
            E::Removed => {
                self.log("removed by another of my devices");
                self.emit(Change::Removed);
            }
            E::ContactRemoved(u) => {
                // They removed me: they and our chat are simply gone here, no line about it.
                self.log(format!("unfriended by {}", short(&u.to_hex())));
                self.forget_friend(&u.to_hex());
            }
            E::Replied(u) => {
                // The maker of a link I answered opened my reply: we met (ContactsChanged comes too).
                self.log(format!("replied: met {}", short(&u.to_hex())));
                self.adopt_contacts();
                self.emit(Change::Replied { user: u.to_hex() });
            }
            E::ReplyLapsed(u) => {
                self.log(format!("reply lapsed for {}", short(&u.to_hex())));
                self.emit(Change::ReplyLapsed { user: u.to_hex() });
            }
            E::ContactRedirected { from, to } => {
                self.log(format!("redirect {} → {}", short(&from.to_hex()), short(&to.to_hex())));
                self.adopt_contacts();
                self.redirect(&from.to_hex(), &to.to_hex());
            }
        }
    }

    /// This device on the network. Online: the internet reaches it (its router holds a port for
    /// it, it runs a relay others reach, or a punch gets through). Else through the meeting
    /// device, one of mine or a friend's, while I hold a live connection to it; else not
    /// reachable, naming the one I am not connected to.
    pub fn net_state(&self) -> NetState {
        if !self.is_online() {
            return NetState::Offline;
        }
        let p = &self.net.peer;
        let m = p.invite_meeting();
        let me = self.device();
        if m.device.map(|d| d.to_hex()) == Some(me) || p.mapped().is_some() || p.reachable() == peer::probe::Reachable::Yes {
            return NetState::Online;
        }
        let Some(d) = m.device.filter(|_| m.kind != peer::MeetingKind::None) else { return NetState::NotReachable { away: None } };
        let own = m.kind == peer::MeetingKind::Own;
        let name = if own { device_name(&m.device_name) } else { format!("{}'s {}", m.user_name.split(' ').next().unwrap_or(""), device_name(&m.device_name)) };
        if self.net.is_online(&d.to_hex()) { NetState::Through { name, own } } else { NetState::NotReachable { away: Some(if own { format!("your {name}") } else { name }) } }
    }
}

/// The short device name the pictures show: "Mac mini", not "Ana's Mac mini".
fn device_name(name: &str) -> String {
    let n = name.replace('\u{2019}', "'");
    let n = n.split_once("'s ").map(|(_, r)| r.to_owned()).unwrap_or(n);
    if n.chars().count() > 14 {
        let c: Vec<char> = n.chars().collect();
        format!("{}…{}", c[..7].iter().collect::<String>(), c[c.len() - 6..].iter().collect::<String>())
    } else {
        n
    }
}

/// peer's events, one at a time, on the core's runtime.
pub(crate) fn listen(core: &Arc<Core>, mut rx: mpsc::UnboundedReceiver<peer::Event>) {
    let weak = Arc::downgrade(core);
    core.rt.spawn(async move {
        while let Some(e) = rx.recv().await {
            let Some(core) = weak.upgrade().filter(|c| !c.is_closed()) else { return };
            // The handlers touch SQLite and peer's locks: off the async workers.
            let _ = tokio::task::spawn_blocking(move || core.on(e)).await;
        }
    });
}
