//! Every device is a helper for everyone whose card it holds, in three jobs: cache (freshest
//! records), carrier (envelopes, 14 days, 200 MB, three hops), relay (an embedded iroh relay on a
//! reachable device, admitting only cardholders). Budgets are enforced here.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::net::{SocketAddr, UdpSocket};
use std::sync::{Arc, RwLock};

use iroh::{EndpointId, RelayUrl};
use serde::{Deserialize, Serialize};

use crate::identity::{DeviceId, Secret, UserId};
use crate::{Error, Result};
use crate::sync::Shared;

pub const ENVELOPE_TTL_MS: u64 = 14 * 24 * 3600 * 1000;
/// Clocks differ between devices: an envelope posted with the longest TTL on a clock a little
/// ahead of mine must still be carried. Only the upper bound gets the slack.
pub const CLOCK_SLACK_MS: u64 = 10 * 60 * 1000;
pub const CARRIER_BUDGET_BYTES: u64 = 200 * 1024 * 1024;
pub const MAX_HOPS: u8 = 3;
/// Relay bytes per friend per day; own devices are unlimited.
pub const RELAY_BUDGET_PER_DAY: u64 = 1024 * 1024 * 1024;

/// A sealed payload in transit. Says who it is for and nothing else.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Envelope {
    /// blake3 of `to || expires || ciphertext`; carriers dedupe and ack by it.
    pub id: [u8; 32],
    pub to: DeviceId,
    pub expires: u64,
    pub hops: u8,
    pub ciphertext: Vec<u8>,
}

/// Sealed box to a device key: ephemeral X25519 against the device's Ed25519 key on the
/// Montgomery curve, HKDF-SHA256 to a one-time ChaCha20-Poly1305 key, `{to, expires}` as
/// associated data. Carriers and relays see `{to, size, expires}` and nothing else, whatever
/// the app put in `bytes`. Layout: 32 bytes ephemeral public key, then the ciphertext.
pub fn seal(to: &DeviceId, expires: u64, plaintext: &[u8]) -> Result<Vec<u8>> {
    use chacha20poly1305::aead::{Aead, KeyInit, Payload};
    let recipient = x25519_dalek::PublicKey::from(to.to_x25519()?);
    let eph = x25519_dalek::StaticSecret::from(rand::random::<[u8; 32]>());
    let eph_pub = x25519_dalek::PublicKey::from(&eph);
    let key = envelope_key(eph.diffie_hellman(&recipient).as_bytes(), eph_pub.as_bytes(), &to.0);
    let cipher = chacha20poly1305::ChaCha20Poly1305::new((&key).into());
    let aad = aad(to, expires);
    let ct = cipher.encrypt((&[0u8; 12]).into(), Payload { msg: plaintext, aad: &aad }).map_err(|_| Error::Encoding)?;
    let mut out = eph_pub.as_bytes().to_vec();
    out.extend(ct);
    Ok(out)
}

/// Open an envelope sealed to this device. Anything not sealed to it, or tampered with, fails.
pub fn open(device: &Secret, env: &Envelope) -> Result<Vec<u8>> {
    use chacha20poly1305::aead::{Aead, KeyInit, Payload};
    if env.to != device.device_id() || env.ciphertext.len() < 32 {
        return Err(Error::BadKey);
    }
    let eph_pub = x25519_dalek::PublicKey::from(<[u8; 32]>::try_from(&env.ciphertext[..32]).unwrap());
    let me = x25519_dalek::StaticSecret::from(device.to_x25519());
    let key = envelope_key(me.diffie_hellman(&eph_pub).as_bytes(), eph_pub.as_bytes(), &env.to.0);
    let cipher = chacha20poly1305::ChaCha20Poly1305::new((&key).into());
    let aad = aad(&env.to, env.expires);
    cipher.decrypt((&[0u8; 12]).into(), Payload { msg: &env.ciphertext[32..], aad: &aad }).map_err(|_| Error::BadSignature)
}

fn envelope_key(shared: &[u8; 32], eph_pub: &[u8; 32], to: &[u8; 32]) -> [u8; 32] {
    let hk = hkdf::Hkdf::<sha2::Sha256>::new(Some(b"peer envelope v1"), shared);
    let mut info = eph_pub.to_vec();
    info.extend_from_slice(to);
    let mut key = [0u8; 32];
    hk.expand(&info, &mut key).expect("32 bytes is a valid length");
    key
}

fn aad(to: &DeviceId, expires: u64) -> Vec<u8> {
    let mut v = to.0.to_vec();
    v.extend_from_slice(&expires.to_le_bytes());
    v
}

impl Envelope {
    pub fn new(to: DeviceId, expires: u64, ciphertext: Vec<u8>) -> Self {
        let id = *blake3::Hasher::new().update(&to.0).update(&expires.to_le_bytes()).update(&ciphertext).finalize().as_bytes();
        Envelope { id, to, expires, hops: 0, ciphertext }
    }
    pub fn size(&self) -> u64 {
        self.ciphertext.len() as u64
    }
}

/// What this device holds for others, within budget.
#[derive(Debug, Default)]
pub struct Carrier {
    held: BTreeMap<[u8; 32], Envelope>,
    bytes: u64,
}

impl Carrier {
    /// Hold it if it is fresh, within hops, not already held, and within the budget.
    pub fn hold(&mut self, mut env: Envelope, now: u64) -> Result<bool> {
        if env.expires <= now || env.expires > now + ENVELOPE_TTL_MS + CLOCK_SLACK_MS {
            return Err(Error::Expired);
        }
        if env.hops >= MAX_HOPS {
            return Err(Error::Budget);
        }
        if self.held.contains_key(&env.id) {
            return Ok(false);
        }
        if self.bytes + env.size() > CARRIER_BUDGET_BYTES {
            return Err(Error::Budget);
        }
        env.hops += 1;
        self.bytes += env.size();
        self.held.insert(env.id, env);
        Ok(true)
    }

    pub fn ack(&mut self, id: &[u8; 32]) -> bool {
        match self.held.remove(id) {
            Some(e) => {
                self.bytes -= e.size();
                true
            }
            None => false,
        }
    }

    pub fn expire(&mut self, now: u64) -> usize {
        let dead: Vec<[u8; 32]> = self.held.values().filter(|e| e.expires <= now).map(|e| e.id).collect();
        for id in &dead {
            self.ack(id);
        }
        dead.len()
    }

    pub fn for_device(&self, to: &DeviceId) -> Vec<&Envelope> {
        self.held.values().filter(|e| e.to == *to).collect()
    }

    pub fn all(&self) -> Vec<&Envelope> {
        self.held.values().collect()
    }

    pub fn holds(&self, id: &[u8; 32]) -> bool {
        self.held.contains_key(id)
    }

    pub fn count(&self) -> usize {
        self.held.len()
    }
    pub fn bytes(&self) -> u64 {
        self.bytes
    }
}

/// This node's relay job, when it has one.
pub struct RelayRole {
    /// The public URL first, then one per LAN interface: a home router rarely hairpins, so a
    /// device on the same LAN reaches the relay by its private address.
    pub urls: Vec<RelayUrl>,
    /// How the port became reachable: a mapping the gateway granted, or the person said so.
    pub mapped: Option<SocketAddr>,
}

/// What the UI shows under *helping*.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Helping {
    pub envelopes: u32,
    pub bytes: u64,
    pub budget_bytes: u64,
    pub records_cached: u32,
    pub relaying: bool,
    pub relay_url: Option<String>,
}

/// The relay's door: devices in cards this node holds (shares the transport's allow-list), and a
/// stranger who presents a cardholder's meet token (`link::meet_token`, in the relay URL of an
/// invite naming this node as the meeting device) until the invite expires. Either way the relay
/// carries QUIC already encrypted to both ends: it sees ciphertext and sizes.
#[derive(Clone)]
pub struct CardholdersOnly {
    pub allow: Arc<RwLock<HashSet<EndpointId>>>,
    /// The person each cardholder device belongs to.
    pub people: Arc<RwLock<HashMap<EndpointId, UserId>>>,
    /// Who came in on a meet token, on whose, and until when.
    pub met: Met,
    /// This node: a token names the helper it is for.
    pub me: DeviceId,
    pub trace: Arc<crate::trace::Trace>,
}

/// Strangers a relay admitted on a meet token: whose token (the inviting device), until its link
/// expires. Through the relay they reach only this host and the inviter's person; besides it they
/// may ask this host one thing, on `transport::BIND_ALPN`: what address it sees them at.
#[derive(Clone, Debug, Default)]
pub struct Met(Arc<RwLock<HashMap<EndpointId, HashMap<DeviceId, u64>>>>);

impl Met {
    fn admit(&self, client: EndpointId, inviter: DeviceId, expires: u64) {
        let mut m = self.0.writing();
        let now = now_secs();
        m.retain(|_, tokens| {
            tokens.retain(|_, e| *e > now);
            !tokens.is_empty()
        });
        let e = m.entry(client).or_default().entry(inviter).or_default();
        *e = (*e).max(expires);
    }

    /// Admitted on a token whose link has not expired.
    pub fn holds(&self, client: &EndpointId) -> bool {
        !self.inviters(client).is_empty()
    }

    /// The devices whose unexpired tokens admitted `client`.
    fn inviters(&self, client: &EndpointId) -> Vec<DeviceId> {
        let now = now_secs();
        self.0.reading().get(client).map(|t| t.iter().filter(|(_, e)| **e > now).map(|(d, _)| *d).collect()).unwrap_or_default()
    }
}

fn now_secs() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

impl std::fmt::Debug for CardholdersOnly {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CardholdersOnly").field("me", &self.me.short()).finish()
    }
}

impl iroh_relay::server::AccessControl for CardholdersOnly {
    async fn on_connect(&self, request: &iroh_relay::server::ClientRequest) -> iroh_relay::server::Access {
        let client = request.endpoint_id();
        if self.allow.reading().contains(&client) {
            return iroh_relay::server::Access::Allow;
        }
        let inviter = crate::link::meet_token_of(request.uri().query()).and_then(|t| crate::link::check_meet_token(t, &self.me, now_secs()));
        match inviter {
            Some((inviter, expires)) if self.allow.reading().contains(&EndpointId::from(inviter)) => {
                self.trace.emit("meet", serde_json::json!({ "inviter": inviter.short(), "client": DeviceId::from(client).short() }));
                self.met.admit(client, inviter, expires);
                iroh_relay::server::Access::Allow
            }
            _ => iroh_relay::server::Access::Deny { reason: Some("not in this node's book".into()) },
        }
    }

    /// A cardholder reaches anyone here, as ever. A stranger in on a meet token reaches this host
    /// and the devices of the person whose token let it in, and nobody else reaches it: it cannot
    /// find who else is on this relay (a datagram to them is dropped as if they were not).
    fn may_relay(&self, src: EndpointId, dst: EndpointId) -> bool {
        self.reaches(src, dst) && self.reaches(dst, src)
    }
}

impl CardholdersOnly {
    fn reaches(&self, from: EndpointId, to: EndpointId) -> bool {
        let me = EndpointId::from(self.me);
        if from == me || to == me || self.allow.reading().contains(&from) {
            return true;
        }
        let people = self.people.reading();
        let Some(person) = people.get(&to) else { return false };
        self.met.inviters(&from).into_iter().any(|i| people.get(&EndpointId::from(i)) == Some(person))
    }
}

/// The interface the default route leaves through. UDP connect sends nothing.
pub fn primary_ip() -> Option<std::net::IpAddr> {
    let s = UdpSocket::bind("0.0.0.0:0").ok()?;
    s.connect("192.0.2.1:9").ok()?; // TEST-NET-1
    s.local_addr().ok().map(|a| a.ip())
}

/// The global IPv6 address the default route leaves from, when this network has IPv6. Nothing is
/// sent: connecting a UDP socket only asks the routing table.
pub fn primary_ip_v6() -> Option<std::net::IpAddr> {
    let s = UdpSocket::bind("[::]:0").ok()?;
    s.connect("[2001:db8::1]:9").ok()?; // documentation prefix
    s.local_addr().ok().map(|a| a.ip()).filter(crate::record::is_global)
}

/// An iroh relay in this process, lifted from darkroom's `relay.rs`: plain HTTP on `port`
/// (the payload is QUIC, already encrypted to both device keys), admitting only cardholders.
/// Runs only on a device whose probe said `reachable`; the URL goes in its record.
pub async fn spawn_relay(port: u16, access: CardholdersOnly) -> Result<iroh_relay::server::Server> {
    use iroh_relay::server::{RelayConfig, Server, ServerConfig};
    let mut relay = RelayConfig::new(SocketAddr::from(([0, 0, 0, 0], port)));
    relay.access = Arc::new(access);
    let mut config = ServerConfig::default();
    config.relay = Some(relay);
    Server::spawn(config).await.map_err(|e| Error::Net(format!("relay on tcp {port}: {e}")))
}

/// The URLs a relay on `port` is offered at: the public address first, then one per LAN address.
pub fn relay_urls(public: Option<SocketAddr>, lan: &[std::net::IpAddr], port: u16) -> Result<Vec<RelayUrl>> {
    let mut addrs: Vec<SocketAddr> = public.into_iter().collect();
    addrs.extend(lan.iter().filter(|ip| !ip.is_loopback()).map(|ip| SocketAddr::new(*ip, port)));
    if addrs.is_empty() {
        addrs.push(SocketAddr::new(primary_ip().unwrap_or(std::net::Ipv4Addr::LOCALHOST.into()), port));
    }
    let mut urls = Vec::new();
    for a in addrs {
        let url: RelayUrl = format!("http://{a}").parse().map_err(|e| Error::Net(format!("relay url: {e}")))?;
        if !urls.contains(&url) {
            urls.push(url);
        }
    }
    Ok(urls)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sealed_to_one_device_only() {
        let (sam, eve) = (Secret::generate(), Secret::generate());
        let ct = seal(&sam.device_id(), 99, b"hello").unwrap();
        assert_ne!(&ct[32..], b"hello");
        let env = Envelope::new(sam.device_id(), 99, ct.clone());
        assert_eq!(open(&sam, &env).unwrap(), b"hello");
        assert!(open(&eve, &env).is_err(), "not for eve");
        let mut wrong_expiry = env.clone();
        wrong_expiry.expires = 100;
        assert!(open(&sam, &wrong_expiry).is_err(), "expiry is bound in");
        let mut tampered = env.clone();
        let last = tampered.ciphertext.len() - 1;
        tampered.ciphertext[last] ^= 1;
        assert!(open(&sam, &tampered).is_err());
        assert_ne!(seal(&sam.device_id(), 99, b"hello").unwrap(), ct, "a fresh ephemeral key every time");
    }

    #[test]
    fn carrier_budget_hops_and_expiry() {
        let now = 1_000_000;
        let mut c = Carrier::default();
        let to = DeviceId([1; 32]);
        let e = Envelope::new(to, now + 1000, vec![1, 2, 3]);
        assert!(c.hold(e.clone(), now).unwrap());
        assert!(!c.hold(e.clone(), now).unwrap(), "same id held once");
        assert_eq!(c.for_device(&to)[0].hops, 1);
        assert_eq!(c.hold(Envelope::new(to, now, vec![]), now), Err(Error::Expired));
        assert_eq!(c.hold(Envelope::new(to, now + ENVELOPE_TTL_MS + CLOCK_SLACK_MS + 1, vec![]), now), Err(Error::Expired));
        assert_eq!(Carrier::default().hold(Envelope::new(to, now + ENVELOPE_TTL_MS + 1000, vec![9]), now), Ok(true), "a sender's clock a second ahead is carried");
        let mut hopped = Envelope::new(to, now + 1, vec![9]);
        hopped.hops = MAX_HOPS;
        assert_eq!(c.hold(hopped, now), Err(Error::Budget));
        let big = Envelope::new(to, now + 1, vec![0; CARRIER_BUDGET_BYTES as usize]);
        assert_eq!(c.hold(big, now), Err(Error::Budget));
        assert_eq!(c.expire(now + 1000), 1);
        assert_eq!((c.count(), c.bytes()), (0, 0));
        assert!(!c.ack(&e.id));
    }
}
