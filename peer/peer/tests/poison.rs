//! A panic in one task takes nothing down with it. A task that panicked holding the node's locks
//! poisoned them, every later `lock().unwrap()` panicked in turn, and the app trapped on its next
//! call into the crate (baud 0.2.7: `networkChanged`, from the main thread).

use std::sync::Arc;
use std::time::Duration;

use peer::identity::MemoryKeychain;
use peer::{Config, Peer};

async fn node(name: &str) -> (Peer, tempfile::TempDir) {
    let d = tempfile::tempdir().unwrap();
    let mut c = Config::new("poison", name, &format!("{name}-dev"));
    c.nearby = false;
    c.portmap = false; // tests never map a port on the developer's router
    let p = Peer::open(d.path().to_path_buf(), Arc::new(MemoryKeychain::default()), c).await.unwrap();
    p.set_online(true);
    (p, d)
}

#[tokio::test(flavor = "multi_thread")]
async fn a_panic_holding_the_locks_takes_nothing_down_with_it() {
    let (ana, _da) = node("ana").await;
    let (bo, _db) = node("bo").await;
    bo.add(&ana.invite().unwrap()).await.unwrap();
    ana.poison_locks().await;

    // Every entry point the app calls still answers.
    ana.network_changed();
    ana.set_online(false);
    ana.set_online(true);
    let _ = (ana.me(), ana.contacts(), ana.peers(), ana.records(), ana.inbox(), ana.outbox(), ana.helping(), ana.reachable());
    ana.invite().unwrap();
    assert!(ana.trace().iter().any(|l| l.contains(r#""ev":"panic""#) && l.contains("a bug, holding")), "the panic is in the trace");

    // And the node still works: a message each way.
    let to = |p: &Peer| p.contacts()[0].devices[0].device;
    for _ in 0..100 {
        if !ana.contacts().is_empty() && ana.contacts()[0].devices.iter().any(|d| d.online) {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    ana.post(to(&ana), b"still here".to_vec(), Duration::from_secs(60)).await.unwrap();
    bo.post(to(&bo), b"so am I".to_vec(), Duration::from_secs(60)).await.unwrap();
    for _ in 0..100 {
        if ana.inbox().iter().any(|e| e.bytes == b"so am I") && bo.inbox().iter().any(|e| e.bytes == b"still here") {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(bo.inbox().iter().any(|e| e.bytes == b"still here"));
    assert!(ana.inbox().iter().any(|e| e.bytes == b"so am I"));
    ana.close().await;
    bo.close().await;
}
