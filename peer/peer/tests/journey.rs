//! Journey 1 between in-process nodes: invite and add (both sides see each other, records
//! exchanged, online with a direct path), a name change reaches the contact by card push,
//! a third node links as the first person's device and gets the book, removal tells the other side.

use std::sync::{Arc, Mutex};
use std::time::Duration;

/// Serial: the restart test frees a UDP port and asks for it again; a sibling test binding an
/// endpoint in between could be handed that port, and "same port after a restart" would lie.
static SERIAL: Mutex<()> = Mutex::new(());

use peer::identity::MemoryKeychain;
use peer::{Config, Event, Listener, Peer};

struct Log(Mutex<Vec<Event>>);
impl Listener for Log {
    fn on(&self, e: Event) {
        self.0.lock().unwrap().push(e);
    }
}

async fn node(name: &str) -> (Peer, Arc<Log>, tempfile::TempDir) {
    let dir = tempfile::tempdir().unwrap();
    let mut config = Config::new("journey", name, &format!("{name}-dev"));
    config.nearby = false;
    config.portmap = false;
    config.auto_confirm_links = true;
    let p = Peer::open(dir.path().to_path_buf(), Arc::new(MemoryKeychain::default()), config).await.unwrap();
    let log = Arc::new(Log(Mutex::new(Vec::new())));
    p.subscribe(log.clone());
    p.set_online(true);
    (p, log, dir)
}

async fn until(what: &str, mut f: impl FnMut() -> bool) {
    for _ in 0..100 {
        if f() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("timed out waiting for {what}");
}

#[tokio::test]
async fn address_book_between_two_nodes() {
    let _serial = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let (ana, ana_log, _a) = node("ana").await;
    let (sam, sam_log, _s) = node("sam").await;

    // Invite and add: mutual contacts, cards and records both ways, from one round trip.
    let link = ana.invite().unwrap();
    let text = peer::link::format(&link, "https://baud.rubric.sh/add");
    let contact = sam.add(&peer::link::parse(&text).unwrap()).await.unwrap();
    assert_eq!(contact.name, "ana");
    assert_eq!(contact.card.as_ref().unwrap().user(), ana.me().user);
    // Found by the invite (a fresher record pushed once they connect replaces it, found by push).
    assert!(sam.records().iter().any(|r| r.device == ana.me().this_device && r.found_by == peer::record::FoundBy::Invite));
    until("ana sees sam", || ana.contacts().iter().any(|c| c.name == "sam")).await;
    // A link works once: the person who redeemed it may ask again (an answer lost on the way
    // gets the same answer), anyone else holding it is refused.
    assert_eq!(sam.add(&link).await.map(|c| c.user), Ok(ana.me().user));
    let (eve, _eve_log, _e) = node("eve").await;
    assert_eq!(eve.add(&link).await.map(|c| c.user), Err(peer::Error::Used), "a link works once");
    eve.close().await;

    // Online with a direct path on both sides, found by the invite.
    until("sam online at ana", || ana.contacts()[0].devices.iter().any(|d| d.online)).await;
    until("ana online at sam", || sam.contacts()[0].devices.iter().any(|d| d.online)).await;
    // Read once, the path could be caught mid-swap (both sides dialed, one connection kept).
    until("a direct path at sam", || matches!(sam.contacts()[0].devices[0].path, peer::Path::Direct { vpn: false })).await;
    assert!(ana_log.0.lock().unwrap().iter().any(|e| matches!(e, Event::Online(_))));
    assert!(sam_log.0.lock().unwrap().iter().any(|e| matches!(e, Event::ContactsChanged)));

    // A name change on ana reaches sam's copy of her card by card push.
    ana.set_name("Ana").unwrap();
    until("sam holds ana's new card", || sam.contacts()[0].card.as_ref().unwrap().body.name == "Ana").await;
    assert_eq!(sam.contacts()[0].name, "ana", "the petname is sam's, not hers");
    sam.rename(ana.me().user, "Ana B").unwrap();
    assert_eq!(sam.contacts()[0].name, "Ana B");

    // Safety number: verify pins the key.
    assert!(sam.verify(ana.me().user, &ana.me().fingerprint).unwrap());
    assert!(sam.contacts()[0].verified);
    assert!(!sam.verify(ana.me().user, "00000").unwrap());

    // A third node becomes ana's device: same person, the whole book and the records come along.
    let (mac, _mac_log, _m) = node("throwaway").await;
    let dlink = ana.link_device().unwrap();
    mac.link(&dlink, "ana-mac").await.unwrap();
    assert_eq!(mac.me().user, ana.me().user);
    assert_eq!(mac.me().name, "Ana");
    assert_eq!(mac.me().devices.len(), 2);
    until("ana's card lists the mac", || ana.me().devices.len() == 2).await;
    let mac_device = mac.me().this_device;
    until("ana and her mac hold each other's records", || ana.records().iter().any(|r| r.device == mac_device) && mac.records().iter().any(|r| r.device == ana.me().this_device)).await;
    until("ana and her mac connect", || ana.peers().iter().any(|p| p.device == mac_device && p.online)).await;
    assert_eq!(mac.contacts()[0].name, "sam", "the book replicated");
    until("sam learns ana's new device by card push", || sam.contacts()[0].card.as_ref().unwrap().body.devices.len() == 2).await;
    until("the mac dials sam from the replicated record", || mac.contacts()[0].devices.iter().any(|d| d.online)).await;
    until("sam sees both of ana's devices online", || sam.contacts()[0].devices.iter().filter(|d| d.online).count() == 2).await;
    assert!(mac.link(&dlink, "again").await.is_err(), "a device link works once");

    // Removal is told to the other side.
    sam.remove(ana.me().user).unwrap();
    assert!(sam.contacts().is_empty());
    until("ana was told", || ana.contacts().is_empty()).await;

    ana.close().await;
    sam.close().await;
    mac.close().await;
}

#[tokio::test]
async fn a_store_refuses_another_devices_keychain() {
    let _serial = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let dir = tempfile::tempdir().unwrap();
    let mut config = Config::new("journey", "ana", "ana-dev");
    config.nearby = false;
    config.portmap = false;
    let first = Peer::open(dir.path().to_path_buf(), Arc::new(MemoryKeychain::default()), config.clone()).await.unwrap();
    first.close().await;
    // Same dir, a keychain holding a different device key: refused with a clear error, not a silent swap.
    let err = Peer::open(dir.path().to_path_buf(), Arc::new(MemoryKeychain::default()), config).await.err().unwrap();
    assert!(matches!(err, peer::Error::Keychain(ref m) if m.contains("belongs to device") || m.contains("sealed under another")), "{err}");
}

#[tokio::test]
async fn two_own_devices_find_each_other_after_both_restart() {
    let _serial = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    // No helper, no mDNS: only the cached records. They stay valid because each store binds the
    // same UDP port it bound last time.
    let (da, db) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (ka, kb) = (Arc::new(MemoryKeychain::default()), Arc::new(MemoryKeychain::default()));
    let mut config = Config::new("journey", "ana", "mac");
    config.nearby = false;
    config.portmap = false;
    config.auto_confirm_links = true;
    let mac = Peer::open(da.path().to_path_buf(), ka.clone(), config.clone()).await.unwrap();
    let phone = Peer::open(db.path().to_path_buf(), kb.clone(), config.clone()).await.unwrap();
    mac.set_online(true);
    phone.set_online(true);
    phone.link(&mac.link_device().unwrap(), "phone").await.unwrap();
    let (mac_dev, phone_dev) = (mac.me().this_device, phone.me().this_device);
    until("linked and online", || mac.peers().iter().any(|p| p.device == phone_dev && p.online)).await;
    let port_before = mac.addr().ip_addrs().next().unwrap().port();
    mac.close().await;
    phone.close().await;

    let t = std::time::Instant::now();
    let mac = Peer::open(da.path().to_path_buf(), ka, config.clone()).await.unwrap();
    let phone = Peer::open(db.path().to_path_buf(), kb, config).await.unwrap();
    assert_eq!(mac.addr().ip_addrs().next().unwrap().port(), port_before, "same port after a restart");
    mac.set_online(true);
    phone.set_online(true);
    until("both online within 5 s", || mac.peers().iter().any(|p| p.device == phone_dev && p.online) && phone.peers().iter().any(|p| p.device == mac_dev && p.online)).await;
    assert!(t.elapsed() < Duration::from_secs(5), "{:?}", t.elapsed());
    mac.close().await;
    phone.close().await;
}

#[tokio::test]
async fn sign_as_user_survives_a_restart_after_adopt() {
    let _serial = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let dir = tempfile::tempdir().unwrap();
    let keys = Arc::new(MemoryKeychain::default());
    let mut config = Config::new("journey", "", "mac");
    config.nearby = false;
    config.portmap = false;
    let (dev, user) = (peer::identity::Secret::generate(), peer::identity::Secret::generate());
    let m = peer::Migration { device_secret: dev.to_bytes(), user_secret: user.to_bytes(), name: "dexter".into(), devices: vec![], card_at: 77 };
    let p = Peer::adopt(dir.path().to_path_buf(), keys.clone(), config.clone(), m).await.unwrap();
    assert_eq!(p.me().user, user.user_id());
    assert!(p.sign_as_user(b"cert").is_ok());
    p.close().await;
    let p = Peer::open(dir.path().to_path_buf(), keys, config).await.unwrap();
    assert!(user.user_id().verify(b"cert", &p.sign_as_user(b"cert").unwrap()).is_ok(), "adopted outlives the adopt launch");
    let mut fresh_config = Config::new("journey", "x", "y");
    fresh_config.portmap = false;
    let fresh = Peer::open(tempfile::tempdir().unwrap().path().to_path_buf(), Arc::new(MemoryKeychain::default()), fresh_config).await.unwrap();
    assert!(fresh.sign_as_user(b"cert").is_err(), "never on a crate-native node");
    p.close().await;
    fresh.close().await;
}

#[tokio::test]
async fn adopted_contacts_survive_a_restart() {
    let _serial = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    use peer::AdoptedDevice;
    let dir = tempfile::tempdir().unwrap();
    let keys = Arc::new(MemoryKeychain::default());
    let mut config = Config::new("journey", "ana", "ana-dev");
    config.nearby = false;
    config.portmap = false;
    let friend = peer::identity::Secret::generate();
    let dev = peer::identity::Secret::generate().device_id();
    let ana = Peer::open(dir.path().to_path_buf(), keys.clone(), config.clone()).await.unwrap();
    let c = ana.adopt_contact(friend.user_id(), "old friend", vec![AdoptedDevice { id: dev, name: "their mac".into(), addresses: vec![peer::TransportAddr::Ip("198.51.100.9:4101".parse().unwrap())] }], 1234).unwrap();
    assert_eq!(c.devices[0].name, "their mac");
    ana.close().await;
    let ana = Peer::open(dir.path().to_path_buf(), keys, config).await.unwrap();
    let c = ana.contacts().into_iter().find(|c| c.name == "old friend").expect("adopted contact persisted");
    assert_eq!(c.devices[0].device, dev);
    assert_eq!(c.devices[0].name, "their mac");
    assert_eq!(ana.record_addr(dev).unwrap().ip_addrs().count(), 1, "addresses persisted");
    assert_eq!(ana.identity_of_device(dev).user, friend.user_id());
    ana.close().await;
}

#[tokio::test]
async fn records_survive_a_restart_and_redial() {
    let _serial = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let dir_a = tempfile::tempdir().unwrap();
    let keys_a = Arc::new(MemoryKeychain::default());
    let mut config = Config::new("journey", "ana", "ana-dev");
    config.nearby = false;
    config.portmap = false;
    let ana = Peer::open(dir_a.path().to_path_buf(), keys_a.clone(), config.clone()).await.unwrap();
    ana.set_online(true);
    let (sam, _log, _s) = node("sam").await;
    sam.add(&ana.invite().unwrap()).await.unwrap();
    until("online", || sam.contacts()[0].devices.iter().any(|d| d.online)).await;
    ana.close().await;
    until("sam sees ana offline", || !sam.contacts()[0].devices.iter().any(|d| d.online)).await;
    assert_eq!(sam.contacts()[0].devices[0].path, peer::Path::Waiting);

    // Ana reopens from the same store: contacts and records are there, and she dials sam from cache.
    let ana = Peer::open(dir_a.path().to_path_buf(), keys_a, config).await.unwrap();
    assert_eq!(ana.contacts()[0].name, "sam");
    assert_eq!(ana.records().len(), 1);
    ana.set_online(true);
    until("ana redials sam from cache", || ana.contacts()[0].devices.iter().any(|d| d.online)).await;
    until("sam sees ana back", || sam.contacts()[0].devices.iter().any(|d| d.online)).await;
    ana.close().await;
    sam.close().await;
}
