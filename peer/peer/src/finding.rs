//! Finding, in order: cache and dial, push on change, exchange on connect, nearby. This module
//! holds the pure rules: who gets a pushed record, how far it travels, and when each mutual is
//! dialed (the schedule the node's network loop runs).

use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

use crate::identity::DeviceId;
use crate::record::SignedRecord;

/// The devices a record is forwarded to on arrival: every connected peer that holds a card for
/// the record's device, except where it came from, while hops remain. Three hops, old seq loses.
pub fn forward_to<'a>(
    rec: &SignedRecord,
    from: DeviceId,
    hops: u8,
    connected: impl IntoIterator<Item = &'a DeviceId>,
    holds_card_for: impl Fn(&DeviceId, &DeviceId) -> bool,
) -> Vec<DeviceId> {
    if hops >= crate::helper::MAX_HOPS {
        return Vec::new();
    }
    connected
        .into_iter()
        .copied()
        .filter(|peer| *peer != from && *peer != rec.device() && holds_card_for(peer, &rec.device()))
        .collect()
}

/// Rule 2 of the network loop: a dial to every mutual device with a record is always either
/// live or scheduled. Backoff 1, 2, 4 … 60 s; back to 1 s the moment a fresh record for it
/// arrives, the network changes, `set_online(true)` is called, or its connection closes.
pub const BACKOFF_MIN: Duration = Duration::from_secs(1);
pub const BACKOFF_MAX: Duration = Duration::from_secs(60);
/// `set_online(true)` must have every cached record dialed within this budget.
pub const FIRST_DIAL_BUDGET_MS: u64 = 2000;

#[derive(Clone, Copy, Debug)]
struct Slot {
    backoff: Duration,
    next: Instant,
    inflight: bool,
}

/// The dial schedule, pure: the node asks it what is due and tells it how dials ended.
#[derive(Default, Debug)]
pub struct Schedule {
    slots: HashMap<DeviceId, Slot>,
}

impl Schedule {
    /// Mutuals with a record, and whether each is connected: returns the devices to dial now and
    /// when the next one falls due. A connected device keeps a 1 s backoff, so the moment its
    /// connection closes it is dialed again; one no longer in the set is forgotten.
    pub fn due(&mut self, now: Instant, mutuals: impl IntoIterator<Item = (DeviceId, bool)>) -> (Vec<DeviceId>, Option<Instant>) {
        let mut seen = HashSet::new();
        let mut dial = Vec::new();
        let mut next: Option<Instant> = None;
        for (d, connected) in mutuals {
            seen.insert(d);
            let slot = self.slots.entry(d).or_insert(Slot { backoff: BACKOFF_MIN, next: now, inflight: false });
            if connected {
                slot.backoff = BACKOFF_MIN;
                continue;
            }
            if slot.inflight {
                continue;
            }
            if slot.next <= now {
                slot.inflight = true;
                dial.push(d);
            } else {
                next = Some(next.map_or(slot.next, |n| n.min(slot.next)));
            }
        }
        self.slots.retain(|d, _| seen.contains(d));
        (dial, next)
    }

    /// A dial began outside the schedule (an app's `connect`, a forced redial): count it in flight.
    pub fn started(&mut self, d: DeviceId, now: Instant) -> bool {
        let slot = self.slots.entry(d).or_insert(Slot { backoff: BACKOFF_MIN, next: now, inflight: false });
        !std::mem::replace(&mut slot.inflight, true)
    }

    /// A dial ended. Failure doubles the wait (to 60 s); success keeps it at 1 s.
    pub fn finished(&mut self, d: DeviceId, ok: bool, now: Instant) {
        if let Some(slot) = self.slots.get_mut(&d) {
            slot.inflight = false;
            if ok {
                slot.backoff = BACKOFF_MIN;
                slot.next = now + BACKOFF_MIN;
            } else {
                slot.next = now + slot.backoff;
                slot.backoff = (slot.backoff * 2).min(BACKOFF_MAX);
            }
        }
    }

    /// Dial it now, and start its backoff over.
    pub fn reset(&mut self, d: DeviceId, now: Instant) {
        let slot = self.slots.entry(d).or_insert(Slot { backoff: BACKOFF_MIN, next: now, inflight: false });
        slot.backoff = BACKOFF_MIN;
        slot.next = now;
    }

    pub fn reset_all(&mut self, now: Instant) {
        for slot in self.slots.values_mut() {
            slot.backoff = BACKOFF_MIN;
            slot.next = now;
        }
    }

    pub fn inflight(&self, d: &DeviceId) -> bool {
        self.slots.get(d).is_some_and(|s| s.inflight)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::Secret;
    use crate::record::AddressRecord;

    #[test]
    fn forwards_to_mutual_cardholders_only_within_hops() {
        let k = Secret::generate();
        let rec = SignedRecord::sign(
            AddressRecord { device: k.device_id(), addresses: vec![], relay: None, reachable: Default::default(), awake: true, tags: vec![], seq: 1, at: 1 },
            &k,
        );
        let (a, b, c) = (DeviceId([1; 32]), DeviceId([2; 32]), DeviceId([3; 32]));
        let connected = [a, b, c, k.device_id()];
        let holds = |peer: &DeviceId, _: &DeviceId| *peer != c;
        assert_eq!(forward_to(&rec, a, 0, &connected, holds), vec![b]);
        assert_eq!(forward_to(&rec, a, 3, &connected, holds), Vec::<DeviceId>::new());
    }

    #[test]
    fn schedule_backs_off_and_resets() {
        let (a, b) = (DeviceId([1; 32]), DeviceId([2; 32]));
        let mut s = Schedule::default();
        let t = Instant::now();
        let (dial, _) = s.due(t, [(a, false), (b, true)]);
        assert_eq!(dial, vec![a]);
        // In flight: not dialed twice.
        assert!(s.due(t, [(a, false)]).0.is_empty());
        s.finished(a, false, t);
        let (dial, next) = s.due(t, [(a, false)]);
        assert!(dial.is_empty());
        assert_eq!(next, Some(t + Duration::from_secs(1)));
        s.due(t + Duration::from_secs(1), [(a, false)]);
        s.finished(a, false, t + Duration::from_secs(1));
        assert_eq!(s.due(t + Duration::from_secs(1), [(a, false)]).1, Some(t + Duration::from_secs(3)));
        for i in 0..10 {
            let now = t + Duration::from_secs(100 * (i + 2));
            s.due(now, [(a, false)]);
            s.finished(a, false, now);
        }
        assert_eq!(s.slots[&a].backoff, BACKOFF_MAX);
        // A fresh record (or a network change) dials at once.
        let now = t + Duration::from_secs(5000);
        s.reset(a, now);
        assert_eq!(s.due(now, [(a, false)]).0, vec![a]);
        // Gone from the set: forgotten.
        s.due(now, [(b, true)]);
        assert!(!s.slots.contains_key(&a));
    }
}
