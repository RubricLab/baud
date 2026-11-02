//! Introductions: hole punching with any mutual device as the go-between.
//!
//! I want a device I hold no connection to, and neither of us can be dialed cold: two NATs, no
//! port either router opened, no relay we share. Each of us is connected to some third device,
//! though: one of mine, or a friend we both know. So I ask the devices I am connected to (own
//! first, `INTRODUCERS` at most) to introduce us, naming the device only by `want_hash`, as in
//! `Exchange`: a device that does not already hold it learns nothing. One that is connected to
//! it, and holds both of us, tells it where it sees me and to dial me now (`Punch`), and tells me
//! where it sees it (`Introduced`). Then we both dial, each at the address the other's NAT gave
//! that third device: each outgoing packet opens our own NAT to the other, and a NAT that keeps
//! one port per socket (most home routers) lets the other's through. Both must start together:
//! a packet that reaches a Linux router before its own side has sent is recorded as traffic to
//! the router itself, and the outgoing dial that follows is given another port, which the far
//! NAT drops (the lab's routers, with the target dialing one round trip early). The go-between
//! tells the target first and the asker once the target agrees, so the target waits `start_wait`.
//! For the same reason a dial holds back where a punch aims (the device's public IPv4 addresses,
//! unless its record says they answer unasked) while an introduction to it is out
//! (`Introductions::pending`): an uncoordinated packet there would spoil the punch the
//! introduction is arranging. iroh sends to every address a dial has named until a path is
//! chosen, so this guards the first introduction. Where the NAT picks a new
//! port per destination, the punch fails and the relay, if there is one, carries the
//! connection as it always did. Nothing waits on an introduction: it races the plain dial.
//!
//! The go-between sees two addresses it already saw. Every step is spaced, so neither a busy
//! dial loop nor a misbehaving device turns introductions into traffic.

use std::collections::{HashMap, HashSet};
use std::hash::Hash;
use std::net::SocketAddr;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use crate::identity::DeviceId;
use crate::sync::Locked;

/// Devices asked to introduce me, own ones first.
pub const INTRODUCERS: usize = 4;
/// How long an asker waits for a go-between's answer.
pub const ANSWER_WAIT: Duration = Duration::from_secs(2);
/// Nobody could introduce us yet (the far side has not heard of me, or its go-between has not
/// heard of it: both just learnt of each other): ask once more after this, before dialing its
/// punch targets uncoordinated.
pub const ASK_AGAIN: Duration = Duration::from_millis(1500);
/// How long an introduced address is dialed after it was learnt.
pub const HINT_TTL: Duration = Duration::from_secs(30);
/// At most one introduction asked for per device, one forwarded per pair, and one dial back per
/// asker, in this long.
pub const SPACING: Duration = Duration::from_secs(20);

/// At most once per `every` for each key.
pub struct Spacing<K> {
    last: Mutex<HashMap<K, Instant>>,
    every: Duration,
}

impl<K: Eq + Hash + Clone> Spacing<K> {
    pub fn new(every: Duration) -> Self {
        Spacing { last: Mutex::new(HashMap::new()), every }
    }

    /// Whether `key` may go now; if so, it is counted as gone.
    pub fn allow(&self, key: K) -> bool {
        self.allow_at(key, Instant::now())
    }

    fn allow_at(&self, key: K, now: Instant) -> bool {
        let mut last = self.last.locked();
        last.retain(|_, t| now.duration_since(*t) < self.every);
        if last.contains_key(&key) {
            return false;
        }
        last.insert(key, now);
        true
    }
}

/// Addresses a go-between gave for a device, dialed beside its record's while fresh.
#[derive(Default)]
pub struct Hints {
    by: Mutex<HashMap<DeviceId, (Vec<SocketAddr>, Instant)>>,
}

impl Hints {
    /// Learnt now; returns whether any of them is new for this device.
    pub fn add(&self, device: DeviceId, addrs: &[SocketAddr]) -> bool {
        let mut by = self.by.locked();
        let now = Instant::now();
        let entry = by.entry(device).or_insert_with(|| (Vec::new(), now));
        if now.duration_since(entry.1) >= HINT_TTL {
            entry.0.clear();
        }
        entry.1 = now;
        let mut new = false;
        for a in addrs {
            if !entry.0.contains(a) {
                entry.0.push(*a);
                new = true;
            }
        }
        new
    }

    pub fn fresh(&self, device: &DeviceId) -> Vec<SocketAddr> {
        let mut by = self.by.locked();
        by.retain(|_, (_, at)| at.elapsed() < HINT_TTL);
        by.get(device).map(|(a, _)| a.clone()).unwrap_or_default()
    }
}

/// Everything a node keeps for introductions, in each of its three roles.
pub struct Introductions {
    pub hints: Hints,
    /// Asker: an introduction to this device was asked for.
    pub asked: Spacing<DeviceId>,
    /// Go-between: this asker was introduced to this device.
    pub forwarded: Spacing<(DeviceId, DeviceId)>,
    /// Asked for: this asker was dialed back.
    pub answered: Spacing<DeviceId>,
    /// Introductions out, by device: until each is answered, dials leave its punch targets alone.
    pending: Mutex<HashSet<DeviceId>>,
}

impl Default for Introductions {
    fn default() -> Self {
        Introductions { hints: Hints::default(), asked: Spacing::new(SPACING), forwarded: Spacing::new(SPACING), answered: Spacing::new(SPACING), pending: Mutex::default() }
    }
}

impl Introductions {
    pub fn begin(&self, device: DeviceId) {
        self.pending.locked().insert(device);
    }

    /// The introduction was answered (or nobody could make it): true if it was out.
    pub fn end(&self, device: &DeviceId) -> bool {
        self.pending.locked().remove(device)
    }

    pub fn pending(&self, device: &DeviceId) -> bool {
        self.pending.locked().contains(device)
    }
}

/// A punch's targets: public IPv4 addresses, where a NAT answers for the device behind it.
pub fn punch_target(addr: &SocketAddr) -> bool {
    addr.is_ipv4() && crate::record::is_global(&addr.ip())
}

/// How long the target waits before dialing so the asker starts at the same moment. The target
/// hears the `Punch` half a round trip after it leaves; the asker hears `Introduced` once the
/// target's answer is back and half its own round trip later: `rtt_target + rtt_asker / 2` after.
pub fn start_wait(rtt_asker_ms: u32, rtt_target_ms: u32) -> u32 {
    (rtt_asker_ms + rtt_target_ms) / 2
}

/// Only addresses across the internet travel through a go-between: a LAN address means nothing
/// on the far side's network, and its own LAN is found by its own means.
pub fn worth_passing(addr: &SocketAddr) -> bool {
    crate::record::is_global(&addr.ip())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spacing_lets_one_through_per_interval() {
        let s = Spacing::new(Duration::from_secs(20));
        let t = Instant::now();
        assert!(s.allow_at(1, t));
        assert!(!s.allow_at(1, t + Duration::from_secs(5)), "too soon");
        assert!(s.allow_at(2, t + Duration::from_secs(5)), "another key is its own");
        assert!(s.allow_at(1, t + Duration::from_secs(21)), "after the interval");
    }

    #[test]
    fn hints_merge_and_say_what_is_new() {
        let h = Hints::default();
        let d = DeviceId([1; 32]);
        let a: SocketAddr = "203.0.113.1:4101".parse().unwrap();
        let b: SocketAddr = "[2001:db8::7]:4101".parse().unwrap();
        assert!(h.add(d, &[a]));
        assert!(!h.add(d, &[a]), "nothing new");
        assert!(h.add(d, &[a, b]));
        assert_eq!(h.fresh(&d), vec![a, b]);
        assert!(h.fresh(&DeviceId([2; 32])).is_empty());
    }

    #[test]
    fn both_dials_start_together() {
        // Go-between sends at 0: the target hears it at 15, answers by 30; the asker hears at 30 + 50.
        let (asker, target) = (100, 30);
        assert_eq!(target / 2 + start_wait(asker, target), target + asker / 2);
        assert_eq!(start_wait(0, 0), 0);
    }

    #[test]
    fn an_introduction_out_is_ended_once() {
        let i = Introductions::default();
        let d = DeviceId([3; 32]);
        i.begin(d);
        assert!(i.pending(&d));
        assert!(i.end(&d));
        assert!(!i.end(&d), "ended already");
        assert!(punch_target(&"203.0.113.1:4101".parse().unwrap()));
        assert!(!punch_target(&"[2001:db8::7]:4101".parse().unwrap()), "IPv6 is not translated: no punch to spoil");
        assert!(!punch_target(&"192.168.1.30:4101".parse().unwrap()));
    }

    #[test]
    fn only_public_addresses_travel() {
        assert!(worth_passing(&"203.0.113.1:4101".parse().unwrap()));
        assert!(worth_passing(&"[2607:fb91::1]:4101".parse().unwrap()));
        assert!(!worth_passing(&"192.168.1.30:4101".parse().unwrap()));
        assert!(!worth_passing(&"100.101.102.103:4101".parse().unwrap()), "a VPN address");
        assert!(!worth_passing(&"127.0.0.1:4101".parse().unwrap()));
    }
}
