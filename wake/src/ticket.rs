//! A wake ticket: an iPhone's push tokens, sealed by the iPhone itself to the relay's public key
//! (HPKE, RFC 9180: DHKEM(X25519, HKDF-SHA256), HKDF-SHA256, ChaCha20-Poly1305), so the friend
//! who holds it can't read it and only the relay can open it.
//!
//! ```text
//! ticket     version (1) · key id (1) · encapsulated key (32) · sealed body
//! body       flags (1) · expires, unix seconds (4, big-endian) · ticket id (16)
//!            · alert token length (1) · alert token · VoIP token length (1) · VoIP token
//! flags      1 sandbox · 2 may wake for messages · 4 may ring for calls
//! ```
//!
//! The first two bytes are the seal's associated data, so neither can be changed in transit.

use hpke::{aead::ChaCha20Poly1305, kdf::HkdfSha256, kem::X25519HkdfSha256, Deserializable, Kem as _, OpModeR, OpModeS, Serializable};

pub const VERSION: u8 = 1;
pub const INFO: &[u8] = b"baud wake ticket";
pub const SANDBOX: u8 = 1;
pub const MESSAGES: u8 = 2;
pub const CALLS: u8 = 4;

pub type PrivateKey = <X25519HkdfSha256 as hpke::Kem>::PrivateKey;
pub type PublicKey = <X25519HkdfSha256 as hpke::Kem>::PublicKey;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Ticket {
    pub flags: u8,
    pub expires: u32,
    pub id: [u8; 16],
    pub alert: Vec<u8>,
    pub voip: Vec<u8>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Refused {
    /// Not a ticket at all.
    Malformed,
    /// Sealed to a key this relay doesn't hold (an old one, or another relay's).
    UnknownKey,
    /// Its time is up: the phone makes a fresh one whenever the two are connected.
    Expired,
}

impl Ticket {
    pub fn sandbox(&self) -> bool { self.flags & SANDBOX != 0 }
    pub fn may(&self, flag: u8) -> bool { self.flags & flag != 0 }

    fn body(&self) -> Vec<u8> {
        let mut b = vec![self.flags];
        b.extend_from_slice(&self.expires.to_be_bytes());
        b.extend_from_slice(&self.id);
        b.push(self.alert.len() as u8);
        b.extend_from_slice(&self.alert);
        b.push(self.voip.len() as u8);
        b.extend_from_slice(&self.voip);
        b
    }

    fn parse(b: &[u8]) -> Option<Ticket> {
        let (&flags, rest) = b.split_first()?;
        let expires = u32::from_be_bytes(rest.get(..4)?.try_into().ok()?);
        let id: [u8; 16] = rest.get(4..20)?.try_into().ok()?;
        let rest = &rest[20..];
        let (&n, rest) = rest.split_first()?;
        let alert = rest.get(..n as usize)?.to_vec();
        let rest = &rest[n as usize..];
        let (&m, rest) = rest.split_first()?;
        let voip = rest.get(..m as usize)?.to_vec();
        if rest.len() != m as usize { return None }
        Some(Ticket { flags, expires, id, alert, voip })
    }

    /// Seal for the relay's key (`key_id` names it). The iPhone does this with CryptoKit; this is
    /// for tests and tools.
    pub fn seal(&self, key_id: u8, to: &PublicKey) -> Vec<u8> {
        let head = [VERSION, key_id];
        let (enc, ct) = hpke::single_shot_seal::<ChaCha20Poly1305, HkdfSha256, X25519HkdfSha256>(&OpModeS::Base, to, INFO, &self.body(), &head).expect("seal");
        [&head[..], &enc.to_bytes()[..], &ct[..]].concat()
    }
}

/// Open a ticket with whichever of the relay's keys sealed it, and check it's still good at `now`.
pub fn open(bytes: &[u8], keys: &[(u8, PrivateKey)], now: u32) -> Result<Ticket, Refused> {
    if bytes.len() < 2 + 32 + 16 || bytes[0] != VERSION { return Err(Refused::Malformed) }
    let (_, key) = keys.iter().find(|(id, _)| *id == bytes[1]).ok_or(Refused::UnknownKey)?;
    let enc = <X25519HkdfSha256 as hpke::Kem>::EncappedKey::from_bytes(&bytes[2..34]).map_err(|_| Refused::Malformed)?;
    let body = hpke::single_shot_open::<ChaCha20Poly1305, HkdfSha256, X25519HkdfSha256>(&OpModeR::Base, key, &enc, INFO, &bytes[34..], &bytes[..2]).map_err(|_| Refused::Malformed)?;
    let t = Ticket::parse(&body).ok_or(Refused::Malformed)?;
    if t.expires <= now { return Err(Refused::Expired) }
    Ok(t)
}

pub fn keypair() -> (PrivateKey, PublicKey) { X25519HkdfSha256::gen_keypair() }

pub fn private_from(bytes: &[u8]) -> Option<PrivateKey> { PrivateKey::from_bytes(bytes).ok() }

pub fn public_of(key: &PrivateKey) -> PublicKey { X25519HkdfSha256::sk_to_pk(key) }

pub fn bytes_of<T: Serializable>(k: &T) -> Vec<u8> { k.to_bytes().to_vec() }

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> Ticket {
        Ticket { flags: MESSAGES | CALLS | SANDBOX, expires: 2_000_000_000, id: [7; 16], alert: vec![0xab; 32], voip: vec![0xcd; 32] }
    }

    #[test]
    fn a_sealed_ticket_opens_with_its_key_and_no_other() {
        let (sk, pk) = keypair();
        let (other, _) = keypair();
        let t = sample();
        let sealed = t.seal(1, &pk);
        assert_eq!(open(&sealed, &[(1, sk.clone())], 1_000), Ok(t.clone()));
        assert_eq!(open(&sealed, &[(1, other)], 1_000), Err(Refused::Malformed));
        assert_eq!(open(&sealed, &[(2, sk)], 1_000), Err(Refused::UnknownKey));
    }

    #[test]
    fn a_ticket_past_its_time_is_refused() {
        let (sk, pk) = keypair();
        let sealed = sample().seal(1, &pk);
        assert_eq!(open(&sealed, &[(1, sk)], 2_000_000_000), Err(Refused::Expired));
    }

    #[test]
    fn changing_any_byte_breaks_it() {
        let (sk, pk) = keypair();
        let sealed = sample().seal(1, &pk);
        for i in 2..sealed.len() {
            let mut bad = sealed.clone();
            bad[i] ^= 1;
            assert!(open(&bad, &[(1, sk.clone())], 1_000).is_err(), "byte {i}");
        }
        assert_eq!(open(&sealed[..40], &[(1, sk)], 1_000), Err(Refused::Malformed));
    }

    /// What the iPhone seals with CryptoKit opens here (`wake/tests/swift-ticket.json`, written by
    /// BaudCore's WakeTests).
    #[test]
    fn a_ticket_sealed_by_the_iphone_opens() {
        use base64::{engine::general_purpose::STANDARD, Engine};
        let v: serde_json::Value = serde_json::from_str(include_str!("../tests/swift-ticket.json")).unwrap();
        let sk = private_from(&STANDARD.decode(v["key"].as_str().unwrap()).unwrap()).unwrap();
        let t = open(&STANDARD.decode(v["ticket"].as_str().unwrap()).unwrap(), &[(1, sk)], 1_000).unwrap();
        let hex = |b: &[u8]| b.iter().map(|x| format!("{x:02x}")).collect::<String>();
        assert_eq!(t.flags as u64, v["flags"].as_u64().unwrap());
        assert_eq!(t.expires as u64, v["expires"].as_u64().unwrap());
        assert_eq!(hex(&t.id), v["id"].as_str().unwrap());
        assert_eq!(hex(&t.alert), v["alert"].as_str().unwrap());
        assert_eq!(hex(&t.voip), v["voip"].as_str().unwrap());
        assert!(t.sandbox() && t.may(MESSAGES) && t.may(CALLS));
    }

    /// Two tickets for the same phone share no bytes a holder could compare.
    #[test]
    fn two_seals_of_one_ticket_look_unrelated() {
        let (_, pk) = keypair();
        let (a, b) = (sample().seal(1, &pk), sample().seal(1, &pk));
        assert_eq!(a.len(), b.len());
        assert_ne!(a[2..], b[2..]);
    }
}
