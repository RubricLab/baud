//! The reachability probe between real iroh endpoints on loopback: one node asks four others
//! what address they see it at. Loopback answers are not public, so the verdict is `Unknown`
//! (a LAN peer says nothing about the NAT); what this proves is the machinery: four binding
//! answers over authenticated connections, one port. The verdict table is unit-tested.

use std::sync::{Arc, Mutex};

use peer::identity::MemoryKeychain;

/// The three tests open up to five endpoints each; run them one at a time so port and timing
/// contention between them can never turn a verdict. A flaky gate is no gate.
static SERIAL: Mutex<()> = Mutex::new(());

use peer::probe::Reachable;
use peer::{Config, Error, Peer};

async fn node(name: &str) -> (Peer, tempfile::TempDir) {
    let dir = tempfile::tempdir().unwrap();
    let mut config = Config::new("probe-test", name, "test");
    config.nearby = false;
    config.portmap = false;
    let peer = Peer::open(dir.path().to_path_buf(), Arc::new(MemoryKeychain::default()), config).await.unwrap();
    (peer, dir)
}

fn loopback(p: &Peer) -> iroh::EndpointAddr {
    let port = p.addr().ip_addrs().next().expect("a bound port").port();
    iroh::EndpointAddr::new(p.me().this_device.into()).with_ip_addr(([127, 0, 0, 1], port).into())
}

#[tokio::test]
async fn four_responders_agree_so_reachable() {
    let _serial = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let (a, _da) = node("a").await;
    let mut others = Vec::new();
    for n in ["b", "c", "d", "e"] {
        let (p, d) = node(n).await;
        p.permit(a.me().this_device);
        a.connect_raw(loopback(&p)).await.unwrap();
        others.push((p, d));
    }
    let conns = a.connections();
    assert_eq!(conns.len(), 4, "{conns:?}");
    assert!(conns.iter().all(|p| matches!(p.path, peer::Path::Direct { vpn: false }) && p.online), "{conns:?}");
    let outcome = peer::probe::run(&a.crate_connections(), None, None, None, &[]).await;
    assert_eq!(outcome.observations.len(), 4, "{outcome:?}");
    let ports: std::collections::BTreeSet<u16> = outcome.observations.iter().map(|o| o.observed.port()).collect();
    assert_eq!(ports.len(), 1, "one socket, one port: {outcome:?}");
    assert_eq!(outcome.reachable, Reachable::Unknown, "loopback is not the internet");
    assert_eq!(a.probe().await, Reachable::Unknown);
    a.close().await;
    for (p, _) in others {
        p.close().await;
    }
}

#[tokio::test]
async fn one_responder_is_unknown() {
    let _serial = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let (a, _da) = node("a").await;
    let (b, _db) = node("b").await;
    b.permit(a.me().this_device);
    a.connect_raw(loopback(&b)).await.unwrap();
    assert_eq!(a.probe().await, Reachable::Unknown);
    assert!(!a.reachable().advertised());
    a.close().await;
    b.close().await;
}

#[tokio::test]
async fn a_stranger_is_not_in_their_book() {
    let _serial = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let (a, _da) = node("a").await;
    let (b, _db) = node("b").await;
    let err = a.connect_raw(loopback(&b)).await.unwrap_err();
    assert_eq!(err, Error::NotInTheirBook, "the gate must be distinguishable from a timeout");
    a.close().await;
    b.close().await;
}

/// The dial back that checks a mapping: from a throwaway endpoint, a handshake with the asker's
/// key at its port gets through (its gate refusing the stranger after it), a port nobody holds
/// does not. And a responder that does not see me across the internet never weighs in: the
/// gateway's word stands, so a mapping is withdrawn only on an answer from outside.
#[tokio::test]
async fn a_dial_back_reaches_the_asker_and_only_outside_answers_count() {
    let _serial = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let (a, _da) = node("a").await;
    let (b, _db) = node("b").await;
    let limit = std::time::Duration::from_secs(3);
    let at = loopback(&a).ip_addrs().next().copied().unwrap();
    let nobody = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
    let dead = nobody.local_addr().unwrap();
    drop(nobody);
    // One endpoint per dial, as `dial_back` does: iroh would remember the path to a's key.
    for (to, through) in [(dead, false), (at, true)] {
        let ep = peer::transport::throwaway().await.unwrap();
        assert_eq!(peer::transport::handshakes(&ep, a.me().this_device.into(), to, limit).await, through, "{to}");
        ep.close().await;
    }

    b.permit(a.me().this_device);
    a.connect_raw(loopback(&b)).await.unwrap();
    let mapping = Some("203.0.113.1:4101".parse().unwrap());
    let outcome = peer::probe::run(&a.crate_connections(), mapping, None, None, &[]).await;
    assert_eq!((outcome.udp_check, outcome.reachable), (None, Reachable::Yes), "{outcome:?}");
    // One an earlier check did not get through stays doubted while nobody can check it again.
    let outcome = peer::probe::run(&a.crate_connections(), mapping, None, mapping, &[]).await;
    assert_eq!((outcome.udp_check, outcome.reachable, outcome.public), (None, Reachable::Unknown, None), "{outcome:?}");
    a.close().await;
    b.close().await;
}
