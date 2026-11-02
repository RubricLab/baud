//! Replies (`Peer::reply`): a friend link whose maker its redeemer cannot reach is answered with a
//! reply the maker opens, and both dial at once. Here every node can reach every other, so a copy
//! of the link that names an address nobody answers stands for "the redeemer cannot reach the
//! inviter": the reply's secret comes from the link's, which the copy keeps.

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use peer::identity::MemoryKeychain;
use peer::link::{Kind, Link};
use peer::{Config, Error, Event, Listener, Peer};

static SERIAL: Mutex<()> = Mutex::new(());

struct Log(Mutex<Vec<Event>>);
impl Listener for Log {
    fn on(&self, e: Event) {
        self.0.lock().unwrap().push(e);
    }
}
impl Log {
    fn saw(&self, f: impl Fn(&Event) -> bool) -> bool {
        self.0.lock().unwrap().iter().any(f)
    }
}

fn config(name: &str) -> Config {
    let mut c = Config::new("reply", name, &format!("{name}-dev"));
    c.nearby = false;
    c.portmap = false; // tests never map a port on the developer's router
    c.auto_confirm_links = true;
    c
}

async fn node(name: &str) -> (Peer, Arc<Log>, tempfile::TempDir) {
    let d = tempfile::tempdir().unwrap();
    let p = Peer::open(d.path().to_path_buf(), Arc::new(MemoryKeychain::default()), config(name)).await.unwrap();
    let log = Arc::new(Log(Mutex::new(Vec::new())));
    p.subscribe(log.clone());
    p.set_online(true);
    (p, log, d)
}

async fn within(what: &str, limit: Duration, mut f: impl FnMut() -> bool) {
    let t = Instant::now();
    while t.elapsed() < limit {
        if f() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("{what}: not within {limit:?}");
}

/// The link as the redeemer holds it when the inviter's network refuses it: nothing answers there.
fn unreachable(link: &Link) -> Link {
    let mut l = link.clone();
    l.meet.addrs = vec!["192.0.2.1:9".into()];
    l
}

fn has(p: &Peer, other: &Peer) -> bool {
    p.contacts().iter().any(|c| c.user == other.me().user)
}

#[tokio::test(flavor = "multi_thread")]
async fn a_reply_opened_by_the_links_maker_meets_them() {
    let _serial = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let (ana, _, _da) = node("ana").await;
    let (bo, bo_log, _db) = node("bo").await;
    let invite = ana.invite().unwrap();
    let link = unreachable(&invite);
    let reply = bo.reply(&link).unwrap();
    assert_eq!((reply.kind, reply.user, reply.meet.device), (Kind::Reply, bo.me().user, bo.me().this_device));
    assert_eq!(reply.secret, peer::link::reply_secret(&link.secret));
    assert!(reply.expires <= link.expires);
    // As it travels: the text the app sends back.
    let reply = peer::link::parse(&bo.link_url(&reply)).unwrap();

    let contact = ana.add(&reply).await.expect("ana dials bo, who is waiting");
    assert_eq!((contact.user, contact.name.as_str()), (bo.me().user, "bo"));
    within("bo has ana", Duration::from_secs(5), || has(&bo, &ana)).await;
    within("bo hears it was replied", Duration::from_secs(5), || bo_log.saw(|e| *e == Event::Replied(ana.me().user))).await;
    assert_eq!(bo.contacts().iter().find(|c| c.user == ana.me().user).unwrap().name, "ana", "named as the link named her");

    // Opened again: the contact as it is, no second meeting.
    assert_eq!(ana.add(&reply).await.unwrap().user, bo.me().user);
    // The invite is spent: the link itself is refused to anyone else now.
    let (cy, _, _dc) = node("cy").await;
    assert!(matches!(cy.add(&invite).await, Err(Error::Used)));
    for p in [ana, bo, cy] {
        p.close().await;
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn an_add_that_gets_through_spends_the_reply() {
    let _serial = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let (ana, _, _da) = node("ana").await;
    let (bo, bo_log, _db) = node("bo").await;
    let link = ana.invite().unwrap();
    // Made while the add is still trying (the app makes it a few seconds in), from the same link.
    let reply = bo.reply(&unreachable(&link)).unwrap();
    bo.add(&link).await.expect("the link works after all");
    assert!(matches!(bo.reply(&link), Err(Error::Used)), "no reply to someone already added");
    // Opened late: ana gets bo's contact as it is. (The reply's own first dial, made before the add
    // began, may be the one that got through: it then says .replied. Either way it is spent.)
    assert_eq!(ana.add(&reply).await.unwrap().user, bo.me().user);
    tokio::time::sleep(Duration::from_secs(4)).await;
    assert!(!bo_log.saw(|e| matches!(e, Event::ReplyLapsed(_))), "spent, not lapsed");
    for p in [ana, bo] {
        p.close().await;
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn only_the_links_maker_takes_a_reply() {
    let _serial = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let (ana, _, _da) = node("ana").await;
    let (bo, _, _db) = node("bo").await;
    let (cy, _, _dc) = node("cy").await;
    let link = ana.invite().unwrap();
    let reply = bo.reply(&unreachable(&link)).unwrap();
    assert!(matches!(cy.add(&reply).await, Err(Error::NotFound)), "cy holds no invite it answers");
    assert!(!has(&bo, &cy) && !has(&cy, &bo));
    // Ana's link spent on someone else: her reply from bo is refused as used.
    cy.add(&link).await.unwrap();
    assert!(matches!(ana.add(&reply).await, Err(Error::Used)));
    assert!(!has(&ana, &bo));
    // A friend link is not a reply, and a reply is not something to reply to.
    assert!(matches!(bo.reply(&reply), Err(Error::Encoding)));
    for p in [ana, bo, cy] {
        p.close().await;
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn a_reply_lapses_with_the_link() {
    let _serial = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let (ana, _, _da) = node("ana").await;
    let (bo, bo_log, _db) = node("bo").await;
    let mut link = unreachable(&ana.invite().unwrap());
    link.expires = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() + 3;
    let reply = bo.reply(&link).unwrap();
    assert_eq!(reply.expires, link.expires, "never past the link it answers");
    within("bo stops waiting", Duration::from_secs(10), || bo_log.saw(|e| *e == Event::ReplyLapsed(ana.me().user))).await;
    assert!(matches!(ana.add(&reply).await, Err(Error::Expired)));
    for p in [ana, bo] {
        p.close().await;
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn a_reply_waits_across_a_relaunch() {
    let _serial = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let (ana, _, _da) = node("ana").await;
    let (db, kb) = (tempfile::tempdir().unwrap(), Arc::new(MemoryKeychain::default()));
    let bo = Peer::open(db.path().to_path_buf(), kb.clone(), config("bo")).await.unwrap();
    bo.set_online(true);
    let reply = bo.reply(&unreachable(&ana.invite().unwrap())).unwrap();
    bo.close().await;
    let bo = Peer::open(db.path().to_path_buf(), kb, config("bo")).await.unwrap();
    bo.set_online(true);
    assert_eq!(ana.add(&reply).await.unwrap().user, bo.me().user);
    within("bo, relaunched, has ana", Duration::from_secs(5), || has(&bo, &ana)).await;
    for p in [ana, bo] {
        p.close().await;
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn a_reply_opened_on_another_of_my_devices() {
    let _serial = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let (phone, _, _dp) = node("ana").await;
    let (mac, _, _dm) = node("throwaway").await;
    mac.link(&phone.link_device().unwrap(), "ana-mac").await.unwrap();
    within("the phone and the Mac connected", Duration::from_secs(10), || {
        let mac_id = mac.me().this_device;
        phone.peers().iter().any(|s| s.device == mac_id && s.online)
    })
    .await;
    let (bo, bo_log, _db) = node("bo").await;
    // The phone made the link and holds the invite; the reply comes back to the Mac.
    let reply = bo.reply(&unreachable(&phone.invite().unwrap())).unwrap();
    assert_eq!(mac.add(&reply).await.expect("the phone, which holds it, dials bo").user, bo.me().user);
    within("bo has ana", Duration::from_secs(5), || has(&bo, &phone)).await;
    within("bo hears it was replied", Duration::from_secs(5), || bo_log.saw(|e| matches!(e, Event::Replied(_)))).await;
    for p in [phone, mac, bo] {
        p.close().await;
    }
}
