//! Waking a sleeping iPhone (`Wake.swift`). An iPhone seals its push addresses to the wake
//! relay's key and hands each device it connects to a ticket. When a message for that iPhone
//! can't go live and goes to carriers, the device holding its ticket hands the ticket to the
//! relay, which asks Apple to wake the phone and keeps nothing; the phone comes online and takes
//! what's waiting, peer to peer. This side only keeps tickets and spends them: an Android phone
//! keeps its own service running and has no push address to give.

use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

use base64::Engine;
use base64::engine::general_purpose::STANDARD;

use crate::core::{Core, short};
use crate::store::now;

/// What a wake is for: a message (an alert) or a call (VoIP, rings at once; with Android calls).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WakeKind {
    Message,
    Call,
}

impl WakeKind {
    fn as_str(self) -> &'static str {
        match self {
            WakeKind::Message => "message",
            WakeKind::Call => "call",
        }
    }
    /// The relay folds and limits too; this only spares it the asking.
    fn gap(self) -> Duration {
        match self {
            WakeKind::Message => Duration::from_secs(20),
            WakeKind::Call => Duration::from_secs(10),
        }
    }
}

pub const RELAY: &str = "https://wake.baud.rubric.sh";
/// A ticket is a few dozen bytes plus two tokens; anything near this is not one.
const MAX_TICKET: usize = 512;

/// HTTPS with ring and Mozilla's roots, built once.
fn client() -> &'static reqwest::Client {
    static C: OnceLock<reqwest::Client> = OnceLock::new();
    C.get_or_init(|| {
        let mut roots = rustls::RootCertStore::empty();
        roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
        let tls = rustls::ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
            .with_safe_default_protocol_versions()
            .map(|b| b.with_root_certificates(roots).with_no_client_auth());
        let b = reqwest::Client::builder().timeout(Duration::from_secs(10));
        match tls {
            Ok(t) => b.tls_backend_preconfigured(t),
            Err(_) => b,
        }
        .build()
        .unwrap_or_default()
    })
}

impl Core {
    fn relay_url(&self) -> String {
        self.config.wake_url.clone().or_else(|| std::env::var("BAUD_WAKE_URL").ok()).unwrap_or_else(|| RELAY.into())
    }

    /// A ticket from a device I know, to wake it when it's asleep; a newer one replaces it.
    pub(crate) fn keep_wake(&self, ticket: &[u8], expires: f64, from: &str) {
        let known = self.store.int("select count(*) as n from devices where id=?", &[&from]) > 0;
        if !known || expires <= now() || ticket.is_empty() || ticket.len() >= MAX_TICKET {
            self.log(format!("wake ticket from {} refused", short(from)));
            return;
        }
        self.store.run("insert or replace into me(k,v) values(?,?)", &[&format!("wake:{from}"), &format!("{} {}", STANDARD.encode(ticket), crate::json::swift_double(expires))]);
        self.log(format!("wake ticket from {} kept, good until {}", short(from), expires as i64));
    }

    /// The ticket I hold for that device, unless it has expired.
    pub(crate) fn wake_ticket(&self, d: &str) -> Option<Vec<u8>> {
        let v = self.store.one("select v from me where k=?", &[&format!("wake:{d}")])?.string("v")?;
        let (t, exp) = v.split_once(' ')?;
        (exp.parse::<f64>().ok()? > now()).then(|| STANDARD.decode(t).ok()).flatten()
    }

    /// Whether I could wake that device.
    pub fn can_wake(&self, d: &str) -> bool {
        self.wake_ticket(d).is_some()
    }

    /// Ask the relay to wake that device, if I hold a ticket for it: true once Apple has it. At
    /// most one message wake every 20 s per device, one ring every 10 s. A 410 means the ticket
    /// has expired or the phone is gone: forget it and wait for a fresh one.
    pub async fn wake(&self, d: &str, kind: WakeKind) -> bool {
        let Some(ticket) = self.wake_ticket(d) else { return false };
        {
            let mut st = self.st();
            let key = format!("{d}{}", kind.as_str());
            if st.last_wake.get(&key).map(|t| t.elapsed() < kind.gap()).unwrap_or(false) {
                return false;
            }
            st.last_wake.insert(key, Instant::now());
        }
        let body = crate::json::encode(&serde_json::json!({ "ticket": STANDARD.encode(&ticket), "kind": kind.as_str() }));
        let url = format!("{}/v1/wake", self.relay_url().trim_end_matches('/'));
        let code = match client().post(&url).header("content-type", "application/json").body(body).send().await {
            Ok(r) => r.status().as_u16(),
            Err(e) => {
                self.log(format!("wake {} for {}: {e}", kind.as_str(), short(d)));
                0
            }
        };
        if code == 410 {
            self.store.run("delete from me where k=?", &[&format!("wake:{d}")]);
        }
        self.log(format!("wake {} for {}: {code}", kind.as_str(), short(d)));
        code == 202
    }
}

/// GET through the wake client, for checking the relay is reachable over TLS from here (a
/// phone included): `/health` answers 200.
#[doc(hidden)]
pub async fn relay_get(url: &str) -> Option<u16> {
    client().get(url).send().await.ok().map(|r| r.status().as_u16())
}
