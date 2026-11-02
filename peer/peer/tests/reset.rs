//! A device removed from another of mine hears it and the friends' copies of my card drop it;
//! `reset` leaves no key and no file behind, so the directory opens as a new device.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use peer::identity::{DEVICE_KEY, Keychain, MemoryKeychain, STORE_KEY, USER_KEY};
use peer::{Config, Event, Listener, Peer};

#[derive(Default)]
struct Log(Mutex<Vec<Event>>);
impl Listener for Log {
    fn on(&self, e: Event) {
        self.0.lock().unwrap().push(e);
    }
}

fn config(name: &str) -> Config {
    let mut c = Config::new("reset", name, &format!("{name}-dev"));
    c.nearby = false;
    c.portmap = false; // tests never map a port on the developer's router
    c.auto_confirm_links = true;
    c
}

async fn until(what: &str, mut f: impl FnMut() -> bool) {
    for _ in 0..200 {
        if f() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    panic!("timed out waiting for {what}");
}

#[tokio::test]
async fn a_removed_device_hears_it_and_reset_leaves_nothing() {
    let (dm, dp, ds) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (km, kp) = (Arc::new(MemoryKeychain::default()), Arc::new(MemoryKeychain::default()));
    let mac = Peer::open(dm.path().to_path_buf(), km, config("ana")).await.unwrap();
    let phone = Peer::open(dp.path().to_path_buf(), kp.clone(), config("throwaway")).await.unwrap();
    let sam = Peer::open(ds.path().to_path_buf(), Arc::new(MemoryKeychain::default()), config("sam")).await.unwrap();
    for p in [&mac, &phone, &sam] {
        p.set_online(true);
    }
    let log = Arc::new(Log::default());
    phone.subscribe(log.clone());
    phone.link(&mac.link_device().unwrap(), "phone").await.unwrap();
    sam.add(&mac.invite().unwrap()).await.unwrap();
    let phone_dev = phone.me().this_device;
    let sams_copy_lists_phone = |sam: &Peer| sam.contacts().iter().any(|c| c.card.as_ref().is_some_and(|card| card.has_device(&phone_dev)));
    until("sam holds ana's card with the phone", || sams_copy_lists_phone(&sam)).await;

    mac.remove_device(phone_dev).unwrap();
    assert!(mac.me().devices.iter().all(|d| d.id != phone_dev));
    until("the phone hears it was removed", || log.0.lock().unwrap().iter().any(|e| matches!(e, Event::Removed))).await;
    until("sam's copy of ana's card drops the phone", || !sams_copy_lists_phone(&sam)).await;

    let old_device = phone.me().this_device;
    phone.reset().await.unwrap();
    for item in [DEVICE_KEY, USER_KEY, STORE_KEY] {
        assert_eq!(kp.get(item).unwrap(), None, "{item} deleted");
    }
    assert_eq!(std::fs::read_dir(dp.path()).unwrap().count(), 0, "nothing left in the directory");
    let fresh = Peer::open(dp.path().to_path_buf(), kp, config("new")).await.unwrap();
    assert_ne!(fresh.me().this_device, old_device, "a new device");
    fresh.close().await;
    mac.close().await;
    sam.close().await;
}

/// A friend who removes me: I hear it (`ContactRemoved`), and their contact is gone on my side.
#[tokio::test]
async fn a_friend_who_removes_me_is_heard() {
    let (da, ds) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let ana = Peer::open(da.path().to_path_buf(), Arc::new(MemoryKeychain::default()), config("ana")).await.unwrap();
    let sam = Peer::open(ds.path().to_path_buf(), Arc::new(MemoryKeychain::default()), config("sam")).await.unwrap();
    ana.set_online(true);
    sam.set_online(true);
    let log = Arc::new(Log::default());
    ana.subscribe(log.clone());
    ana.add(&sam.invite().unwrap()).await.unwrap();
    let sam_user = sam.me().user;
    until("connected", || ana.contacts().iter().any(|c| c.user == sam_user && c.devices.iter().any(|d| d.online))).await;
    sam.remove(ana.me().user).unwrap();
    until("ana hears sam removed her", || log.0.lock().unwrap().iter().any(|e| matches!(e, Event::ContactRemoved(u) if *u == sam_user))).await;
    assert!(ana.contacts().iter().all(|c| c.user != sam_user));
    ana.close().await;
    sam.close().await;
}
