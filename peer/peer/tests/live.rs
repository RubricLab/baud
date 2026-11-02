//! A call's connection (Live) ends within seconds of its path dying. The far side frozen, as iOS
//! suspends an app, used to leave this side in the call for QUIC's 20 s idle timeout while the
//! other had long given up; one side on, the other gone.

use std::sync::Arc;
use std::time::{Duration, Instant};

use peer::identity::MemoryKeychain;
use peer::policy::Class;
use peer::{Config, Peer};

const ALPN: &[u8] = b"live/1";

fn config(name: &str) -> Config {
    let mut c = Config::new("live", name, &format!("{name}-dev"));
    c.nearby = false;
    c.portmap = false; // tests never map a port on the developer's router
    c.alpns = vec![ALPN.to_vec()];
    c
}

#[tokio::test(flavor = "multi_thread")]
async fn a_call_ends_within_seconds_of_the_far_side_freezing() {
    // Bo on a runtime of his own, one thread: blocking it freezes him, his socket unanswered.
    let (link_tx, link_rx) = std::sync::mpsc::channel();
    let (freeze_tx, freeze_rx) = std::sync::mpsc::channel::<()>();
    let bo = std::thread::spawn(move || {
        let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        rt.block_on(async move {
            let dir = tempfile::tempdir().unwrap();
            let bo = Peer::open(dir.path().to_path_buf(), Arc::new(MemoryKeychain::default()), config("bo")).await.unwrap();
            bo.set_online(true);
            link_tx.send((bo.invite().unwrap(), bo.me().this_device)).unwrap();
            while freeze_rx.try_recv().is_err() {
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
            std::thread::sleep(Duration::from_secs(10));
        });
    });
    let (link, bo_device) = link_rx.recv().unwrap();
    let dir = tempfile::tempdir().unwrap();
    let ana = Peer::open(dir.path().to_path_buf(), Arc::new(MemoryKeychain::default()), config("ana")).await.unwrap();
    ana.set_online(true);
    ana.add(&link).await.unwrap();
    let call = ana.connect(bo_device, Class::Live, ALPN).await.unwrap();
    let mut s = call.open().await.unwrap();
    s.send(b"ring").await.unwrap();

    freeze_tx.send(()).unwrap();
    let t = Instant::now();
    let ended = tokio::time::timeout(Duration::from_secs(15), call.recv_datagram()).await;
    assert!(matches!(ended, Ok(Err(_))), "the call ends: {ended:?}");
    assert!(t.elapsed() < Duration::from_secs(7), "within seconds, not QUIC's 20: {:?}", t.elapsed());

    ana.close().await;
    bo.join().unwrap();
}
