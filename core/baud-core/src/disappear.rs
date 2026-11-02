//! Disappearing messages (`Disappear.swift`). The setting is a state line ("disappear", in
//! seconds); each message written while it is on carries its own `ttl`, so when it goes never
//! depends on the order the setting arrived in. My own messages go `ttl` after they were sent;
//! anyone else's `ttl` after any device of mine first read them (the earliest read receipt of
//! mine at or past it), and an unread one waits. Each device does this on its own: the message
//! is blanked as a redaction blanks one, with its edits, its pin and its files, and its feed row
//! stays so the clocks stay whole and nobody sends it again.

use std::collections::{BTreeMap, BTreeSet};
use std::time::Duration;

use crate::core::Core;
use crate::json::decode;
use crate::store::now;
use crate::types::*;
use crate::wire::*;

/// A message body's `ttl` in SQL, as the decoder reads it: a whole number, or null for a body that
/// isn't JSON (which `json_extract` would fail the whole statement on) or has none.
const TTL: &str = "(case when json_valid(body) then (case when json_type(body,'$.ttl')='integer' then json_extract(body,'$.ttl') end) end)";

impl Core {
    /// When a message goes from this device: mine at `at + ttl`, anyone else's `ttl` after my
    /// first read of it; none without a `ttl`, or while it's unread.
    pub(crate) fn expiry_of(&self, e: &WireEvent) -> Option<f64> {
        if e.kind != EventType::Message {
            return None;
        }
        let ttl = decode::<MessageBody>(&e.body).and_then(|b| b.ttl).filter(|t| *t > 0)? as f64;
        let me = self.user();
        if e.user == me {
            return Some(e.at + ttl);
        }
        let read = self.store.one("select min(at) as t from receipts where conv=? and user=? and kind='read' and lamport>=?", &[&e.conv, &me, &e.lamport]).and_then(|r| r.double("t"))?;
        Some(read + ttl)
    }

    /// A message already blanked here (gone, or redacted).
    pub(crate) fn gone(&self, id: &str) -> bool {
        self.store.one("select body from events where id=? and type='message'", &[&id]).and_then(|r| r.string("body")).as_deref() == Some("{}")
    }

    /// My read of a conversation up to `lamport`, at `at`, on this device or another of mine:
    /// the clock starts on everyone else's disappearing messages it covers, and an earlier read
    /// that arrives late moves it sooner. Whatever is past its time goes at once.
    pub(crate) fn start_clocks(&self, conv: &str, lamport: i64, at: f64) {
        let changed = self.store.run(
            &format!("update events set expires_at=?+{TTL} where conv=? and type='message' and user<>? and lamport<=? and body like '%\"ttl\":%' and {TTL}>0 and (expires_at is null or expires_at>?+{TTL})"),
            &[&at, &conv, &self.user(), &lamport, &at],
        );
        if changed > 0 {
            self.expire(now());
        }
    }

    /// Every disappearing message whose time has come goes from this device: its words and
    /// files blanked as `redact` blanks them (text null, body '{}', out of search), the edits
    /// that carry its words too, its pin, and each file no message still here names (nor
    /// anyone's photo). The timelines and the list redraw; `Expired` takes their notifications
    /// away. Then the sweep waits for the next one. How many went.
    pub(crate) fn expire(&self, at: f64) -> usize {
        let due = self.store.query("select id, conv, body from events where type='message' and expires_at<=? and body<>'{}' order by lamport", &[&at]);
        let mut by_conv: BTreeMap<ConversationId, Vec<EventId>> = BTreeMap::new();
        if !due.is_empty() {
            let mut files = BTreeSet::new();
            self.store.transaction(|| {
                for r in &due {
                    let (Some(id), Some(conv)) = (r.string("id"), r.string("conv")) else { continue };
                    for a in r.string("body").and_then(|b| decode::<MessageBody>(&b)).and_then(|b| b.attachments).unwrap_or_default() {
                        files.insert(a.hash);
                    }
                    self.store.run("delete from fts where event=?", &[&id]);
                    self.store.run("update events set text=null, body='{}' where id=? or (type='edit' and target=?)", &[&id, &id]);
                    self.store.run("delete from pins where event=?", &[&id]);
                    by_conv.entry(conv).or_default().push(id);
                }
            });
            for h in files {
                let named = self.store.int("select count(*) as n from events where type='message' and instr(body, ?) > 0", &[&h]) > 0;
                let face = self.store.int("select count(*) as n from people where avatar=?", &[&h]) > 0;
                if !named && !face {
                    let _ = std::fs::remove_file(self.blob_path(&h));
                }
            }
        }
        let n: usize = by_conv.values().map(Vec::len).sum();
        if n > 0 {
            self.log(format!("expired {n} in {} conversations", by_conv.len()));
            for (conv, events) in by_conv {
                self.emit(Change::Expired { conv: conv.clone(), events });
                self.emit(Change::Conversation { id: conv });
            }
            self.emit(Change::Conversations);
        }
        self.schedule_expiry();
        n
    }

    /// The sweep waits for the next message due to go, while this core runs; a sooner one
    /// arriving moves it up.
    pub(crate) fn schedule_expiry(&self) {
        let next = self.store.one("select min(expires_at) as t from events where type='message' and expires_at is not null and body<>'{}'", &[]).and_then(|r| r.double("t"));
        let mut st = self.st();
        if st.expiry_due == next {
            return;
        }
        if let Some(t) = st.expiry_task.take() {
            t.abort();
        }
        st.expiry_due = next;
        let Some(next) = next else { return };
        let core = self.this.clone();
        st.expiry_task = Some(self.rt.spawn(async move {
            tokio::time::sleep(Duration::from_secs_f64((next - now()).max(0.0))).await;
            let Some(core) = core.upgrade() else { return };
            {
                let mut st = core.st();
                st.expiry_task = None;
                st.expiry_due = None;
            }
            core.expire(now());
        }));
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use peer::identity::MemoryKeychain;

    use crate::core::Core;
    use crate::json::encode;
    use crate::store::now;
    use crate::types::*;
    use crate::wire::*;

    fn config(name: &str) -> Config {
        let mut c = Config::new(name, &format!("{name}'s phone"), DeviceKind::Android);
        c.nearby = false;
        c.portmap = false; // tests never map a port on the developer's router
        c
    }

    async fn open(dir: &std::path::Path, name: &str) -> Arc<Core> {
        let c = Core::open(dir.to_path_buf(), Arc::new(MemoryKeychain::default()), config(name)).await.unwrap();
        c.set_online(true);
        c
    }

    async fn until(what: &str, secs: u64, mut f: impl FnMut() -> bool) {
        for _ in 0..secs * 20 {
            if f() {
                return;
            }
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        }
        panic!("timed out waiting for {what}");
    }

    fn texts(c: &Core, conv: &str) -> Vec<String> {
        c.events(conv, None, 50).into_iter().filter_map(|e| e.text).collect()
    }

    fn col(c: &Core, id: &str, k: &str) -> Option<String> {
        c.store.one("select * from events where id=?", &[&id]).and_then(|r| r.string(k))
    }

    fn at(c: &Core, id: &str, k: &str) -> Option<f64> {
        c.store.one("select * from events where id=?", &[&id]).and_then(|r| r.double(k))
    }

    /// A message from someone else, as it would arrive: from a device and a person this one
    /// doesn't need to know.
    fn theirs(conv: &str, seq: i64, lamport: i64, at: f64, body: &MessageBody) -> WireEvent {
        WireEvent { id: format!("f-{conv}-{seq}"), conv: conv.into(), device: "friend-device".into(), seq, user: "friend".into(), at, lamport, kind: EventType::Message, text: body.text.clone(), reply: None, thread: None, target: None, body: encode(body) }
    }

    /// The setting travels between two real cores as a state line both read, with its line; a
    /// message written while it's on carries its `ttl`, and Ben's copy, unread, waits until he
    /// reads it.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn the_setting_travels_and_theirs_waits_until_read() {
        let d: Vec<tempfile::TempDir> = (0..2).map(|_| tempfile::tempdir().unwrap()).collect();
        let ana = open(d[0].path(), "Ana").await;
        let ben = open(d[1].path(), "Ben").await;
        ben.add(&ana.invite().unwrap().url).await.unwrap();
        let (a, b) = (ana.me().user, ben.me().user);
        let chat = |c: &Core, u: &str| c.conversations(Some(Kind::Chat)).into_iter().find(|x| x.is_direct && x.members.iter().any(|m| m == u));
        until("the chat", 10, || chat(&ana, &b).is_some() && chat(&ben, &a).is_some()).await;
        let conv = chat(&ana, &b).unwrap().id;

        ana.set_disappear(&conv, 86_400).unwrap();
        until("ben has the setting", 10, || ben.conversation(&conv).map(|c| c.disappear) == Some(86_400)).await;
        let lines = |c: &Core| c.events(&conv, None, 20).into_iter().filter_map(|e| e.system).collect::<Vec<_>>();
        assert!(lines(&ana).contains(&"You set messages to disappear 1 day after they're read".to_owned()), "{:?}", lines(&ana));
        assert!(lines(&ben).contains(&"Ana set messages to disappear 1 day after they're read".to_owned()), "{:?}", lines(&ben));

        let e = ana.send(&conv, Draft { text: "the door code is 4471".into(), ..Default::default() }).unwrap();
        until("ben has it", 10, || texts(&ben, &conv).contains(&"the door code is 4471".to_owned())).await;
        assert_eq!(decode_ttl(&col(&ben, &e.id, "body").unwrap()), Some(86_400));
        let sent = at(&ana, &e.id, "at").unwrap();
        assert!((at(&ana, &e.id, "expires_at").unwrap() - (sent + 86_400.0)).abs() < 0.001, "mine: a day after I sent it");
        assert_eq!(at(&ben, &e.id, "expires_at"), None, "theirs, unread: no clock yet");
        assert_eq!(ben.expire(now() + 365.0 * 86_400.0), 0, "unread, it waits");
        assert!(texts(&ben, &conv).contains(&"the door code is 4471".to_owned()));

        ben.mark_read(&conv, &e.id).unwrap();
        let read = ben.store.one("select at from receipts where event=? and kind='read'", &[&e.id]).and_then(|r| r.double("at")).unwrap();
        assert!((at(&ben, &e.id, "expires_at").unwrap() - (read + 86_400.0)).abs() < 0.001, "theirs: a day after I read it");
        assert_eq!(ben.expire(now() + 3600.0), 0);
        assert_eq!(ben.expire(now() + 86_401.0), 1);
        assert!(!texts(&ben, &conv).contains(&"the door code is 4471".to_owned()));
        assert!(ben.search("4471", None).is_empty());

        ana.set_disappear(&conv, 0).unwrap();
        until("off for ben", 10, || ben.conversation(&conv).map(|c| c.disappear) == Some(0)).await;
        assert!(lines(&ben).contains(&"Ana turned off disappearing messages".to_owned()));
        let after = ana.send(&conv, Draft { text: "back to normal".into(), ..Default::default() }).unwrap();
        assert!(!col(&ana, &after.id, "body").unwrap().contains("ttl"), "today's bytes when it's off");
    }

    fn decode_ttl(body: &str) -> Option<i64> {
        crate::json::decode::<MessageBody>(body).and_then(|b| b.ttl)
    }

    /// Mine goes `ttl` after I sent it: from the timeline, search and the list's last line, with
    /// its edit and its pin; its feed row stays. And the sweep runs on its own at its time.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn mine_goes_at_send_plus_ttl() {
        let d = tempfile::tempdir().unwrap();
        let ana = open(d.path(), "Ana").await;
        let g = ana.create_group("notes", &[]).unwrap();
        ana.set_disappear(&g.id, 60).unwrap();
        let e = ana.send(&g.id, Draft { text: "meet at the north gate".into(), ..Default::default() }).unwrap();
        ana.edit(&g.id, &e.id, "meet at the south gate").unwrap();
        ana.pin(&g.id, &e.id, true).unwrap();
        assert_eq!(ana.conversation(&g.id).unwrap().pinned, vec![e.id.clone()]);
        assert_eq!(ana.expire(now() + 30.0), 0);
        assert!(texts(&ana, &g.id).contains(&"meet at the south gate".to_owned()));
        assert_eq!(ana.expire(now() + 61.0), 1);
        assert!(!texts(&ana, &g.id).iter().any(|t| t.contains("gate")));
        assert!(ana.search("gate", None).is_empty());
        let c = ana.conversation(&g.id).unwrap();
        assert_ne!(c.last_event.as_deref(), Some(e.id.as_str()));
        assert!(c.pinned.is_empty(), "unpinned");
        assert_eq!(col(&ana, &e.id, "body").as_deref(), Some("{}"), "blanked as a redaction is");
        assert_eq!(col(&ana, &e.id, "text"), None);
        assert_eq!(ana.clock(&g.id).get(&ana.me().this_device).copied(), Some(e.seq as i64 + 2), "the feed rows stay");
        let edit = ana.store.one("select * from events where type='edit' and target=?", &[&e.id]).unwrap();
        assert_eq!((edit.string("text"), edit.string("body").as_deref()), (None, Some("{}")), "the edit carried the words too");

        // On its own, at its time.
        ana.set_disappear(&g.id, 1).unwrap();
        ana.send(&g.id, Draft { text: "gone in a second".into(), ..Default::default() }).unwrap();
        assert!(texts(&ana, &g.id).contains(&"gone in a second".to_owned()));
        until("the sweep took it", 5, || !texts(&ana, &g.id).contains(&"gone in a second".to_owned())).await;
    }

    /// A message already gone on another device of mine arrives by the clocks blanked: kept (the
    /// feed stays whole, nobody sends it again) and never shown. One that arrives whole after my
    /// read of it already ran out goes the moment it lands; an edit of a gone one goes too.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn gone_elsewhere_arrives_hidden() {
        let d = tempfile::tempdir().unwrap();
        let me = open(d.path(), "Dee").await;
        let g = me.create_group("plans", &[]).unwrap();
        let blank = WireEvent { body: "{}".into(), text: None, ..theirs(&g.id, 1, 50, now(), &MessageBody::default()) };
        let packet = |es: Vec<WireEvent>| seal_packet(&Frame::Events(es), None, false, [0; 12]);
        me.receive_packet(&packet(vec![blank.clone()]), "friend-device");
        assert_eq!(col(&me, &blank.id, "body").as_deref(), Some("{}"), "stored");
        assert!(!me.events(&g.id, None, 10).iter().any(|e| e.id == blank.id), "never shown");
        let c = me.conversation(&g.id).unwrap();
        assert_eq!((c.unread, c.last_event), (0, None));
        assert_eq!(me.clock(&g.id).get("friend-device").copied(), Some(1), "the feed is whole");

        // Read on another device of mine two minutes ago, with a minute to live: gone on arrival.
        let old = now() - 120.0;
        let whole = theirs(&g.id, 2, 51, old, &MessageBody { text: Some("the door is blue".into()), ttl: Some(60), ..Default::default() });
        let other = "my-other-device";
        me.receive(Frame::Receipt(WireReceipt { conv: g.id.clone(), device: other.into(), user: me.me().user, event: whole.id.clone(), lamport: 51, kind: "read".into(), at: old }), other, None);
        me.receive_packet(&packet(vec![whole.clone()]), "friend-device");
        assert_eq!(col(&me, &whole.id, "body").as_deref(), Some("{}"));
        assert!(me.search("blue", None).is_empty());
        let late = WireEvent { id: "late-edit".into(), seq: 3, lamport: 52, kind: EventType::Edit, text: Some("the door is red".into()), target: Some(whole.id.clone()), body: encode(&EditBody { target: whole.id.clone(), text: "the door is red".into() }), ..whole.clone() };
        me.receive_packet(&packet(vec![late]), "friend-device");
        assert_eq!(col(&me, "late-edit", "text"), None);
        assert!(me.search("red", None).is_empty());
    }

    /// A body that isn't JSON in the same conversation doesn't stop the clocks.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_broken_body_doesnt_stop_the_clocks() {
        let d = tempfile::tempdir().unwrap();
        let me = open(d.path(), "Dee").await;
        let g = me.create_group("plans", &[]).unwrap();
        let broken = WireEvent { body: "{\"ttl\":60,".into(), ..theirs(&g.id, 1, 40, now(), &MessageBody::default()) };
        let whole = theirs(&g.id, 2, 41, now(), &MessageBody { text: Some("still goes".into()), ttl: Some(60), ..Default::default() });
        me.receive_packet(&seal_packet(&Frame::Events(vec![broken.clone(), whole.clone()]), None, false, [0; 12]), "friend-device");
        me.mark_read(&g.id, &whole.id).unwrap();
        assert!(at(&me, &whole.id, "expires_at").is_some());
        assert_eq!(at(&me, &broken.id, "expires_at"), None);
    }

    /// Its files leave the blob store, unless another message still here names the same file.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn files_go_unless_still_named() {
        let d = tempfile::tempdir().unwrap();
        let me = open(d.path(), "Dee").await;
        let fleeting = me.create_group("fleeting", &[]).unwrap();
        let lasting = me.create_group("lasting", &[]).unwrap();
        me.set_disappear(&fleeting.id, 60).unwrap();
        let (only, shared) = (d.path().join("only.txt"), d.path().join("shared.txt"));
        std::fs::write(&only, "only here").unwrap();
        std::fs::write(&shared, "in two places").unwrap();
        let path = |p: &std::path::Path| p.to_string_lossy().into_owned();
        let e = me.send(&fleeting.id, Draft { attachments: vec![path(&only), path(&shared)], ..Default::default() }).unwrap();
        me.send(&lasting.id, Draft { text: "kept".into(), attachments: vec![path(&shared)], ..Default::default() }).unwrap();
        let (a, b) = (e.attachments[0].hash.clone(), e.attachments[1].hash.clone());
        assert!(me.blob_path(&a).exists() && me.blob_path(&b).exists());
        assert_eq!(me.expire(now() + 61.0), 1);
        assert!(!me.blob_path(&a).exists(), "nobody else names it");
        assert!(me.blob_path(&b).exists(), "the other chat still names it");
    }

    /// In a channel only an admin changes it; in a chat anyone does (the first test).
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn the_setting_is_an_admins_in_a_channel() {
        let d = tempfile::tempdir().unwrap();
        let me = open(d.path(), "Dee").await;
        let id = crate::ids::new_conversation_id(&me.me().this_device);
        me.store.run("insert into conversations(id,kind,name,created_at) values(?,'channel','general',?)", &[&id, &now()]);
        me.store.run("insert into members(conv,user,admin,joined_at) values(?,?,0,?)", &[&id, &me.me().user, &now()]);
        assert!(matches!(me.set_disappear(&id, 3600), Err(crate::Error::NotAdmin)));
        me.store.run("update members set admin=1 where conv=?", &[&id]);
        me.set_disappear(&id, 3600).unwrap();
        assert_eq!(me.conversation(&id).unwrap().disappear, 3600);
    }
}
