//! Journey 3, inboxing: three nodes, ana and sam are jo's friends and each other's; sam goes
//! offline; ana posts; jo (online, holding sam's card) carries it; sam returns, dials jo from
//! cache, the envelope arrives naming jo as the carrier, ana learns it was delivered.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use peer::identity::MemoryKeychain;
use peer::{Config, Event, Listener, Peer};

struct Log(Mutex<Vec<Event>>);
impl Listener for Log {
    fn on(&self, e: Event) {
        self.0.lock().unwrap().push(e);
    }
}

fn config(name: &str) -> Config {
    let mut c = Config::new("inbox", name, &format!("{name}-dev"));
    c.nearby = false;
    c.portmap = false; // tests never map a port on the developer's router
    c
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

#[tokio::test]
async fn carried_by_a_mutual_friend_while_offline() {
    let (da, ds, dj) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (ka, ks) = (Arc::new(MemoryKeychain::default()), Arc::new(MemoryKeychain::default()));
    let ana = Peer::open(da.path().to_path_buf(), ka.clone(), config("ana")).await.unwrap();
    let sam = Peer::open(ds.path().to_path_buf(), ks.clone(), config("sam")).await.unwrap();
    let jo = Peer::open(dj.path().to_path_buf(), Arc::new(MemoryKeychain::default()), config("jo")).await.unwrap();
    let ana_log = Arc::new(Log(Mutex::new(Vec::new())));
    ana.subscribe(ana_log.clone());
    for p in [&ana, &sam, &jo] {
        p.set_online(true);
    }
    // Everyone is everyone's friend: jo is the mutual contact who stays online.
    sam.add(&ana.invite().unwrap()).await.unwrap();
    jo.add(&ana.invite().unwrap()).await.unwrap();
    jo.add(&sam.invite().unwrap()).await.unwrap();
    until("all online", || online(&ana, "sam") && online(&ana, "jo") && online(&jo, "sam") && online(&sam, "jo")).await;
    let sam_device = sam.me().this_device;
    let jo_device = jo.me().this_device;

    // Online: delivered directly, from is known.
    let id0 = ana.post(sam_device, b"hello while online".to_vec(), Duration::from_secs(3600)).await.unwrap();
    until("direct delivery", || sam.inbox().iter().any(|e| e.id == id0)).await;
    let e = sam.inbox().into_iter().find(|e| e.id == id0).unwrap();
    assert_eq!(e.from, Some(ana.me().this_device));
    assert!(e.carried_by.is_empty());
    assert!(ana_log.0.lock().unwrap().iter().any(|e| *e == Event::Delivered(id0)));
    sam.ack(id0).unwrap();

    // Sam leaves. Ana posts: jo holds it, ana's outbox keeps it.
    sam.close().await;
    until("ana sees sam offline", || !online(&ana, "sam")).await;
    let id = ana.post(sam_device, b"carried while away".to_vec(), Duration::from_secs(3600)).await.unwrap();
    until("jo holds it", || jo.helping().envelopes == 1).await;
    assert_eq!(ana.outbox(), vec![id]);
    assert!(sam.inbox().is_empty());
    // Ana leaves too: the two phones are never online at the same time; jo's Mac is.
    ana.close().await;
    until("jo sees ana offline", || !online(&jo, "ana")).await;

    // Sam returns from the same store, dials jo from cache, and the envelope arrives via jo.
    let sam = Peer::open(ds.path().to_path_buf(), ks, config("sam")).await.unwrap();
    let sam_log = Arc::new(Log(Mutex::new(Vec::new())));
    sam.subscribe(sam_log.clone());
    sam.set_online(true);
    until("carried delivery", || sam.inbox().iter().any(|e| e.id == id)).await;
    let e = sam.inbox().into_iter().find(|e| e.id == id).unwrap();
    assert_eq!(e.carried_by, vec![jo_device], "named carrier");
    assert_eq!(e.from, None, "a carried envelope names no sender");
    assert_eq!(e.bytes, b"carried while away");
    assert!(sam_log.0.lock().unwrap().iter().any(|x| *x == Event::Inbox(id)));
    // The ack reaches jo, who drops the copy.
    until("jo dropped it", || jo.helping().envelopes == 0).await;
    // Ana returns later, re-hands what her outbox still holds, and jo answers with the ack.
    let ana = Peer::open(da.path().to_path_buf(), ka, config("ana")).await.unwrap();
    // The loop dials jo inside `open`, so jo's ack may already have emptied the outbox: either
    // way the envelope came back from the store.
    let short = peer::identity::hex_of(&id.0[..4]);
    assert!(ana.outbox() == vec![id] || ana.trace().iter().any(|l| l.contains("\"ev\":\"delivered\"") && l.contains(&short)), "the outbox survives a restart");
    let ana_log = Arc::new(Log(Mutex::new(Vec::new())));
    ana.subscribe(ana_log.clone());
    ana.set_online(true);
    until("ana learns delivered", || ana.outbox().is_empty()).await;
    until("delivered said", || ana_log.0.lock().unwrap().iter().any(|e| *e == Event::Delivered(id)) || ana.trace().iter().any(|l| l.contains("\"ev\":\"delivered\"") && l.contains(&short))).await;

    // The inbox survives a restart until acked.
    sam.close().await;
    let sam = Peer::open(ds.path().to_path_buf(), Arc::new(MemoryKeychain::default()), config("sam")).await;
    assert!(sam.is_err(), "a different keychain cannot open the store");
    ana.close().await;
    jo.close().await;
}

/// The newest `held` event's time in a node's trace, if any.
fn last_held(p: &Peer) -> Option<u64> {
    p.trace().iter().filter(|l| l.contains("\"ev\":\"held\"")).filter_map(|l| serde_json::from_str::<serde_json::Value>(l).ok()?.get("t")?.as_u64()).max()
}

/// Three carriers connected to each other, all holding a card for the device away, are handed
/// one envelope: each holds it once and the network goes quiet. Each used to forward what it was
/// handed to all but its sender, so the three passed it round without end (a Mac mini, a MacBook
/// and an iPhone, 2026-10-16: 15 GB in an hour and a half).
#[tokio::test]
async fn carriers_do_not_pass_an_envelope_round() {
    let dirs: Vec<_> = (0..4).map(|_| tempfile::tempdir().unwrap()).collect();
    let open = |i: usize, name: &'static str| Peer::open(dirs[i].path().to_path_buf(), Arc::new(MemoryKeychain::default()), config(name));
    let (ana, jo, rex, sam) = (open(0, "ana").await.unwrap(), open(1, "jo").await.unwrap(), open(2, "rex").await.unwrap(), open(3, "sam").await.unwrap());
    for p in [&ana, &jo, &rex, &sam] {
        p.set_online(true);
    }
    // Everyone is everyone's friend, so ana, jo and rex all hold sam's card.
    sam.add(&ana.invite().unwrap()).await.unwrap();
    jo.add(&ana.invite().unwrap()).await.unwrap();
    jo.add(&sam.invite().unwrap()).await.unwrap();
    rex.add(&ana.invite().unwrap()).await.unwrap();
    rex.add(&sam.invite().unwrap()).await.unwrap();
    rex.add(&jo.invite().unwrap()).await.unwrap();
    until("all online", || online(&ana, "jo") && online(&ana, "rex") && online(&jo, "rex") && online(&ana, "sam")).await;
    let sam_device = sam.me().this_device;
    sam.close().await;
    until("sam away", || !online(&ana, "sam") && !online(&jo, "sam") && !online(&rex, "sam")).await;

    ana.post(sam_device, b"while you're away".to_vec(), Duration::from_secs(3600)).await.unwrap();
    until("jo and rex hold it", || jo.helping().envelopes == 1 && rex.helping().envelopes == 1).await;
    tokio::time::sleep(Duration::from_secs(2)).await;
    let settled = [last_held(&ana), last_held(&jo), last_held(&rex)];
    tokio::time::sleep(Duration::from_secs(3)).await;
    assert_eq!([last_held(&ana), last_held(&jo), last_held(&rex)], settled, "held again and again: the carriers are passing it round");
    for p in [ana, jo, rex] {
        p.close().await;
    }
}
