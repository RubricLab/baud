//! Messages for the lab, sent as baud sends them (apps/shared/Carry.swift, Crate.swift): on a
//! cached Small connection on its own ALPN, one stream per message, counted sent once the far
//! side has it (`delivered`); else to carriers (`post`). Arrivals print as the crate's inbox does:
//! `· inbox app: "<text>"`. Streams are read on every connection, dialed or accepted, as baud does.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use peer::identity::DeviceId;
use peer::policy::Class;
use peer::{Conn, ConnId, Peer};

pub const ALPN: &[u8] = b"lab-msg/1";

#[derive(Default)]
pub struct Messages {
    conns: Mutex<HashMap<DeviceId, Arc<Conn>>>,
}

impl Messages {
    /// `send <name> <text>`: to each of their devices.
    pub async fn send(self: &Arc<Self>, p: &Peer, name: &str, text: &str) {
        let Some(c) = p.contacts().into_iter().find(|c| c.name == name) else {
            return println!("send failed: no contact {name}");
        };
        for d in c.devices.iter().map(|d| d.device) {
            let t = Instant::now();
            let how = if self.direct(p, d, text).await {
                "direct"
            } else {
                match p.post(d, text.as_bytes().to_vec(), Duration::from_secs(14 * 86400)).await {
                    Ok(_) => "to carriers",
                    Err(e) => return println!("send to {} failed: {e}", d.short()),
                }
            };
            println!("sent {text} to {name}'s {} {how} in {} ms", d.short(), t.elapsed().as_millis());
        }
    }

    async fn direct(&self, p: &Peer, d: DeviceId, text: &str) -> bool {
        let cached = self.conns.lock().unwrap().get(&d).cloned();
        let conn = match cached {
            Some(c) => c,
            None => match p.connect(d, Class::Small, ALPN).await {
                Ok(c) => {
                    let c = Arc::new(c);
                    self.conns.lock().unwrap().insert(d, c.clone());
                    tokio::spawn(serve(c.clone()));
                    c
                }
                Err(_) => return false,
            },
        };
        let sent = async {
            let mut s = conn.open().await?;
            s.send(text.as_bytes()).await?;
            s.delivered().await
        };
        if sent.await.is_ok() {
            return true;
        }
        self.conns.lock().unwrap().remove(&d);
        false
    }

    /// An inbound message connection: kept, and served.
    pub async fn accept(self: &Arc<Self>, p: &Peer, id: ConnId) {
        let Ok(conn) = p.accept(id) else { return };
        let conn = Arc::new(conn);
        self.conns.lock().unwrap().insert(conn.identity().device, conn.clone());
        serve(conn).await;
    }
}

/// Every stream the far side opens on `conn` is one message.
async fn serve(conn: Arc<Conn>) {
    while let Ok(s) = conn.accept_stream().await {
        let (_, mut rx) = s.split();
        let mut text = Vec::new();
        while let Ok(Some(b)) = rx.recv(1 << 16).await {
            text.extend_from_slice(&b);
        }
        println!("· inbox app: {:?}", String::from_utf8_lossy(&text));
    }
}
