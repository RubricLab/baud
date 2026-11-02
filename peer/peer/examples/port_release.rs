//! Does the UDP port come back after Peer::close in-process?
use std::sync::Arc;
#[tokio::main]
async fn main() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = peer::Config::new("x", "a", "b");
    c.nearby = false;
    let p = peer::Peer::open(dir.path().to_path_buf(), Arc::new(peer::identity::MemoryKeychain::default()), c).await.unwrap();
    let port = p.addr().ip_addrs().next().unwrap().port();
    p.close().await; // the Peer stays alive, as a binding's object would
    for i in 0..8 {
        match std::net::UdpSocket::bind(("0.0.0.0", port)) {
            Ok(_) => { println!("port {port} free after {}00 ms", i * 5); return; }
            Err(e) => { println!("{}00 ms: {e}", i * 5); tokio::time::sleep(std::time::Duration::from_millis(500)).await; }
        }
    }
}
