//! Real cores on real peer nodes on this machine (no router asked, nothing announced on the
//! LAN): meet by invite, message both ways with receipts, carried while away, a photo.

use std::sync::Arc;
use std::time::Duration;

use baud_core::Core;
use baud_core::types::*;
use peer::identity::MemoryKeychain;

fn config(name: &str) -> Config {
    let mut c = Config::new(name, &format!("{name}'s phone"), DeviceKind::Android);
    c.nearby = false;
    c.portmap = false; // tests never map a port on the developer's router
    c
}

async fn open(dir: &std::path::Path, keys: &Arc<MemoryKeychain>, name: &str) -> Arc<Core> {
    let c = Core::open(dir.to_path_buf(), keys.clone(), config(name)).await.unwrap();
    c.set_online(true);
    c
}

async fn until(what: &str, secs: u64, mut f: impl FnMut() -> bool) {
    let t0 = std::time::Instant::now();
    for _ in 0..secs * 20 {
        if f() {
            if t0.elapsed() > Duration::from_secs(2) {
                eprintln!("slow: {what} took {:?}", t0.elapsed());
            }
            return;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("timed out waiting for {what}");
}

fn chat_with(c: &Core, user: &str) -> Option<Conversation> {
    c.conversations(Some(Kind::Chat)).into_iter().find(|x| x.is_direct && x.members.iter().any(|m| m == user))
}

fn texts(c: &Core, conv: &str) -> Vec<String> {
    c.events(conv, None, 50).into_iter().filter_map(|e| e.text).collect()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn meet_message_carry_photo() {
    let dirs: Vec<tempfile::TempDir> = (0..3).map(|_| tempfile::tempdir().unwrap()).collect();
    let keys: Vec<Arc<MemoryKeychain>> = (0..3).map(|_| Arc::new(MemoryKeychain::default())).collect();
    let ana = open(dirs[0].path(), &keys[0], "Ana").await;
    let ben = open(dirs[1].path(), &keys[1], "Ben").await;
    let jo = open(dirs[2].path(), &keys[2], "Jo").await;
    let (a, b) = (ana.me().user, ben.me().user);
    assert_eq!(ana.me().name, "Ana");

    // Meet: Ben redeems Ana's invite; both are friends and Ana, the inviter, opens the chat.
    let link = ana.invite().unwrap();
    assert_eq!(link.kind, LinkKind::Friend);
    assert_eq!(baud_core::link::parse_code(&link.code).map(|l| l.name), Some("Ana".into()));
    let c = ben.add(&link.url).await.unwrap();
    assert_eq!(c.user, a);
    until("ana has ben", 10, || ana.contacts().iter().any(|c| c.user == b)).await;
    until("the chat on both sides", 10, || chat_with(&ana, &b).is_some() && chat_with(&ben, &a).is_some()).await;
    let conv = chat_with(&ana, &b).unwrap().id;
    assert_eq!(chat_with(&ben, &a).unwrap().id, conv, "one chat, the inviter's");

    // Both ways, with delivery and read.
    let sent = ana.send(&conv, Draft { text: "hi Ben https://x.y/z".into(), ..Default::default() }).unwrap();
    until("ben has it", 10, || texts(&ben, &conv).contains(&"hi Ben https://x.y/z".to_owned())).await;
    until("delivered", 10, || ana.delivery(&conv, &sent.id).best == DeliveryState::Delivered).await;
    let theirs = ben.events(&conv, None, 10).into_iter().find(|e| e.id == sent.id).unwrap();
    assert!(!theirs.mine);
    assert_eq!(ben.conversation(&conv).unwrap().unread, 1);
    ben.mark_read(&conv, &sent.id).unwrap();
    until("read", 10, || ana.delivery(&conv, &sent.id).best == DeliveryState::Read).await;
    assert_eq!(ana.delivery(&conv, &sent.id).sentence, "read");
    ben.send(&conv, Draft { text: "hi Ana".into(), ..Default::default() }).unwrap();
    until("ana has the reply", 10, || texts(&ana, &conv).contains(&"hi Ana".to_owned())).await;
    ana.react(&conv, &sent.id, "👍", true).unwrap();
    until("the reaction", 10, || ben.events(&conv, None, 10).iter().any(|e| e.id == sent.id && e.reactions.iter().any(|r| r.key == "👍"))).await;

    // Jo is everyone's friend and stays online; Ben goes away; Ana writes; Jo carries it.
    jo.add(&ana.invite().unwrap().url).await.unwrap();
    jo.add(&ben.invite().unwrap().url).await.unwrap();
    until("jo online to both", 15, || ana.contacts().iter().any(|c| c.name == "Jo" && c.online) && ben.contacts().iter().any(|c| c.name == "Jo" && c.online)).await;
    let ben_device = ben.me().this_device;
    ben.close().await;
    drop(ben);
    until("ana sees ben away", 15, || !ana.contacts().iter().any(|c| c.user == b && c.online)).await;
    let away = ana.send(&conv, Draft { text: "while you were out".into(), ..Default::default() }).unwrap();
    until("carried", 15, || matches!(ana.delivery(&conv, &away.id).best, DeliveryState::Carried { .. })).await;
    assert!(ana.delivery(&conv, &away.id).sentence.starts_with("carried by Jo's"), "{}", ana.delivery(&conv, &away.id).sentence);
    // Ana goes too: the two are never online at once, and only Jo can hand it over.
    ana.close().await;
    drop(ana);
    let ben = open(dirs[1].path(), &keys[1], "Ben").await;
    assert_eq!(ben.me().this_device, ben_device);
    until("ben has it after coming back", 30, || texts(&ben, &conv).contains(&"while you were out".to_owned())).await;
    let got = ben.events(&conv, None, 20).into_iter().find(|e| e.id == away.id).unwrap();
    assert_eq!(got.via, Some(Via::Carried), "it came by a carrier");
    assert_eq!(got.carried_by, Some(jo.me().this_device), "Jo carried it");
    let ana = open(dirs[0].path(), &keys[0], "Ana").await;
    until("ana and ben meet again", 30, || ana.contacts().iter().any(|c| c.user == b && c.online)).await;
    until("delivered once ben is back", 30, || ana.delivery(&conv, &away.id).best == DeliveryState::Delivered).await;

    // A photo: the bytes come along with the message.
    let png = dirs[0].path().join("dot.png");
    std::fs::write(&png, PNG).unwrap();
    let photo = ana.send(&conv, Draft { text: String::new(), attachments: vec![png.to_string_lossy().into()], ..Default::default() }).unwrap();
    let att = photo.attachments[0].clone();
    assert_eq!((att.mime.as_str(), att.width, att.height), ("image/png", Some(1), Some(1)));
    until("ben has the photo's message", 15, || ben.events(&conv, None, 20).iter().any(|e| e.id == photo.id)).await;
    let path = tokio::time::timeout(Duration::from_secs(30), ben.blob(&att.hash, &att.key)).await.unwrap().unwrap();
    assert_eq!(baud_core::file_hash(std::path::Path::new(&path)).unwrap(), att.hash);
}

/// A 1×1 PNG.
const PNG: &[u8] = &[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
    0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0x0F, 0x00, 0x00, 0x01, 0x01, 0x00, 0x05, 0x18, 0xD8, 0x4E, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
    0x42, 0x60, 0x82,
];

/// A group of three where two of them have never met: Ana's friends Ben and Jo. What Ben writes
/// reaches Jo through Ana (peer's chat tier: a co-member who isn't a contact is reached through
/// a mutual), and Jo's answer reaches Ben the same way.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn group_of_strangers() {
    let dirs: Vec<tempfile::TempDir> = (0..3).map(|_| tempfile::tempdir().unwrap()).collect();
    let keys: Vec<Arc<MemoryKeychain>> = (0..3).map(|_| Arc::new(MemoryKeychain::default())).collect();
    let ana = open(dirs[0].path(), &keys[0], "Ana").await;
    let ben = open(dirs[1].path(), &keys[1], "Ben").await;
    let jo = open(dirs[2].path(), &keys[2], "Jo").await;
    ben.add(&ana.invite().unwrap().url).await.unwrap();
    jo.add(&ana.invite().unwrap().url).await.unwrap();
    until("ana's friends", 10, || ana.contacts().len() == 2).await;
    let (b, j) = (ben.me().user, jo.me().user);
    let g = ana.create_group("Trip", &[b.clone(), j.clone()]).unwrap();
    assert_eq!(g.name.as_deref(), Some("Trip"));
    until("the group everywhere", 15, || ben.conversation(&g.id).map(|c| c.members.len()) == Some(3) && jo.conversation(&g.id).map(|c| c.members.len()) == Some(3)).await;
    let lines = ben.events(&g.id, None, 10).into_iter().filter_map(|e| e.system).collect::<Vec<_>>();
    assert!(lines.iter().any(|l| l == "Ana made the group Trip"), "{lines:?}");
    ben.send(&g.id, Draft { text: "hi all".into(), ..Default::default() }).unwrap();
    until("jo has ben's line", 20, || texts(&jo, &g.id).contains(&"hi all".to_owned())).await;
    until("ana has it", 10, || texts(&ana, &g.id).contains(&"hi all".to_owned())).await;
    jo.send(&g.id, Draft { text: "hi ben".into(), ..Default::default() }).unwrap();
    until("ben has jo's line", 20, || texts(&ben, &g.id).contains(&"hi ben".to_owned())).await;
    let m = ben.members(&g.id);
    assert_eq!(m.iter().find(|x| x.user == j).map(|x| x.name.as_str()), Some("Jo"), "a stranger's name comes on their card");
}

/// A new device of mine, linked by a real device link and its six digits: it becomes me, and
/// my chats come over to it from my other device, history included; then it talks as me.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn linked_device_gets_my_chats() {
    let dirs: Vec<tempfile::TempDir> = (0..3).map(|_| tempfile::tempdir().unwrap()).collect();
    let keys: Vec<Arc<MemoryKeychain>> = (0..3).map(|_| Arc::new(MemoryKeychain::default())).collect();
    let ana = open(dirs[0].path(), &keys[0], "Ana").await;
    let ben = open(dirs[1].path(), &keys[1], "Ben").await;
    ben.add(&ana.invite().unwrap().url).await.unwrap();
    let b = ben.me().user;
    until("the chat", 10, || chat_with(&ana, &b).is_some()).await;
    let conv = chat_with(&ana, &b).unwrap().id;
    ana.send(&conv, Draft { text: "before the tablet".into(), ..Default::default() }).unwrap();
    until("ben has it", 10, || texts(&ben, &conv).contains(&"before the tablet".to_owned())).await;
    ana.set_profile("colour", "0090FF");

    // The old device confirms every request it sees (the person compares the digits).
    let a2 = ana.clone();
    ana.subscribe(Box::new(move |c| {
        if let Change::LinkRequest { req, .. } = c {
            a2.confirm_link(req, true);
        }
    }));
    let tablet = open(dirs[2].path(), &keys[2], "").await;
    let link = ana.link_device().unwrap();
    assert_eq!(link.kind, LinkKind::Device);
    assert_eq!(tablet.joining_code(&link.url).map(|c| c.len()), Some(6));
    tablet.link(&link.url).await.unwrap();
    assert_eq!(tablet.me().user, ana.me().user);
    until("both devices on my card", 10, || ana.me().devices.len() == 2 && tablet.me().devices.len() == 2).await;
    until("my chat with Ben on the tablet", 20, || texts(&tablet, &conv).contains(&"before the tablet".to_owned())).await;
    until("my colour on the tablet", 20, || tablet.profile("colour").as_deref() == Some("0090FF")).await;
    tablet.send(&conv, Draft { text: "from the tablet".into(), ..Default::default() }).unwrap();
    until("ben has the tablet's", 20, || texts(&ben, &conv).contains(&"from the tablet".to_owned())).await;
    until("and my phone has it too", 20, || texts(&ana, &conv).contains(&"from the tablet".to_owned())).await;
    assert!(ben.events(&conv, None, 10).iter().any(|e| e.text.as_deref() == Some("from the tablet") && e.user == ana.me().user));
}

/// Stop and start, as a service does: what was written while the other side was away, and
/// even after shutdown, goes out from the next open of the same directory. Nothing is lost.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn restart_keeps_the_outbox() {
    let dirs: Vec<tempfile::TempDir> = (0..2).map(|_| tempfile::tempdir().unwrap()).collect();
    let keys: Vec<Arc<MemoryKeychain>> = (0..2).map(|_| Arc::new(MemoryKeychain::default())).collect();
    let ana = open(dirs[0].path(), &keys[0], "Ana").await;
    let ben = open(dirs[1].path(), &keys[1], "Ben").await;
    ben.add(&ana.invite().unwrap().url).await.unwrap();
    let (a, b) = (ana.me().user, ben.me().user);
    until("the chat", 10, || chat_with(&ana, &b).is_some() && chat_with(&ben, &a).is_some()).await;
    let conv = chat_with(&ana, &b).unwrap().id;

    // Ben away, nobody to carry: it waits on Ana's side.
    ben.close().await;
    drop(ben);
    until("ana sees ben away", 15, || !ana.contacts().iter().any(|c| c.user == b && c.online)).await;
    let queued = ana.send(&conv, Draft { text: "queued while ben is away".into(), ..Default::default() }).unwrap();
    assert_eq!(ana.delivery(&conv, &queued.id).best, DeliveryState::Sent);
    // The service stops; a line written during teardown is kept too.
    ana.close().await;
    ana.close().await;
    let late = ana.send(&conv, Draft { text: "written after shutdown".into(), ..Default::default() }).unwrap();
    assert_eq!(late.via, Some(Via::Waiting));
    drop(ana);

    // Both come back from their directories, in either order.
    let ana = open(dirs[0].path(), &keys[0], "Ana").await;
    assert_eq!(ana.me().user, a);
    assert!(texts(&ana, &conv).contains(&"written after shutdown".to_owned()));
    let ben = open(dirs[1].path(), &keys[1], "Ben").await;
    assert_eq!(ben.me().user, b);
    until("ben has both", 30, || {
        let t = texts(&ben, &conv);
        t.contains(&"queued while ben is away".to_owned()) && t.contains(&"written after shutdown".to_owned())
    })
    .await;
    until("delivered", 20, || ana.delivery(&conv, &late.id).best == DeliveryState::Delivered).await;
}

/// A friend link that can't get through from the redeemer's side: the redeemer answers with a
/// reply, the link's maker opens it, and they meet; the maker (the inviter) opens the chat.
/// Opened again it just gives the contact; an expired one says so before dialing anyone.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_reply_meets_its_links_maker() {
    let dirs: Vec<tempfile::TempDir> = (0..2).map(|_| tempfile::tempdir().unwrap()).collect();
    let keys: Vec<Arc<MemoryKeychain>> = (0..2).map(|_| Arc::new(MemoryKeychain::default())).collect();
    let ana = open(dirs[0].path(), &keys[0], "Ana").await;
    let ben = open(dirs[1].path(), &keys[1], "Ben").await;
    let heard = Arc::new(std::sync::Mutex::new(vec![]));
    let h = heard.clone();
    ben.subscribe(Box::new(move |c| {
        if let Change::Replied { user } = c {
            h.lock().unwrap().push(user);
        }
    }));
    let link = ana.invite().unwrap();
    let reply = ben.reply(&link.url).unwrap();
    assert_eq!(reply.kind, LinkKind::Reply);
    assert_eq!(reply.name, "Ben");
    assert!(reply.expires <= link.expires);
    assert_eq!(baud_core::link::parse_code(&reply.code).map(|l| l.kind), Some(LinkKind::Reply));
    // Not a reply to a reply, nor to a device link.
    assert!(matches!(ben.reply(&reply.url), Err(baud_core::Error::BadLink)));

    // Expired: faked by moving its time back; refused before anyone is dialed.
    let mut parts: Vec<String> = reply.url.rsplit_once('#').unwrap().1.split('.').map(String::from).collect();
    if parts.len() == 7 {
        parts[4] = "1000000000".into();
        let stale = format!("baud://add#{}", parts.join("."));
        assert!(matches!(ana.add(&stale).await, Err(baud_core::Error::Expired)));
    }

    // Ana relaunches before opening it: no invite of hers is in the process any more, and she
    // still opens the chat, as the one Ben answered.
    ana.close().await;
    drop(ana);
    let ana = open(dirs[0].path(), &keys[0], "Ana").await;
    let c = ana.add(&reply.url).await.unwrap();
    assert_eq!(c.name, "Ben");
    let (a, b) = (ana.me().user, ben.me().user);
    until("ben hears his reply met ana", 10, || heard.lock().unwrap().contains(&a)).await;
    until("friends both ways", 10, || ben.contacts().iter().any(|c| c.user == a)).await;
    until("ana, the inviter, opened the chat", 10, || chat_with(&ana, &b).is_some() && chat_with(&ben, &a).is_some()).await;
    until("one chat, the same on both sides", 10, || chat_with(&ana, &b).map(|c| c.id) == chat_with(&ben, &a).map(|c| c.id)).await;
    assert_eq!(ana.conversations(Some(Kind::Chat)).len(), 1, "no second chat");
    // Opened twice: the contact, no second meeting.
    assert_eq!(ana.add(&reply.url).await.unwrap().user, b);
    // Answering a link from someone already a friend: Used.
    assert!(matches!(ben.reply(&ana.invite().unwrap().url), Err(baud_core::Error::Used)));
}
