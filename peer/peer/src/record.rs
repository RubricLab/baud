//! A device's address record, signed by its key, and the cache of everyone's. Records travel
//! only to cardholders: pushed on change, exchanged on connect, cached, dialed. Never published.

use std::collections::BTreeMap;
use std::net::IpAddr;

use iroh::{EndpointAddr, RelayUrl, TransportAddr};
use serde::{Deserialize, Serialize};

use crate::identity::{DeviceId, Secret, Sig};
use crate::{Error, Result};

/// Two halves: `udp` is a hole-punch target (the UI's one word "reachable"); `tcp` can relay,
/// and `relay` is advertised only with it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Reachability {
    pub udp: bool,
    pub tcp: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AddressRecord {
    pub device: DeviceId,
    /// Direct addresses (VPN interfaces included) and relay URLs, as iroh dials them.
    pub addresses: Vec<TransportAddr>,
    /// The helper device whose embedded relay this device is homed on: its own, or a friend's.
    pub relay: Option<DeviceId>,
    /// Passed the inbound probe on this network. `Unknown` is advertised as false.
    pub reachable: Reachability,
    /// The app is open or in a background window.
    pub awake: bool,
    /// Free-form capabilities the app advertises: "vlm", "asr", "keeps-originals".
    pub tags: Vec<String>,
    /// Monotonic per device: the newer record wins.
    pub seq: u64,
    pub at: u64,
}

impl AddressRecord {
    pub fn endpoint_addr(&self) -> EndpointAddr {
        EndpointAddr::from_parts(self.device.into(), self.addresses.iter().cloned())
    }

    pub fn relay_urls(&self) -> impl Iterator<Item = &RelayUrl> {
        self.addresses.iter().filter_map(|a| match a {
            TransportAddr::Relay(u) => Some(u),
            _ => None,
        })
    }

    /// The same record with no direct addresses: what a `relay_only` contact receives.
    pub fn relay_only(&self) -> AddressRecord {
        let mut r = self.clone();
        r.addresses.retain(|a| matches!(a, TransportAddr::Relay(_)));
        r
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SignedRecord {
    pub record: AddressRecord,
    pub sig: Sig,
}

impl SignedRecord {
    pub fn sign(record: AddressRecord, device_key: &Secret) -> Self {
        debug_assert_eq!(device_key.device_id(), record.device);
        let bytes = postcard::to_allocvec(&record).expect("record serializes");
        SignedRecord { sig: device_key.sign(&bytes), record }
    }

    pub fn verify(&self) -> Result<()> {
        let bytes = postcard::to_allocvec(&self.record).map_err(|_| Error::Encoding)?;
        self.record.device.verify(&bytes, &self.sig)
    }

    pub fn device(&self) -> DeviceId {
        self.record.device
    }
}

/// Which of the four finders produced a record, plus the invite that started it all.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum FoundBy {
    Cache,
    Push,
    Exchange,
    Nearby,
    Invite,
}

/// A cached record. `sig` is None only for a seeded placeholder from migration: last-known
/// addresses from an old card, replaced by the first signed record that arrives.
impl FoundBy {
    pub fn as_str(self) -> &'static str {
        match self {
            FoundBy::Cache => "cache",
            FoundBy::Push => "push",
            FoundBy::Exchange => "exchange",
            FoundBy::Nearby => "nearby",
            FoundBy::Invite => "invite",
        }
    }
    pub fn parse(s: &str) -> FoundBy {
        match s {
            "push" => FoundBy::Push,
            "exchange" => FoundBy::Exchange,
            "nearby" => FoundBy::Nearby,
            "invite" => FoundBy::Invite,
            _ => FoundBy::Cache,
        }
    }
}

#[derive(Clone, Debug)]
pub struct Cached {
    pub record: AddressRecord,
    pub sig: Option<Sig>,
    pub found_by: FoundBy,
    pub received_at: u64,
}

/// What the UI shows per device: age and finder, never the addresses.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RecordView {
    pub device: DeviceId,
    /// The helper that relays for this device, so the UI can say "relayed by Mini" before a connection exists.
    pub relay: Option<DeviceId>,
    pub reachable: Reachability,
    pub awake: bool,
    pub tags: Vec<String>,
    pub seq: u64,
    pub age_ms: u64,
    pub found_by: FoundBy,
}

/// The freshest record known for each device.
#[derive(Debug, Default)]
pub struct Records {
    by_device: BTreeMap<DeviceId, Cached>,
}

impl Records {
    /// Keep it if it verifies and is newer than what we had. Returns whether it was new.
    pub fn put(&mut self, signed: SignedRecord, found_by: FoundBy, now: u64) -> Result<bool> {
        signed.verify()?;
        let newer = self.by_device.get(&signed.record.device).is_none_or(|cur| cur.sig.is_none() || signed.record.seq > cur.record.seq);
        if newer {
            self.by_device.insert(signed.record.device, Cached { record: signed.record, sig: Some(signed.sig), found_by, received_at: now });
        }
        Ok(newer)
    }

    /// Migration: seed last-known addresses from an old card so a friend stays dialable until
    /// their first signed record arrives. Never overwrites a signed record.
    pub fn seed(&mut self, device: DeviceId, addresses: Vec<TransportAddr>, at: u64) {
        if self.by_device.get(&device).is_some_and(|c| c.sig.is_some()) {
            return;
        }
        let record = AddressRecord { device, addresses, relay: None, reachable: Reachability::default(), awake: false, tags: Vec::new(), seq: 0, at };
        self.by_device.insert(device, Cached { record, sig: None, found_by: FoundBy::Cache, received_at: at });
    }

    pub fn get(&self, device: &DeviceId) -> Option<&Cached> {
        self.by_device.get(device)
    }

    pub fn addr(&self, device: &DeviceId) -> Option<EndpointAddr> {
        self.by_device.get(device).map(|c| c.record.endpoint_addr())
    }

    /// The records both sides hold a card for: what "exchange on connect" sends.
    pub fn for_devices<'a>(&'a self, devices: impl IntoIterator<Item = &'a DeviceId>) -> Vec<SignedRecord> {
        devices.into_iter().filter_map(|d| self.by_device.get(d).and_then(|c| c.sig.map(|sig| SignedRecord { record: c.record.clone(), sig }))).collect()
    }

    pub fn views(&self, now: u64) -> Vec<RecordView> {
        self.by_device
            .values()
            .map(|c| RecordView {
                device: c.record.device,
                relay: c.record.relay,
                reachable: c.record.reachable,
                awake: c.record.awake,
                tags: c.record.tags.clone(),
                seq: c.record.seq,
                age_ms: now.saturating_sub(c.received_at),
                found_by: c.found_by,
            })
            .collect()
    }

    /// Every signed record, for the store and for exchange.
    pub fn signed(&self) -> Vec<SignedRecord> {
        self.by_device.values().filter_map(|c| c.sig.map(|sig| SignedRecord { record: c.record.clone(), sig })).collect()
    }

    pub fn remove(&mut self, device: &DeviceId) {
        self.by_device.remove(device);
    }

    pub fn len(&self) -> usize {
        self.by_device.len()
    }
    pub fn is_empty(&self) -> bool {
        self.by_device.is_empty()
    }
}

/// An address a stranger on the internet could route to: not loopback, private, link-local,
/// unspecified or VPN. Only these say anything about the NAT.
pub fn is_global(ip: &IpAddr) -> bool {
    if is_vpn(ip) || ip.is_loopback() || ip.is_unspecified() {
        return false;
    }
    match ip {
        IpAddr::V4(v4) => !(v4.is_private() || v4.is_link_local() || v4.is_broadcast() || v4.octets()[0] == 100 && (64..128).contains(&v4.octets()[1])),
        IpAddr::V6(v6) => !(v6.is_unique_local() || v6.is_unicast_link_local()),
    }
}

/// Tailscale's ranges, verified dialable from a symmetric NAT. Kept in records; shown as
/// "over your VPN" when selected.
pub fn is_vpn(ip: &IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            let o = v4.octets();
            o[0] == 100 && (64..128).contains(&o[1])
        }
        IpAddr::V6(v6) => {
            let s = v6.segments();
            s[0] == 0xfd7a && s[1] == 0x115c && s[2] == 0xa1e0
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rec(k: &Secret, seq: u64) -> AddressRecord {
        AddressRecord {
            device: k.device_id(),
            addresses: vec![TransportAddr::Ip("100.64.0.9:4101".parse().unwrap()), TransportAddr::Relay("http://10.0.0.2:4101".parse().unwrap())],
            relay: Some(DeviceId([1; 32])),
            reachable: Reachability { udp: true, tcp: false },
            awake: true,
            tags: vec!["vlm".into()],
            seq,
            at: seq,
        }
    }

    #[test]
    fn newer_wins_and_forgeries_fail() {
        let k = Secret::generate();
        let r1 = SignedRecord::sign(rec(&k, 1), &k);
        let r2 = SignedRecord::sign(rec(&k, 2), &k);
        let mut recs = Records::default();
        assert!(recs.put(r2.clone(), FoundBy::Push, 10).unwrap());
        assert!(!recs.put(r1, FoundBy::Exchange, 11).unwrap());
        let v = &recs.views(1010)[0];
        assert_eq!((v.seq, v.age_ms, v.found_by), (2, 1000, FoundBy::Push));
        let other = Secret::generate();
        let forged = SignedRecord { record: rec(&k, 9), sig: other.sign(b"nope") };
        assert!(recs.put(forged, FoundBy::Push, 12).is_err());
        let bytes = postcard::to_allocvec(&r2).unwrap();
        assert_eq!(postcard::from_bytes::<SignedRecord>(&bytes).unwrap(), r2);
    }

    #[test]
    fn seeded_records_dial_until_a_signed_one_arrives() {
        let k = Secret::generate();
        let mut recs = Records::default();
        recs.seed(k.device_id(), vec![TransportAddr::Ip("10.0.0.1:1".parse().unwrap())], 5);
        assert_eq!(recs.addr(&k.device_id()).unwrap().ip_addrs().count(), 1);
        assert!(recs.for_devices(&[k.device_id()]).is_empty(), "a seed is never forwarded as if signed");
        assert_eq!(recs.views(6)[0].found_by, FoundBy::Cache);
        assert!(recs.put(SignedRecord::sign(rec(&k, 1), &k), FoundBy::Push, 7).unwrap());
        recs.seed(k.device_id(), vec![], 8);
        assert_eq!(recs.views(9)[0].seq, 1, "a seed never overwrites a signed record");
    }

    #[test]
    fn relay_only_strips_ips_and_addr_builds() {
        let k = Secret::generate();
        let r = rec(&k, 1);
        assert_eq!(r.endpoint_addr().ip_addrs().count(), 1);
        assert_eq!(r.relay_only().addresses.len(), 1);
        assert_eq!(r.relay_only().relay_urls().count(), 1);
    }

    #[test]
    fn vpn_ranges() {
        assert!(is_vpn(&"100.64.0.1".parse().unwrap()));
        assert!(is_vpn(&"100.127.255.255".parse().unwrap()));
        assert!(!is_vpn(&"100.128.0.1".parse().unwrap()));
        assert!(is_vpn(&"fd7a:115c:a1e0::1".parse().unwrap()));
        assert!(!is_vpn(&"192.168.1.1".parse().unwrap()));
    }
}
