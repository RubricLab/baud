//! Apple's push service, for the two wakes and nothing else. Every push for a kind is the same
//! bytes: "New message" for a message (the app fetches the real one peer to peer and replaces
//! it), an empty VoIP push for a call (the app rings through CallKit and the ring itself arrives
//! peer to peer). The provider token is ES256-signed with Rubric's push key and reused for 40
//! minutes, as Apple asks.

use crate::limits::Kind;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD as B64, Engine};
use p256::ecdsa::{signature::Signer, Signature, SigningKey};
use p256::pkcs8::DecodePrivateKey;
use std::future::Future;
use std::pin::Pin;
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

#[derive(Debug, PartialEq, Eq)]
pub enum PushError {
    /// Apple says this token is no longer a phone (baud reinstalled, or the token is wrong): the
    /// ticket is dead.
    Gone,
    /// Apple asked us to slow down.
    Busy,
    /// Anything else: our key, Apple's service, the network.
    Unavailable,
}

pub trait Pusher: Send + Sync {
    fn push<'a>(&'a self, kind: Kind, sandbox: bool, token: &'a [u8]) -> Pin<Box<dyn Future<Output = Result<(), PushError>> + Send + 'a>>;
}

pub const MESSAGE: &str = r#"{"aps":{"alert":{"body":"New message"},"sound":"default","content-available":1,"thread-id":"wake"}}"#;
pub const CALL: &str = "{}";

pub struct Apns {
    http: reqwest::Client,
    key: SigningKey,
    key_id: String,
    team: String,
    topic: String,
    jwt: Mutex<Option<(String, Instant)>>,
}

impl Apns {
    pub fn new(pem: &str, key_id: String, team: String, topic: String) -> Result<Apns, String> {
        let key = SigningKey::from_pkcs8_pem(pem).map_err(|e| format!("the push key isn't a PKCS#8 P-256 key: {e}"))?;
        let http = reqwest::Client::builder().timeout(Duration::from_secs(10)).build().map_err(|e| e.to_string())?;
        Ok(Apns { http, key, key_id, team, topic, jwt: Mutex::new(None) })
    }

    fn token(&self) -> String {
        let mut slot = self.jwt.lock().unwrap_or_else(|p| p.into_inner());
        if let Some((t, at)) = slot.as_ref() { if at.elapsed() < Duration::from_secs(40 * 60) { return t.clone() } }
        let iat = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
        let head = B64.encode(format!(r#"{{"alg":"ES256","kid":"{}"}}"#, self.key_id));
        let claims = B64.encode(format!(r#"{{"iss":"{}","iat":{iat}}}"#, self.team));
        let input = format!("{head}.{claims}");
        let sig: Signature = self.key.sign(input.as_bytes());
        let t = format!("{input}.{}", B64.encode(sig.to_bytes()));
        *slot = Some((t.clone(), Instant::now()));
        t
    }
}

impl Pusher for Apns {
    fn push<'a>(&'a self, kind: Kind, sandbox: bool, token: &'a [u8]) -> Pin<Box<dyn Future<Output = Result<(), PushError>> + Send + 'a>> {
        Box::pin(async move {
            let host = if sandbox { "api.sandbox.push.apple.com" } else { "api.push.apple.com" };
            let hex: String = token.iter().map(|b| format!("{b:02x}")).collect();
            let now = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
            let req = self.http.post(format!("https://{host}/3/device/{hex}")).bearer_auth(self.token()).header("apns-priority", "10");
            let req = match kind {
                // A message wake is worth delivering for an hour (a phone that was off); one
                // notification on the lock screen however many came.
                Kind::Message => req.header("apns-topic", &self.topic).header("apns-push-type", "alert").header("apns-expiration", (now + 3600).to_string()).header("apns-collapse-id", "wake").body(MESSAGE),
                // A ring is now or never.
                Kind::Call => req.header("apns-topic", format!("{}.voip", self.topic)).header("apns-push-type", "voip").header("apns-expiration", "0").body(CALL),
            };
            let res = req.send().await.map_err(|_| PushError::Unavailable)?;
            match res.status().as_u16() {
                200 => Ok(()),
                410 => Err(PushError::Gone),
                429 => Err(PushError::Busy),
                400 => {
                    let why = res.text().await.unwrap_or_default();
                    if why.contains("BadDeviceToken") || why.contains("DeviceTokenNotForTopic") { Err(PushError::Gone) } else { Err(PushError::Unavailable) }
                }
                _ => Err(PushError::Unavailable),
            }
        })
    }
}
