//! Identity redirect: bob started on a phone of his own (one user key) and on a Mac as carl
//! (another); linking the phone into carl merges them. Bob's friends (ana online, dan away)
//! get the old key's signed redirect, keep one contact named as before under the new key, and
//! reach the phone under it; carl's own friend eve, never bob's, learns nothing.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use peer::identity::MemoryKeychain;
use peer::{Config, Event, Listener, Peer};

#[derive(Default)]
struct Log(Mutex<Vec<Event>>);
impl Listener for Log {
    fn on(&self, e: Event) {
        self.0.lock().unwrap().push(e);
    }
}

fn config(name: &str) -> Config {
    let mut c = Config::new("redirect", name, &format!("{name}-dev"));
    c.nearby = false;
    c.portmap = false; // tests never map a port on the developer's router
    c.auto_confirm_links = true;
    c
}

async fn until(what: &str, secs: u64, mut f: impl FnMut() -> bool) {
    for _ in 0..secs * 40 {
        if f() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    panic!("timed out waiting for {what}");
}

#[tokio::test]
async fn linking_a_device_with_a_person_into_another_merges_them() {
    let open = |name: &'static str, dir: std::path::PathBuf, keys: Arc<MemoryKeychain>| async move {
        let p = Peer::open(dir, keys, config(name)).await.unwrap();
        p.set_online(true);
        p
    };
    let dirs: Vec<tempfile::TempDir> = (0..5).map(|_| tempfile::tempdir().unwrap()).collect();
    let keys: Vec<Arc<MemoryKeychain>> = (0..5).map(|_| Arc::new(MemoryKeychain::default())).collect();
    let ana = open("ana", dirs[0].path().into(), keys[0].clone()).await;
    let bob = open("bob", dirs[1].path().into(), keys[1].clone()).await;
    let carl = open("carl", dirs[2].path().into(), keys[2].clone()).await;
    let dan = open("dan", dirs[3].path().into(), keys[3].clone()).await;
    let eve = open("eve", dirs[4].path().into(), keys[4].clone()).await;
    let log = Arc::new(Log::default());
    ana.subscribe(log.clone());

    bob.add(&ana.invite().unwrap()).await.unwrap();
    dan.add(&bob.invite().unwrap()).await.unwrap();
    eve.add(&carl.invite().unwrap()).await.unwrap();
    let (old_bob, phone, carl_user) = (bob.me().user, bob.me().this_device, carl.me().user);
    until("ana and bob connected", 5, || ana.peers().iter().any(|p| p.device == phone && p.online)).await;
    dan.close().await; // away while bob links

    // Bob's phone joins carl: the old key signs the redirect on its way out.
    bob.link(&carl.link_device().unwrap(), "bob's phone").await.unwrap();
    assert_eq!(bob.me().user, carl_user);
    assert_eq!(bob.redirects().len(), 1, "issued");

    // Ana: one contact, named as before, under the new key; vouched by the old key, not verified.
    until("ana follows the redirect", 2, || ana.contacts().iter().any(|c| c.user == carl_user)).await;
    let contacts = ana.contacts();
    assert_eq!(contacts.len(), 1, "one contact, not two");
    let c = &contacts[0];
    assert_eq!((c.name.as_str(), c.redirected_from, c.verified), ("bob", Some(old_bob), false));
    assert!(log.0.lock().unwrap().iter().any(|e| matches!(e, Event::ContactRedirected { from, to } if *from == old_bob && *to == carl_user)));
    assert_eq!(ana.redirects().len(), 1);

    // A message from ana reaches bob's phone under carl.
    let id = ana.post(phone, b"still me?".to_vec(), Duration::from_secs(60)).await.unwrap();
    until("the phone gets ana's message", 2, || bob.inbox().iter().any(|e| e.id == id)).await;
    // Carl's Mac took bob's book: ana is carl's contact too.
    until("carl holds ana", 5, || carl.contacts().iter().any(|c| c.user == ana.me().user)).await;

    // Dan was away: on his way back he meets the phone, which tells him then.
    let dan = open("dan", dirs[3].path().into(), keys[3].clone()).await;
    until("dan follows the redirect", 5, || dan.contacts().iter().any(|c| c.user == carl_user && c.name == "bob")).await;
    assert_eq!(dan.contacts().len(), 1);

    // Eve was never bob's: nothing reached her.
    assert!(eve.redirects().is_empty(), "the redirect goes only to the old key's contacts");
    for p in [ana, bob, carl, dan, eve] {
        p.close().await;
    }
}
