//! `close` lets go of every file in the node's directory: on Windows an open file cannot be
//! deleted, and an app that closes a node may remove its directory next.

use std::sync::Arc;

use peer::identity::MemoryKeychain;
use peer::{Config, Peer};

#[tokio::test]
async fn close_leaves_no_file_open() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = Config::new("close", "ana", "ana-dev");
    c.nearby = false;
    c.portmap = false;
    let p = Peer::open(dir.path().to_path_buf(), Arc::new(MemoryKeychain::default()), c).await.unwrap();
    p.set_online(true);
    let root = std::fs::canonicalize(dir.path()).unwrap().to_string_lossy().into_owned();
    let open = || -> Option<Vec<String>> {
        let out = std::process::Command::new("lsof").args(["-p", &std::process::id().to_string(), "-Fn"]).output().ok()?;
        Some(String::from_utf8_lossy(&out.stdout).lines().filter_map(|l| l.strip_prefix('n')).filter(|n| n.starts_with(&root)).map(str::to_owned).collect())
    };
    let Some(before) = open() else { return }; // no lsof here
    assert!(!before.is_empty(), "the store is open while the node runs");
    p.close().await;
    assert_eq!(open().unwrap(), Vec::<String>::new());
}

/// After `close` every entry point still answers, and nothing panics: a task that outlived it
/// (a probe, a push) or an app call racing it found the endpoint gone ("transport stopped").
#[tokio::test(flavor = "multi_thread")]
async fn a_closed_node_answers_and_nothing_panics() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = Config::new("close", "ana", "ana-dev");
    c.nearby = false;
    c.portmap = false;
    let p = Peer::open(dir.path().to_path_buf(), Arc::new(MemoryKeychain::default()), c).await.unwrap();
    p.set_online(true);
    p.network_changed();
    p.close().await;
    p.network_changed();
    p.set_online(false);
    p.set_online(true);
    let _ = (p.me(), p.addr(), p.contacts(), p.peers(), p.records(), p.inbox(), p.outbox(), p.helping(), p.reachable());
    tokio::time::sleep(std::time::Duration::from_secs(3)).await;
    let panics: Vec<_> = p.trace().into_iter().filter(|l| l.contains(r#""ev":"panic""#)).collect();
    assert!(panics.is_empty(), "{panics:?}");
}
