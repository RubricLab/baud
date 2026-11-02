//! Sharing where I am (`Places.swift`, mirroring `PlacesTests.swift` on real cores): only to the
//! chat I chose, updated as I move, gone when I stop or the time is up; a place claimed for
//! someone else, by another device, or for a chat its sender isn't in is dropped.

use std::sync::Arc;
use std::time::Duration;

use baud_core::Core;
use baud_core::types::*;
use baud_core::wire::{Frame, WirePlace, seal_packet};
use peer::identity::MemoryKeychain;

fn config(name: &str) -> Config {
    let mut c = Config::new(name, &format!("{name}'s phone"), DeviceKind::Android);
    c.nearby = false;
    c.portmap = false;
    c
}

async fn open(dir: &std::path::Path, keys: &Arc<MemoryKeychain>, name: &str) -> Arc<Core> {
    let c = Core::open(dir.to_path_buf(), keys.clone(), config(name)).await.unwrap();
    c.set_online(true);
    c
}

async fn until(what: &str, secs: u64, mut f: impl FnMut() -> bool) {
    for _ in 0..secs * 20 {
        if f() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("timed out waiting for {what}");
}

fn now_ms() -> i64 {
    baud_core::sentences::now_ms()
}

/// Two friends with their chat, both online: `PairCore.pair()`.
async fn pair(dirs: &[tempfile::TempDir], keys: &[Arc<MemoryKeychain>]) -> (Arc<Core>, Arc<Core>, String) {
    let ana = open(dirs[0].path(), &keys[0], "Ana").await;
    let ben = open(dirs[1].path(), &keys[1], "Ben").await;
    ben.add(&ana.invite().unwrap().url).await.unwrap();
    let (a, b) = (ana.me().user, ben.me().user);
    let chat = |c: &Core, u: &str| c.conversations(Some(Kind::Chat)).into_iter().find(|x| x.is_direct && x.members.iter().any(|m| m == u));
    until("the chat", 10, || chat(&ana, &b).is_some() && chat(&ben, &a).is_some()).await;
    let conv = chat(&ana, &b).unwrap().id;
    until("ben's device online for ana", 10, || ana.contacts().iter().any(|c| c.user == b && c.online)).await;
    (ana, ben, conv)
}

fn dirs(n: usize) -> (Vec<tempfile::TempDir>, Vec<Arc<MemoryKeychain>>) {
    ((0..n).map(|_| tempfile::tempdir().unwrap()).collect(), (0..n).map(|_| Arc::new(MemoryKeychain::default())).collect())
}

/// The frame as the Swift app writes it, and as Foundation's `JSONEncoder` writes it (keys in
/// its own order, `until` absent while a share runs until stopped).
#[test]
fn the_swift_frames_decode() {
    let spec = r#"{"place":{"_0":"<conv>","_1":{"accuracy":15,"at":1792400000,"device":"<device>","lat":40.7359,"lon":-73.9911,"until":1792403600,"user":"<user>"}}}"#;
    let f: Frame = baud_core::json::decode(spec).unwrap();
    let want = WirePlace { user: "<user>".into(), device: "<device>".into(), lat: 40.7359, lon: -73.9911, accuracy: 15.0, at: 1792400000.0, until: Some(1792403600.0) };
    assert_eq!(f, Frame::Place("<conv>".into(), want));
    let (conv, user, device) = ("c3".repeat(32), "a1".repeat(32), "d4".repeat(32));
    let foundation = [
        format!(r#"{{"place":{{"_0":"{conv}","_1":{{"at":1792400000,"lat":40.7359,"device":"{device}","until":1792403600,"user":"{user}","lon":-73.9911,"accuracy":15}}}}}}"#),
        format!(r#"{{"place":{{"_0":"{conv}","_1":{{"user":"{user}","lon":-73.9911,"at":1792400000,"lat":40.7359,"accuracy":15,"device":"{device}"}}}}}}"#),
    ];
    for (i, raw) in foundation.iter().enumerate() {
        let f: Frame = baud_core::json::decode(raw).unwrap_or_else(|| panic!("{raw}"));
        let Frame::Place(c, p) = &f else { panic!("{f:?}") };
        assert_eq!((c, &p.user, &p.device, p.lat, p.lon, p.accuracy, p.at), (&conv, &user, &device, 40.7359, -73.9911, 15.0, 1792400000.0));
        assert_eq!(p.until, if i == 0 { Some(1792403600.0) } else { None });
        // Written back: the same JSON, and the same numbers as Swift writes them.
        let again = baud_core::json::encode(&f);
        assert_eq!(serde_json::from_str::<serde_json::Value>(&again).unwrap(), serde_json::from_str::<serde_json::Value>(raw).unwrap());
        assert!(again.contains("\"accuracy\":15") && again.contains("\"at\":1792400000"), "{again}");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_share_reaches_the_chat_and_stops() {
    let (d, k) = dirs(2);
    let (ana, ben, conv) = pair(&d, &k).await;
    let a = ana.me().user;
    assert!(!ana.wants_place());
    // A fix before any share goes nowhere.
    ana.moved(40.7128, -74.0060, 12.0);
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(ben.places(&conv).is_empty());

    ana.share_place(&conv, Some(now_ms() + 3_600_000));
    assert!(ana.wants_place());
    assert_eq!(ana.sharing().iter().map(|s| s.conv.as_str()).collect::<Vec<_>>(), vec![conv.as_str()]);
    until("ben sees ana", 10, || ben.places(&conv).len() == 1).await;
    let first = ben.places(&conv)[0].clone();
    assert_eq!((first.user.as_str(), first.device.as_str(), first.lat, first.accuracy), (a.as_str(), ana.me().this_device.as_str(), 40.7128, 12.0));
    assert!(first.until.is_some());

    ana.moved(40.7306, -73.9866, 8.0);
    until("ben sees ana move", 10, || ben.places(&conv).first().map(|p| p.lat) == Some(40.7306)).await;
    assert_eq!(ben.places(&conv).len(), 1, "one place per person");

    ana.stop_sharing(&conv);
    assert!(!ana.wants_place());
    until("ana's place gone", 10, || ben.places(&conv).is_empty()).await;
    // Moving after stopping sends nothing.
    ana.moved(1.0, 1.0, 5.0);
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(ben.places(&conv).is_empty());

    // Until I stop: no end on the wire, and it holds.
    ana.share_place(&conv, None);
    until("ben sees ana again", 10, || ben.places(&conv).len() == 1).await;
    assert_eq!(ben.places(&conv)[0].until, None);
    assert_eq!(ana.sharing()[0].until, None);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_share_ends_on_its_own() {
    let (d, k) = dirs(2);
    let (ana, ben, conv) = pair(&d, &k).await;
    ana.moved(51.5, -0.12, 20.0);
    ana.share_place(&conv, Some(now_ms() + 1500));
    until("ben sees it", 5, || ben.places(&conv).len() == 1).await;
    tokio::time::sleep(Duration::from_millis(1800)).await;
    assert!(ben.places(&conv).is_empty(), "over once its time is up, with no word from ana");
    assert!(ana.sharing().is_empty());
    assert!(!ana.wants_place());
}

/// A device that comes online gets my latest fix at once, without my moving.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_device_coming_online_gets_the_latest() {
    let (d, k) = dirs(2);
    let (ana, ben, conv) = pair(&d, &k).await;
    let b = ben.me().user;
    ben.close().await;
    drop(ben);
    until("ben away", 15, || !ana.contacts().iter().any(|c| c.user == b && c.online)).await;
    ana.moved(48.8566, 2.3522, 10.0);
    ana.share_place(&conv, None);
    let ben = open(d[1].path(), &k[1], "Ben").await;
    until("ben has ana's place on coming back", 20, || ben.places(&conv).first().map(|p| p.lat) == Some(48.8566)).await;
}

/// Places are only taken from their own device, about its own person, in a chat both are in.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn only_the_sender_and_only_its_chat() {
    let (d, k) = dirs(3);
    let (ana, ben, conv) = pair(&d, &k).await;
    let jo = open(d[2].path(), &k[2], "Jo").await;
    jo.add(&ben.invite().unwrap().url).await.unwrap();
    let (a, ad, jd) = (ana.me().user, ana.me().this_device, jo.me().this_device);
    until("ben knows jo's device", 10, || ben.contacts().iter().any(|c| c.devices.iter().any(|x| x.id == jd))).await;
    let place = |user: &str, device: &str| WirePlace { user: user.into(), device: device.into(), lat: 1.0, lon: 2.0, accuracy: 3.0, at: now_ms() as f64 / 1000.0, until: None };
    let packet = |conv: &str, p: WirePlace| seal_packet(&Frame::Place(conv.into(), p), None, false, [0; 12]);

    ben.receive_packet(&packet(&conv, place("someone-else", &ad)), &ad);
    assert!(ben.places(&conv).is_empty(), "claimed for someone else");
    ben.receive_packet(&packet(&conv, place(&a, &jd)), &ad);
    assert!(ben.places(&conv).is_empty(), "claimed for another device");
    let jo_user = jo.me().user;
    ben.receive_packet(&packet(&conv, place(&jo_user, &jd)), &jd);
    assert!(ben.places(&conv).is_empty(), "jo isn't in ana and ben's chat");
    ben.receive_packet(&packet("not-a-chat-ben-is-in", place(&a, &ad)), &ad);
    assert!(ben.places("not-a-chat-ben-is-in").is_empty(), "a chat ben isn't in");
    // And the real thing, for contrast.
    ben.receive_packet(&packet(&conv, place(&a, &ad)), &ad);
    assert_eq!(ben.places(&conv).len(), 1);
    // An older fix doesn't replace a newer one; a stop removes it.
    let mut old = place(&a, &ad);
    old.at -= 60.0;
    old.lat = 9.0;
    ben.receive_packet(&packet(&conv, old), &ad);
    assert_eq!(ben.places(&conv)[0].lat, 1.0);
    let mut stop = place(&a, &ad);
    stop.until = Some(stop.at - 1.0);
    ben.receive_packet(&packet(&conv, stop), &ad);
    assert!(ben.places(&conv).is_empty());
}
