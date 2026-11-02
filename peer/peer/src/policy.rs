//! Who carries what. Every stream declares a class; the crate enforces the path it may take.
//! Also the release gate: the list of non-peer hosts a node could talk to, which must be empty.

use serde::{Deserialize, Serialize};

use crate::Path;
use crate::identity::DeviceId;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Class {
    /// Calls, screen, typing: direct, or relayed by a device of either endpoint's person.
    Live,
    /// Blobs over 50 MB, library sync: direct, or a device of either endpoint's person.
    Bulk,
    /// Messages, records, envelopes, invites, metadata: any helper.
    Small,
}

/// Blobs at or above this many bytes never go to carriers.
pub const BULK_BYTES: u64 = 50 * 1024 * 1024;

/// May a stream of `class` use `path`? `endpoint_owned` says whether a relay device belongs to
/// either endpoint's person: a relay on the far side's own home Mac reveals nothing the direct
/// path would not. A third person's relay is never allowed for Live or Bulk.
pub fn allows(class: Class, path: &Path, endpoint_owned: impl Fn(&DeviceId) -> bool) -> bool {
    match (class, path) {
        (_, Path::Waiting | Path::Unreachable) => false,
        (_, Path::Direct { .. } | Path::Nearby) => true,
        (Class::Small, Path::Relay(_)) => true,
        (Class::Live | Class::Bulk, Path::Relay(d)) => endpoint_owned(d),
    }
}

/// Per-friend overrides on top of the class table.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct FriendPolicy {
    /// They get a record with no direct addresses: they never see my IP.
    pub relay_only: bool,
    /// Second cut: they may relay bulk for me.
    pub may_carry_bulk: bool,
}

/// Every non-peer host a node could send to. The release gate asserts it is empty: the only
/// relay URLs an endpoint knows are those inserted from cardholders' records, and the only
/// discovery is mDNS. `presets::Minimal` has no DNS, no pkarr, no n0 relay map.
pub fn hosts(endpoint: &iroh::Endpoint, peer_relays: &[iroh::RelayUrl]) -> Vec<String> {
    endpoint.addr().relay_urls().filter(|u| !peer_relays.contains(u)).map(|u| u.to_string()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn table() {
        let mine = DeviceId([1; 32]);
        let theirs = DeviceId([2; 32]); // a third person's device
        let own = |d: &DeviceId| *d == mine;
        for c in [Class::Live, Class::Bulk, Class::Small] {
            assert!(allows(c, &Path::Direct { vpn: true }, own));
            assert!(allows(c, &Path::Nearby, own));
            assert!(allows(c, &Path::Relay(mine), own));
            assert!(!allows(c, &Path::Waiting, own));
            assert!(!allows(c, &Path::Unreachable, own));
        }
        assert!(allows(Class::Small, &Path::Relay(theirs), own));
        assert!(!allows(Class::Live, &Path::Relay(theirs), own));
        assert!(!allows(Class::Bulk, &Path::Relay(theirs), own));
    }
}
