//! A loop that asks faster than its peer answers costs refusals, not memory. Three carriers that
//! passed envelopes round queued request after request for stream credit, and a Mac mini grew to
//! 15 GB (3ad457b). Past `MAX_ASKS` in flight on one connection, an ask waits a second for a
//! slot, then fails; a burst flows through as asks end.

use std::sync::Arc;
use std::time::{Duration, Instant};

use peer::identity::MemoryKeychain;
use peer::transport::{MAX_ASKS, Msg, ask};
use peer::{Config, Error, Peer};

const ALPN: &[u8] = b"asks/1";

async fn node(name: &str) -> (Peer, tempfile::TempDir) {
    let d = tempfile::tempdir().unwrap();
    let mut c = Config::new("asks", name, &format!("{name}-dev"));
    c.nearby = false;
    c.portmap = false; // tests never map a port on the developer's router
    c.alpns = vec![ALPN.to_vec()];
    let p = Peer::open(d.path().to_path_buf(), Arc::new(MemoryKeychain::default()), c).await.unwrap();
    p.set_online(true);
    (p, d)
}

#[tokio::test(flavor = "multi_thread")]
async fn a_peer_that_cannot_keep_up_costs_refusals_and_a_burst_flows() {
    let (ana, _da) = node("ana").await;
    let (bo, _db) = node("bo").await;
    ana.add(&bo.invite().unwrap()).await.unwrap();
    // On the app's ALPN, which nobody on bo's side reads: every ask waits, as on a peer that stopped.
    let port = bo.transport().port().unwrap();
    let addr = iroh::EndpointAddr::new(bo.me().this_device.into()).with_ip_addr(([127, 0, 0, 1], port).into());
    let conn = ana.transport().connect(addr, ALPN).await.unwrap();
    let waiting: Vec<_> = (0..MAX_ASKS)
        .map(|_| {
            let conn = conn.clone();
            tokio::spawn(async move { tokio::time::timeout(Duration::from_secs(3), ask(&conn, &Msg::Bind)).await })
        })
        .collect();
    tokio::time::sleep(Duration::from_millis(300)).await;
    // One past the cap waits a second for a slot, none frees, and it is refused.
    let t = Instant::now();
    let r = tokio::time::timeout(Duration::from_secs(2), ask(&conn, &Msg::Bind)).await;
    assert!(matches!(r, Ok(Err(Error::Budget))), "one past the cap: {r:?}");
    assert!(t.elapsed() < Duration::from_millis(1500), "refused in {:?}", t.elapsed());
    for w in waiting {
        assert!(w.await.unwrap().is_err(), "unanswered");
    }
    // A burst flows through: one held at the cap takes the slot the first to end gives back.
    let full: Vec<_> = (0..MAX_ASKS)
        .map(|_| {
            let conn = conn.clone();
            tokio::spawn(async move { tokio::time::timeout(Duration::from_millis(300), ask(&conn, &Msg::Bind)).await })
        })
        .collect();
    tokio::time::sleep(Duration::from_millis(100)).await;
    let r = tokio::time::timeout(Duration::from_millis(1200), ask(&conn, &Msg::Bind)).await;
    assert!(r.is_err(), "taken once a slot freed, then waiting on bo, not refused: {r:?}");
    for f in full {
        let _ = f.await;
    }
    ana.close().await;
    bo.close().await;
}
