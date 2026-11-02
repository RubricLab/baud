//! Replies through the surface Swift calls: `reply(link:)` returns the text the app sends back,
//! in the link scheme's form; `parseLink` calls it a "reply"; `add(link:)` takes it on the other
//! side; `.replied` arrives on the side that made it.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use peer_uniffi::{Config, Keychain, Listener, Peer, PeerError, PeerEvent, parse_link};

#[derive(Default)]
struct Keys(Mutex<HashMap<String, Vec<u8>>>);
impl Keychain for Keys {
    fn get(&self, item: String) -> Result<Option<Vec<u8>>, PeerError> {
        Ok(self.0.lock().unwrap().get(&item).cloned())
    }
    fn put(&self, item: String, bytes: Vec<u8>) -> Result<(), PeerError> {
        self.0.lock().unwrap().insert(item, bytes);
        Ok(())
    }
    fn delete(&self, item: String) -> Result<(), PeerError> {
        self.0.lock().unwrap().remove(&item);
        Ok(())
    }
}

/// Who each `.replied` named.
#[derive(Default)]
struct Replied(Mutex<Vec<String>>);
impl Listener for Replied {
    fn on(&self, event: PeerEvent) {
        if let PeerEvent::Replied { user } = event {
            self.0.lock().unwrap().push(user);
        }
    }
}

fn config(name: &str) -> Config {
    Config {
        app: "reply".into(),
        name: name.into(),
        device_name: format!("{name}-dev"),
        link_scheme: "swift://add".into(),
        nearby: false,
        alpns: Vec::new(),
        device_kind: String::new(),
        vpn: true,
        portmap: false, // tests never map a port on the developer's router
        relay: false,
        public: false,
        port: None,
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn a_reply_through_the_swift_surface() {
    let (da, db) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let ana = Peer::open(da.path().to_string_lossy().into_owned(), Arc::new(Keys::default()), config("ana")).await.unwrap();
    let bo = Peer::open(db.path().to_string_lossy().into_owned(), Arc::new(Keys::default()), config("bo")).await.unwrap();
    let replied = Arc::new(Replied::default());
    bo.subscribe(replied.clone());
    ana.set_online(true);
    bo.set_online(true);

    let link = ana.invite().unwrap();
    let reply = bo.reply(link.clone()).unwrap();
    assert!(reply.starts_with("swift://add#"), "{reply}");
    let parsed = parse_link(reply.clone()).unwrap();
    assert_eq!((parsed.kind.as_str(), parsed.user.as_str(), parsed.name.as_str()), ("reply", bo.me().user.as_str(), "bo"));
    assert!(matches!(bo.reply(reply.clone()), Err(_)), "a reply is not something to reply to");

    let contact = ana.add(reply).await.unwrap();
    assert_eq!(contact.user, bo.me().user);
    let t = Instant::now();
    while !replied.0.lock().unwrap().contains(&ana.me().user) {
        assert!(t.elapsed() < Duration::from_secs(5), "bo hears .replied");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    ana.close().await;
    bo.close().await;
}
