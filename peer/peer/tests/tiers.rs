//! Three tiers (DESIGN.md): in a chat, a co-member who is not a contact gets my card but never
//! my record, is never dialed or admitted, and still receives what I send, carried by a friend we
//! share. In a space every member is a mutual: records shared, dialed, connected.

use std::sync::Arc;
use std::time::Duration;

use peer::identity::{GroupId, MemoryKeychain};
use peer::{Config, GroupKind, Peer};

fn config(name: &str) -> Config {
    let mut c = Config::new("tiers", name, &format!("{name}-dev"));
    c.nearby = false;
    c.portmap = false; // tests never map a port on the developer's router
    c
}

async fn node(name: &str) -> (Peer, tempfile::TempDir) {
    let d = tempfile::tempdir().unwrap();
    let p = Peer::open(d.path().to_path_buf(), Arc::new(MemoryKeychain::default()), config(name)).await.unwrap();
    p.set_online(true);
    (p, d)
}

async fn until(what: &str, mut f: impl FnMut() -> bool) {
    for _ in 0..200 {
        if f() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("timed out waiting for {what}");
}

/// ana and carol are each bob's friend, not each other's; bob puts the three in a group of `kind`.
async fn three(kind: GroupKind, g: u8) -> ((Peer, tempfile::TempDir), (Peer, tempfile::TempDir), (Peer, tempfile::TempDir), GroupId) {
    let (bob, db) = node("bob").await;
    let (ana, da) = node("ana").await;
    let (carol, dc) = node("carol").await;
    ana.add(&bob.invite().unwrap()).await.unwrap();
    carol.add(&bob.invite().unwrap()).await.unwrap();
    let group = GroupId([g; 32]);
    for p in [&bob, &ana, &carol] {
        p.create_group(group, kind).unwrap();
    }
    until("bob reaches both", || bob.peers().iter().filter(|s| s.online).count() == 2).await;
    // Each member's app adds who its own group event names; here, the one who invited them.
    ana.add_member(group, ana.card_of(bob.me().user).unwrap()).unwrap();
    carol.add_member(group, carol.card_of(bob.me().user).unwrap()).unwrap();
    bob.add_member(group, bob.card_of(ana.me().user).unwrap()).unwrap();
    bob.add_member(group, bob.card_of(carol.me().user).unwrap()).unwrap();
    until("ana holds carol's card through bob", || ana.group_members(group).iter().any(|m| m.user == carol.me().user)).await;
    ((bob, db), (ana, da), (carol, dc), group)
}

#[tokio::test]
async fn a_chat_co_member_gets_my_card_and_my_messages_but_never_my_record() {
    let ((bob, _db), (ana, _da), (carol, _dc), group) = three(GroupKind::Chat, 7).await;
    let (ana_dev, carol_dev) = (ana.me().this_device, carol.me().this_device);
    let m = ana.group_members(group).into_iter().find(|m| m.user == carol.me().user).unwrap();
    assert_eq!(m.name, "carol", "a non-contact is shown by the name on their card");
    assert!(!m.contact && !m.mutual);
    assert_eq!(ana.group_kind(group), Some(GroupKind::Chat));

    // What ana sends carol arrives, carried by bob.
    ana.post(carol_dev, b"hello carol".to_vec(), Duration::from_secs(600)).await.unwrap();
    until("carol has it", || carol.inbox().iter().any(|e| e.bytes == b"hello carol")).await;
    let e = carol.inbox().into_iter().find(|e| e.bytes == b"hello carol").unwrap();
    assert_eq!(e.carried_by, vec![bob.me().this_device]);

    // And neither ever holds the other's record, lists the other as a peer, or connects.
    tokio::time::sleep(Duration::from_millis(1500)).await;
    assert!(!ana.records().iter().any(|r| r.device == carol_dev), "ana must not hold carol's record");
    assert!(!carol.records().iter().any(|r| r.device == ana_dev), "carol must not hold ana's record");
    assert!(!ana.peers().iter().any(|p| p.device == carol_dev));
    assert!(!ana.connections().iter().any(|p| p.device == carol_dev));

    bob.close().await;
    ana.close().await;
    carol.close().await;
}

#[tokio::test]
async fn space_members_are_mutuals_and_connect() {
    let ((bob, _db), (ana, _da), (carol, _dc), group) = three(GroupKind::Space, 9).await;
    let carol_dev = carol.me().this_device;
    assert!(ana.group_members(group).iter().find(|m| m.user == carol.me().user).unwrap().mutual);
    until("ana holds carol's record", || ana.records().iter().any(|r| r.device == carol_dev)).await;
    until("ana and carol connect", || ana.peers().iter().any(|p| p.device == carol_dev && p.online)).await;
    bob.close().await;
    ana.close().await;
    carol.close().await;
}
