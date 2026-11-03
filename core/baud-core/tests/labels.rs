//! A member's label in a group (`LabelTests.swift` on real cores): their own, or an admin's word
//! on anyone's, seen by everyone in it, short, and gone when emptied.

use std::sync::Arc;
use std::time::Duration;

use baud_core::Core;
use baud_core::types::*;
use baud_core::wire::{LabelBody, StateBody};
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

/// The label as the Swift app writes it decodes here, and the other way round.
#[test]
fn the_swift_label_decodes() {
    let swift = r#"{"key":"label","value":"{\"text\":\"driver\",\"user\":\"b2\"}"}"#;
    let s: StateBody = baud_core::json::decode(swift).unwrap();
    let l: LabelBody = baud_core::json::decode(&s.value).unwrap();
    assert_eq!(l, LabelBody { user: "b2".into(), text: "driver".into() });
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn labels_are_their_own_or_an_admins() {
    let (d, k) = dirs(2);
    let (ana, ben, _) = pair(&d, &k).await;
    let (a, b) = (ana.me().user, ben.me().user);
    // Ana makes the group, so she is its admin.
    let group = ana.create_group("hike", &[b.clone()]).unwrap().id;
    until("ben in the group", 10, || ben.conversation(&group).is_some()).await;
    let label = |c: &Core, u: &str| c.members(&group).into_iter().find(|m| m.user == u).and_then(|m| m.label);

    ben.set_label(&group, &b, Some("  driver  ")).unwrap();
    until("ana sees ben's label", 10, || label(&ana, &b).as_deref() == Some("driver")).await;

    // Ben isn't an admin: Ana's label isn't his to set.
    assert!(ben.set_label(&group, &a, Some("late")).is_err());

    // The admin may set anyone's, cut to 24 characters; None takes it away.
    ana.set_label(&group, &b, Some("organiser and driver for the whole weekend")).unwrap();
    until("ben sees the admin's label", 10, || label(&ben, &b).as_deref() == Some("organiser and driver for")).await;
    ana.set_label(&group, &b, None).unwrap();
    until("the label gone", 10, || label(&ben, &b).is_none()).await;
    assert!(label(&ana, &a).is_none());
}
