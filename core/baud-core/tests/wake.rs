//! Wake tickets (`Wake.swift`): a ticket an iPhone hands over, in the frame exactly as Swift
//! writes it, is kept for that device; a message for it that has to go to carriers spends it at
//! the relay (a stub here), once per 20 s, never for my own message syncing to my own device.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use baud_core::Core;
use baud_core::types::*;
use peer::identity::MemoryKeychain;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

fn config(name: &str, wake: Option<String>) -> Config {
    let mut c = Config::new(name, &format!("{name}'s phone"), DeviceKind::Android);
    c.nearby = false;
    c.portmap = false;
    c.wake_url = wake;
    c
}

async fn open(dir: &std::path::Path, keys: &Arc<MemoryKeychain>, name: &str, wake: Option<String>) -> Arc<Core> {
    let c = Core::open(dir.to_path_buf(), keys.clone(), config(name, wake)).await.unwrap();
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

fn now() -> f64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs_f64()
}

/// A ticket the way an iPhone sends it: `{"wake":{"_0":…,"_1":…}}` as Foundation writes it
/// (`/` escaped), in an unsealed packet (conv ""), as `Packet` writes it.
fn swift_packet(ticket: &[u8], expires: f64) -> Vec<u8> {
    let t = STANDARD.encode(ticket).replace('/', "\\/");
    let frame = format!("{{\"wake\":{{\"_1\":{},\"_0\":\"{t}\"}}}}", baud_core::json::swift_double(expires));
    format!("{{\"body\":\"{}\",\"v\":2}}", STANDARD.encode(frame.as_bytes()).replace('/', "\\/")).into_bytes()
}

/// A ticket as `WakeTicket.mint` lays one out (version, key id, HPKE key, sealed body): the
/// core never opens it, so any bytes of that shape do; these have `/` in their base64.
fn ticket(seed: u8) -> Vec<u8> {
    let mut t = vec![1u8, 1];
    t.extend((0..135u32).map(|i| (i as u8).wrapping_mul(seed).wrapping_add(0xfb)));
    t
}

/// From Foundation's `JSONEncoder` on macOS 26 (`case wake(Data, Double)`, Wire.swift), verbatim:
/// the frame, and the unsealed packet it travels in.
const SWIFT_FRAME: &str = r#"{"wake":{"_0":"AQH7IEVqj7TZ\/iNIbZK33AEmS3CVut8EKU5zmL3iByxRdpvA5QovVHmew+gNMld8ocbrEDVaf6TJ7hM4XYKnzPEWO2CFqs\/0GT5jiK3S9xxBZouw1fofRGmOs9j9IkdskbbbACVKb5S53gMoTXKXvOEGK1B1mr\/kCS5TeJ3C5wwxVnugxeoPNFk=","_1":4102444800.123456}}"#;
const SWIFT_PACKET: &str = r#"{"v":2,"body":"eyJ3YWtlIjp7Il8wIjoiQVFIN0lFVnFqN1RaXC9pTkliWkszM0FFbVMzQ1Z1dDhFS1U1em1MM2lCeXhSZHB2QTVRb3ZWSG1ldytnTk1sZDhvY2JyRURWYWY2VEo3aE00WFlLbnpQRVdPMkNGcXNcLzBHVDVqaUszUzl4eEJab3V3MWZvZlJHbU9zOWo5SWtkc2tiYmJBQ1ZLYjVTNTNnTW9UWEtYdk9FR0sxQjFtclwva0NTNVRlSjNDNXd3eFZudWd4ZW9QTkZrPSIsIl8xIjo0MTAyNDQ0ODAwLjEyMzQ1Nn19"}"#;

/// The ticket in those: `[1, 1] + (0..<135).map { ($0 * 37 + 0xfb) & 0xff }`.
fn swift_ticket() -> Vec<u8> {
    let mut t = vec![1u8, 1];
    t.extend((0..135u32).map(|i| ((i * 37 + 0xfb) & 0xff) as u8));
    t
}

#[test]
fn the_swift_frame_decodes() {
    let f: baud_core::wire::Frame = baud_core::json::decode(SWIFT_FRAME).unwrap();
    assert_eq!(f, baud_core::wire::Frame::Wake(swift_ticket(), 4102444800.123456));
    // And writes back the same: the same bytes, keys in Swift's order or not.
    let again: serde_json::Value = serde_json::from_str(&baud_core::json::encode(&f)).unwrap();
    assert_eq!(again, serde_json::from_str::<serde_json::Value>(SWIFT_FRAME).unwrap());
    let p: baud_core::wire::Packet = baud_core::json::decode(SWIFT_PACKET).unwrap();
    assert_eq!((p.v, p.conv, p.body), (Some(2), None, SWIFT_FRAME.as_bytes().to_vec()));
}

/// The relay, as far as a device sees it: POST /v1/wake, a status.
struct Stub {
    url: String,
    asks: Arc<Mutex<Vec<serde_json::Value>>>,
}

async fn stub(status: u16) -> Stub {
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", l.local_addr().unwrap());
    let asks = Arc::new(Mutex::new(vec![]));
    let seen = asks.clone();
    tokio::spawn(async move {
        while let Ok((mut s, _)) = l.accept().await {
            let seen = seen.clone();
            tokio::spawn(async move {
                let mut buf = vec![];
                let mut chunk = [0u8; 4096];
                loop {
                    let n = s.read(&mut chunk).await.unwrap_or(0);
                    if n == 0 {
                        break;
                    }
                    buf.extend_from_slice(&chunk[..n]);
                    let text = String::from_utf8_lossy(&buf).to_string();
                    let Some(end) = text.find("\r\n\r\n") else { continue };
                    let len = text.lines().find_map(|l| l.to_lowercase().strip_prefix("content-length:").map(|v| v.trim().parse::<usize>().unwrap_or(0))).unwrap_or(0);
                    if buf.len() < end + 4 + len {
                        continue;
                    }
                    assert!(text.starts_with("POST /v1/wake "), "{text}");
                    seen.lock().unwrap().push(serde_json::from_slice(&buf[end + 4..end + 4 + len]).unwrap());
                    let _ = s.write_all(format!("HTTP/1.1 {status} X\r\ncontent-length: 0\r\nconnection: close\r\n\r\n").as_bytes()).await;
                    break;
                }
            });
        }
    });
    Stub { url, asks }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn tickets_are_kept_from_known_devices_only() {
    let dirs: Vec<tempfile::TempDir> = (0..2).map(|_| tempfile::tempdir().unwrap()).collect();
    let keys: Vec<Arc<MemoryKeychain>> = (0..2).map(|_| Arc::new(MemoryKeychain::default())).collect();
    let ana = open(dirs[0].path(), &keys[0], "Ana", None).await;
    let ben = open(dirs[1].path(), &keys[1], "Ben", None).await;
    ben.add(&ana.invite().unwrap().url).await.unwrap();
    let bd = ben.me().this_device;
    until("ana knows ben's device", 10, || ana.contacts().iter().any(|c| c.devices.iter().any(|d| d.id == bd))).await;

    // The packet exactly as the iPhone sends it.
    ana.receive_packet(SWIFT_PACKET.as_bytes(), &bd);
    assert!(ana.can_wake(&bd), "the iPhone's frame, as Swift writes it, is kept");
    let stranger = "ab".repeat(32);
    ana.receive_packet(&swift_packet(&ticket(3), now() + 3600.0), &stranger);
    assert!(!ana.can_wake(&stranger), "a device I don't know");
    let jo = "cd".repeat(32);
    ana.receive_packet(&swift_packet(&ticket(3), now() - 1.0), &jo);
    assert!(!ana.can_wake(&jo), "a stranger's, expired");
    let (bd2, now2) = (bd.clone(), now());
    // Refused: expired, or 512 bytes (too big for a ticket); either leaves the one held.
    ana.receive_packet(&swift_packet(&ticket(3), now2 - 1.0), &bd2);
    ana.receive_packet(&swift_packet(&[7u8; 512], now2 + 3600.0), &bd2);
    assert!(ana.can_wake(&bd2));
    // A newer one replaces it.
    ana.receive_packet(&swift_packet(&ticket(3), now2 + 3600.0), &bd2);
    assert!(ana.can_wake(&bd2));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_message_for_a_sleeping_iphone_wakes_it_once() {
    let relay = stub(202).await;
    let dirs: Vec<tempfile::TempDir> = (0..3).map(|_| tempfile::tempdir().unwrap()).collect();
    let keys: Vec<Arc<MemoryKeychain>> = (0..3).map(|_| Arc::new(MemoryKeychain::default())).collect();
    let ana = open(dirs[0].path(), &keys[0], "Ana", Some(relay.url.clone())).await;
    let ben = open(dirs[1].path(), &keys[1], "Ben", None).await;
    // Ana's tablet: her own device, which also hands her a ticket.
    let a2 = ana.clone();
    ana.subscribe(Box::new(move |c| {
        if let Change::LinkRequest { req, .. } = c {
            a2.confirm_link(req, true);
        }
    }));
    let tablet = open(dirs[2].path(), &keys[2], "", None).await;
    tablet.link(&ana.link_device().unwrap().url).await.unwrap();
    ben.add(&ana.invite().unwrap().url).await.unwrap();
    let (b, bd, td) = (ben.me().user, ben.me().this_device, tablet.me().this_device);
    until("the chat", 10, || ana.conversations(Some(Kind::Chat)).iter().any(|c| c.is_direct && c.members.contains(&b))).await;
    until("ana's devices", 10, || ana.me().devices.len() == 2).await;
    let conv = ana.conversations(Some(Kind::Chat)).into_iter().find(|c| c.is_direct && c.members.contains(&b)).unwrap().id;
    let (tb, tt) = (ticket(3), ticket(5));
    // An older ticket first: the newer one replaces it, and only the newer is spent.
    ana.receive_packet(&swift_packet(&ticket(7), now() + 1800.0), &bd);
    ana.receive_packet(&swift_packet(&tb, now() + 3600.0), &bd);
    ana.receive_packet(&swift_packet(&tt, now() + 3600.0), &td);
    assert!(ana.can_wake(&bd) && ana.can_wake(&td));

    // Both asleep. Ana's message goes to carriers for each; only Ben's phone is woken for it.
    ben.close().await;
    tablet.close().await;
    until("both away", 15, || ana.peers().iter().filter(|p| p.device.id == bd || p.device.id == td).all(|p| !p.device.online)).await;
    let m = ana.send(&conv, Draft { text: "wake up".into(), ..Default::default() }).unwrap();
    until("the relay is asked", 10, || !relay.asks.lock().unwrap().is_empty()).await;
    ana.send(&conv, Draft { text: "and again, within 20 s".into(), ..Default::default() }).unwrap();
    tokio::time::sleep(Duration::from_secs(3)).await;
    let asks = relay.asks.lock().unwrap().clone();
    assert_eq!(asks.len(), 1, "one wake, for Ben's phone: {asks:?}");
    assert_eq!(asks[0]["kind"], "message");
    assert_eq!(asks[0]["ticket"], STANDARD.encode(&tb));
    assert_eq!(ana.delivery(&conv, &m.id).devices.len(), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_gone_ticket_is_forgotten() {
    let relay = stub(410).await;
    let dirs: Vec<tempfile::TempDir> = (0..2).map(|_| tempfile::tempdir().unwrap()).collect();
    let keys: Vec<Arc<MemoryKeychain>> = (0..2).map(|_| Arc::new(MemoryKeychain::default())).collect();
    let ana = open(dirs[0].path(), &keys[0], "Ana", Some(relay.url.clone())).await;
    let ben = open(dirs[1].path(), &keys[1], "Ben", None).await;
    ben.add(&ana.invite().unwrap().url).await.unwrap();
    let (b, bd) = (ben.me().user, ben.me().this_device);
    until("the chat", 10, || ana.conversations(Some(Kind::Chat)).iter().any(|c| c.is_direct && c.members.contains(&b))).await;
    let conv = ana.conversations(Some(Kind::Chat)).into_iter().find(|c| c.is_direct && c.members.contains(&b)).unwrap().id;
    ana.receive_packet(&swift_packet(&ticket(9), now() + 3600.0), &bd);
    ben.close().await;
    until("ben away", 15, || !ana.contacts().iter().any(|c| c.user == b && c.online)).await;
    ana.send(&conv, Draft { text: "are you there".into(), ..Default::default() }).unwrap();
    until("410 forgets it", 10, || !ana.can_wake(&bd)).await;
    assert_eq!(relay.asks.lock().unwrap().len(), 1);
}

/// The live relay over TLS (ring, Mozilla's roots), read-only: `cargo test -- --ignored`.
#[tokio::test]
#[ignore]
async fn the_live_relay_answers() {
    assert_eq!(baud_core::relay_get(&format!("{}/health", baud_core::WAKE_RELAY)).await, Some(200));
}
