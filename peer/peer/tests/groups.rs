//! Relay-only records, revoke, groups.

use std::sync::Arc;
use std::time::Duration;

use peer::identity::{GroupId, MemoryKeychain};
use peer::{Config, Peer};

fn config(name: &str) -> Config {
    let mut c = Config::new("groups", name, &format!("{name}-dev"));
    c.nearby = false;
    c.portmap = false; // tests never map a port on the developer's router
    c.auto_confirm_links = true;
    c
}

async fn node(name: &str) -> (Peer, tempfile::TempDir) {
    let d = tempfile::tempdir().unwrap();
    let p = Peer::open(d.path().to_path_buf(), Arc::new(MemoryKeychain::default()), config(name)).await.unwrap();
    p.set_online(true);
    (p, d)
}

fn online(p: &Peer, name: &str) -> bool {
    p.contacts().iter().find(|c| c.name == name).is_some_and(|c| c.devices.iter().any(|d| d.online))
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

#[tokio::test]
async fn relay_only_hides_addresses_and_revoke_drops_a_device() {
    let (ana, _a) = node("ana").await;
    let (sam, _s) = node("sam").await;
    sam.add(&ana.invite().unwrap()).await.unwrap();
    until("online", || sam.contacts()[0].devices.iter().any(|d| d.online)).await;
    // Ana marks sam relay-only: ana's next record to sam carries no direct addresses.
    let ana_dev = ana.me().this_device;
    let before = sam.record_addr(ana_dev).unwrap();
    assert!(before.ip_addrs().count() > 0);
    ana.set_relay_only(sam.me().user, true).unwrap();
    ana.set_tags(vec!["x".into()]).unwrap(); // re-signs and pushes
    until("sam holds ana's stripped record", || sam.record_addr(ana_dev).is_some_and(|a| a.ip_addrs().count() == 0)).await;

    // Revoke: ana links a third device, then revokes it from her first.
    let (mac, _m) = node("throwaway").await;
    mac.link(&ana.link_device().unwrap(), "ana-mac").await.unwrap();
    let mac_dev = mac.me().this_device;
    until("sam sees two devices", || sam.contacts()[0].card.as_ref().unwrap().body.devices.len() == 2).await;
    ana.revoke(mac_dev).unwrap();
    assert_eq!(ana.me().devices.iter().filter(|d| d.id == mac_dev).count(), 0, "revoked devices leave me()");
    until("sam's copy of the card revokes the mac", || sam.contacts()[0].card.as_ref().unwrap().is_revoked(&mac_dev, u64::MAX)).await;
    until("sam drops the mac from the contact", || sam.contacts()[0].devices.iter().all(|d| d.device != mac_dev)).await;
    assert!(ana.revoke(ana.me().this_device).is_err(), "not the device you are on");
    ana.close().await;
    sam.close().await;
    mac.close().await;
}

#[tokio::test]
async fn group_members_are_admitted_without_being_contacts() {
    let (ana, _a) = node("ana").await;
    let (jo, _j) = node("jo").await;
    // Ana learned jo's card from a group's membership event (here: out of band), never by invite.
    let jo_card = jo.card();
    let ana_card = ana.card();
    let group = GroupId([7; 32]);
    ana.add_member(group, jo_card).unwrap();
    jo.add_member(group, ana_card).unwrap();
    assert!(ana.contacts().is_empty() && jo.contacts().is_empty(), "members are not contacts");
    assert_eq!(ana.members(group).len(), 1);
    // Neither holds a record yet; a seeded dial proves admission: jo lets ana in because of the card.
    let port = jo.addr().ip_addrs().next().unwrap().port();
    let addr = iroh::EndpointAddr::new(jo.me().this_device.into()).with_ip_addr(([127, 0, 0, 1], port).into());
    ana.connect_raw(addr).await.unwrap();
    until("records exchanged on connect", || jo.records().iter().any(|r| r.device == ana.me().this_device)).await;
    assert!(ana.peers().iter().any(|p| p.device == jo.me().this_device && p.online));
    // The identity on accept names the group that admitted ana.
    assert_eq!(jo.identity_of_device(ana.me().this_device).groups, vec![group]);
    // Leaving the group forgets the card and closes the connection.
    jo.remove_member(group, ana.me().user).unwrap();
    assert!(jo.members(group).is_empty());
    until("jo forgets ana", || jo.peers().iter().all(|p| p.device != ana.me().this_device)).await;
    ana.close().await;
    jo.close().await;
}

#[tokio::test]
async fn post_to_an_unseen_member_device_is_held_then_delivered() {
    let (ana, _a) = node("ana").await;
    let (jo, _j) = node("jo").await;
    let group = GroupId([8; 32]);
    ana.add_member(group, jo.card()).unwrap();
    jo.add_member(group, ana.card()).unwrap();
    let jo_dev = jo.me().this_device;
    // No record for jo, never seen: post must still enqueue.
    let id = ana.post(jo_dev, b"for a member I have never met".to_vec(), Duration::from_secs(3600)).await.unwrap();
    assert_eq!(ana.outbox(), vec![id]);
    assert!(ana.helpers_for(jo_dev).is_empty(), "nobody to carry it yet");
    // Jo appears (dials ana from the card's addresses, here loopback): the envelope is handed over.
    let port = ana.addr().ip_addrs().next().unwrap().port();
    let addr = iroh::EndpointAddr::new(ana.me().this_device.into()).with_ip_addr(([127, 0, 0, 1], port).into());
    jo.connect_raw(addr).await.unwrap();
    until("delivered to jo", || jo.inbox().iter().any(|e| e.id == id)).await;
    assert_eq!(jo.inbox()[0].from, Some(ana.me().this_device));
    until("ana learns delivered", || ana.outbox().is_empty()).await;
    ana.close().await;
    jo.close().await;
}

#[tokio::test]
async fn co_members_learn_each_other_through_the_group() {
    let (ana, _a) = node("ana").await;
    let (bo, _b) = node("bo").await;
    let (cy, _c) = node("cy").await;
    bo.add(&ana.invite().unwrap()).await.unwrap();
    cy.add(&ana.invite().unwrap()).await.unwrap();
    until("ana online with both", || online(&ana, "bo") && online(&ana, "cy")).await;
    let group = GroupId([9; 32]);
    // Ana adds both; bo and cy only know ana is in the group (from the app's membership event).
    ana.add_member(group, bo.card()).unwrap();
    ana.add_member(group, cy.card()).unwrap();
    bo.add_member(group, ana.card()).unwrap();
    cy.add_member(group, ana.card()).unwrap();
    until("bo holds cy's card via the group", || bo.card_of(cy.me().user).is_some()).await;
    until("cy holds bo's card via the group", || cy.card_of(bo.me().user).is_some()).await;
    assert_eq!(bo.members(group).len(), 2);
    assert!(bo.contacts().iter().all(|c| c.name != "cy"), "a co-member is not a contact");
    // Identity names the group even for a contact (ana is bo's contact and co-member).
    assert_eq!(bo.identity_of_device(ana.me().this_device).groups, vec![group]);
    // Removing ana as a contact keeps her card and admission: she is still a co-member.
    bo.remove(ana.me().user).unwrap();
    assert!(bo.card_of(ana.me().user).is_some());
    assert_eq!(bo.members(group).len(), 2);
    for p in [&ana, &bo, &cy] {
        p.close().await;
    }
}

/// The maker's list reaches a member before that member keeps the group, and is refused; nobody
/// sends it again. The member keeping the group and adding the maker gets the maker's whole list
/// back, so the two members still learn each other.
#[tokio::test]
async fn a_member_who_keeps_the_group_late_still_learns_the_others() {
    let (ana, _a) = node("ana").await;
    let (bo, _b) = node("bo").await;
    let (cy, _c) = node("cy").await;
    bo.add(&ana.invite().unwrap()).await.unwrap();
    cy.add(&ana.invite().unwrap()).await.unwrap();
    until("ana online with both", || online(&ana, "bo") && online(&ana, "cy")).await;
    let group = GroupId([7; 32]);
    ana.create_group(group, peer::GroupKind::Space).unwrap();
    ana.add_member(group, bo.card()).unwrap();
    ana.add_member(group, cy.card()).unwrap();
    // Ana's lists have gone out and been refused: neither had the group yet.
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    for p in [&bo, &cy] {
        p.create_group(group, peer::GroupKind::Space).unwrap();
        p.add_member(group, ana.card()).unwrap();
    }
    until("bo holds cy's card via the group", || bo.card_of(cy.me().user).is_some()).await;
    until("cy holds bo's card via the group", || cy.card_of(bo.me().user).is_some()).await;
    for p in [&ana, &bo, &cy] {
        p.close().await;
    }
}
