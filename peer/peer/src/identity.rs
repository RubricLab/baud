//! Keys and ids. A device is an Ed25519 key; a person is another. Ids are public keys and nothing
//! more. Secrets live behind the `Keychain` seam, never in an app-readable file.

use std::collections::HashMap;
use std::fmt;
use std::path::PathBuf;
use std::sync::Mutex;

use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use serde::{Deserialize, Serialize};

use crate::{Error, Result};
use crate::sync::Locked;

macro_rules! id {
    ($name:ident, $doc:literal) => {
        #[doc = $doc]
        #[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
        pub struct $name(pub [u8; 32]);

        // Bytes on the wire (postcard), hex in anything a person or a binding reads (JSON).
        impl Serialize for $name {
            fn serialize<S: serde::Serializer>(&self, s: S) -> std::result::Result<S::Ok, S::Error> {
                if s.is_human_readable() { s.serialize_str(&hex(&self.0)) } else { self.0.serialize(s) }
            }
        }
        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D: serde::Deserializer<'de>>(d: D) -> std::result::Result<Self, D::Error> {
                if d.is_human_readable() {
                    let s = String::deserialize(d)?;
                    unhex32(&s).map($name).map_err(|_| serde::de::Error::custom("expected 64 hex chars"))
                } else {
                    <[u8; 32]>::deserialize(d).map($name)
                }
            }
        }

        impl $name {
            pub fn verifying(&self) -> Result<VerifyingKey> {
                VerifyingKey::from_bytes(&self.0).map_err(|_| Error::BadKey)
            }
            /// The public key on the Montgomery curve, for sealing to it.
            pub fn to_x25519(&self) -> Result<[u8; 32]> {
                Ok(self.verifying()?.to_montgomery().to_bytes())
            }
            pub fn verify(&self, msg: &[u8], sig: &Sig) -> Result<()> {
                self.verifying()?.verify(msg, &Signature::from_bytes(&sig.0)).map_err(|_| Error::BadSignature)
            }
            pub fn short(&self) -> String {
                hex(&self.0[..5])
            }
            pub fn to_hex(&self) -> String {
                hex(&self.0)
            }
            pub fn from_hex(s: &str) -> Result<Self> {
                Ok(Self(unhex32(s)?))
            }
        }
        impl fmt::Debug for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                write!(f, "{}({})", stringify!($name), self.short())
            }
        }
        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str(&hex(&self.0))
            }
        }
    };
}

id!(DeviceId, "A device's public key: the only thing anyone dials.");
id!(UserId, "A person's public key: the address; the petname is the UI.");

/// An app-defined namespace: a darkroom space, a baud channel, a computer share.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize, Debug)]
pub struct GroupId(pub [u8; 32]);

impl From<DeviceId> for iroh::EndpointId {
    fn from(id: DeviceId) -> Self {
        iroh::EndpointId::from_bytes(&id.0).expect("a device id is a valid ed25519 key")
    }
}
impl From<iroh::EndpointId> for DeviceId {
    fn from(id: iroh::EndpointId) -> Self {
        DeviceId(*id.as_bytes())
    }
}

/// An Ed25519 signature, as bytes so it serializes with postcard.
#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Sig(#[serde(with = "serde_bytes64")] pub [u8; 64]);

impl fmt::Debug for Sig {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Sig({}…)", hex(&self.0[..4]))
    }
}

/// A secret key, for a device or a person.
#[derive(Clone)]
pub struct Secret(SigningKey);

impl Secret {
    pub fn generate() -> Self {
        Self(SigningKey::from_bytes(&rand::random::<[u8; 32]>()))
    }
    pub fn from_bytes(bytes: &[u8; 32]) -> Self {
        Self(SigningKey::from_bytes(bytes))
    }
    pub fn to_bytes(&self) -> [u8; 32] {
        self.0.to_bytes()
    }
    pub fn public(&self) -> [u8; 32] {
        self.0.verifying_key().to_bytes()
    }
    pub fn sign(&self, msg: &[u8]) -> Sig {
        Sig(self.0.sign(msg).to_bytes())
    }
    pub fn device_id(&self) -> DeviceId {
        DeviceId(self.public())
    }
    pub fn user_id(&self) -> UserId {
        UserId(self.public())
    }
    pub fn iroh(&self) -> iroh::SecretKey {
        iroh::SecretKey::from_bytes(&self.to_bytes())
    }
    /// The same key on the Montgomery curve, for sealing envelopes to a device.
    pub fn to_x25519(&self) -> [u8; 32] {
        self.0.to_scalar_bytes()
    }
}

impl fmt::Debug for Secret {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Secret({})", hex(&self.public()[..5]))
    }
}

/// The 60-digit safety number for a person, in twelve groups of five.
pub fn fingerprint(user: &UserId) -> String {
    let mut bytes = [0u8; 60];
    blake3::Hasher::new().update(b"peer fingerprint v1").update(&user.0).finalize_xof().fill(&mut bytes);
    let mut digits = String::with_capacity(72);
    for (i, chunk) in bytes.chunks(5).enumerate() {
        let mut n: u64 = 0;
        for b in chunk {
            n = (n << 8) | *b as u64;
        }
        if i > 0 {
            digits.push(' ');
        }
        digits.push_str(&format!("{:05}", n % 100_000));
    }
    digits
}

/// Where secrets live. The crate stores exactly three items: `device-key`, `user-key`,
/// `store-key`, 32 bytes each. Apps provide the platform keychain; tests use `MemoryKeychain`;
/// a headless box uses `FileKeychain` at 0600.
pub trait Keychain: Send + Sync {
    fn get(&self, item: &str) -> Result<Option<Vec<u8>>>;
    fn put(&self, item: &str, bytes: &[u8]) -> Result<()>;
    fn delete(&self, item: &str) -> Result<()>;
}

pub const DEVICE_KEY: &str = "device-key";
pub const USER_KEY: &str = "user-key";
pub const STORE_KEY: &str = "store-key";

#[derive(Default)]
pub struct MemoryKeychain(Mutex<HashMap<String, Vec<u8>>>);

impl Keychain for MemoryKeychain {
    fn get(&self, item: &str) -> Result<Option<Vec<u8>>> {
        Ok(self.0.locked().get(item).cloned())
    }
    fn put(&self, item: &str, bytes: &[u8]) -> Result<()> {
        self.0.locked().insert(item.to_owned(), bytes.to_vec());
        Ok(())
    }
    fn delete(&self, item: &str) -> Result<()> {
        self.0.locked().remove(item);
        Ok(())
    }
}

/// One file per item under `dir`, mode 0600. For `peer-node` only.
pub struct FileKeychain(pub PathBuf);

impl Keychain for FileKeychain {
    fn get(&self, item: &str) -> Result<Option<Vec<u8>>> {
        match std::fs::read(self.0.join(item)) {
            Ok(b) => Ok(Some(b)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(Error::Keychain(e.to_string())),
        }
    }
    fn put(&self, item: &str, bytes: &[u8]) -> Result<()> {
        std::fs::create_dir_all(&self.0).map_err(|e| Error::Keychain(e.to_string()))?;
        let path = self.0.join(item);
        std::fs::write(&path, bytes).map_err(|e| Error::Keychain(e.to_string()))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&self.0, std::fs::Permissions::from_mode(0o700));
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).map_err(|e| Error::Keychain(e.to_string()))?;
        }
        Ok(())
    }
    fn delete(&self, item: &str) -> Result<()> {
        match std::fs::remove_file(self.0.join(item)) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(Error::Keychain(e.to_string())),
        }
    }
}

/// Load a 32-byte secret from the keychain, or make one and store it.
pub fn load_or_make(keychain: &dyn Keychain, item: &str) -> Result<Secret> {
    if let Some(bytes) = keychain.get(item)? {
        let bytes: [u8; 32] = bytes.try_into().map_err(|_| Error::BadKey)?;
        return Ok(Secret::from_bytes(&bytes));
    }
    let secret = Secret::generate();
    keychain.put(item, &secret.to_bytes())?;
    Ok(secret)
}

/// Lowercase hex, for ids that cross a binding as text.
pub fn hex_of(bytes: &[u8]) -> String {
    hex(bytes)
}

pub(crate) fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

pub(crate) fn unhex32(s: &str) -> Result<[u8; 32]> {
    if s.len() != 64 || !s.is_ascii() {
        return Err(Error::Encoding);
    }
    let mut out = [0u8; 32];
    for (i, b) in out.iter_mut().enumerate() {
        *b = u8::from_str_radix(&s[i * 2..i * 2 + 2], 16).map_err(|_| Error::Encoding)?;
    }
    Ok(out)
}

mod serde_bytes64 {
    use serde::{Deserialize, Deserializer, Serializer};
    pub fn serialize<S: Serializer>(v: &[u8; 64], s: S) -> std::result::Result<S::Ok, S::Error> {
        s.serialize_bytes(v)
    }
    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> std::result::Result<[u8; 64], D::Error> {
        let v: &[u8] = Deserialize::deserialize(d)?;
        v.try_into().map_err(|_| serde::de::Error::custom("signature must be 64 bytes"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sign_and_verify() {
        let k = Secret::generate();
        let sig = k.sign(b"hi");
        k.device_id().verify(b"hi", &sig).unwrap();
        assert!(k.device_id().verify(b"ho", &sig).is_err());
    }

    #[test]
    fn fingerprint_is_sixty_digits() {
        let f = fingerprint(&Secret::generate().user_id());
        assert_eq!(f.replace(' ', "").len(), 60);
    }

    #[test]
    fn iroh_key_matches() {
        let k = Secret::generate();
        assert_eq!(*k.iroh().public().as_bytes(), k.public());
    }

    #[test]
    fn keychains_round_trip() {
        let dir = tempfile::tempdir().unwrap();
        for kc in [Box::new(MemoryKeychain::default()) as Box<dyn Keychain>, Box::new(FileKeychain(dir.path().join("keys")))] {
            let a = load_or_make(kc.as_ref(), DEVICE_KEY).unwrap();
            let b = load_or_make(kc.as_ref(), DEVICE_KEY).unwrap();
            assert_eq!(a.to_bytes(), b.to_bytes());
            kc.delete(DEVICE_KEY).unwrap();
            assert!(kc.get(DEVICE_KEY).unwrap().is_none());
        }
    }

    #[test]
    fn ids_are_hex_in_json_and_bytes_in_postcard() {
        let id = Secret::generate().device_id();
        let json = serde_json::to_string(&id).unwrap();
        assert_eq!(json, format!("\"{}\"", id.to_hex()));
        assert_eq!(serde_json::from_str::<DeviceId>(&json).unwrap(), id);
        let bytes = postcard::to_allocvec(&id).unwrap();
        assert_eq!(bytes.len(), 32);
        assert_eq!(postcard::from_bytes::<DeviceId>(&bytes).unwrap(), id);
    }

    #[test]
    fn hex_round_trip() {
        let id = Secret::generate().device_id();
        assert_eq!(DeviceId::from_hex(&id.to_hex()).unwrap(), id);
        assert!(DeviceId::from_hex("zz").is_err());
    }
}
