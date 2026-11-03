//! One device (`LocalCore.swift` and the apps' `Baud.swift` in one): identity, cards and
//! presence are peer's; feeds, conversations, sealing and delivery are here, in SQLite, as real
//! rows. Every method answers truthfully for what this device knows.

use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::path::{Path as FsPath, PathBuf};
use std::sync::{Arc, Mutex, Weak};
use std::time::Instant;

use rusqlite::types::ToSql;

use crate::error::{Error, Result};
use crate::files::BlobWait;
use crate::ids::{event_id, fingerprint as card_fingerprint, home_id, new_conversation_id};
use crate::json::{decode, encode};
use crate::net::Net;
use crate::sentences;
use crate::store::{Row, Store, now};
use crate::types::*;
use crate::wire::*;

/// Mutable state that isn't rows. Held briefly, never across a store call or a listener.
#[derive(Default)]
pub(crate) struct State {
    pub device: DeviceId,
    pub user: UserId,
    pub name: String,
    pub online: bool,
    pub typing_seen: HashMap<ConversationId, HashMap<UserId, Instant>>,
    /// Online state and path per device as peer reports it.
    pub live: HashMap<DeviceId, (bool, Path)>,
    /// Sealed packets for a conversation whose key hasn't arrived yet.
    pub waiting_for_key: Vec<(ConversationId, Vec<u8>, DeviceId, Option<DeviceId>)>,
    /// Files being asked for from other devices, and devices that asked me for one I lacked.
    pub blob_waits: HashMap<BlobHash, BlobWait>,
    pub wanted_by: HashMap<BlobHash, HashSet<DeviceId>>,
    /// peer's cards, mine and everyone's I have met or share a conversation with.
    pub my_peer_card: Option<Vec<u8>>,
    pub peer_cards: HashMap<UserId, Vec<u8>>,
    /// An invite of mine is out: the next new contact is the one who redeemed it.
    pub invited: bool,
    /// The people whose reply to my link I opened: when one arrives as a new contact, I'm their
    /// inviter and open the chat. A reply from someone already a friend leaves only their entry.
    pub answered: HashSet<UserId>,
    /// Groups given their tier in peer this run.
    pub made: HashSet<ConversationId>,
    /// Catching a device up after its connection was replaced: at most once per settle.
    pub resynced: HashMap<DeviceId, Instant>,
    /// When I last asked the wake relay for a device, by device and kind (wake.rs).
    pub last_wake: HashMap<String, Instant>,
    /// Where the people sharing with me are, by chat and person; my own latest fix (places.rs).
    pub held_places: HashMap<ConversationId, HashMap<UserId, WirePlace>>,
    pub last_fix: Option<(f64, f64, f64, f64)>,
    pub trace: VecDeque<String>,
    /// The sweep that waits for the next disappearing message due to go, and when (disappear.rs).
    pub expiry_task: Option<tokio::task::JoinHandle<()>>,
    pub expiry_due: Option<f64>,
}

type Callback = Arc<dyn Fn(Change) + Send + Sync>;

pub struct Core {
    pub(crate) this: Weak<Core>,
    pub(crate) dir: PathBuf,
    pub(crate) store: Store,
    pub(crate) st: Mutex<State>,
    listeners: Mutex<(u64, BTreeMap<u64, Callback>)>,
    pub(crate) net: Net,
    pub(crate) rt: tokio::runtime::Handle,
    pub(crate) config: Config,
    /// `close` ran: nothing more goes to peer (its transport is gone); what was written stays in
    /// the store and goes out from the next open, by the clocks.
    pub(crate) closed: std::sync::atomic::AtomicBool,
}

/// What the timeline shows: messages and the lines for joins, names and creation, not threads'
/// replies, nothing redacted or gone (a message whose body is '{}'), never my settings.
const TIMELINE: &str = "select * from events where conv=? and type in ('message','member','state','create') and thread is null and id not in (select target from events where conv=? and type='redact' and target is not null) and not (type='state' and body like '%\"key\":\"profile.%') and not (type='message' and body='{}')";

impl Core {
    /// Open or create: peer first (the identity is its), then the store, then the network's
    /// events. Under a second; nothing here waits on another device.
    pub async fn open(dir: PathBuf, keychain: Arc<dyn peer::identity::Keychain>, config: Config) -> Result<Arc<Core>> {
        std::fs::create_dir_all(dir.join("blobs"))?;
        let (net, events) = Net::open(&dir, keychain, &config).await?;
        let store = Store::open(Some(&dir.join("baud.sqlite")))?;
        let core = Arc::new_cyclic(|this| Core {
            this: this.clone(),
            dir,
            store,
            st: Mutex::new(State::default()),
            listeners: Mutex::new((0, BTreeMap::new())),
            net,
            rt: tokio::runtime::Handle::current(),
            config,
            closed: Default::default(),
        });
        core.wipe_legacy();
        // The name typed before peer was up goes onto its card now.
        if core.net.peer.me().name.is_empty() && !core.config.name.is_empty() {
            let _ = core.net.peer.set_name(&core.config.name);
        }
        core.adopt_identity();
        core.adopt_contacts();
        // What came due while baud was closed goes now; the rest waits for its time.
        core.expire(now());
        // Redirects that came while the app was closed.
        for r in core.net.peer.redirects() {
            core.redirect(&r.from.to_hex(), &r.to.to_hex());
        }
        core.st().my_peer_card = Some(core.net.peer.card().to_bytes());
        crate::net::listen(&core, events);
        core.net.peer.set_online(true);
        core.drain_inbox();
        core.resync_loop();
        let me = core.me();
        core.log(format!("baud {} open: {}… on {}…", crate::version(), short(&me.user), short(&me.this_device)));
        Ok(core)
    }

    pub(crate) fn st(&self) -> std::sync::MutexGuard<'_, State> {
        self.st.lock().unwrap_or_else(|e| e.into_inner())
    }
    pub(crate) fn arc(&self) -> Arc<Core> {
        self.this.upgrade().expect("core alive")
    }
    pub(crate) fn device(&self) -> DeviceId {
        self.st().device.clone()
    }
    pub(crate) fn user(&self) -> UserId {
        self.st().user.clone()
    }
    pub(crate) fn is_online(&self) -> bool {
        self.st().online && !self.is_closed()
    }
    pub(crate) fn is_closed(&self) -> bool {
        self.closed.load(std::sync::atomic::Ordering::SeqCst)
    }
    pub(crate) fn spawn<F: std::future::Future<Output = ()> + Send + 'static>(&self, f: F) {
        self.rt.spawn(f);
    }

    /// The core's own trace line: kept for `trace()`, and to stderr when `BAUD_LOG` is set.
    pub(crate) fn log(&self, line: impl Into<String>) {
        let line = line.into();
        if std::env::var_os("BAUD_LOG").is_some() {
            eprintln!("baud: {line}");
        }
        tracing::debug!("{line}");
        let mut st = self.st();
        st.trace.push_back(format!("{{\"at\":{},\"baud\":{}}}", sentences::now_ms(), encode(&line)));
        while st.trace.len() > 512 {
            st.trace.pop_front();
        }
    }

    /// Once per store, before wire 2: every message goes (0.2.4 and before left each device with
    /// different ones). A new store has none; this only marks it.
    fn wipe_legacy(&self) {
        if self.store.one("select v from me where k='epoch'", &[]).and_then(|r| r.string("v")) == Some(WIRE_VERSION.to_string()) {
            return;
        }
        self.store.wipe_messages();
        self.store.run("insert or replace into me(k,v) values('epoch',?)", &[&WIRE_VERSION.to_string()]);
    }

    pub fn subscribe(&self, f: Box<dyn Fn(Change) + Send + Sync>) -> u64 {
        let mut l = self.listeners.lock().unwrap();
        l.0 += 1;
        let id = l.0;
        l.1.insert(id, Arc::from(f));
        id
    }
    pub fn unsubscribe(&self, id: u64) {
        self.listeners.lock().unwrap().1.remove(&id);
    }
    pub(crate) fn emit(&self, c: Change) {
        let ls: Vec<Callback> = self.listeners.lock().unwrap().1.values().cloned().collect();
        for l in ls {
            l(c.clone());
        }
    }

    // MARK: me and my devices

    pub fn me(&self) -> Person {
        let (user, name, device) = {
            let s = self.st();
            (s.user.clone(), s.name.clone(), s.device.clone())
        };
        let fp = peer::identity::UserId::from_hex(&user).map(|u| peer::identity::fingerprint(&u)).unwrap_or_default();
        let avatar = self.store.one("select avatar from people where user=?", &[&user]).and_then(|r| r.string("avatar"));
        Person { devices: self.devices_of(&user), user, name, fingerprint: fp, this_device: device, avatar }
    }

    /// A new name, on peer's card and on mine, told to everyone who knows me.
    pub fn set_name(&self, new: &str) -> Result<()> {
        let n = new.trim();
        if n.is_empty() {
            return Ok(());
        }
        self.net.peer.set_name(n).map_err(|e| Error::from_peer(e, "", true))?;
        let user = {
            let mut s = self.st();
            s.name = n.to_owned();
            s.user.clone()
        };
        let now = now();
        self.store.run("insert or replace into me(k,v) values('name',?)", &[&n]);
        self.store.run(
            "insert or replace into people(user,name,fingerprint,verified,contact,met_at,avatar,peer_card) values(?,?,?,1,0,coalesce((select met_at from people where user=?),?),(select avatar from people where user=?),(select peer_card from people where user=?))",
            &[&user, &n, &card_fingerprint(&user), &user, &now, &user, &user],
        );
        self.st().my_peer_card = Some(self.net.peer.card().to_bytes());
        self.tell(Frame::Card(self.card()));
        self.emit(Change::Me);
        self.emit(Change::Contacts);
        self.emit(Change::Conversations);
        Ok(())
    }

    /// A photo onto my card: stored as a blob, its hash on the card, told to everyone.
    pub fn set_avatar(&self, path: &str) -> Result<()> {
        let a = self.add_blob(FsPath::new(path))?;
        self.store.run("update people set avatar=? where user=?", &[&a.hash, &self.user()]);
        self.tell(Frame::Card(self.card()));
        self.emit(Change::Me);
        self.emit(Change::Contacts);
        Ok(())
    }

    pub fn link_device(&self) -> Result<Link> {
        let url = self.net.peer.link_device().map(|l| self.net.peer.link_url(&l)).map_err(|e| Error::from_peer(e, "", true))?;
        crate::link::parse_url(&url).ok_or(Error::BadLink)
    }

    /// This device becomes that person's: peer copies the identity once the other device
    /// confirms; then my devices sync everything over.
    pub async fn link(&self, url: &str) -> Result<()> {
        let l = crate::link::parse_code(url).ok_or(Error::BadLink)?;
        let pl = peer::link::parse(&l.url).map_err(|_| Error::BadLink)?;
        self.net.peer.link(&pl, &self.config.device_name).await.map_err(|e| Error::from_peer(e, &l.name, true))?;
        self.adopt_identity();
        self.adopt_contacts();
        self.emit(Change::Me);
        self.emit(Change::Conversations);
        self.emit(Change::Peers);
        Ok(())
    }

    pub fn joining_code(&self, url: &str) -> Option<String> {
        let l = crate::link::parse_code(url)?;
        peer::link::parse(&l.url).ok().map(|pl| self.net.peer.joining_code(&pl))
    }

    pub fn confirm_link(&self, req: u64, accept: bool) {
        let _ = self.net.peer.confirm_link(peer::LinkReqId(req), accept);
    }

    /// One of my devices leaves: peer drops it from my card and tells it; my card here too.
    pub fn revoke(&self, dev: &str) -> Result<()> {
        if dev == self.device() {
            return Err(Error::NotFound);
        }
        if let Ok(d) = peer::identity::DeviceId::from_hex(dev) {
            self.net.peer.remove_device(d).map_err(|e| Error::from_peer(e, "", true))?;
        }
        self.store.run("delete from devices where id=? and user=?", &[&dev, &self.user()]);
        self.tell(Frame::Card(self.card()));
        self.emit(Change::Me);
        self.emit(Change::Peers);
        Ok(())
    }

    // MARK: contacts

    pub fn invite(&self) -> Result<Link> {
        let url = self.net.peer.invite().map(|l| self.net.peer.link_url(&l)).map_err(|e| Error::from_peer(e, "", false))?;
        self.st().invited = true;
        crate::link::parse_url(&url).ok_or(Error::BadLink)
    }

    /// Redeem a friend link, or open a reply to one of mine (then I'm the inviter, and the
    /// inviter opens the chat).
    pub async fn add(&self, url: &str) -> Result<Contact> {
        let l = crate::link::parse_code(url).ok_or(Error::BadLink)?;
        if l.kind == LinkKind::Device {
            return Err(Error::BadLink);
        }
        let pl = peer::link::parse(&l.url).map_err(|_| Error::BadLink)?;
        // A reply answers my link: I'm their inviter, and the inviter opens the chat when they
        // arrive as a new contact (ContactsChanged, net.rs), as after an invite of mine.
        if l.kind == LinkKind::Reply {
            self.st().answered.insert(pl.user.to_hex());
        }
        let c = self.net.peer.add(&pl).await.map_err(|e| Error::from_peer(e, &l.name, false))?;
        let user = c.user.to_hex();
        // Whichever sees them first opens the chat: ContactsChanged, or here, when this side
        // adopted them before that event looked for new contacts (a race, under load).
        if l.kind == LinkKind::Reply && self.st().answered.remove(&user) {
            self.adopt_contacts();
            self.announce(&user);
            let _ = self.create_chat(&[user.clone()]);
        }
        self.adopt_contacts();
        self.contacts().into_iter().find(|k| k.user == user).ok_or(Error::NotFound)
    }

    /// A friend link that isn't getting through from here: my answer, for its maker to open (or
    /// scan); this device keeps dialing theirs until they do (`Change::Replied`) or it lapses.
    pub fn reply(&self, url: &str) -> Result<Link> {
        let l = crate::link::parse_code(url).ok_or(Error::BadLink)?;
        if l.kind != LinkKind::Friend {
            return Err(Error::BadLink);
        }
        let pl = peer::link::parse(&l.url).map_err(|_| Error::BadLink)?;
        let r = self.net.peer.reply(&pl).map_err(|e| Error::from_peer(e, &l.name, false))?;
        self.log(format!("answered {}'s link, waiting for it to be opened", l.name));
        crate::link::parse_url(&self.net.peer.link_url(&r)).ok_or(Error::BadLink)
    }

    pub fn contacts(&self) -> Vec<Contact> {
        let me = self.user();
        self.store
            .query("select * from people where contact=1 and user<>? order by name collate nocase", &[&me])
            .into_iter()
            .map(|r| {
                let u = r.string("user").unwrap_or_default();
                let devices = self.devices_of(&u);
                Contact {
                    name: r.string("name").unwrap_or_default(),
                    verified: r.bool("verified"),
                    fingerprint: r.string("fingerprint").unwrap_or_default(),
                    met_at: r.ms("met_at").unwrap_or_else(sentences::now_ms),
                    avatar: r.string("avatar"),
                    vouched: r.bool("vouched"),
                    online: devices.iter().any(|d| d.online),
                    last_online: devices.iter().filter_map(|d| d.last_online).max(),
                    sentence: sentences::contact(&devices),
                    devices,
                    user: u,
                }
            })
            .collect()
    }

    pub fn verify(&self, u: &str, fp: &str) -> Result<bool> {
        let user = peer::identity::UserId::from_hex(u).map_err(|_| Error::NotFound)?;
        let ok = self.net.peer.verify(user, fp.trim()).map_err(|e| Error::from_peer(e, "", false))?;
        if ok {
            self.adopt_contacts();
            self.store.run("update people set verified=1 where user=?", &[&u]);
            self.emit(Change::Contacts);
        }
        Ok(ok)
    }

    /// No longer friends: peer tells them; they and our chat leave this device's lists.
    pub fn unfriend(&self, u: &str) -> Result<()> {
        if let Ok(user) = peer::identity::UserId::from_hex(u) {
            let _ = self.net.peer.remove(user);
        }
        self.forget_friend(u);
        Ok(())
    }

    pub(crate) fn forget_friend(&self, u: &str) {
        self.store.run("update people set contact=0 where user=?", &[&u]);
        let direct = self.store.query(
            "select c.id from conversations c where c.kind='chat' and c.name is null and (select count(*) from members m where m.conv=c.id)=2 and exists(select 1 from members m where m.conv=c.id and m.user=?)",
            &[&u],
        );
        for r in direct {
            if let Some(id) = r.string("id") {
                self.hide(&id);
            }
        }
        self.emit(Change::Contacts);
        self.emit(Change::Peers);
        self.emit(Change::Conversations);
    }

    // MARK: conversations

    pub fn conversations(&self, kind: Option<Kind>) -> Vec<Conversation> {
        let me = self.user();
        let rows = match kind {
            Some(k) => self.store.query("select c.* from conversations c join members m on m.conv=c.id where m.user=? and c.kind=?", &[&me, &k.as_str()]),
            None => self.store.query("select c.* from conversations c join members m on m.conv=c.id where m.user=? and c.kind<>'home'", &[&me]),
        };
        let shown: Vec<Row> = rows
            .into_iter()
            .filter(|r| {
                let Some(id) = r.string("id") else { return false };
                match self.cutoff("hidden:", &id) {
                    None => true,
                    Some(cut) => self.store.int("select coalesce(max(lamport),0) as n from events where conv=? and type='message' and body<>'{}'", &[&id]) > cut,
                }
            })
            .collect();
        let mut out = self.collapse(shown.iter().map(|r| self.conversation_of(r)).collect());
        out.sort_by(|a, b| b.last_at.cmp(&a.last_at));
        out
    }

    /// Deleting a chat here: it leaves the list until a message newer than the deletion
    /// arrives (the friend stays a friend). A group is left first, which tells its members.
    pub fn delete(&self, conv: &str) -> Result<()> {
        let c = self.conversation(conv).ok_or(Error::NotFound)?;
        if c.kind == Kind::Home {
            self.clear(conv);
            return Ok(());
        }
        if !c.is_direct {
            let _ = self.leave(conv);
        }
        self.hide(conv);
        self.emit(Change::Conversations);
        Ok(())
    }

    /// Hidden here and on every other device of mine: the cutoff travels as a state line in my
    /// chat with myself, like the colour.
    fn hide(&self, conv: &str) {
        let l = self.store.int("select coalesce(max(lamport),0) as n from events where conv=?", &[&conv]);
        self.store.run("insert or replace into me(k,v) values(?,?)", &[&format!("hidden:{conv}"), &l.to_string()]);
        self.set_profile(&format!("hidden.{conv}"), &l.to_string());
    }

    /// Clearing my chat with myself: its lines before now leave this device's view.
    pub fn clear(&self, conv: &str) {
        let l = self.store.int("select coalesce(max(lamport),0) as n from events where conv=?", &[&conv]);
        self.store.run("insert or replace into me(k,v) values(?,?)", &[&format!("cleared:{conv}"), &l.to_string()]);
        self.set_profile(&format!("cleared.{conv}"), &l.to_string());
        self.emit(Change::Conversation { id: conv.into() });
        self.emit(Change::Conversations);
    }

    /// A cutoff from another device of mine: the later of the two wins.
    fn raise(&self, key: &str, conv: &str, l: i64) {
        if self.cutoff(key, conv).unwrap_or(-1) < l {
            self.store.run("insert or replace into me(k,v) values(?,?)", &[&format!("{key}{conv}"), &l.to_string()]);
        }
    }
    fn cutoff(&self, key: &str, conv: &str) -> Option<i64> {
        self.store.one("select v from me where k=?", &[&format!("{key}{conv}")]).and_then(|r| r.string("v")).and_then(|v| v.parse().ok())
    }

    /// My settings that follow me to my other devices (the colour): a state line in my chat
    /// with myself, never shown in it; the latest one wins everywhere.
    pub fn set_profile(&self, key: &str, value: &str) {
        let Some(home) = self.notes().map(|c| c.id) else { return };
        let _ = self.write(&home, EventType::State, encode(&StateBody { key: format!("profile.{key}"), value: value.into() }), None, None, None, None);
    }

    pub fn profile(&self, key: &str) -> Option<String> {
        let home = home_id(&self.user());
        // The last one set, by when: a device that picks before it has caught up with my
        // others writes below their clock, and by clock alone their older pick took it back.
        self.store
            .one("select body from events where conv=? and type='state' and body like ? order by at desc, lamport desc, id desc limit 1", &[&home, &format!("%\"profile.{key}\"%")])
            .and_then(|r| r.string("body"))
            .and_then(|b| decode::<StateBody>(&b))
            .map(|b| b.value)
    }

    /// My chat with myself: the home conversation every device of mine holds.
    pub fn notes(&self) -> Option<Conversation> {
        let user = self.user();
        if user.is_empty() {
            return None;
        }
        let id = home_id(&user);
        self.ensure(&id, Kind::Home, None, None, &user, false, now());
        self.store.one("select * from conversations where id=?", &[&id]).map(|r| self.conversation_of(&r))
    }

    /// A direct chat is keyed by the other person's key, never by a name. When two exist for
    /// the same pair (both sides opened one before seeing the other's), the one with the
    /// smaller id is the chat on both sides, and the other's messages show inside it.
    fn collapse(&self, cs: Vec<Conversation>) -> Vec<Conversation> {
        let me = self.user();
        let mut direct: BTreeMap<UserId, Vec<Conversation>> = BTreeMap::new();
        let mut out = vec![];
        for c in cs {
            match c.members.iter().find(|m| **m != me) {
                Some(other) if c.is_direct => direct.entry(other.clone()).or_default().push(c),
                _ => out.push(c),
            }
        }
        for (_, group) in direct {
            if group.len() == 1 {
                out.extend(group);
                continue;
            }
            let mut keep = group.iter().min_by(|a, b| a.id.cmp(&b.id)).unwrap().clone();
            let latest = group.iter().max_by_key(|c| c.last_at).unwrap();
            keep.last_at = latest.last_at;
            keep.last_text = latest.last_text.clone();
            keep.last_user = latest.last_user.clone();
            keep.last_event = latest.last_event.clone();
            keep.unread = group.iter().map(|c| c.unread).sum();
            keep.mentions = group.iter().map(|c| c.mentions).sum();
            keep.event_count = group.iter().map(|c| c.event_count).sum();
            out.push(keep);
        }
        out
    }

    /// The other direct chats with the same person as this one, when it is the one shown.
    fn aliases(&self, conv: &str) -> Vec<ConversationId> {
        let me = self.user();
        let Some(c) = self.conversation(conv) else { return vec![] };
        if !c.is_direct {
            return vec![];
        }
        let Some(other) = c.members.iter().find(|m| **m != me) else { return vec![] };
        let all: Vec<ConversationId> = self
            .store
            .query("select c.* from conversations c join members m on m.conv=c.id where m.user=? and c.kind='chat' and c.name is null", &[other])
            .iter()
            .map(|r| self.conversation_of(r))
            .filter(|c| c.is_direct && c.members.contains(&me))
            .map(|c| c.id)
            .collect();
        if all.len() < 2 || all.iter().min().map(|m| m.as_str()) != Some(conv) {
            return vec![];
        }
        all.into_iter().filter(|c| c != conv).collect()
    }

    pub fn conversation(&self, id: &str) -> Option<Conversation> {
        self.store.one("select * from conversations where id=?", &[&id]).map(|r| self.conversation_of(&r))
    }

    pub fn events(&self, conv: &str, before: Option<&str>, limit: u32) -> Vec<Event> {
        let others = self.aliases(conv);
        if !others.is_empty() {
            // A merged direct chat: each conversation's page, resolved on its own, interleaved by time.
            let cut = before.and_then(|b| self.store.one("select at from events where id=?", &[&b])).and_then(|r| r.double("at"));
            let mut all: Vec<Event> = std::iter::once(conv.to_owned()).chain(others).flat_map(|c| self.page_by_time(&c, cut, limit)).collect();
            all.sort_by(|a, b| (a.at, &a.id).cmp(&(b.at, &b.id)));
            let n = all.len().saturating_sub(limit as usize);
            return all.split_off(n);
        }
        let mut sql = TIMELINE.to_owned();
        let mut args: Vec<Box<dyn ToSql>> = vec![Box::new(conv.to_owned()), Box::new(conv.to_owned())];
        if let Some(cut) = self.cutoff("cleared:", conv) {
            sql += " and lamport > ?";
            args.push(Box::new(cut));
        }
        if let Some(b) = before.and_then(|b| self.store.one("select lamport from events where id=?", &[&b]).map(|r| (b, r.int("lamport").unwrap_or(0)))) {
            sql += " and (lamport < ? or (lamport = ? and id < ?))";
            args.push(Box::new(b.1));
            args.push(Box::new(b.1));
            args.push(Box::new(b.0.to_owned()));
        }
        sql += " order by lamport desc, id desc limit ?";
        args.push(Box::new(limit as i64));
        let refs: Vec<&dyn ToSql> = args.iter().map(|a| a.as_ref()).collect();
        let mut rows = self.store.query(&sql, &refs);
        rows.reverse();
        self.resolve(&rows, conv, true)
    }

    fn page_by_time(&self, conv: &str, before: Option<f64>, limit: u32) -> Vec<Event> {
        let mut sql = TIMELINE.to_owned();
        let mut args: Vec<Box<dyn ToSql>> = vec![Box::new(conv.to_owned()), Box::new(conv.to_owned())];
        if let Some(b) = before {
            sql += " and at < ?";
            args.push(Box::new(b));
        }
        sql += " order by at desc, id desc limit ?";
        args.push(Box::new(limit as i64));
        let refs: Vec<&dyn ToSql> = args.iter().map(|a| a.as_ref()).collect();
        let mut rows = self.store.query(&sql, &refs);
        rows.reverse();
        self.resolve(&rows, conv, true)
    }

    pub fn thread(&self, conv: &str, root: &str, _before: Option<&str>, _limit: u32) -> Vec<Event> {
        let rows = self.store.query(
            "select * from events where conv=? and (id=? or thread=?) and id not in (select target from events where conv=? and type='redact' and target is not null) and not (type='message' and body='{}') order by lamport, id",
            &[&conv, &root, &root, &conv],
        );
        self.resolve(&rows, conv, true)
    }

    pub fn send(&self, conv: &str, draft: Draft) -> Result<Event> {
        if !self.is_member(conv) {
            return Err(Error::NotMember);
        }
        let mut attachments = vec![];
        for p in &draft.attachments {
            attachments.push(self.add_blob(FsPath::new(p))?);
        }
        let text = draft.text.trim().to_owned();
        // While the conversation's messages disappear, this one carries its own time.
        let ttl = self.store.one("select disappear from conversations where id=?", &[&conv]).and_then(|r| r.int("disappear")).unwrap_or(0);
        let body = MessageBody {
            text: (!text.is_empty()).then(|| text.clone()),
            attachments: (!attachments.is_empty()).then_some(attachments),
            reply: draft.reply.clone(),
            thread: draft.thread.clone(),
            mentions: (!draft.mentions.is_empty()).then(|| draft.mentions.clone()),
            ttl: (ttl > 0).then_some(ttl),
        };
        let e = self.write(conv, EventType::Message, encode(&body), body.text.clone(), draft.reply, draft.thread, None)?;
        self.event(&e.id, true).ok_or(Error::NotFound)
    }

    pub fn react(&self, conv: &str, target: &str, key: &str, on: bool) -> Result<()> {
        self.write(conv, EventType::Reaction, encode(&ReactionBody { target: target.into(), key: key.into(), on }), None, None, None, Some(target.into())).map(|_| ())
    }
    pub fn edit(&self, conv: &str, target: &str, text: &str) -> Result<()> {
        if self.event(target, false).map(|e| e.mine) != Some(true) {
            return Err(Error::NotFound);
        }
        self.write(conv, EventType::Edit, encode(&EditBody { target: target.into(), text: text.into() }), Some(text.into()), None, None, Some(target.into())).map(|_| ())
    }
    pub fn redact(&self, conv: &str, target: &str) -> Result<()> {
        let e = self.event(target, false).ok_or(Error::NotAdmin)?;
        if !(e.mine || self.is_admin(conv)) {
            return Err(Error::NotAdmin);
        }
        self.write(conv, EventType::Redact, encode(&RedactBody { target: target.into() }), None, None, None, Some(target.into())).map(|_| ())
    }
    pub fn pin(&self, conv: &str, target: &str, on: bool) -> Result<()> {
        if !(self.is_admin(conv) || self.conversation(conv).map(|c| c.kind) == Some(Kind::Chat)) {
            return Err(Error::NotAdmin);
        }
        let value = if on { target.to_owned() } else { format!("-{target}") };
        self.write(conv, EventType::State, encode(&StateBody { key: "pin".into(), value }), Some("pin".into()), None, None, Some(target.into())).map(|_| ())
    }

    pub fn mark_read(&self, conv: &str, ev: &str) -> Result<()> {
        // A merged direct chat is read as one: the other conversations' last lines too.
        for a in self.aliases(conv) {
            if let Some(last) = self.store.one("select id from events where conv=? and type='message' order by lamport desc limit 1", &[&a]).and_then(|r| r.string("id")) {
                if last != ev {
                    self.mark_read(&a, &last)?;
                }
            }
        }
        let Some(e) = self.store.one("select lamport, conv from events where id=?", &[&ev]) else { return Ok(()) };
        let conv = e.string("conv").unwrap_or_else(|| conv.to_owned());
        let l = e.int("lamport").unwrap_or(0);
        if self.store.one("select lamport from reads where conv=?", &[&conv]).and_then(|r| r.int("lamport")).unwrap_or(-1) >= l {
            return Ok(());
        }
        self.store.run("insert or replace into reads(conv,event,lamport) values(?,?,?)", &[&conv, &ev, &l]);
        let r = WireReceipt { conv: conv.clone(), device: self.device(), user: self.user(), event: ev.into(), lamport: l, kind: "read".into(), at: now() };
        self.apply_receipt(&r);
        let me = self.device();
        for d in self.member_devices(&conv) {
            if d != me {
                self.post(Frame::Receipt(r.clone()), &d, &conv, false);
            }
        }
        self.emit(Change::Conversations);
        Ok(())
    }

    /// Typing goes only to devices online now: it is news now or never.
    pub fn typing(&self, conv: &str) {
        if !self.is_online() {
            return;
        }
        let me = self.device();
        let frame = Frame::Typing(conv.into(), self.user());
        for d in self.member_devices(conv) {
            if d != me && self.net.is_online(&d) {
                let bytes = self.seal(&frame, Some(conv), false);
                let core = self.arc();
                self.spawn(async move {
                    core.send_to(&bytes, &d).await;
                });
            }
        }
    }

    pub fn typing_now(&self, conv: &str) -> Vec<UserId> {
        let mut v: Vec<UserId> = self.st().typing_seen.get(conv).map(|m| m.iter().filter(|(_, t)| t.elapsed().as_secs_f64() < 5.0).map(|(u, _)| u.clone()).collect()).unwrap_or_default();
        v.sort();
        v
    }

    pub fn members(&self, conv: &str) -> Vec<Member> {
        let me = self.user();
        self.store
            .query("select m.*, p.name, p.verified from members m left join people p on p.user=m.user where m.conv=? order by m.joined_at", &[&conv])
            .into_iter()
            .map(|r| {
                let u = r.string("user").unwrap_or_default();
                let devices = self.devices_of(&u);
                Member {
                    name: if u == me { "You".into() } else { r.string("name").unwrap_or_else(|| "?".into()) },
                    admin: r.bool("admin"),
                    joined_at: r.ms("joined_at").unwrap_or_else(sentences::now_ms),
                    online: devices.iter().any(|d| d.online),
                    devices,
                    verified: r.bool("verified"),
                    me: u == me,
                    label: r.string("label").filter(|s| !s.is_empty()),
                    user: u,
                }
            })
            .collect()
    }

    /// A member's label in a group, for everyone in it: my own, or anyone's if I'm an admin. Short
    /// (24 characters); None or empty takes it away. A quiet change: no line in the chat.
    pub fn set_label(&self, conv: &str, u: &str, text: Option<&str>) -> Result<()> {
        if u != self.user() && !self.is_admin(conv) {
            return Err(Error::NotAdmin);
        }
        let t: String = text.unwrap_or("").trim().chars().take(24).collect();
        let body = encode(&LabelBody { user: u.into(), text: t });
        self.write(conv, EventType::State, encode(&StateBody { key: "label".into(), value: body }), Some("label".into()), None, None, None).map(|_| ())
    }

    /// Into the conversation, with their card; then peer admits their devices for it.
    pub fn add_member(&self, conv: &str, u: &str) -> Result<()> {
        let c = self.conversation(conv).ok_or(Error::NotFound)?;
        if !(c.kind == Kind::Chat || self.is_admin(conv)) {
            return Err(Error::NotAdmin);
        }
        let cd = self.card_of(u).ok_or(Error::NotFound)?;
        self.write(conv, EventType::Member, encode(&MemberBody { user: u.into(), card: Some(cd), action: "add".into(), admin: Some(false) }), Some("add".into()), None, None, None)?;
        self.admit(conv, u);
        Ok(())
    }
    pub fn remove_member(&self, conv: &str, u: &str) -> Result<()> {
        if !self.is_admin(conv) {
            return Err(Error::NotAdmin);
        }
        self.write(conv, EventType::Member, encode(&MemberBody { user: u.into(), card: None, action: "remove".into(), admin: None }), Some("remove".into()), None, None, None).map(|_| ())
    }
    pub fn leave(&self, conv: &str) -> Result<()> {
        self.conversation(conv).ok_or(Error::NotFound)?;
        self.write(conv, EventType::Member, encode(&MemberBody { user: self.user(), card: None, action: "leave".into(), admin: None }), Some("leave".into()), None, None, None)?;
        self.emit(Change::Conversations);
        Ok(())
    }
    pub fn set_conversation_name(&self, conv: &str, n: &str) -> Result<()> {
        if !(self.is_admin(conv) || self.conversation(conv).map(|c| c.kind) == Some(Kind::Chat)) {
            return Err(Error::NotAdmin);
        }
        self.write(conv, EventType::State, encode(&StateBody { key: "name".into(), value: n.into() }), Some("name".into()), None, None, None).map(|_| ())
    }
    pub fn set_topic(&self, conv: &str, t: &str) -> Result<()> {
        if !(self.is_admin(conv) || self.conversation(conv).map(|c| c.kind) == Some(Kind::Chat)) {
            return Err(Error::NotAdmin);
        }
        self.write(conv, EventType::State, encode(&StateBody { key: "topic".into(), value: t.into() }), Some("topic".into()), None, None, None).map(|_| ())
    }
    /// Disappearing messages: each message written from now on carries this many seconds and
    /// goes that long after it is read (its writer's copies, after it is sent); 0 turns it off.
    /// Anyone in a chat changes it, only an admin in a channel. A state line, resolved like the name.
    pub fn set_disappear(&self, conv: &str, seconds: u32) -> Result<()> {
        if !(self.is_admin(conv) || self.conversation(conv).map(|c| c.kind) == Some(Kind::Chat)) {
            return Err(Error::NotAdmin);
        }
        self.write(conv, EventType::State, encode(&StateBody { key: "disappear".into(), value: seconds.to_string() }), Some("disappear".into()), None, None, None).map(|_| ())
    }

    pub fn create_chat(&self, users: &[String]) -> Result<Conversation> {
        let me = self.user();
        let mut all: HashSet<&String> = users.iter().collect();
        all.insert(&me);
        if all.len() == 2 {
            if let Some(u) = users.iter().find(|u| **u != me) {
                if let Some(existing) = self.conversations(Some(Kind::Chat)).into_iter().find(|c| c.is_direct && c.members.contains(u)) {
                    return Ok(existing);
                }
            }
        }
        self.create(Kind::Chat, None, users)
    }
    pub fn create_group(&self, name: &str, users: &[String]) -> Result<Conversation> {
        self.create(Kind::Chat, Some(name.into()), users)
    }

    fn create(&self, kind: Kind, name: Option<String>, users: &[String]) -> Result<Conversation> {
        let id = new_conversation_id(&self.device());
        let body = CreateBody { kind, name: name.clone(), space: None, history: "members".into(), creator: self.card(), is_default: Some(false) };
        self.write(&id, EventType::Create, encode(&body), name, None, None, None)?;
        let me = self.user();
        for u in users {
            if *u != me {
                self.add_member(&id, u)?;
            }
        }
        self.emit(Change::Conversations);
        self.conversation(&id).ok_or(Error::NotFound)
    }

    pub fn search(&self, query: &str, conv: Option<&str>) -> Vec<Hit> {
        let terms: Vec<String> = query.split_whitespace().map(|t| format!("\"{}\"*", t.replace('"', ""))).collect();
        if terms.is_empty() {
            return vec![];
        }
        let me = self.user();
        let q = terms.join(" ");
        let rows = match conv {
            Some(c) => self.store.query("select event, conv, snippet(fts, 0, '', '', '…', 14) as s from fts where fts match ? and conv=? order by rowid desc limit 60", &[&q, &c]),
            None => self.store.query("select event, conv, snippet(fts, 0, '', '', '…', 14) as s from fts where fts match ? order by rowid desc limit 60", &[&q]),
        };
        let mut convs: HashMap<String, Option<Conversation>> = HashMap::new();
        rows.into_iter()
            .filter_map(|r| {
                let e = self.event(&r.string("event")?, false)?;
                let cid = r.string("conv")?;
                let c = convs.entry(cid.clone()).or_insert_with(|| self.conversation(&cid)).clone()?;
                c.members.contains(&me).then(|| Hit { event: e, conversation: c, snippet: r.string("s").unwrap_or_default() })
            })
            .collect()
    }

    pub async fn blob(&self, hash: &str, _key: &str) -> Result<String> {
        let mine = self.blob_path(hash);
        if mine.exists() {
            return Ok(mine.to_string_lossy().into_owned());
        }
        match self.fetch_blob(hash).await {
            Some(p) => Ok(p.to_string_lossy().into_owned()),
            None => Err(Error::Unreachable("Nobody who has it is online.".into())),
        }
    }

    // MARK: the network

    pub fn peers(&self) -> Vec<Peer> {
        let (me, dev) = (self.user(), self.device());
        let live: HashMap<String, peer::PeerStatus> = self.net.peer.peers().into_iter().map(|p| (p.device.to_hex(), p)).collect();
        self.store
            .query("select d.*, p.name as pname from devices d left join people p on p.user=d.user where d.id<>? order by d.user=? desc, pname collate nocase, d.name", &[&dev, &me])
            .into_iter()
            .map(|r| {
                let mut d = self.device_of(&r);
                let own = r.string("user").as_deref() == Some(me.as_str());
                let contact = self.store.int("select count(*) as n from people where user=? and contact=1", &[&d.user]) > 0;
                let s = live.get(&d.id);
                if let Some(seen) = s.filter(|s| !s.online).and_then(|s| s.last_seen) {
                    d.last_online = Some(seen as i64);
                    d.sentence = sentences::device(d.online, &d.path, d.last_online);
                }
                let mut p = Peer {
                    user_name: if own { "You".into() } else { r.string("pname").unwrap_or_else(|| "?".into()) },
                    own,
                    record_age: s.and_then(|s| s.record_age_ms).map(|a| a as i64).or(if d.online { Some(0) } else { d.last_online.map(|t| sentences::now_ms() - t) }),
                    found_by: s.and_then(|s| s.found_by).and_then(|f| FoundBy::parse(f.as_str())).or(Some(if own { FoundBy::Exchange } else if contact { FoundBy::Invite } else { FoundBy::Exchange })),
                    relaying: false,
                    holding_for_me: 0,
                    i_hold_for_it: self.store.int("select count(*) as n from envelopes where to_device=?", &[&d.id]) as u32,
                    sentence: String::new(),
                    device: d,
                };
                p.sentence = sentences::peer(&p);
                p
            })
            .collect()
    }

    pub fn carrying(&self) -> Carrying {
        let me = self.user();
        let held: Vec<Held> = self
            .store
            .query("select e.to_device, count(*) as n, sum(size) as b, d.kind, d.user, p.name as pname from envelopes e left join devices d on d.id=e.to_device left join people p on p.user=d.user group by e.to_device", &[])
            .into_iter()
            .map(|r| Held {
                device: r.string("to_device").unwrap_or_default(),
                name: sentences::whose(r.string("user").as_deref() == Some(me.as_str()), &r.string("pname").unwrap_or_else(|| "?".into()), &r.string("kind").unwrap_or_default()),
                count: r.int("n").unwrap_or(0) as u32,
                bytes: r.int("b").unwrap_or(0) as u64,
            })
            .collect();
        // peer holds the envelopes it carries; it counts them, not whose they are.
        let h = self.net.peer.helping();
        let (n, b, budget) = (h.envelopes + held.iter().map(|h| h.count).sum::<u32>(), h.bytes + held.iter().map(|h| h.bytes).sum::<u64>(), h.budget_bytes);
        Carrying { sentence: sentences::carrying(n, b, budget, &held), envelopes: n, bytes: b, budget_bytes: budget, held }
    }

    pub fn set_online(&self, on: bool) {
        let changed = {
            let mut s = self.st();
            let c = s.online != on;
            s.online = on;
            c
        };
        if self.is_closed() {
            return;
        }
        self.net.peer.set_online(on);
        if !changed {
            return;
        }
        // Devices peer connected before the app said it was in front: their "online" found this
        // core offline and offered nothing, so offer now.
        if on {
            let me = self.device();
            for r in self.store.query("select id from devices where id<>?", &[&me]) {
                if let Some(d) = r.string("id") {
                    if self.net.is_online(&d) {
                        self.connected(&d);
                    }
                }
            }
        }
        self.emit(Change::Peers);
        self.emit(Change::Contacts);
        self.emit(Change::Conversations);
    }

    pub fn network_changed(&self) {
        self.net.peer.network_changed();
    }

    pub fn trace(&self) -> Vec<String> {
        let mut t = self.net.peer.trace();
        t.extend(self.st().trace.iter().cloned());
        t
    }

    /// Let go of the network. Idempotent; the core reads its store after, writes nothing out.
    pub async fn close(&self) {
        if self.closed.swap(true, std::sync::atomic::Ordering::SeqCst) {
            return;
        }
        self.log("closing");
        self.net.peer.close().await;
    }

    /// This device forgets everything it is: peer's keys and files, then the store and blobs.
    pub async fn reset(&self) -> Result<()> {
        self.net.peer.reset().await.map_err(|e| Error::from_peer(e, "", true))?;
        self.store.wipe_messages();
        self.store.exec("delete from people; delete from devices; delete from me; delete from links;");
        let _ = std::fs::remove_dir_all(self.dir.join("blobs"));
        Ok(())
    }

    // MARK: reading rows

    pub(crate) fn conversation_of(&self, r: &Row) -> Conversation {
        let me = self.user();
        let id = r.string("id").unwrap_or_default();
        let members = self.store.query("select user, admin from members where conv=?", &[&id]);
        // A message gone (body '{}') is not a last line, unread, or counted.
        let last = self.store.one("select id, text, user, at from events where conv=? and type='message' and thread is null and body<>'{}' order by lamport desc, id desc limit 1", &[&id]);
        let created = r.ms("created_at").unwrap_or_else(sentences::now_ms);
        let read_l = self.store.one("select lamport from reads where conv=?", &[&id]).and_then(|r| r.int("lamport")).unwrap_or(-1);
        let unread = self.store.int("select count(*) as n from events where conv=? and type='message' and thread is null and user<>? and lamport>? and body<>'{}'", &[&id, &me, &read_l]);
        let mentions = if unread == 0 { 0 } else { self.store.int("select count(*) as n from events where conv=? and type='message' and user<>? and lamport>? and body like ?", &[&id, &me, &read_l, &format!("%\"{me}\"%")]) };
        let count = self.store.int("select count(*) as n from events where conv=? and type='message' and body<>'{}'", &[&id]);
        let kind = Kind::parse(&r.string("kind").unwrap_or_default()).unwrap_or(Kind::Chat);
        let name = r.string("name");
        let member_ids: Vec<String> = members.iter().filter_map(|m| m.string("user")).collect();
        Conversation {
            is_direct: kind == Kind::Chat && name.is_none() && member_ids.len() == 2,
            kind,
            name,
            topic: r.string("topic"),
            space: r.string("space"),
            admins: members.iter().filter(|m| m.bool("admin")).filter_map(|m| m.string("user")).collect(),
            members: member_ids,
            created_at: created,
            last_at: last.as_ref().and_then(|l| l.ms("at")).unwrap_or(created),
            last_text: last.as_ref().and_then(|l| l.string("text")),
            last_user: last.as_ref().and_then(|l| l.string("user")),
            last_event: last.as_ref().and_then(|l| l.string("id")),
            unread: unread as u32,
            mentions: mentions as u32,
            event_count: count as u32,
            is_default: r.bool("is_default"),
            pinned: self.store.query("select event from pins where conv=?", &[&id]).iter().filter_map(|p| p.string("event")).collect(),
            disappear: r.int("disappear").unwrap_or(0).clamp(0, u32::MAX as i64) as u32,
            id,
        }
    }

    pub(crate) fn device_of(&self, r: &Row) -> Device {
        let id = r.string("id").unwrap_or_default();
        let (live, here_online) = {
            let s = self.st();
            (s.live.get(&id).cloned(), s.online)
        };
        // This device is online while the app is in front: it is the one reading this.
        let this = id == self.device();
        let on = if this { here_online } else { live.as_ref().map(|l| l.0).unwrap_or_else(|| self.net.is_online(&id)) };
        let path = if this { Path::NotConnected } else { live.map(|l| l.1).unwrap_or_else(|| if on && here_online { Path::Direct { ms: self.net.rtt(&id) } } else if on { Path::Waiting } else { Path::NotConnected }) };
        let last = r.ms("last_online");
        Device {
            sentence: sentences::device(on, &path, last),
            name: r.string("name").unwrap_or_else(|| "device".into()),
            kind: DeviceKind::parse(&r.string("kind").unwrap_or_else(|| "mac".into())),
            user: r.string("user").unwrap_or_default(),
            added_at: r.ms("added_at").unwrap_or_else(sentences::now_ms),
            online: on,
            last_online: last,
            path,
            id,
        }
    }

    pub(crate) fn devices_of(&self, u: &str) -> Vec<Device> {
        self.store.query("select * from devices where user=? order by added_at", &[&u]).iter().map(|r| self.device_of(r)).collect()
    }

    pub(crate) fn event(&self, id: &str, paths: bool) -> Option<Event> {
        let r = self.store.one("select * from events where id=?", &[&id])?;
        let conv = r.string("conv")?;
        self.resolve(&[r], &conv, paths).into_iter().next()
    }

    /// Edits applied, reactions grouped, thread counts, pins, the system line for non-messages.
    fn resolve(&self, rows: &[Row], conv: &str, paths: bool) -> Vec<Event> {
        if rows.is_empty() {
            return vec![];
        }
        let me = self.user();
        let ids: Vec<String> = rows.iter().filter_map(|r| r.string("id")).collect();
        let marks = vec!["?"; ids.len()].join(",");
        let mut page: Vec<&dyn ToSql> = ids.iter().map(|i| i as &dyn ToSql).collect();
        page.push(&conv);
        let mut edits: HashMap<String, Option<String>> = HashMap::new();
        for e in self.store.query(&format!("select target, text from events where target in ({marks}) and conv=? and type='edit' order by lamport, id"), &page) {
            if let Some(t) = e.string("target") {
                edits.insert(t, e.string("text"));
            }
        }
        let mut reacts: HashMap<String, BTreeMap<String, Vec<UserId>>> = HashMap::new();
        for r in self.store.query(&format!("select target, user, body from events where target in ({marks}) and conv=? and type='reaction' order by lamport, id"), &page) {
            let (Some(b), Some(u)) = (r.string("body").and_then(|b| decode::<ReactionBody>(&b)), r.string("user")) else { continue };
            let users = reacts.entry(b.target).or_default().entry(b.key).or_default();
            users.retain(|x| *x != u);
            if b.on {
                users.push(u);
            }
        }
        let mut threads: HashMap<String, (u32, Vec<UserId>)> = HashMap::new();
        for t in self.store.query(&format!("select thread, count(*) as n, group_concat(user) as users from (select thread, user from events where thread in ({marks}) and conv=? and type='message' and body<>'{{}}' order by lamport) group by thread"), &page) {
            let users = t.string("users").unwrap_or_default();
            let mut seen: Vec<UserId> = vec![];
            for u in users.split(',').rev() {
                if !seen.iter().any(|s| s == u) {
                    seen.push(u.to_owned());
                    if seen.len() == 3 {
                        break;
                    }
                }
            }
            if let Some(th) = t.string("thread") {
                threads.insert(th, (t.int("n").unwrap_or(0) as u32, seen));
            }
        }
        let pinned: HashSet<String> = self.store.query("select event from pins where conv=?", &[&conv]).iter().filter_map(|r| r.string("event")).collect();
        let mut names: HashMap<UserId, String> = HashMap::new();
        let mut name_of = |u: &str| -> String {
            if let Some(n) = names.get(u) {
                return n.clone();
            }
            let n = if u == me { "You".to_owned() } else { self.store.one("select name from people where user=?", &[&u]).and_then(|r| r.string("name")).unwrap_or_else(|| "Someone".into()) };
            names.insert(u.to_owned(), n.clone());
            n
        };
        // How my messages on this page travelled: three queries for the page, not three per line.
        let mine: Vec<String> = if paths { rows.iter().filter(|r| r.string("user").as_deref() == Some(me.as_str())).filter_map(|r| r.string("id")).collect() } else { vec![] };
        let (mut delivered, mut handed, mut read_up_to) = (HashSet::new(), HashSet::new(), -1);
        if !mine.is_empty() {
            let m = vec!["?"; mine.len()].join(",");
            let mut args: Vec<&dyn ToSql> = vec![&conv, &me];
            args.extend(mine.iter().map(|i| i as &dyn ToSql));
            delivered = self.store.query(&format!("select distinct event from receipts where conv=? and user<>? and kind='delivered' and event in ({m})"), &args).iter().filter_map(|r| r.string("event")).collect();
            let ids: Vec<&dyn ToSql> = mine.iter().map(|i| i as &dyn ToSql).collect();
            handed = self.store.query(&format!("select distinct event from handed where event in ({m})"), &ids).iter().filter_map(|r| r.string("event")).collect();
            read_up_to = self.store.one("select max(lamport) as l from receipts where conv=? and user<>? and kind='read'", &[&conv, &me]).and_then(|r| r.int("l")).unwrap_or(-1);
        }
        rows.iter()
            .map(|r| {
                let id = r.string("id").unwrap_or_default();
                let kind = EventType::parse(&r.string("type").unwrap_or_default());
                let u = r.string("user").unwrap_or_default();
                let lamport = r.int("lamport").unwrap_or(0);
                let mut e = Event {
                    id: id.clone(),
                    conv: conv.to_owned(),
                    device: r.string("device").unwrap_or_default(),
                    seq: r.int("seq").unwrap_or(0) as u64,
                    user: u.clone(),
                    at: r.ms("at").unwrap_or(0),
                    lamport: lamport as u64,
                    kind,
                    text: None,
                    attachments: vec![],
                    reply: None,
                    thread: None,
                    mentions: vec![],
                    reactions: vec![],
                    edited: false,
                    replies: 0,
                    last_repliers: vec![],
                    pinned: false,
                    system: None,
                    mine: u == me,
                    carried_by: r.string("carried_by"),
                    via: None,
                };
                let body = r.string("body").unwrap_or_default();
                match kind {
                    EventType::Message => {
                        let stored = r.string("via").and_then(|v| Via::parse(&v));
                        e.via = Some(if u == me {
                            // Mine: waiting until another device has it, carried while one holds it.
                            let arrived = delivered.contains(&id) || lamport <= read_up_to;
                            if handed.contains(&id) { Via::Carried } else if arrived { stored.unwrap_or(Via::Direct) } else { Via::Waiting }
                        } else {
                            stored.unwrap_or(Via::Direct)
                        });
                        let b = decode::<MessageBody>(&body).unwrap_or_default();
                        e.edited = edits.contains_key(&id);
                        e.text = edits.get(&id).cloned().flatten().or(b.text);
                        e.attachments = b.attachments.unwrap_or_default();
                        e.reply = b.reply;
                        e.thread = b.thread;
                        e.mentions = b.mentions.unwrap_or_default();
                        e.reactions = reacts.get(&id).map(|m| m.iter().filter(|(_, v)| !v.is_empty()).map(|(k, v)| Reaction { key: k.clone(), mine: v.contains(&me), users: v.clone() }).collect()).unwrap_or_default();
                        if let Some(t) = threads.get(&id) {
                            e.replies = t.0;
                            e.last_repliers = t.1.clone();
                        }
                        e.pinned = pinned.contains(&id);
                    }
                    EventType::Member => {
                        let b = decode::<MemberBody>(&body);
                        let who = b.as_ref().map(|b| name_of(&b.user)).unwrap_or_else(|| "someone".into());
                        let by = name_of(&u);
                        e.system = Some(match b.as_ref().map(|b| b.action.as_str()) {
                            Some("add") if b.as_ref().map(|b| b.user == u) == Some(true) => format!("{by} joined"),
                            Some("add") => format!("{by} added {who}"),
                            Some("remove") => format!("{by} removed {who}"),
                            _ => format!("{by} left"),
                        });
                    }
                    EventType::State => {
                        let b = decode::<StateBody>(&body);
                        let by = name_of(&u);
                        e.system = match b.as_ref().map(|b| b.key.as_str()) {
                            Some("name") => Some(format!("{by} named it {}", b.as_ref().unwrap().value)),
                            Some("topic") => Some(format!("{by} set the topic: {}", b.as_ref().unwrap().value)),
                            Some("pin") => Some(if b.as_ref().unwrap().value.starts_with('-') { format!("{by} unpinned a message") } else { format!("{by} pinned a message") }),
                            Some("call") => decode::<CallRecord>(&b.as_ref().unwrap().value).map(|c| c.line(u == me, &by)),
                            Some("disappear") => b.as_ref().unwrap().value.parse::<i64>().ok().filter(|s| *s >= 0).map(|s| sentences::disappear_line(&by, s)),
                            _ => None,
                        };
                    }
                    EventType::Create => {
                        let b = decode::<CreateBody>(&body);
                        let by = name_of(&u);
                        e.system = b.and_then(|b| match b.kind {
                            Kind::Channel => Some(format!("{by} created #{}", b.name.unwrap_or_default())),
                            Kind::Space => Some(format!("{by} created the space {}", b.name.unwrap_or_default())),
                            _ => b.name.map(|n| format!("{by} made the group {n}")),
                        });
                    }
                    _ => {}
                }
                e
            })
            .filter(|e| e.kind == EventType::Message || e.system.is_some())
            .collect()
    }

    // MARK: writing

    /// Every event this device writes: its own id, its own next seq, then told to every member
    /// device. A joiner's devices get the conversation so far, with the key.
    pub(crate) fn write(&self, conv: &str, kind: EventType, body: String, text: Option<String>, reply: Option<EventId>, thread: Option<EventId>, target: Option<EventId>) -> Result<WireEvent> {
        let (device, user) = (self.device(), self.user());
        if user.is_empty() {
            return Err(Error::NotMember);
        }
        let seq = self.store.int("select coalesce(max(seq),0) as n from events where conv=? and device=?", &[&conv, &device]) + 1;
        let lamport = self.store.int("select coalesce(max(lamport),0) as n from events where conv=?", &[&conv]) + 1;
        let e = WireEvent { id: event_id(conv, &device, seq as u64), conv: conv.into(), device: device.clone(), seq, user, at: now(), lamport, kind, text, reply, thread, target, body };
        self.apply(&e, None);
        if kind == EventType::Message {
            self.store.run("insert or replace into reads(conv,event,lamport) values(?,?,?)", &[&conv, &e.id, &e.lamport]);
        }
        let mut to: HashSet<DeviceId> = self.member_devices(conv).into_iter().collect();
        if kind == EventType::Member {
            if let Some(space) = self.conversation(conv).and_then(|c| c.space) {
                to.extend(self.member_devices(&space));
            }
        }
        let joining = (kind == EventType::Member).then(|| decode::<MemberBody>(&e.body)).flatten().filter(|b| b.action == "add");
        let joiner: HashSet<DeviceId> = joining.map(|b| self.devices_of(&b.user).into_iter().map(|d| d.id).collect()).unwrap_or_default();
        let history: Vec<WireEvent> = if joiner.is_empty() { vec![] } else { self.store.query("select * from events where conv=? order by lamport, id", &[&conv]).iter().map(wire_of).collect() };
        for d in to {
            if d != device {
                let j = joiner.contains(&d);
                self.post(Frame::Events(if j { history.clone() } else { vec![e.clone()] }), &d, conv, j);
            }
        }
        Ok(e)
    }

    /// The path from a device that just sent me something: relayed, or direct.
    fn via_from(&self, d: &str) -> &'static str {
        if matches!(self.st().live.get(d), Some((_, Path::Relay { .. }))) { "relay" } else { "direct" }
    }

    /// The path my message is leaving by: direct when any other member's device is, else relayed
    /// when one is reached through a helper, else nothing yet (it waits).
    fn via_to(&self, conv: &str) -> Option<&'static str> {
        let others: Vec<String> = self.store.query("select d.id from devices d join members m on m.user=d.user where m.conv=? and m.user<>?", &[&conv, &self.user()]).iter().filter_map(|r| r.string("id")).collect();
        let s = self.st();
        let paths: Vec<&Path> = others.iter().filter_map(|d| s.live.get(d)).filter(|l| l.0).map(|l| &l.1).collect();
        if paths.iter().any(|p| matches!(p, Path::Direct { .. } | Path::Nearby)) {
            return Some("direct");
        }
        if paths.iter().any(|p| matches!(p, Path::Relay { .. })) {
            return Some("relay");
        }
        None
    }

    /// Insert a feed entry (idempotent by id) and its effect on state. True when it was new.
    pub(crate) fn apply(&self, e: &WireEvent, carried_by: Option<&str>) -> bool {
        let me = self.user();
        if self.store.int("select count(*) as n from events where id=?", &[&e.id]) > 0 {
            return false;
        }
        // How it came (theirs) or how it is leaving (mine), as the paths are right now.
        let via: Option<&str> = if carried_by.is_some() { Some("carried") } else if e.device != self.device() { Some(self.via_from(&e.device)) } else { self.via_to(&e.conv) };
        let n = self.store.run(
            "insert or ignore into events(id,conv,device,seq,user,at,lamport,type,text,reply,thread,target,body,carried_by,via) values(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            &[&e.id, &e.conv, &e.device, &e.seq, &e.user, &e.at, &e.lamport, &e.kind.as_str(), &e.text, &e.reply, &e.thread, &e.target, &e.body, &carried_by, &via],
        );
        if n == 0 {
            return false;
        }
        let mut joined: Vec<(ConversationId, UserId)> = vec![];
        let mut expires: Option<f64> = None;
        match e.kind {
            EventType::Message => {
                if let Some(t) = &e.text {
                    self.store.run("insert into fts(text,event,conv,user) values(?,?,?,?)", &[t, &e.id, &e.conv, &e.user]);
                }
                // A disappearing message: when it goes here, if that is known yet.
                expires = self.expiry_of(e);
                if let Some(x) = expires {
                    self.store.run("update events set expires_at=? where id=?", &[&x, &e.id]);
                }
            }
            EventType::Edit => {
                // An edit of a message already gone from here goes with it: it carries the words too.
                if e.target.as_deref().is_some_and(|t| self.gone(t)) {
                    self.store.run("update events set text=null, body='{}' where id=?", &[&e.id]);
                } else if let (Some(t), Some(target)) = (&e.text, &e.target) {
                    self.store.run("delete from fts where event=?", &[target]);
                    self.store.run("insert into fts(text,event,conv,user) values(?,?,?,?)", &[t, target, &e.conv, &e.user]);
                }
            }
            EventType::Redact => {
                if let Some(target) = &e.target {
                    self.store.run("delete from fts where event=?", &[target]);
                    self.store.run("update events set text=null, body='{}' where id=?", &[target]);
                }
            }
            EventType::Create => {
                if let Some(b) = decode::<CreateBody>(&e.body) {
                    self.ensure(&e.conv, b.kind, b.name.as_deref(), b.space.as_deref(), &b.creator.user, b.is_default.unwrap_or(false), e.at);
                    self.save_card(&b.creator, false);
                }
            }
            EventType::Member => {
                if let Some(b) = decode::<MemberBody>(&e.body) {
                    if b.action == "add" {
                        if let Some(c) = &b.card {
                            self.save_card(c, false);
                        }
                        self.store.run("insert or ignore into members(conv,user,admin,joined_at) values(?,?,?,?)", &[&e.conv, &b.user, &b.admin.unwrap_or(false), &e.at]);
                        if b.user != me {
                            joined.push((e.conv.clone(), b.user.clone()));
                        }
                    } else {
                        self.store.run("delete from members where conv=? and user=?", &[&e.conv, &b.user]);
                    }
                }
            }
            EventType::State => {
                if let Some(b) = decode::<StateBody>(&e.body) {
                    match b.key.as_str() {
                        "name" => {
                            self.store.run("update conversations set name=? where id=?", &[&b.value, &e.conv]);
                        }
                        "topic" => {
                            self.store.run("update conversations set topic=? where id=?", &[&b.value, &e.conv]);
                        }
                        "disappear" => {
                            if let Some(s) = b.value.parse::<i64>().ok().filter(|s| *s >= 0) {
                                self.store.run("update conversations set disappear=? where id=?", &[&s, &e.conv]);
                            }
                        }
                        "label" => {
                            // Only their own, or an admin's word on anyone's.
                            if let Some(l) = decode::<LabelBody>(&b.value) {
                                let admin = self.store.one("select admin from members where conv=? and user=?", &[&e.conv, &e.user]).map(|r| r.bool("admin")).unwrap_or(false);
                                if l.user == e.user || admin {
                                    let t: String = l.text.chars().take(24).collect();
                                    self.store.run("update members set label=? where conv=? and user=?", &[&t, &e.conv, &l.user]);
                                }
                            }
                        }
                        "pin" => {
                            if let Some(t) = b.value.strip_prefix('-') {
                                self.store.run("delete from pins where conv=? and event=?", &[&e.conv, &t]);
                            } else if !self.gone(&b.value) {
                                self.store.run("insert or ignore into pins(conv,event) values(?,?)", &[&e.conv, &b.value]);
                            }
                        }
                        "channels" => {
                            for ch in decode::<Vec<ChannelRef>>(&b.value).unwrap_or_default() {
                                self.store.run("insert or ignore into conversations(id,kind,name,space,created_at,is_default) values(?,?,?,?,?,?)", &[&ch.conv, &"channel", &ch.name, &e.conv, &e.at, &ch.is_default]);
                            }
                        }
                        key => {
                            // A chat deleted or cleared on another device of mine.
                            if e.user == me && e.conv == home_id(&me) {
                                if let Ok(l) = b.value.parse::<i64>() {
                                    if let Some(c) = key.strip_prefix("profile.hidden.") {
                                        self.raise("hidden:", c, l);
                                    }
                                    if let Some(c) = key.strip_prefix("profile.cleared.") {
                                        self.raise("cleared:", c, l);
                                    }
                                }
                            }
                        }
                    }
                }
            }
            EventType::Card => {
                if let Some(c) = decode::<WireCard>(&e.body) {
                    self.save_card(&c, false);
                }
            }
            _ => {}
        }
        // Past its time already (it was read on another device of mine, or written long ago): it
        // goes now, before anyone sees it; else the sweep waits for it.
        if let Some(x) = expires {
            if x <= now() {
                self.expire(now());
            } else {
                self.schedule_expiry();
            }
        }
        for (c, u) in joined {
            self.admit(&c, &u);
        }
        if e.kind == EventType::Create || e.kind == EventType::Member || (e.kind == EventType::State && matches!(e.text.as_deref(), Some("channels" | "disappear"))) {
            self.emit(Change::Conversations);
        }
        // A cutoff from another device of mine: the list and that chat redraw.
        if e.kind == EventType::State && e.user == me {
            if let Some(b) = decode::<StateBody>(&e.body) {
                if b.key.starts_with("profile.hidden.") || b.key.starts_with("profile.cleared.") {
                    self.emit(Change::Conversations);
                    self.emit(Change::Conversation { id: b.key.splitn(3, '.').last().unwrap_or_default().into() });
                }
            }
        }
        self.emit(Change::Conversation { id: e.conv.clone() });
        true
    }

    pub(crate) fn ensure(&self, conv: &str, kind: Kind, name: Option<&str>, space: Option<&str>, creator: &str, is_default: bool, at: f64) {
        self.store.run("insert or ignore into conversations(id,kind,name,space,created_at,is_default) values(?,?,?,?,?,?)", &[&conv, &kind.as_str(), &name, &space, &at, &is_default]);
        self.store.run("update conversations set is_default=? where id=? and is_default=0", &[&is_default, &conv]);
        self.store.run("insert or ignore into members(conv,user,admin,joined_at) values(?,?,1,?)", &[&conv, &creator, &at]);
    }

    // MARK: cards

    pub(crate) fn save_card(&self, c: &WireCard, contact: bool) {
        if let Some(pc) = &c.peer_card {
            self.st().peer_cards.insert(c.user.clone(), pc.clone());
        }
        self.store.run(
            "insert into people(user,name,fingerprint,verified,contact,met_at,demo,avatar) values(?,?,?,0,?,?,0,?) on conflict(user) do update set name=excluded.name, contact=max(people.contact, excluded.contact), avatar=coalesce(excluded.avatar, people.avatar)",
            &[&c.user, &c.name, &c.fingerprint, &contact, &now(), &c.avatar],
        );
        if let Some(pc) = &c.peer_card {
            self.store.run("update people set peer_card=? where user=?", &[pc, &c.user]);
        }
        for d in &c.devices {
            self.store.run("insert or ignore into devices(id,user,name,kind,added_at) values(?,?,?,?,?)", &[&d.id, &c.user, &d.name, &d.kind.as_str(), &d.added_at]);
            // baud's card knows the kind better than peer's (which has no Android yet).
            if d.kind != DeviceKind::Node {
                self.store.run("update devices set kind=? where id=? and user=?", &[&d.kind.as_str(), &d.id, &c.user]);
            }
        }
        if !c.devices.is_empty() {
            let marks = vec!["?"; c.devices.len()].join(",");
            let mut args: Vec<&dyn ToSql> = vec![&c.user];
            args.extend(c.devices.iter().map(|d| &d.id as &dyn ToSql));
            self.store.run(&format!("delete from devices where user=? and id not in ({marks})"), &args);
        }
    }

    pub(crate) fn wire_devices(&self, u: &str) -> Vec<WireDevice> {
        self.store
            .query("select * from devices where user=?", &[&u])
            .iter()
            .map(|r| WireDevice { id: r.string("id").unwrap_or_default(), name: r.string("name").unwrap_or_default(), kind: DeviceKind::parse(&r.string("kind").unwrap_or_else(|| "mac".into())), added_at: r.double("added_at").unwrap_or(0.0) })
            .collect()
    }

    /// My card, with peer's card inside.
    pub(crate) fn card(&self) -> WireCard {
        let (user, name, pc) = {
            let s = self.st();
            (s.user.clone(), s.name.clone(), s.my_peer_card.clone())
        };
        WireCard { fingerprint: card_fingerprint(&user), devices: self.wire_devices(&user), avatar: self.store.one("select avatar from people where user=?", &[&user]).and_then(|r| r.string("avatar")), peer_card: pc, name, user }
    }

    pub(crate) fn card_of(&self, u: &str) -> Option<WireCard> {
        let p = self.store.one("select * from people where user=?", &[&u])?;
        let pc = self.peer_card_of(u);
        Some(WireCard { user: u.into(), name: p.string("name").unwrap_or_default(), fingerprint: p.string("fingerprint").unwrap_or_default(), devices: self.wire_devices(u), avatar: p.string("avatar"), peer_card: pc })
    }

    pub(crate) fn peer_card_of(&self, u: &str) -> Option<Vec<u8>> {
        if let Some(c) = peer::identity::UserId::from_hex(u).ok().and_then(|id| self.net.peer.card_of(id)) {
            return Some(c.to_bytes());
        }
        if let Some(c) = self.st().peer_cards.get(u).cloned() {
            return Some(c);
        }
        self.store.one("select peer_card from people where user=?", &[&u]).and_then(|r| r.blob("peer_card"))
    }

    /// My card, with peer's inside, to one person's devices: after meeting, so each side can
    /// later vouch for the other to co-members.
    pub(crate) fn announce(&self, u: &str) {
        let card = self.card();
        for d in self.devices_of(u) {
            self.post(Frame::Card(card.clone()), &d.id, "", false);
        }
    }

    pub(crate) fn is_member(&self, conv: &str) -> bool {
        self.store.int("select count(*) as n from members where conv=? and user=?", &[&conv, &self.user()]) > 0
    }
    pub(crate) fn is_admin(&self, conv: &str) -> bool {
        self.store.int("select count(*) as n from members where conv=? and user=? and admin=1", &[&conv, &self.user()]) > 0
    }
    pub(crate) fn member_devices(&self, conv: &str) -> Vec<DeviceId> {
        self.store.query("select d.id from devices d join members m on m.user=d.user where m.conv=?", &[&conv]).iter().filter_map(|r| r.string("id")).collect()
    }
    pub(crate) fn user_of(&self, d: &str) -> Option<UserId> {
        self.store.one("select user from devices where id=?", &[&d]).and_then(|r| r.string("user"))
    }

    // MARK: peer's identity and book, mirrored into the store

    /// Take peer's identity: this device is that person's, with those devices.
    pub(crate) fn adopt_identity(&self) {
        let m = self.net.peer.me();
        let (u, dev) = (m.user.to_hex(), m.this_device.to_hex());
        let stored = self.store.one("select v from me where k='name'", &[]).and_then(|r| r.string("v"));
        let n = if m.name.is_empty() { stored.unwrap_or_else(|| self.config.name.clone()) } else { m.name.clone() };
        let old = self.user();
        if !old.is_empty() && old != u {
            // Linked into another person: everything written as the old one is the new one's.
            for t in ["events", "members", "receipts", "devices"] {
                self.store.run(&format!("update {t} set user=? where user=?"), &[&u, &old]);
            }
            self.store.run("update people set user=? where user=?", &[&u, &old]);
            let (oh, nh) = (home_id(&old), home_id(&u));
            for t in ["conversations set id", "members set conv", "events set conv", "reads set conv"] {
                self.store.run(&format!("update {t}=? where {}=?", t.rsplit(' ').next().unwrap()), &[&nh, &oh]);
            }
        }
        {
            let mut s = self.st();
            s.user = u.clone();
            s.device = dev.clone();
            s.name = n.clone();
        }
        let now = now();
        self.store.run("insert or replace into me(k,v) values('name',?)", &[&n]);
        self.store.run(
            "insert into people(user,name,fingerprint,verified,contact,met_at) values(?,?,?,1,0,?) on conflict(user) do update set name=excluded.name, fingerprint=excluded.fingerprint, verified=1",
            &[&u, &n, &card_fingerprint(&u), &now],
        );
        for d in &m.devices {
            let id = d.id.to_hex();
            let kind = if id == dev { self.config.device_kind } else { DeviceKind::parse(d.kind.as_str()) };
            self.store.run("insert or ignore into devices(id,user,name,kind,added_at) values(?,?,?,?,?)", &[&id, &u, &d.name, &kind.as_str(), &(d.added_at as f64 / 1000.0)]);
            if id == dev {
                self.store.run("update devices set kind=?, name=? where id=?", &[&kind.as_str(), &d.name, &id]);
            }
        }
        let ids: Vec<String> = m.devices.iter().map(|d| d.id.to_hex()).collect();
        if !ids.is_empty() {
            let marks = vec!["?"; ids.len()].join(",");
            let mut args: Vec<&dyn ToSql> = vec![&u];
            args.extend(ids.iter().map(|i| i as &dyn ToSql));
            self.store.run(&format!("delete from devices where user=? and id not in ({marks})"), &args);
        }
        self.ensure(&home_id(&u), Kind::Home, None, None, &u, false, now);
        self.emit(Change::Me);
    }

    /// peer's book is the book, on every device of mine: anyone it no longer lists leaves the
    /// friends list here too; everyone it lists is a contact, with the online state it reports.
    pub(crate) fn adopt_contacts(&self) {
        let book = self.net.peer.contacts();
        let users: HashSet<String> = book.iter().map(|c| c.user.to_hex()).collect();
        let me = self.user();
        let mut dropped = 0;
        for r in self.store.query("select user from people where contact=1 and user<>?", &[&me]) {
            if let Some(u) = r.string("user").filter(|u| !users.contains(u)) {
                self.store.run("update people set contact=0 where user=?", &[&u]);
                dropped += 1;
            }
        }
        let now = now();
        for c in &book {
            let u = c.user.to_hex();
            let fp = peer::identity::fingerprint(&c.user);
            let vouched = c.redirected_from.is_some() && !c.verified;
            self.store.run(
                "insert into people(user,name,fingerprint,verified,contact,met_at) values(?,?,?,?,1,?) on conflict(user) do update set name=excluded.name, fingerprint=excluded.fingerprint, verified=excluded.verified, contact=1, vouched=case when excluded.verified=1 then 0 else people.vouched end",
                &[&u, &c.name, &fp, &c.verified, &(if c.met_at == 0 { now } else { c.met_at as f64 / 1000.0 })],
            );
            if vouched {
                self.store.run("update people set vouched=1 where user=?", &[&u]);
            }
            if let Some(card) = &c.card {
                self.st().peer_cards.insert(u.clone(), card.to_bytes());
            }
            // The card's devices, named and kinded; the status list for who is online.
            let entries: Vec<(String, String, String)> = match &c.card {
                Some(card) => {
                    let ids: Vec<peer::identity::DeviceId> = card.device_ids().collect();
                    card.body.devices.iter().filter(|d| ids.contains(&d.id)).map(|d| (d.id.to_hex(), d.name.clone(), d.kind.as_str().to_owned())).collect()
                }
                None => c.devices.iter().map(|d| (d.device.to_hex(), d.name.clone(), d.kind.as_str().to_owned())).collect(),
            };
            for (id, name, kind) in &entries {
                let name = if name.is_empty() { "device" } else { name.as_str() };
                self.store.run("insert or ignore into devices(id,user,name,kind,added_at) values(?,?,?,?,?)", &[id, &u, &name, &self.kind_of(id, kind, name).as_str(), &now]);
            }
            if !entries.is_empty() {
                let marks = vec!["?"; entries.len()].join(",");
                let mut args: Vec<&dyn ToSql> = vec![&u];
                args.extend(entries.iter().map(|e| &e.0 as &dyn ToSql));
                self.store.run(&format!("delete from devices where user=? and id not in ({marks})"), &args);
            }
            for d in &c.devices {
                let p = self.path_of(&d.path, d.rtt_ms);
                self.st().live.insert(d.device.to_hex(), (d.online, p));
            }
        }
        if dropped > 0 || !book.is_empty() {
            self.emit(Change::Contacts);
            self.emit(Change::Peers);
        }
    }

    /// A device's kind as baud says it: the card's word when it knows one, else what my store
    /// already holds for it (an Android phone tells its kind in baud's card, peer says "node").
    fn kind_of(&self, id: &str, peer_kind: &str, name: &str) -> DeviceKind {
        if let Some(k) = self.store.one("select kind from devices where id=?", &[&id]).and_then(|r| r.string("kind")) {
            return DeviceKind::parse(&k);
        }
        match peer_kind {
            "mac" => DeviceKind::Mac,
            "iphone" | "ipad" => DeviceKind::Iphone,
            _ if name.to_lowercase().contains("iphone") => DeviceKind::Iphone,
            _ => DeviceKind::parse(peer_kind),
        }
    }

    pub(crate) fn path_of(&self, p: &peer::Path, rtt: Option<u32>) -> Path {
        match p {
            peer::Path::Direct { .. } => Path::Direct { ms: rtt },
            peer::Path::Relay(d) => {
                let id = d.to_hex();
                let name = self
                    .store
                    .one("select d.kind, d.user, p.name from devices d left join people p on p.user=d.user where d.id=?", &[&id])
                    .map(|r| sentences::whose(r.string("user").as_deref() == Some(self.user().as_str()), &r.string("name").unwrap_or_default(), &r.string("kind").unwrap_or_default()))
                    .unwrap_or_else(|| "a friend's device".into());
                Path::Relay { device: id, name }
            }
            peer::Path::Nearby => Path::Nearby,
            peer::Path::Waiting => Path::Waiting,
            peer::Path::Unreachable => Path::Unreachable,
        }
    }

    /// A friend who had two identities is one now (peer's redirect): everything the old key
    /// wrote, joined or received is the new key's, and one contact remains. Vouched, not verified.
    pub(crate) fn redirect(&self, old: &str, new: &str) {
        let me = self.user();
        if old == new || old.is_empty() || new.is_empty() || new == me || old == me {
            return;
        }
        let was = self.store.one("select * from people where user=?", &[&old]);
        for t in ["events", "receipts", "devices"] {
            self.store.run(&format!("update {t} set user=? where user=?"), &[&new, &old]);
        }
        self.store.run("update or ignore members set user=? where user=?", &[&new, &old]);
        self.store.run("delete from members where user=?", &[&old]);
        self.store.run(
            "insert into people(user,name,fingerprint,verified,contact,met_at,vouched) values(?,?,'',0,1,?,1) on conflict(user) do update set contact=1, vouched=case when people.verified=1 then 0 else 1 end, name=case when people.name is null or people.name='' then excluded.name else people.name end",
            &[&new, &was.as_ref().and_then(|w| w.string("name")).unwrap_or_default(), &was.as_ref().and_then(|w| w.double("met_at")).unwrap_or_else(now)],
        );
        self.store.run("delete from people where user=?", &[&old]);
        self.emit(Change::Contacts);
        self.emit(Change::Peers);
        self.emit(Change::Conversations);
    }

    /// peer admits a co-member's devices for this conversation once it holds their card; the
    /// group gets its tier before its first member (a chat: reached through mutuals).
    pub(crate) fn admit(&self, conv: &str, u: &str) {
        let Some(card) = self.peer_card_of(u) else {
            self.log(format!("no card for {} to admit into {}", short(u), short(conv)));
            return;
        };
        let Ok(group) = group_of(conv) else { return };
        if self.st().made.insert(conv.to_owned()) {
            let space = self.conversation(conv).map(|c| matches!(c.kind, Kind::Space | Kind::Channel)).unwrap_or(false);
            let _ = self.net.peer.create_group(group, if space { peer::GroupKind::Space } else { peer::GroupKind::Chat });
        }
        match peer::card::Card::from_bytes(&card) {
            Ok(c) => {
                if let Err(e) = self.net.peer.add_member(group, c) {
                    self.log(format!("addMember failed: {e}"));
                }
            }
            Err(e) => self.log(format!("bad card for {}: {e}", short(u))),
        }
    }

    pub(crate) fn blob_path(&self, hash: &str) -> PathBuf {
        self.dir.join("blobs").join(hash)
    }
}

pub(crate) fn wire_of(r: &Row) -> WireEvent {
    WireEvent {
        id: r.string("id").unwrap_or_default(),
        conv: r.string("conv").unwrap_or_default(),
        device: r.string("device").unwrap_or_default(),
        seq: r.int("seq").unwrap_or(0),
        user: r.string("user").unwrap_or_default(),
        at: r.double("at").unwrap_or(0.0),
        lamport: r.int("lamport").unwrap_or(0),
        kind: EventType::parse(&r.string("type").unwrap_or_default()),
        text: r.string("text"),
        reply: r.string("reply"),
        thread: r.string("thread"),
        target: r.string("target"),
        body: r.string("body").unwrap_or_else(|| "{}".into()),
    }
}

pub(crate) fn short(s: &str) -> &str {
    &s[..s.len().min(8)]
}

pub(crate) fn group_of(conv: &str) -> std::result::Result<peer::identity::GroupId, ()> {
    if conv.len() != 64 {
        return Err(());
    }
    let mut b = [0u8; 32];
    for i in 0..32 {
        b[i] = u8::from_str_radix(&conv[i * 2..i * 2 + 2], 16).map_err(|_| ())?;
    }
    Ok(peer::identity::GroupId(b))
}
