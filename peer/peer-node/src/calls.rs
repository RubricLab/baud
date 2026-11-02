//! Calls for the lab, shaped like baud's: a Live connection on its own ALPN, one stream for
//! signals, a datagram every 20 ms each way for the media. A call ends when its connection does,
//! said once: `· call ended: <why> (<secs> s in)`. One call at a time.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use peer::policy::Class;
use peer::{Conn, ConnId, Peer, SendHalf};

pub const ALPN: &[u8] = b"lab-call/1";

#[derive(Default)]
pub struct Calls {
    current: Mutex<Option<Arc<Call>>>,
}

struct Call {
    conn: Conn,
    tx: tokio::sync::Mutex<SendHalf>,
    who: String,
    started: Instant,
    ended: AtomicBool,
    heard: AtomicU64,
}

impl Calls {
    /// `call <name> [device]`: dial their device whose id starts so, else their first.
    pub async fn dial(self: &Arc<Self>, p: &Peer, arg: &str) {
        let (name, which) = arg.split_once(' ').unwrap_or((arg, ""));
        let devices = p.contacts().into_iter().find(|c| c.name == name).map(|c| c.devices).unwrap_or_default();
        let Some(device) = devices.iter().map(|d| d.device).find(|d| d.short().starts_with(which)) else {
            println!("call failed: no contact {name} with a device {which}");
            return;
        };
        let t = Instant::now();
        let conn = match p.connect(device, Class::Live, ALPN).await {
            Ok(c) => c,
            Err(e) => return println!("call failed: {e} in {} ms", t.elapsed().as_millis()),
        };
        let stream = match conn.open().await {
            Ok(s) => s,
            Err(e) => return println!("call failed: {e} in {} ms", t.elapsed().as_millis()),
        };
        let (mut tx, rx) = stream.split();
        // The far side sees the stream only once bytes arrive on it.
        if let Err(e) = tx.send(b"ring").await {
            return println!("call failed: {e} in {} ms", t.elapsed().as_millis());
        }
        println!("· call up with {name} via {} in {} ms", conn.path(), t.elapsed().as_millis());
        self.start(conn, tx, rx, name.to_owned());
    }

    /// An inbound call: answered.
    pub async fn answer(self: &Arc<Self>, p: &Peer, id: ConnId) {
        let Ok(conn) = p.accept(id) else { return };
        let who = conn.identity().device.short();
        let Ok(stream) = conn.accept_stream().await else { return };
        println!("· call from {who} via {}", conn.path());
        let (tx, rx) = stream.split();
        self.start(conn, tx, rx, who);
    }

    /// `hangup`: the last signal, a beat, then the connection, as baud does.
    pub async fn hang_up(&self) {
        let Some(call) = self.current.lock().unwrap().clone() else { return };
        let _ = call.tx.lock().await.send(b"end").await;
        tokio::time::sleep(Duration::from_millis(400)).await;
        call.end("I hung up");
    }

    /// `callstat`: datagrams heard on the current call.
    pub fn stat(&self) {
        match self.current.lock().unwrap().as_ref() {
            Some(c) => println!("call with {}: heard {} datagrams, {}", c.who, c.heard.load(Ordering::Relaxed), if c.ended.load(Ordering::Relaxed) { "ended" } else { "on" }),
            None => println!("no call"),
        }
    }

    fn start(self: &Arc<Self>, conn: Conn, tx: SendHalf, mut rx: peer::RecvHalf, who: String) {
        let call = Arc::new(Call { conn, tx: tokio::sync::Mutex::new(tx), who, started: Instant::now(), ended: AtomicBool::new(false), heard: AtomicU64::new(0) });
        *self.current.lock().unwrap() = Some(call.clone());
        let media = call.clone();
        tokio::spawn(async move {
            while !media.ended.load(Ordering::Relaxed) && media.conn.send_datagram(bytes::Bytes::from_static(&[0u8; 160])).is_ok() {
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        });
        let heard = call.clone();
        tokio::spawn(async move {
            loop {
                match heard.conn.recv_datagram().await {
                    Ok(_) => {
                        if heard.heard.fetch_add(1, Ordering::Relaxed) == 0 {
                            println!("· media from {}", heard.who);
                        }
                    }
                    Err(e) => return heard.end(&format!("connection closed ({e})")),
                }
            }
        });
        tokio::spawn(async move {
            loop {
                match rx.recv(1024).await {
                    Ok(Some(b)) if b.as_ref() == b"end" => return call.end("they hung up"),
                    Ok(Some(_)) => {}
                    Ok(None) => return call.end("their stream ended"),
                    Err(e) => return call.end(&format!("connection closed ({e})")),
                }
            }
        });
    }
}

impl Call {
    fn end(&self, why: &str) {
        if !self.ended.swap(true, Ordering::Relaxed) {
            println!("· call ended: {why} ({:.1} s in)", self.started.elapsed().as_secs_f64());
            self.conn.close("end");
        }
    }
}
