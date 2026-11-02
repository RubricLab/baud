//! A send counts once the far side has it. `finish` used to return once the end of the stream
//! was queued here, so a frame sent on a connection dead in all but name (its relay frozen, the
//! far side asleep or gone off its network) was reported sent and lost when the connection timed
//! out; the app, told it was delivered, never handed it to carriers.

use std::sync::Arc;
use std::time::{Duration, Instant};

use peer::identity::MemoryKeychain;
use peer::policy::Class;
use peer::{Config, Peer};

const ALPN: &[u8] = b"delivery/1";

fn config(name: &str) -> Config {
    let mut c = Config::new("delivery", name, &format!("{name}-dev"));
    c.nearby = false;
    c.portmap = false; // tests never map a port on the developer's router
    c.alpns = vec![ALPN.to_vec()];
    c
}

#[tokio::test(flavor = "multi_thread")]
async fn a_send_counts_only_once_the_far_side_has_it() {
    // Bo lives on a runtime of his own, one thread: blocking it freezes him the way iOS suspends
    // an app, every task stopped and his socket unanswered, his connections open.
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
    let conn = ana.connect(bo_device, Class::Small, ALPN).await.unwrap();

    let s = peer_uniffi::Stream::from(conn.open().await.unwrap());
    s.send(b"while bo is awake".to_vec()).await.unwrap();
    s.finish().await.expect("bo has it");

    freeze_tx.send(()).unwrap();
    tokio::time::sleep(Duration::from_millis(200)).await;
    let s = peer_uniffi::Stream::from(conn.open().await.unwrap());
    s.send(b"while bo is frozen".to_vec()).await.unwrap();
    let t = Instant::now();
    assert!(s.finish().await.is_err(), "not delivered: bo is frozen");
    assert!(t.elapsed() < Duration::from_secs(6), "said so in {:?}", t.elapsed());

    // And the next message is not held back dialing into the same silence: carriers, at once.
    let t = Instant::now();
    assert!(ana.connect(bo_device, Class::Small, ALPN).await.is_err(), "bo went silent");
    assert!(t.elapsed() < Duration::from_secs(1), "refused in {:?}", t.elapsed());

    ana.close().await;
    bo.join().unwrap();
}
