//! An invite names the best meeting device (DESIGN.md, "baud, aggressively simple"): two nodes
//! that cannot reach each other directly meet through a third that runs a relay, whether it is
//! the inviter's own device or a friend's, and the redeemer is a stranger to it. The link carries
//! the helper's relay URLs with the inviter's meet token and none of the inviter's addresses; the
//! helper relays ciphertext and learns nothing of the redeemer.

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use peer::identity::MemoryKeychain;
use peer::{Config, MeetingKind, Peer};

static SERIAL: Mutex<()> = Mutex::new(());

fn config(name: &str) -> Config {
    let mut c = Config::new("meet", name, &format!("{name}-dev"));
    c.nearby = false;
    c.portmap = false; // tests never map a port on the developer's router
    c.auto_confirm_links = true;
    c
}

async fn node(c: Config) -> (Peer, tempfile::TempDir) {
    let d = tempfile::tempdir().unwrap();
    let p = Peer::open(d.path().to_path_buf(), Arc::new(MemoryKeychain::default()), c).await.unwrap();
    p.set_online(true);
    (p, d)
}

/// A node that runs a relay on a free port, offered at its own address (no mapping in a test).
async fn helper(name: &str) -> (Peer, tempfile::TempDir) {
    let port = std::net::TcpListener::bind("0.0.0.0:0").unwrap().local_addr().unwrap().port();
    let mut c = config(name);
    c.port = Some(port);
    c.relay = true;
    c.public = true;
    node(c).await
}

async fn within(what: &str, limit: Duration, mut f: impl FnMut() -> bool) -> Duration {
    let t = Instant::now();
    while t.elapsed() < limit {
        if f() {
            return t.elapsed();
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("{what}: not within {limit:?}");
}

/// Homed on one of the helper's relay URLs: a link through it reaches this node.
fn homed_on(p: &Peer, helper: &Peer) -> bool {
    let theirs: Vec<String> = helper.helping().relay_url.unwrap_or_default().split(' ').map(str::to_owned).collect();
    p.transport().addr().relay_urls().any(|u| theirs.contains(&u.to_string()))
}

/// `invite()` names the helper; the redeemer, who holds no card for it, adds through it.
async fn meet_through(inviter: &Peer, h: &Peer, kind: MeetingKind) {
    let meeting = inviter.invite_meeting();
    assert_eq!((meeting.kind, meeting.device), (kind, Some(h.me().this_device)));
    within("the inviter homes on the helper's relay", Duration::from_secs(2), || homed_on(inviter, h)).await;
    let link = inviter.invite().unwrap();
    assert!(!link.meet.addrs.is_empty() && link.meet.addrs.iter().all(|a| a.starts_with("relay=") && a.contains("?m=")), "only the helper's relay, with a token: {:?}", link.meet.addrs);

    let (stranger, _ds) = node(config("ana")).await;
    let t = Instant::now();
    let contact = stranger.add(&link).await.expect("added through the helper");
    let took = t.elapsed();
    assert_eq!(contact.user, inviter.me().user);
    assert!(took < Duration::from_secs(5), "within 5 s: {took:?}");
    within("the inviter has ana", Duration::from_secs(2), || inviter.contacts().iter().any(|c| c.name == "ana")).await;
    // One use: the same person may ask again (a lost answer); anyone else holding it may not.
    assert_eq!(stranger.add(&link).await.map(|c| c.user), Ok(inviter.me().user));
    let (other, _do) = node(config("eve")).await;
    assert_eq!(other.add(&link).await.map(|c| c.user), Err(peer::Error::Used));
    other.close().await;

    // The helper relayed QUIC between them and learned nothing above it: no card, no record.
    let ana = stranger.me();
    if kind == MeetingKind::Friend {
        assert!(h.contacts().iter().all(|c| c.user != ana.user), "the helper holds no card for the redeemer");
        assert!(h.records().iter().all(|r| r.device != ana.this_device), "nor a record");
    }
    stranger.close().await;
}

#[tokio::test]
async fn two_nodes_meet_through_the_inviters_own_device() {
    let _serial = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let (mac, _dm) = helper("bob").await;
    let (dp, kp) = (tempfile::tempdir().unwrap(), Arc::new(MemoryKeychain::default()));
    let phone = Peer::open(dp.path().to_path_buf(), kp.clone(), config("throwaway")).await.unwrap();
    phone.set_online(true);
    phone.link(&mac.link_device().unwrap(), "phone").await.unwrap();
    assert_eq!(phone.invite_meeting().kind, MeetingKind::Own);
    meet_through(&phone, &mac, MeetingKind::Own).await;

    // Reopened on its store (records first, the endpoint after), it homes on its Mac again.
    phone.close().await;
    let phone = Peer::open(dp.path().to_path_buf(), kp, config("throwaway")).await.unwrap();
    phone.set_online(true);
    within("the reopened phone homes on its Mac", Duration::from_secs(5), || homed_on(&phone, &mac)).await;
    phone.close().await;
    mac.close().await;
}

#[tokio::test]
async fn two_nodes_meet_through_a_friends_device() {
    let _serial = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let (sam, _ds) = helper("sam").await;
    let (bob, _db) = node(config("bob")).await;
    assert_eq!(bob.invite_meeting().kind, MeetingKind::None, "no helper yet: raw addresses");
    // Sam's own invite names sam himself (he runs the relay); bob redeems it through sam's relay.
    assert_eq!(sam.invite_meeting().kind, MeetingKind::Own);
    bob.add(&sam.invite().unwrap()).await.unwrap();
    within("bob holds sam's record", Duration::from_secs(5), || bob.invite_meeting().kind == MeetingKind::Friend).await;
    meet_through(&bob, &sam, MeetingKind::Friend).await;
    bob.close().await;
    sam.close().await;
}

/// A relay on a port nobody outside can reach is not offered: no confirmed mapping (here no
/// mapping at all), not public. The node is not its own meeting device until one exists.
#[tokio::test]
async fn a_relay_without_a_reachable_port_is_not_offered() {
    let _serial = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let mut c = config("mac");
    c.relay = true; // no port: the endpoint's own; portmap off in tests, and not public
    let (mac, _d) = node(c).await;
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(!mac.helping().relaying);
    assert_eq!(mac.invite_meeting().kind, MeetingKind::None);
    assert!(!mac.reachability().tcp);
    mac.close().await;
}


/// A relay that will not carry us is a no now, not a dial's whole timeout: a stranger dialing a
/// friend of the helper's through the helper's relay alone hears `NotInTheirBook` in moments.
#[tokio::test]
async fn a_relay_that_refuses_is_a_no_at_once() {
    let _serial = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let (h, _dh) = helper("hal").await;
    let (ana, _da) = node(config("ana")).await;
    let (eve, _de) = node(config("eve")).await;
    ana.add(&h.invite().unwrap()).await.unwrap();
    within("ana homed on hal's relay", Duration::from_secs(15), || homed_on(&ana, &h)).await;
    // Ana through hal's relay, and nothing else: eve is in neither book.
    let mut addr = iroh::EndpointAddr::new(ana.me().this_device.into());
    for u in ana.transport().addr().relay_urls() {
        addr = addr.with_relay_url(u.clone());
    }
    let t = Instant::now();
    let r = eve.transport().connect_proven(addr).await;
    assert!(matches!(r, Err(peer::Error::NotInTheirBook)), "{:?}", r.err());
    assert!(t.elapsed() < Duration::from_secs(6), "refused in {:?}", t.elapsed());
    for p in [h, ana, eve] {
        p.close().await;
    }
}

/// Met through a friend's relay, a device may have no direct path to anyone, so nobody can tell
/// it its public address and no punch can replace the relay. The relay's host tells it, on the
/// Bind-only ALPN, while its meet token's link lasts: its own address and nothing else. A
/// stranger the relay never admitted is refused.
#[tokio::test]
async fn the_relay_host_tells_whom_it_admits_their_address() {
    let _serial = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let (h, _dh) = helper("hal").await;
    let (ana, _da) = node(config("ana")).await;
    let (bo, _db) = node(config("bo")).await;
    let (eve, _de) = node(config("eve")).await;
    ana.add(&h.invite().unwrap()).await.unwrap();
    within("ana homed on hal's relay", Duration::from_secs(15), || homed_on(&ana, &h)).await;
    // Bo redeems ana's link through hal's relay, on ana's token: hal holds no card of his.
    bo.add(&ana.invite().unwrap()).await.unwrap();
    let port = h.transport().port().unwrap();
    let hal_at = iroh::EndpointAddr::new(h.me().this_device.into()).with_ip_addr(([127, 0, 0, 1], port).into());
    let conn = bo.transport().bind_conn(hal_at.clone()).await.expect("a direct path to hal");
    let seen = peer::probe::bind(&conn).await.unwrap().expect("seen on a direct path");
    assert_eq!(seen.port(), bo.transport().port().unwrap(), "bo's own address");
    // The ALPN answers Bind alone: nothing reaches hal's node.
    assert!(matches!(peer::transport::ask(&conn, &peer::transport::Msg::Check { udp: None, tcp: None }).await, Ok(peer::transport::Msg::No { .. })));
    // Eve, whom the relay never admitted, is turned away after the handshake.
    if let Some(c) = eve.transport().bind_conn(hal_at).await {
        assert!(peer::probe::bind(&c).await.is_err(), "eve is refused");
    }
    for p in [h, ana, bo, eve] {
        p.close().await;
    }
}

/// A meet token lets its holder reach, through the helper's relay, the person who issued it and
/// the helper itself (its Bind), and nobody else there: a dial to another of the helper's
/// friends, online on that relay, meets the same silence as a dial to a device that is not
/// there. A link's redeemer cannot use the relay to find who else is on it.
#[tokio::test]
async fn a_meet_token_reaches_its_issuer_and_nobody_else() {
    let _serial = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let (h, _dh) = helper("hal").await;
    let (ana, _da) = node(config("ana")).await;
    let (cy, _dc) = node(config("cy")).await;
    let (bo, _db) = node(config("bo")).await;
    for p in [&ana, &cy] {
        p.add(&h.invite().unwrap()).await.unwrap();
        within("homed on hal's relay", Duration::from_secs(15), || homed_on(p, &h)).await;
    }
    let link = ana.invite().unwrap();
    bo.add(&link).await.expect("bo reaches ana, whose token it is");
    // The link's relay URLs, token and all, toward another device.
    let through = |id: iroh::EndpointId| link.meet.addrs.iter().filter_map(|a| a.strip_prefix("relay=")).filter_map(|u| u.parse::<iroh::RelayUrl>().ok()).fold(iroh::EndpointAddr::new(id), |a, u| a.with_relay_url(u));
    assert!(bo.transport().bind_conn(through(h.me().this_device.into())).await.is_some(), "hal answers bo's Bind through its relay");
    let limit = Duration::from_secs(3);
    let to_cy = bo.transport().connect_within(through(cy.me().this_device.into()), peer::transport::ALPN, limit).await;
    assert!(matches!(to_cy, Err(peer::Error::Unreachable)), "cy, online on hal's relay, must look absent: {:?}", to_cy.map(|_| ()));
    let nobody = peer::identity::Secret::generate().device_id();
    let to_nobody = bo.transport().connect_within(through(nobody.into()), peer::transport::ALPN, limit).await;
    assert!(matches!(to_nobody, Err(peer::Error::Unreachable)), "the same as nobody");
    for p in [h, ana, cy, bo] {
        p.close().await;
    }
}

/// A phone whose meeting device is its own Mac hands the Mac the invite and the link names the
/// Mac: redeemed while the phone is closed (asleep, as iOS keeps it), the friend is made all the
/// same, and the phone has them once it is back, through its book.
#[tokio::test(flavor = "multi_thread")]
async fn a_link_is_answered_while_the_inviters_phone_sleeps() {
    let _serial = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let (mac, _dm) = helper("bob").await;
    let (dp, kp) = (tempfile::tempdir().unwrap(), Arc::new(MemoryKeychain::default()));
    let phone = Peer::open(dp.path().to_path_buf(), kp.clone(), config("throwaway")).await.unwrap();
    phone.set_online(true);
    phone.link(&mac.link_device().unwrap(), "phone").await.unwrap();
    within("the phone homes on its Mac", Duration::from_secs(5), || homed_on(&phone, &mac)).await;
    let link = phone.invite().unwrap();
    assert_eq!(link.meet.device, mac.me().this_device, "the link names the Mac, which holds the invite");
    phone.close().await;

    let (ana, _da) = node(config("ana")).await;
    let contact = ana.add(&link).await.expect("the Mac answers for the sleeping phone");
    assert_eq!(contact.user, mac.me().user);
    let phone = Peer::open(dp.path().to_path_buf(), kp, config("throwaway")).await.unwrap();
    phone.set_online(true);
    within("the phone, back, has ana", Duration::from_secs(10), || phone.contacts().iter().any(|c| c.name == "ana")).await;
    for p in [phone, mac, ana] {
        p.close().await;
    }
}
