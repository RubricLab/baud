//! The port a gateway mapping forwards to is the one the endpoint is bound on, even once the node
//! knows a public address whose port is the gateway's. A remap after a router restart took the
//! first known address's port (the external one) and mapped the router to a port nobody held.

use std::sync::Arc;

use peer::identity::MemoryKeychain;
use peer::{Config, Peer};

#[tokio::test]
async fn the_bound_port_not_a_learnt_public_one() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = Config::new("bound", "ana", "ana-dev");
    c.nearby = false;
    c.portmap = false;
    let p = Peer::open(dir.path().to_path_buf(), Arc::new(MemoryKeychain::default()), c).await.unwrap();
    let bound = p.transport().port().expect("a bound port");
    let public: std::net::SocketAddr = format!("1.2.3.4:{}", if bound == 4242 { 4243 } else { 4242 }).parse().unwrap();
    p.transport().ep().add_external_addr(public).await;
    let t0 = std::time::Instant::now();
    while !p.addr().ip_addrs().any(|a| *a == public) && t0.elapsed() < std::time::Duration::from_secs(2) {
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    assert!(p.addr().ip_addrs().any(|a| *a == public), "the public address is known");
    // Addresses sort by IP, so a low public one comes first: the old lookup.
    assert_eq!(p.addr().ip_addrs().next().map(|a| a.port()), Some(public.port()));
    assert_eq!(p.transport().port(), Some(bound));
    p.close().await;
}

/// Both families on the one port: an address a peer cached, IPv4 or IPv6, stays good across a
/// restart. Where IPv6 is not available the endpoint still opens, on IPv4 alone.
#[tokio::test]
async fn ipv6_on_the_same_port_as_ipv4() {
    let dir = tempfile::tempdir().unwrap();
    let keychain = Arc::new(MemoryKeychain::default());
    let mut c = Config::new("bound", "ana", "ana-dev");
    c.nearby = false;
    c.portmap = false;
    let p = Peer::open(dir.path().to_path_buf(), keychain.clone(), c.clone()).await.unwrap();
    let port = p.transport().port().expect("a bound port");
    p.close().await;
    // Reopened, it asks for last time's port: now both families take it.
    let p = Peer::open(dir.path().to_path_buf(), keychain, c).await.unwrap();
    let sockets = p.transport().ep().bound_sockets();
    assert!(sockets.iter().any(|s| s.is_ipv4() && s.port() == port), "{sockets:?}");
    if std::net::UdpSocket::bind("[::1]:0").is_ok() {
        assert!(sockets.iter().any(|s| s.is_ipv6() && s.port() == port), "IPv6 beside IPv4 on {port}: {sockets:?}");
    }
    p.close().await;
}

/// A first launch, with no port asked for and none from last time, already shares one port
/// between the families: the second launch moves nothing a peer cached.
#[tokio::test]
async fn ipv6_on_the_same_port_from_the_first_launch() {
    if std::net::UdpSocket::bind("[::1]:0").is_err() {
        return; // no IPv6 on this host
    }
    let dir = tempfile::tempdir().unwrap();
    let mut c = Config::new("bound", "ana", "ana-dev");
    c.nearby = false;
    c.portmap = false;
    let p = Peer::open(dir.path().to_path_buf(), Arc::new(MemoryKeychain::default()), c).await.unwrap();
    let sockets = p.transport().ep().bound_sockets();
    let v4 = sockets.iter().find(|s| s.is_ipv4()).map(|s| s.port());
    let v6 = sockets.iter().find(|s| s.is_ipv6()).map(|s| s.port());
    assert!(v4.is_some() && v4 == v6, "one port for both families on a first launch: {sockets:?}");
    p.close().await;
}
