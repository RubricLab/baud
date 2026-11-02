//! A card is what a contact knows about a person: name, avatar, devices, revocations. Signed by
//! the user key. It never holds an address.

use serde::{Deserialize, Serialize};

use crate::identity::{DeviceId, Secret, Sig, UserId};
use crate::{Error, Result};

/// What a device is, so a sentence can say "Jo's iPhone". `Node` is a headless box. New kinds go
/// at the end: in a card a kind is its index, and an index from a later version is kept as it
/// came (`Unknown`, shown as `node`), so its card still reads and still verifies here, the
/// signature being over those very bytes. An unknown kind once failed the whole card.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum DeviceKind {
    Mac,
    Iphone,
    Ipad,
    Windows,
    Linux,
    #[default]
    Node,
    Android,
    /// A later version's kind, by its index.
    Unknown(u32),
}

impl DeviceKind {
    /// The build target's kind; an iPad must say so itself.
    pub fn this() -> DeviceKind {
        if cfg!(target_os = "macos") {
            DeviceKind::Mac
        } else if cfg!(target_os = "ios") {
            DeviceKind::Iphone
        } else if cfg!(target_os = "windows") {
            DeviceKind::Windows
        } else if cfg!(target_os = "linux") {
            DeviceKind::Linux
        } else if cfg!(target_os = "android") {
            DeviceKind::Android
        } else {
            DeviceKind::Node
        }
    }
    pub fn as_str(self) -> &'static str {
        match self {
            DeviceKind::Mac => "mac",
            DeviceKind::Iphone => "iphone",
            DeviceKind::Ipad => "ipad",
            DeviceKind::Windows => "windows",
            DeviceKind::Linux => "linux",
            DeviceKind::Node | DeviceKind::Unknown(_) => "node",
            DeviceKind::Android => "android",
        }
    }
    pub fn parse(s: &str) -> DeviceKind {
        match s {
            "mac" => DeviceKind::Mac,
            "iphone" => DeviceKind::Iphone,
            "ipad" => DeviceKind::Ipad,
            "windows" => DeviceKind::Windows,
            "linux" => DeviceKind::Linux,
            "android" => DeviceKind::Android,
            _ => DeviceKind::Node,
        }
    }

    /// Its index on the wire: the order above, as postcard numbers an enum's variants.
    fn index(self) -> u32 {
        match self {
            DeviceKind::Mac => 0,
            DeviceKind::Iphone => 1,
            DeviceKind::Ipad => 2,
            DeviceKind::Windows => 3,
            DeviceKind::Linux => 4,
            DeviceKind::Node => 5,
            DeviceKind::Android => 6,
            DeviceKind::Unknown(n) => n,
        }
    }

    fn of_index(n: u32) -> DeviceKind {
        match n {
            0 => DeviceKind::Mac,
            1 => DeviceKind::Iphone,
            2 => DeviceKind::Ipad,
            3 => DeviceKind::Windows,
            4 => DeviceKind::Linux,
            5 => DeviceKind::Node,
            6 => DeviceKind::Android,
            n => DeviceKind::Unknown(n),
        }
    }
}

/// On the wire, the index as a varint: byte for byte what the derived enum wrote, an index this
/// version does not know included. In JSON and the like, the lowercase name.
impl Serialize for DeviceKind {
    fn serialize<S: serde::Serializer>(&self, s: S) -> std::result::Result<S::Ok, S::Error> {
        if s.is_human_readable() { s.serialize_str(self.as_str()) } else { s.serialize_u32(self.index()) }
    }
}

impl<'de> Deserialize<'de> for DeviceKind {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> std::result::Result<Self, D::Error> {
        if d.is_human_readable() { Ok(DeviceKind::parse(&String::deserialize(d)?)) } else { Ok(DeviceKind::of_index(u32::deserialize(d)?)) }
    }
}

/// One of a person's devices, as listed in their card.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct DeviceEntry {
    pub id: DeviceId,
    pub name: String,
    pub kind: DeviceKind,
    pub added_at: u64,
    /// Opaque per-device keys the app needs in a card (baud: olm identity and prekey). The crate
    /// carries them and never reads them.
    pub app: Vec<u8>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Revocation {
    pub id: DeviceId,
    pub at: u64,
}

/// "I am now that person": a person who started on two devices has two user keys, and when a
/// device of the first links into the second, it signs this with the first key before giving it
/// up. Each contact of the first identity gets it (sealed to their devices, never anyone else),
/// replaces that contact's key with `to`, and refuses any later card from `from`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Redirect {
    pub from: UserId,
    pub to: UserId,
    /// Unix milliseconds.
    pub at: u64,
    pub sig: Sig,
}

impl Redirect {
    fn message(from: &UserId, to: &UserId, at: u64) -> Vec<u8> {
        let mut m = b"peer redirect v1".to_vec();
        m.extend_from_slice(&from.0);
        m.extend_from_slice(&to.0);
        m.extend_from_slice(&at.to_le_bytes());
        m
    }

    pub fn sign(old_user_key: &Secret, to: UserId, at: u64) -> Self {
        let from = old_user_key.user_id();
        Redirect { sig: old_user_key.sign(&Self::message(&from, &to, at)), from, to, at }
    }

    /// Signed by `from`'s key, and not to itself.
    pub fn verify(&self) -> Result<()> {
        if self.from == self.to {
            return Err(Error::BadKey);
        }
        self.from.verify(&Self::message(&self.from, &self.to, self.at), &self.sig)
    }
}

/// The unsigned content of a card.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CardBody {
    pub user: UserId,
    pub name: String,
    /// blake3 hash of the avatar blob, if any.
    pub avatar: Option<[u8; 32]>,
    pub devices: Vec<DeviceEntry>,
    pub revoked: Vec<Revocation>,
    /// Monotonic per person. The highest seq wins everywhere.
    pub seq: u64,
}

/// A signed card: the body's postcard bytes and the user key's signature over them.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Card {
    pub body: CardBody,
    pub sig: Sig,
}

impl Card {
    pub fn sign(body: CardBody, user_key: &Secret) -> Self {
        debug_assert_eq!(user_key.user_id(), body.user);
        let bytes = postcard::to_allocvec(&body).expect("a card body serializes");
        Card { sig: user_key.sign(&bytes), body }
    }

    /// Checks the signature against the user id inside the card.
    pub fn verify(&self) -> Result<()> {
        let bytes = postcard::to_allocvec(&self.body).map_err(|_| Error::Encoding)?;
        self.body.user.verify(&bytes, &self.sig)
    }

    pub fn user(&self) -> UserId {
        self.body.user
    }

    /// Is this device currently one of this person's: listed and not revoked?
    pub fn has_device(&self, id: &DeviceId) -> bool {
        self.body.devices.iter().any(|d| d.id == *id) && !self.is_revoked(id, u64::MAX)
    }

    /// Was this device revoked at or before `at`?
    pub fn is_revoked(&self, id: &DeviceId, at: u64) -> bool {
        self.body.revoked.iter().any(|r| r.id == *id && r.at <= at)
    }

    pub fn device_ids(&self) -> impl Iterator<Item = DeviceId> + '_ {
        self.body.devices.iter().map(|d| d.id).filter(|id| !self.is_revoked(id, u64::MAX))
    }

    /// A new body, ready to edit and re-sign with the next seq.
    pub fn next(&self) -> CardBody {
        let mut body = self.body.clone();
        body.seq += 1;
        body
    }

    /// Prefer the newer of two cards for the same person. Both must verify.
    pub fn newer<'a>(a: &'a Card, b: &'a Card) -> &'a Card {
        if b.body.seq > a.body.seq { b } else { a }
    }

    /// Two of a person's devices migrating the same old book sign the same seq. Merge by union
    /// of devices and revocations, re-signed; the caller holds the user key because it is that person.
    pub fn merge_own(a: &Card, b: &Card, user_key: &Secret) -> Card {
        if a.body.seq != b.body.seq {
            return Card::newer(a, b).clone();
        }
        let mut body = a.body.clone();
        for d in &b.body.devices {
            if !body.devices.iter().any(|x| x.id == d.id) {
                body.devices.push(d.clone());
            }
        }
        for r in &b.body.revoked {
            if !body.revoked.iter().any(|x| x.id == r.id) {
                body.revoked.push(r.clone());
            }
        }
        body.devices.sort_by(|x, y| x.id.cmp(&y.id));
        body.revoked.sort_by(|x, y| x.id.cmp(&y.id));
        Card::sign(body, user_key)
    }

    pub fn to_bytes(&self) -> Vec<u8> {
        postcard::to_allocvec(self).expect("a card serializes")
    }

    pub fn from_bytes(bytes: &[u8]) -> Result<Self> {
        let card: Card = postcard::from_bytes(bytes).map_err(|_| Error::Encoding)?;
        card.verify()?;
        Ok(card)
    }
}

/// The first card for a brand new person on their first device.
pub fn first_card(user_key: &Secret, device: &Secret, name: &str, device_name: &str, now: u64) -> Card {
    first_card_of(user_key, device, name, device_name, DeviceKind::this(), now)
}

pub fn first_card_of(user_key: &Secret, device: &Secret, name: &str, device_name: &str, kind: DeviceKind, now: u64) -> Card {
    let body = CardBody {
        user: user_key.user_id(),
        name: name.to_owned(),
        avatar: None,
        devices: vec![DeviceEntry { id: device.device_id(), name: device_name.to_owned(), kind, added_at: now, app: Vec::new() }],
        revoked: Vec::new(),
        seq: 1,
    };
    Card::sign(body, user_key)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A card from a later version, a device of a kind this one has never heard of (index 42):
    /// it reads, verifies, shows `node`, and goes on byte for byte as it came.
    #[test]
    fn a_card_with_a_later_kind_reads_and_verifies() {
        #[derive(Serialize)]
        struct Entry {
            id: DeviceId,
            name: String,
            kind: u32,
            added_at: u64,
            app: Vec<u8>,
        }
        #[derive(Serialize)]
        struct Body {
            user: UserId,
            name: String,
            avatar: Option<[u8; 32]>,
            devices: Vec<Entry>,
            revoked: Vec<Revocation>,
            seq: u64,
        }
        let (user, device) = (Secret::generate(), Secret::generate());
        let body = Body { user: user.user_id(), name: "Jo".into(), avatar: None, devices: vec![Entry { id: device.device_id(), name: "Jo's phone".into(), kind: 42, added_at: 1, app: vec![] }], revoked: vec![], seq: 1 };
        let body_bytes = postcard::to_allocvec(&body).unwrap();
        let mut bytes = body_bytes.clone();
        bytes.extend_from_slice(&postcard::to_allocvec(&user.sign(&body_bytes)).unwrap());
        let card = Card::from_bytes(&bytes).expect("reads and verifies");
        assert_eq!(card.body.devices[0].kind.as_str(), "node");
        assert_eq!(card.to_bytes(), bytes, "re-encoded as it came");
        // Android, new here, at the end: the index an older reader keeps.
        assert_eq!(postcard::to_allocvec(&DeviceKind::Android).unwrap(), [6]);
        assert_eq!(DeviceKind::parse("android"), DeviceKind::Android);
        assert_eq!(postcard::from_bytes::<DeviceKind>(&[3]).unwrap(), DeviceKind::Windows, "the old indices hold");
        assert_eq!(serde_json::to_string(&DeviceKind::Iphone).unwrap(), "\"iphone\"", "and the old names");
    }

    #[test]
    fn round_trip_and_tamper() {
        let user = Secret::generate();
        let dev = Secret::generate();
        let card = first_card(&user, &dev, "ana", "iphone", 1);
        card.verify().unwrap();
        assert!(card.has_device(&dev.device_id()));
        let back = Card::from_bytes(&card.to_bytes()).unwrap();
        assert_eq!(back, card);
        let mut forged = card.clone();
        forged.body.name = "eve".into();
        assert!(forged.verify().is_err());
        assert!(Card::from_bytes(&forged.to_bytes()).is_err());
    }

    #[test]
    fn revocation() {
        let user = Secret::generate();
        let dev = Secret::generate();
        let card = first_card(&user, &dev, "ana", "iphone", 1);
        let mut body = card.next();
        body.revoked.push(Revocation { id: dev.device_id(), at: 50 });
        let card2 = Card::sign(body, &user);
        assert!(!card2.has_device(&dev.device_id()));
        assert!(!card2.is_revoked(&dev.device_id(), 49));
        assert!(card2.is_revoked(&dev.device_id(), 50));
        assert_eq!(Card::newer(&card, &card2).body.seq, 2);
        assert_eq!(card2.device_ids().count(), 0);
    }

    #[test]
    fn equal_seq_own_cards_merge_by_union() {
        let user = Secret::generate();
        let (d1, d2) = (Secret::generate(), Secret::generate());
        let a = first_card(&user, &d1, "ana", "mac", 1);
        let b = first_card(&user, &d2, "ana", "phone", 1);
        let m = Card::merge_own(&a, &b, &user);
        m.verify().unwrap();
        assert_eq!(m.body.seq, 1);
        assert!(m.has_device(&d1.device_id()) && m.has_device(&d2.device_id()));
        assert_eq!(Card::merge_own(&m, &a, &user).body, m.body, "the union is stable");
    }
}
