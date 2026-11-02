//! Posting and receiving (`Carry.swift`, `Transport.swift`): a frame to a device now or to
//! carriers, sealed with its conversation's key; frames in; clocks on connect so each side
//! sends what the other lacks; and the delivery rows that make "carried by Jo's Mac" true.

use std::collections::{BTreeMap, HashSet};
use std::time::Duration;

use base64::Engine;
use base64::engine::general_purpose::STANDARD;

use crate::core::{Core, short, wire_of};
use crate::json::decode_bytes;
use crate::sentences;
use crate::store::now;
use crate::types::*;
use crate::wire::*;

/// How long a carrier holds an envelope: two weeks.
const TTL: Duration = Duration::from_secs(14 * 86_400);

impl Core {
    /// Live if it can, else to someone in the conversation who holds the recipient's card, else
    /// sealed to carriers; the answer comes back later. A frame to another device of mine carries
    /// the conversation's key too (it is me, over peer's device-to-device encryption): a device
    /// that just became mine can open my chats.
    pub(crate) fn post(&self, frame: Frame, d: &str, conv: &str, joiner: bool) {
        // Closed: it is in the store, and the clocks carry it from the next open.
        if self.is_closed() {
            return;
        }
        let own = self.store.int("select count(*) as n from devices where id=? and user=?", &[&d, &self.user()]) > 0;
        let bytes = self.seal(&frame, (!conv.is_empty()).then_some(conv), joiner || own);
        let events: Vec<EventId> = match &frame {
            Frame::Events(es) => es.iter().map(|e| e.id.clone()).collect(),
            _ => vec![],
        };
        // Asleep, it is woken for a message someone else wrote; never for my own, syncing to my phone.
        let theirs = self.user_of(d);
        let wakes = match &frame {
            Frame::Events(es) => es.iter().any(|e| e.kind == EventType::Message && Some(&e.user) != theirs.as_ref()),
            _ => false,
        };
        let (core, d, conv) = (self.arc(), d.to_owned(), conv.to_owned());
        self.spawn(async move {
            if core.net.is_online(&d) && core.send_to(&bytes, &d).await {
                return;
            }
            // A co-member who isn't a friend: no card, so no connection and no carriers. Someone
            // in the conversation who holds both cards passes it on, now.
            if !conv.is_empty() && !core.reaches(&d) && core.relay(&bytes, &d, &conv).await {
                return;
            }
            let carriers = core.post_to_carriers(bytes, &d).await;
            if wakes {
                let (core, d) = (core.clone(), d.clone());
                core.clone().spawn(async move {
                    core.wake(&d, crate::wake::WakeKind::Message).await;
                });
            }
            let at = now();
            for c in &carriers {
                for e in &events {
                    core.store.run("insert or ignore into handed(event,to_device,carrier,at) values(?,?,?,?)", &[e, &d, c, &at]);
                }
            }
            if !conv.is_empty() {
                core.emit(Change::Delivery { conv });
            }
        });
    }

    /// Sealed and handed to carriers, only to a device whose card peer holds; a member seen
    /// before its card arrived waits here, and the feed sync on the next connection carries it.
    async fn post_to_carriers(&self, bytes: Vec<u8>, d: &str) -> Vec<DeviceId> {
        if !self.reaches(d) {
            self.log(format!("holding post to {}: no card yet", short(d)));
            return vec![];
        }
        let Ok(to) = peer::identity::DeviceId::from_hex(d) else { return vec![] };
        match self.net.peer.post(to, bytes, TTL).await {
            Ok(_) => {
                let carriers: Vec<String> = self.net.peer.helpers_for(to).into_iter().map(|c| c.to_hex()).collect();
                self.log(format!("posted to {}: carriers {:?}", short(d), carriers.iter().map(|c| short(c)).collect::<Vec<_>>()));
                carriers
            }
            Err(e) => {
                self.log(format!("post to {} failed: {e}", short(d)));
                vec![]
            }
        }
    }

    /// Whether peer may connect or post to that device: a card it holds names it (mine, a
    /// contact's, a co-member's). A device linked after I first held the card: ask again.
    pub(crate) fn reaches(&self, d: &str) -> bool {
        let Ok(id) = peer::identity::DeviceId::from_hex(d) else { return false };
        if self.net.peer.user_of_device(&id).is_some() {
            return true;
        }
        let Some(u) = self.user_of(d).and_then(|u| peer::identity::UserId::from_hex(&u).ok()) else { return false };
        self.net.peer.card_of(u).map(|c| c.device_ids().any(|x| x == id)).unwrap_or(false)
    }

    /// Sealed bytes for a co-member I hold no card for, handed to members I'm connected to (at
    /// most two, not mine: my devices hold the same book) to pass on. True when one took it.
    async fn relay(&self, bytes: &[u8], d: &str, conv: &str) -> bool {
        let theirs = self.user_of(d).unwrap_or_default();
        let via: Vec<String> = self
            .store
            .query("select d.id from devices d join members m on m.user=d.user where m.conv=? and d.user<>? and d.user<>?", &[&conv, &self.user(), &theirs])
            .iter()
            .filter_map(|r| r.string("id"))
            .filter(|v| self.net.is_online(v))
            .take(2)
            .collect();
        let mut took = false;
        let wrapped = self.seal(&Frame::Relay(d.to_owned(), bytes.to_vec()), None, false);
        for v in &via {
            if self.send_to(&wrapped, v).await {
                took = true;
            }
        }
        self.log(format!("relay to {} in {} via {:?}: {}", short(d), short(conv), via.iter().map(|v| short(v)).collect::<Vec<_>>(), if took { "taken" } else { "nobody" }));
        took
    }

    /// A member asks me to pass sealed bytes to another: only within a conversation all three
    /// of us are in, and only to a device whose card I hold.
    fn relayed(&self, bytes: Vec<u8>, d: &str, from: &str) {
        let Some(conv) = decode_bytes::<Packet>(&bytes).and_then(|p| p.conv) else { return };
        let (Some(a), Some(b)) = (self.user_of(from), self.user_of(d)) else { return };
        if !self.reaches(d) {
            return;
        }
        let members: HashSet<String> = self.store.query("select user from members where conv=?", &[&conv]).iter().filter_map(|r| r.string("user")).collect();
        if !(members.contains(&self.user()) && members.contains(&a) && members.contains(&b)) {
            self.log(format!("relay refused: {} to {} outside {}", short(from), short(d), short(&conv)));
            return;
        }
        let (core, d) = (self.arc(), d.to_owned());
        self.spawn(async move {
            if core.net.is_online(&d) && core.send_to(&bytes, &d).await {
                return;
            }
            core.post_to_carriers(bytes, &d).await;
        });
    }

    /// Tell every device I know (my own, my contacts', my co-members') something small.
    pub(crate) fn tell(&self, frame: Frame) {
        let me = self.device();
        for r in self.store.query("select id from devices where id<>?", &[&me]) {
            if let Some(d) = r.string("id") {
                self.post(frame.clone(), &d, "", false);
            }
        }
    }

    // MARK: sealing

    fn conv_key(&self, conv: &str) -> [u8; 32] {
        if let Some(k) = self.existing_key(conv) {
            return k;
        }
        let k: [u8; 32] = rand::random();
        self.store.run("insert or replace into me(k,v) values(?,?)", &[&format!("key:{conv}"), &STANDARD.encode(k)]);
        k
    }

    /// The key a conversation already has here; none before its first membership frame arrives.
    fn existing_key(&self, conv: &str) -> Option<[u8; 32]> {
        let v = self.store.one("select v from me where k=?", &[&format!("key:{conv}")])?.string("v")?;
        STANDARD.decode(v).ok()?.try_into().ok()
    }

    /// Seal a frame for the wire. Membership and creation frames for a joiner carry the key.
    pub(crate) fn seal(&self, frame: &Frame, conv: Option<&str>, joiner: bool) -> Vec<u8> {
        match conv {
            None => seal_packet(frame, None, false, [0; 12]),
            Some(c) => {
                let key = self.conv_key(c);
                seal_packet(frame, Some((c, &key)), joiner, rand::random())
            }
        }
    }

    /// Open a packet from the wire; none when it is from an older wire, or for a conversation
    /// this device has no key to yet: then it is kept (with who handed it over) and opened when
    /// the key comes. A message can race its conversation's creation, which carries the key.
    fn open_packet(&self, bytes: &[u8], from: &str, carried_by: Option<&str>) -> Option<Frame> {
        let p: Packet = decode_bytes(bytes)?;
        if p.v != Some(WIRE_VERSION) {
            return None;
        }
        let (Some(conv), Some(nonce)) = (&p.conv, &p.nonce) else { return decode_bytes(&p.body) };
        if let Some(k) = &p.key {
            self.store.run("insert or replace into me(k,v) values(?,?)", &[&format!("key:{conv}"), &STANDARD.encode(k)]);
        }
        let Some(key) = self.existing_key(conv) else {
            let mut st = self.st();
            if st.waiting_for_key.len() < 500 {
                st.waiting_for_key.push((conv.clone(), bytes.to_vec(), from.to_owned(), carried_by.map(String::from)));
            }
            return None;
        };
        decode_bytes(&open_box(&key, nonce, &p.body)?)
    }

    /// peer hands in bytes: open them and treat them as a received frame, then open whatever was
    /// waiting for a key this frame brought.
    /// Bytes as if they came from that device over a connection: for tests that hand in a frame
    /// exactly as another platform wrote it.
    #[doc(hidden)]
    pub fn receive_packet(&self, bytes: &[u8], from: &str) {
        self.receive_bytes(bytes, from, None);
    }

    pub(crate) fn receive_bytes(&self, bytes: &[u8], from: &str, carried_by: Option<&str>) {
        let Some(f) = self.open_packet(bytes, from, carried_by) else { return };
        self.receive(f, from, carried_by);
        let waiting = std::mem::take(&mut self.st().waiting_for_key);
        if waiting.is_empty() {
            return;
        }
        let (ready, still): (Vec<_>, Vec<_>) = waiting.into_iter().partition(|w| self.existing_key(&w.0).is_some());
        self.st().waiting_for_key.extend(still);
        for (_, b, f, c) in ready {
            self.receive_bytes(&b, &f, c.as_deref());
        }
    }

    pub(crate) fn receive(&self, frame: Frame, from: &str, carried_by: Option<&str>) {
        self.store.run("update devices set last_online=? where id=?", &[&now(), &from]);
        let (me, my_device) = (self.user(), self.device());
        match frame {
            Frame::Events(es) => {
                let mut touched = HashSet::new();
                let mut stopped = HashSet::new();
                for e in &es {
                    // An event that reached me from a device other than its writer was carried by that device.
                    let by = carried_by.map(String::from).or_else(|| (from != e.device && !from.is_empty()).then(|| from.to_owned()));
                    if !self.apply(e, by.as_deref()) {
                        continue;
                    }
                    touched.insert(e.conv.clone());
                    // Their message is here: they are no longer typing it.
                    if e.kind == EventType::Message && self.st().typing_seen.get_mut(&e.conv).and_then(|m| m.remove(&e.user)).is_some() {
                        stopped.insert(e.conv.clone());
                    }
                    if e.kind != EventType::Message || e.user == me {
                        continue;
                    }
                    let r = WireReceipt { conv: e.conv.clone(), device: my_device.clone(), user: me.clone(), event: e.id.clone(), lamport: e.lamport, kind: "delivered".into(), at: now() };
                    self.apply_receipt(&r);
                    for d in self.store.query("select id from devices where user=(select user from devices where id=?)", &[&e.device]).iter().filter_map(|r| r.string("id")) {
                        if d != my_device {
                            self.post(Frame::Receipt(r.clone()), &d, &e.conv, false);
                        }
                    }
                }
                if !touched.is_empty() {
                    self.emit(Change::Conversations);
                }
                for c in stopped {
                    self.emit(Change::Typing { conv: c });
                }
                self.prefetch(&es);
            }
            Frame::Receipt(r) => self.apply_receipt(&r),
            Frame::Typing(conv, u) => {
                self.st().typing_seen.entry(conv.clone()).or_default().insert(u, std::time::Instant::now());
                self.emit(Change::Typing { conv });
            }
            Frame::Envelope(env) => {
                // The in-process mesh's carrying; peer carries its own. Kept for a device that
                // still hands one over: opened if mine, held if not.
                if env.to == my_device {
                    self.receive(env.frame, &env.from, Some(from));
                } else {
                    self.store.run(
                        "insert or ignore into envelopes(id,to_device,from_device,conv,frame,size,expires,hops,held_at) values(?,?,?,?,?,?,?,?,?)",
                        &[&env.id, &env.to, &env.from, &env.conv, &crate::json::encode(&env.frame), &env.size, &env.expires, &env.hops, &now()],
                    );
                    self.emit(Change::Carrying);
                }
            }
            Frame::Ack(id) => {
                self.store.run("delete from envelopes where id=?", &[&id]);
                self.emit(Change::Carrying);
            }
            Frame::Card(c) => {
                let contact = self.store.int("select count(*) as n from people where user=? and contact=1", &[&c.user]) > 0;
                self.save_card(&c, contact);
                self.emit(Change::Contacts);
                self.emit(Change::Peers);
            }
            Frame::Welcome { card } => {
                self.save_card(&card, true);
                self.emit(Change::Contacts);
                self.emit(Change::Peers);
            }
            Frame::Clock(conv, theirs) => self.answer_clock(&conv, &theirs, from, true),
            Frame::ClockReply(conv, theirs) => self.answer_clock(&conv, &theirs, from, false),
            Frame::Relay(to, bytes) => self.relayed(bytes, &to, from),
            Frame::InCall(..) => {} // calls come later
            Frame::Want(hash) => self.wanted(&hash, from),
            Frame::Offer(hash, id) => self.offered(&hash, &id, from),
            Frame::Wake(ticket, expires) => self.keep_wake(&ticket, expires, from),
            Frame::Place(conv, p) => self.keep_place(p, &conv, from),
            Frame::Hello { .. } | Frame::Link { .. } => {} // the stub's handshakes; peer meets on its own
        }
    }

    pub(crate) fn apply_receipt(&self, r: &WireReceipt) {
        self.store.run("insert or ignore into receipts(conv,device,user,event,lamport,kind,at) values(?,?,?,?,?,?,?)", &[&r.conv, &r.device, &r.user, &r.event, &r.lamport, &r.kind, &r.at]);
        // Read on another device of mine is read here: the chat's unread follows me.
        let read_here = r.kind == "read"
            && r.user == self.user()
            && r.device != self.device()
            && self.store.one("select lamport from reads where conv=?", &[&r.conv]).and_then(|x| x.int("lamport")).unwrap_or(-1) < r.lamport;
        if read_here {
            self.store.run("insert or replace into reads(conv,event,lamport) values(?,?,?)", &[&r.conv, &r.event, &r.lamport]);
        }
        self.emit(Change::Delivery { conv: r.conv.clone() });
        if read_here {
            self.emit(Change::Conversations);
        }
    }

    pub(crate) fn clock(&self, conv: &str) -> BTreeMap<DeviceId, i64> {
        self.store.query("select device, max(seq) as s from events where conv=? group by device", &[&conv]).iter().filter_map(|r| Some((r.string("device")?, r.int("s").unwrap_or(0)))).collect()
    }

    /// A device came online: offer it my clocks for everything we share, so each side sends
    /// what the other lacks; then ask it again for files I'm missing.
    pub(crate) fn connected(&self, d: &str) {
        if !self.is_online() {
            return;
        }
        let convs: Vec<String> = self
            .store
            .query("select distinct a.conv from members a join members b on b.conv=a.conv join devices d on d.user=b.user where a.user=? and d.id=?", &[&self.user(), &d])
            .iter()
            .filter_map(|r| r.string("conv"))
            .collect();
        for conv in convs {
            self.post(Frame::Clock(conv.clone(), self.clock(&conv)), d, &conv, false);
        }
        self.retry_missing(d);
    }

    /// Envelopes that arrived while away: open each, name its carrier, acknowledge.
    pub(crate) fn drain_inbox(&self) {
        for e in self.net.peer.inbox() {
            let from = e.from.map(|d| d.to_hex()).unwrap_or_default();
            let by = e.carried_by.first().map(|d| d.to_hex());
            self.receive_bytes(&e.bytes, &from, by.as_deref());
            let _ = self.net.peer.ack(e.id);
        }
    }

    // MARK: delivery

    pub fn delivery(&self, conv: &str, ev: &str) -> Delivery {
        let me = self.user();
        let Some(e) = self.store.one("select lamport, user from events where id=?", &[&ev]) else {
            return Delivery { event: ev.into(), devices: vec![], sentence: sentences::delivery(&[]), best: DeliveryState::Sent };
        };
        let l = e.int("lamport").unwrap_or(0);
        let names: std::collections::HashMap<String, String> = self.store.query("select user, name from people", &[]).iter().filter_map(|r| Some((r.string("user")?, r.string("name").unwrap_or_else(|| "?".into())))).collect();
        let mut out = vec![];
        for u in self.store.query("select user from members where conv=? and user<>?", &[&conv, &me]).iter().filter_map(|r| r.string("user")) {
            let read_l = self.store.one("select max(lamport) as l from receipts where conv=? and user=? and kind='read'", &[&conv, &u]).and_then(|r| r.int("l")).unwrap_or(-1);
            for d in self.devices_of(&u) {
                let mut carriers = vec![];
                let state = if read_l >= l {
                    DeliveryState::Read
                } else if self.store.int("select count(*) as n from receipts where conv=? and device=? and event=? and kind='delivered'", &[&conv, &d.id, &ev]) > 0 {
                    DeliveryState::Delivered
                } else {
                    let hs = self.store.query("select h.carrier, d.kind, d.user from handed h left join devices d on d.id=h.carrier where h.event=? and h.to_device=?", &[&ev, &d.id]);
                    if hs.is_empty() {
                        DeliveryState::Sent
                    } else {
                        carriers = hs.iter().map(|h| {
                            let u = h.string("user").unwrap_or_default();
                            sentences::whose(u == me, names.get(&u).map(String::as_str).unwrap_or("someone"), &h.string("kind").unwrap_or_default())
                        }).collect();
                        carriers.sort_by_key(|c| if c.starts_with("your") { String::new() } else { c.clone() });
                        DeliveryState::Carried { by: hs[0].string("carrier").unwrap_or_default() }
                    }
                };
                out.push(DeviceDelivery { device: d, person_name: names.get(&u).cloned().unwrap_or_else(|| "?".into()), state, carriers });
            }
        }
        Delivery { event: ev.into(), sentence: sentences::delivery(&out), best: sentences::best(&out), devices: out }
    }

    /// They told me what they hold: send what they lack from every feed I have, and my
    /// receipts. If they hold anything I lack (a conversation I have never seen included), my
    /// clock goes back once so they send it; a reply is never answered, so it ends there.
    fn answer_clock(&self, conv: &str, theirs: &BTreeMap<DeviceId, i64>, from: &str, answer: bool) {
        let (me, my_device) = (self.user(), self.device());
        let mine = self.clock(conv);
        let mut missing: Vec<crate::store::Row> = vec![];
        for (d, s) in &mine {
            let have = theirs.get(d).copied().unwrap_or(0);
            if *s > have {
                missing.extend(self.store.query("select * from events where conv=? and device=? and seq>? order by seq", &[&conv, d, &have]));
            }
        }
        missing.sort_by(|a, b| (a.int("lamport").unwrap_or(0), a.string("id")).cmp(&(b.int("lamport").unwrap_or(0), b.string("id"))));
        if !missing.is_empty() {
            self.post(Frame::Events(missing.iter().map(wire_of).collect()), from, conv, false);
        }
        for r in self.store.query("select * from receipts where conv=? and device=?", &[&conv, &my_device]) {
            let rec = WireReceipt { conv: conv.into(), device: my_device.clone(), user: me.clone(), event: r.string("event").unwrap_or_default(), lamport: r.int("lamport").unwrap_or(0), kind: r.string("kind").unwrap_or_else(|| "delivered".into()), at: r.double("at").unwrap_or(0.0) };
            self.post(Frame::Receipt(rec), from, conv, false);
        }
        if answer && theirs.iter().any(|(k, v)| *v > mine.get(k).copied().unwrap_or(0)) {
            self.post(Frame::ClockReply(conv.into(), mine), from, conv, false);
        }
    }
}
