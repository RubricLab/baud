//! The network loop (DESIGN.md), in process: a contact added on one own device is on the
//! other within a second and dialed; a peer that restarts is seen again at once by the one that
//! kept running; a wake replaces held connections without anyone going offline.

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use peer::identity::MemoryKeychain;
use peer::{Config, Peer};

static SERIAL: Mutex<()> = Mutex::new(());

fn config(name: &str) -> Config {
    let mut c = Config::new("loop", name, &format!("{name}-dev"));
    c.nearby = false;
    c.portmap = false; // tests never map a port on the developer's router
    c.auto_confirm_links = true;
    c
}

async fn node(name: &str) -> (Peer, tempfile::TempDir, Arc<MemoryKeychain>) {
    let dir = tempfile::tempdir().unwrap();
    let keys = Arc::new(MemoryKeychain::default());
    let p = Peer::open(dir.path().to_path_buf(), keys.clone(), config(name)).await.unwrap();
    p.set_online(true);
    (p, dir, keys)
}

async fn within(what: &str, limit: Duration, mut f: impl FnMut() -> bool) -> Duration {
    let t = Instant::now();
    while t.elapsed() < limit {
        if f() {
            return t.elapsed();
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("{what}: not within {limit:?}");
}

fn online(p: &Peer, d: peer::identity::DeviceId) -> bool {
    p.peers().iter().any(|s| s.device == d && s.online)
}

#[tokio::test]
async fn a_contact_added_on_one_own_device_is_on_the_other_and_dialed() {
    let _serial = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let (mac, _dm, _km) = node("ana").await;
    let (phone, _dp, _kp) = node("throwaway").await;
    let (sam, _ds, _ks) = node("sam").await;
    phone.link(&mac.link_device().unwrap(), "phone").await.unwrap();
    let phone_dev = phone.me().this_device;
    within("mac and phone connected", Duration::from_secs(5), || online(&mac, phone_dev)).await;

    // The phone adds sam; the mac has sam as a contact within a second, and dials him.
    phone.add(&sam.invite().unwrap()).await.unwrap();
    within("sam is a contact on the mac", Duration::from_secs(1), || mac.contacts().iter().any(|c| c.name == "sam")).await;
    let sam_dev = sam.me().this_device;
    within("the mac dials sam", Duration::from_secs(2), || online(&mac, sam_dev)).await;

    // A rename on the mac reaches the phone; a removal too.
    mac.rename(sam.me().user, "Sam B").unwrap();
    within("the rename reaches the phone", Duration::from_secs(1), || phone.contacts().iter().any(|c| c.name == "Sam B")).await;
    phone.remove(sam.me().user).unwrap();
    within("the removal reaches the mac", Duration::from_secs(1), || mac.contacts().is_empty()).await;

    mac.close().await;
    phone.close().await;
    sam.close().await;
}

#[tokio::test]
async fn a_restarted_peer_is_seen_again_and_a_wake_keeps_everyone_online() {
    let _serial = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let (sam, _ds, _ks) = node("sam").await;
    let (ana, da, ka) = node("ana").await;
    sam.add(&ana.invite().unwrap()).await.unwrap();
    let (ana_dev, sam_dev) = (ana.me().this_device, sam.me().this_device);
    within("connected", Duration::from_secs(5), || online(&sam, ana_dev) && online(&ana, sam_dev)).await;

    // A wake: every held connection is redialed, and nobody goes offline for it.
    ana.set_online(false);
    ana.set_online(true);
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(online(&ana, sam_dev) && online(&sam, ana_dev));

    // Ana restarts on her store while sam keeps running: both see each other within 2 s.
    ana.close().await;
    within("sam sees ana gone", Duration::from_secs(5), || !online(&sam, ana_dev)).await;
    let ana = Peer::open(da.path().to_path_buf(), ka, config("ana")).await.unwrap();
    ana.set_online(true);
    within("ana back at sam", Duration::from_secs(2), || online(&sam, ana_dev) && online(&ana, sam_dev)).await;

    ana.close().await;
    sam.close().await;
}

/// A dial begun into a dead network is not waited on once the network is back. Mid-outage the
/// push that checks a held connection fails and redials into nothing; that dial's handshake
/// retransmits on a timer that doubles (0.3, 0.9, 2.1, 4.5, 9.3 s …), so a network back at 5 s
/// would wait until 9.3 s. A network change (the OS's, or the app's `network_changed`) starts it
/// over. Here bob vanishes and comes back on his port; ana marked him relay-only, so he cannot
/// dial her and only her own dial reconnects them.
#[tokio::test]
async fn a_dial_begun_before_a_network_change_is_started_over() {
    let _serial = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let (ana, _da, _ka) = node("ana").await;
    let (bob, db, kb) = node("bob").await;
    ana.add(&bob.invite().unwrap()).await.unwrap();
    let (ana_dev, bob_dev) = (ana.me().this_device, bob.me().this_device);
    within("connected", Duration::from_secs(5), || online(&ana, bob_dev) && online(&bob, ana_dev)).await;
    ana.set_relay_only(bob.me().user, true).unwrap();
    within("bob holds ana's record without addresses", Duration::from_secs(2), || bob.record_addr(ana_dev).is_some_and(|a| a.ip_addrs().count() == 0)).await;

    bob.close().await;
    within("ana sees bob gone", Duration::from_secs(5), || !online(&ana, bob_dev)).await;
    // Ana's loop redialed at once, into nothing; 5 s on, its next retransmit is seconds away.
    tokio::time::sleep(Duration::from_secs(5)).await;
    let bob = Peer::open(db.path().to_path_buf(), kb, config("bob")).await.unwrap();
    bob.set_online(true);
    ana.network_changed();
    let took = within("ana reaches bob again", Duration::from_secs(3), || online(&ana, bob_dev)).await;
    assert!(took < Duration::from_secs(1), "a fresh dial, not the old one's next retransmit: {took:?}");

    ana.close().await;
    bob.close().await;
}
