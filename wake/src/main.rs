//! baud's wake relay. An iPhone that's asleep can be reached only through Apple, so a friend's
//! device that can't reach yours hands this relay the sealed ticket your phone gave it, and the
//! relay asks Apple to wake your phone. That's all it does.
//!
//! What it never has: accounts, a database, a log of requests, or a byte of any message. It opens
//! the ticket for the push token inside, checks the ticket's time and the limits, sends Apple the
//! same push it sends everyone, and forgets. Its limits live in memory and die with the process.
//!
//! ```text
//! POST /v1/wake   {"ticket": base64url, "kind": "message" | "call"}
//!                 202 sent (or folded into a wake just sent) · 400 not a ticket · 403 the ticket
//!                 doesn't allow that kind · 410 expired, unknown key, or the phone's gone: ask it
//!                 for a fresh one · 413 too big · 429 too many · 503 Apple unavailable
//! GET  /v1/key    {"id": 1, "key": base64url}: the key tickets are sealed to (pinned in the app)
//! GET  /health    ok
//! ```
//!
//! Environment: `WAKE_KEYS` ("1:<base64 private key>", comma-separated; the highest id is current),
//! `APNS_KEY` (the .p8's PEM), `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC` (the app's bundle id),
//! `PORT`. `wake keygen` prints a new key pair.

mod apns;
mod limits;
mod ticket;

use apns::{Apns, PushError, Pusher};
use axum::extract::{DefaultBodyLimit, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD as B64};
use base64::Engine;
use limits::{Kind, Limits, Verdict};
use serde::Deserialize;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

struct Relay {
    keys: Vec<(u8, ticket::PrivateKey)>,
    current: (u8, String),
    limits: Mutex<Limits>,
    pusher: Arc<dyn Pusher>,
}

#[derive(Deserialize)]
struct Wake { ticket: String, kind: String }

fn reply(code: StatusCode, word: &str) -> Response { (code, Json(serde_json::json!({ "result": word }))).into_response() }

fn now() -> u32 { SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as u32).unwrap_or(0) }

async fn wake(State(r): State<Arc<Relay>>, body: axum::body::Bytes) -> Response {
    let Ok(w) = serde_json::from_slice::<Wake>(&body) else { return reply(StatusCode::BAD_REQUEST, "not a wake") };
    let kind = match w.kind.as_str() { "message" => Kind::Message, "call" => Kind::Call, _ => return reply(StatusCode::BAD_REQUEST, "unknown kind") };
    let Some(bytes) = B64.decode(w.ticket.trim_end_matches('=')).ok().or_else(|| STANDARD.decode(&w.ticket).ok()) else { return reply(StatusCode::BAD_REQUEST, "not a ticket") };
    let t = match ticket::open(&bytes, &r.keys, now()) {
        Ok(t) => t,
        Err(ticket::Refused::Malformed) => return reply(StatusCode::BAD_REQUEST, "not a ticket"),
        Err(_) => return reply(StatusCode::GONE, "ask for a fresh ticket"),
    };
    let (flag, token) = match kind { Kind::Message => (ticket::MESSAGES, &t.alert), Kind::Call => (ticket::CALLS, &t.voip) };
    if !t.may(flag) || token.is_empty() { return reply(StatusCode::FORBIDDEN, "not with this ticket") }
    let verdict = r.limits.lock().unwrap_or_else(|p| p.into_inner()).check(kind, token, t.id, Instant::now());
    match verdict {
        Verdict::Folded => reply(StatusCode::ACCEPTED, "folded"),
        Verdict::TooMany => reply(StatusCode::TOO_MANY_REQUESTS, "too many"),
        Verdict::Send => match r.pusher.push(kind, t.sandbox(), token).await {
            Ok(()) => reply(StatusCode::ACCEPTED, "sent"),
            Err(PushError::Gone) => reply(StatusCode::GONE, "ask for a fresh ticket"),
            Err(PushError::Busy) => reply(StatusCode::TOO_MANY_REQUESTS, "too many"),
            Err(PushError::Unavailable) => reply(StatusCode::SERVICE_UNAVAILABLE, "try later"),
        },
    }
}

fn router(r: Arc<Relay>) -> Router {
    Router::new()
        .route("/v1/wake", post(wake))
        .route("/v1/key", get(|State(r): State<Arc<Relay>>| async move { Json(serde_json::json!({ "id": r.current.0, "key": r.current.1 })) }))
        .route("/health", get(|| async { "ok" }))
        .layer(DefaultBodyLimit::max(2048))
        .with_state(r)
}

fn keys(spec: &str) -> Result<Vec<(u8, ticket::PrivateKey)>, String> {
    spec.split(',').filter(|s| !s.trim().is_empty()).map(|s| {
        let (id, k) = s.trim().split_once(':').ok_or("WAKE_KEYS is id:key,…")?;
        let id: u8 = id.parse().map_err(|_| "a key id is 1–255")?;
        let raw = STANDARD.decode(k).or_else(|_| B64.decode(k)).map_err(|_| "a key isn't base64")?;
        Ok((id, ticket::private_from(&raw).ok_or("a key isn't 32 bytes of X25519")?))
    }).collect()
}

fn relay(keys: Vec<(u8, ticket::PrivateKey)>, pusher: Arc<dyn Pusher>) -> Arc<Relay> {
    let (id, key) = keys.iter().max_by_key(|(id, _)| *id).expect("at least one key");
    let current = (*id, B64.encode(ticket::bytes_of(&ticket::public_of(key))));
    let mut secret = [0u8; 32];
    getrandom(&mut secret);
    Arc::new(Relay { current, keys, limits: Mutex::new(Limits::new(secret)), pusher })
}

/// The token hash's key: fresh each start, from the system's randomness (an X25519 key is 32
/// random bytes).
fn getrandom(out: &mut [u8; 32]) { out.copy_from_slice(&ticket::bytes_of(&ticket::keypair().0)); }

fn env(name: &str) -> Result<String, String> { std::env::var(name).map_err(|_| format!("{name} is not set")) }

#[tokio::main]
async fn main() -> Result<(), String> {
    if std::env::args().nth(1).as_deref() == Some("keygen") {
        let (sk, pk) = ticket::keypair();
        println!("WAKE_KEYS=1:{}\npublic key (pin in the app): {}", STANDARD.encode(ticket::bytes_of(&sk)), B64.encode(ticket::bytes_of(&pk)));
        return Ok(());
    }
    let apns = Apns::new(&env("APNS_KEY")?.replace("\\n", "\n"), env("APNS_KEY_ID")?, env("APNS_TEAM_ID")?, env("APNS_TOPIC")?)?;
    let r = relay(keys(&env("WAKE_KEYS")?)?, Arc::new(apns));
    let sweeper = r.clone();
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_secs(300)).await;
            sweeper.limits.lock().unwrap_or_else(|p| p.into_inner()).sweep(Instant::now());
        }
    });
    let port = std::env::var("PORT").unwrap_or_else(|_| "8080".into());
    let listener = tokio::net::TcpListener::bind(format!("[::]:{port}")).await.map_err(|e| e.to_string())?;
    // The only line it ever prints: no request is logged.
    println!("wake relay on :{port}, key {}", r.current.0);
    axum::serve(listener, router(r)).await.map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::Request;
    use http_body_util::BodyExt;
    use std::future::Future;
    use std::pin::Pin;
    use tower::ServiceExt;

    #[derive(Default)]
    struct Fake { sent: Mutex<Vec<(Kind, bool, Vec<u8>)>>, gone: bool }
    impl Pusher for Fake {
        fn push<'a>(&'a self, kind: Kind, sandbox: bool, token: &'a [u8]) -> Pin<Box<dyn Future<Output = Result<(), PushError>> + Send + 'a>> {
            Box::pin(async move {
                if self.gone { return Err(PushError::Gone) }
                self.sent.lock().unwrap().push((kind, sandbox, token.to_vec()));
                Ok(())
            })
        }
    }

    fn setup(gone: bool) -> (Router, Arc<Fake>, ticket::PublicKey) {
        let (sk, pk) = ticket::keypair();
        let fake = Arc::new(Fake { gone, ..Default::default() });
        (router(relay(vec![(1, sk)], fake.clone())), fake, pk)
    }

    fn sealed(pk: &ticket::PublicKey, flags: u8, expires: u32, id: u8) -> String {
        B64.encode(ticket::Ticket { flags, expires, id: [id; 16], alert: vec![0xaa; 32], voip: vec![0xbb; 32] }.seal(1, pk))
    }

    async fn post(app: &Router, body: String) -> (u16, String) {
        let res = app.clone().oneshot(Request::post("/v1/wake").header("content-type", "application/json").body(Body::from(body)).unwrap()).await.unwrap();
        let code = res.status().as_u16();
        (code, String::from_utf8(res.into_body().collect().await.unwrap().to_bytes().to_vec()).unwrap())
    }

    fn wake_body(ticket: &str, kind: &str) -> String { serde_json::json!({ "ticket": ticket, "kind": kind }).to_string() }

    #[tokio::test]
    async fn a_ticket_wakes_its_phone_once_per_burst() {
        let (app, fake, pk) = setup(false);
        let t = sealed(&pk, ticket::MESSAGES | ticket::CALLS | ticket::SANDBOX, now() + 3600, 1);
        assert_eq!(post(&app, wake_body(&t, "message")).await.0, 202);
        for _ in 0..5 { assert_eq!(post(&app, wake_body(&t, "message")).await, (202, r#"{"result":"folded"}"#.into())) }
        assert_eq!(post(&app, wake_body(&t, "call")).await.0, 202);
        let sent = fake.sent.lock().unwrap().clone();
        assert_eq!(sent, vec![(Kind::Message, true, vec![0xaa; 32]), (Kind::Call, true, vec![0xbb; 32])]);
    }

    #[tokio::test]
    async fn refusals_say_what_to_do() {
        let (app, fake, pk) = setup(false);
        assert_eq!(post(&app, wake_body(&sealed(&pk, ticket::MESSAGES, now() - 1, 1), "message")).await.0, 410);
        assert_eq!(post(&app, wake_body(&sealed(&pk, ticket::MESSAGES, now() + 60, 1), "call")).await.0, 403);
        assert_eq!(post(&app, wake_body("AAAA", "message")).await.0, 400);
        assert_eq!(post(&app, "{".into()).await.0, 400);
        assert_eq!(post(&app, wake_body(&sealed(&pk, ticket::MESSAGES, now() + 60, 1), "page")).await.0, 400);
        let (other, _, _) = setup(false);
        assert_eq!(post(&other, wake_body(&sealed(&pk, ticket::MESSAGES, now() + 60, 1), "message")).await.0, 400);
        assert_eq!(post(&app, "x".repeat(4096)).await.0, 413);
        assert!(fake.sent.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn a_phone_apple_no_longer_knows_kills_the_ticket() {
        let (app, _, pk) = setup(true);
        assert_eq!(post(&app, wake_body(&sealed(&pk, ticket::MESSAGES, now() + 60, 1), "message")).await.0, 410);
    }

    #[tokio::test]
    async fn the_key_is_public() {
        let (app, _, pk) = setup(false);
        let res = app.oneshot(Request::get("/v1/key").body(Body::empty()).unwrap()).await.unwrap();
        let v: serde_json::Value = serde_json::from_slice(&res.into_body().collect().await.unwrap().to_bytes()).unwrap();
        assert_eq!(v["key"], B64.encode(ticket::bytes_of(&pk)));
    }
}
