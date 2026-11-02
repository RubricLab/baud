//! One structured timing log per node, always on: a JSON line per milestone, never per packet.
//! `t` is monotonic ms since `open` began; durations are `ms`. Kept in a ring the app can read
//! (`Peer::trace`), and handed to a sink as it happens (`peer-node run --trace` prints it).
//!
//! | ev | when | fields |
//! |---|---|---|
//! | `open` | `open` returns | `ms`, `store_ms`, `blobs_ms`, `bind_ms`, `pid` |
//! | `online` | first connection after `open` | `ms` since open began, `device`, `path` |
//! | `wake` | first connection after `set_online(true)` that followed `set_online(false)` | `ms`, `device`, `path` |
//! | `dial` | a crate dial ends | `device`, `ms`, `handshake_ms`, `ok`, `path`, `rtt`, `why` (loop, wake, net, connect, add, link), `tried`, `err` |
//! | `stale` | a held connection failed its `Bind` and the new one replaced it | `device`, `ms` |
//! | `record` / `contact` | a fresher record / a new contact arrived | `device` or `user`, `via` |
//! | `inbox` | an envelope for me arrived | `id`, `from`, `via` (direct, carried) |
//! | `attach` / `detach` | a crate connection is kept / closes | `device`, `side`, `path`, `rtt`, `lived_ms` |
//! | `push` | a record push is acknowledged | `device`, `ms`, `ok` |
//! | `post` | an envelope I posted in this run is delivered | `ms`, `via` |
//! | `delivered` | any envelope from my outbox is delivered (also one posted before a restart) | `id`, `via` |
//! | `handoff` | an envelope leaves my outbox: to its device, or to these carriers | `id`, `to`, `direct`, `carriers` |
//! | `held` | a carrier was handed an envelope for someone else | `id`, `for`, `from`, `new`, `err` |
//! | `portmap` | a gateway mapping is held | `proto`, `external`, `ms`, `reused` |
//! | `nearby` | at open, with nearby on: whether this process may send mDNS multicast | `ok`, `err` |
//! | `net` | my addresses change: the OS's, iroh's, or the app says so | `addrs`, `source` (os, iroh, app) |
//! | `migrated` / `redialed` | after `net`, a connection answers again / is replaced | `device`, `ms` |
//! | `blob` | a fetch finishes | `hash`, `first_byte_ms`, `ms`, `bytes`, `mbps` |
//! | `panic` | anything panicked, on any thread (`record_panics`) | `msg`, `at`, `thread` |

use std::collections::VecDeque;
use std::sync::{Arc, Mutex, Once, Weak};
use std::time::Instant;

use serde_json::{Map, Value, json};
use crate::sync::Locked;

/// Lines kept for the app; the oldest go first.
pub const CAP: usize = 1024;

pub type Sink = Arc<dyn Fn(&str) + Send + Sync>;

pub struct Trace {
    t0: Instant,
    ring: Mutex<VecDeque<String>>,
    sink: Mutex<Option<Sink>>,
}

impl Default for Trace {
    fn default() -> Self {
        Self::new(Instant::now())
    }
}

impl Trace {
    pub fn new(t0: Instant) -> Self {
        Trace { t0, ring: Mutex::new(VecDeque::with_capacity(64)), sink: Mutex::new(None) }
    }

    /// Monotonic ms since the node began opening.
    pub fn t(&self) -> u64 {
        self.t0.elapsed().as_millis() as u64
    }

    pub fn since_open(&self, at: Instant) -> u64 {
        at.saturating_duration_since(self.t0).as_millis() as u64
    }

    /// One line: `{"t":…,"ev":…, fields…}`. `fields` must be a JSON object.
    pub fn emit(&self, ev: &str, fields: Value) {
        let mut m = Map::with_capacity(8);
        m.insert("t".into(), json!(self.t()));
        m.insert("ev".into(), json!(ev));
        if let Value::Object(f) = fields {
            m.extend(f);
        }
        let line = Value::Object(m).to_string();
        let sink = self.sink.locked().clone();
        {
            let mut ring = self.ring.locked();
            if ring.len() == CAP {
                ring.pop_front();
            }
            ring.push_back(line.clone());
        }
        if let Some(s) = sink {
            s(&line);
        }
    }

    /// A line into the ring alone, if it is free now: from a panic hook, which must not wait on a
    /// lock the panicking thread may hold, nor call the app.
    fn note(&self, ev: &str, fields: Value) {
        let mut m = Map::with_capacity(6);
        m.insert("t".into(), json!(self.t()));
        m.insert("ev".into(), json!(ev));
        if let Value::Object(f) = fields {
            m.extend(f);
        }
        if let Ok(mut ring) = self.ring.try_lock() {
            if ring.len() == CAP {
                ring.pop_front();
            }
            ring.push_back(Value::Object(m).to_string());
        }
    }

    /// Every line still in the ring, oldest first.
    pub fn lines(&self) -> Vec<String> {
        self.ring.locked().iter().cloned().collect()
    }

    pub fn set_sink(&self, sink: Option<Sink>) {
        *self.sink.locked() = sink;
    }
}

pub fn ms(since: Instant) -> u64 {
    since.elapsed().as_millis() as u64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ring_keeps_the_newest_and_lines_are_json() {
        let t = Trace::default();
        for i in 0..CAP + 5 {
            t.emit("dial", json!({ "i": i }));
        }
        let lines = t.lines();
        assert_eq!(lines.len(), CAP);
        let first: Value = serde_json::from_str(&lines[0]).unwrap();
        assert_eq!(first["i"], 5);
        assert_eq!(first["ev"], "dial");
        assert!(first["t"].is_u64());
    }
}

/// Every panic, on any thread, into each open node's trace (`ev: panic`), and on to the hook
/// before: a background task's panic used to leave nothing behind but a poisoned lock, and the
/// crash report that followed said nothing of it (baud 0.2.7).
pub fn record_panics(trace: &Arc<Trace>) {
    static TRACES: Mutex<Vec<Weak<Trace>>> = Mutex::new(Vec::new());
    static HOOK: Once = Once::new();
    TRACES.locked().push(Arc::downgrade(trace));
    HOOK.call_once(|| {
        let before = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            let msg = info.payload().downcast_ref::<&str>().map(|s| s.to_string()).or_else(|| info.payload().downcast_ref::<String>().cloned()).unwrap_or_default();
            let at = info.location().map(|l| format!("{}:{}", l.file(), l.line())).unwrap_or_default();
            let thread = std::thread::current().name().unwrap_or_default().to_owned();
            if let Ok(mut traces) = TRACES.try_lock() {
                traces.retain(|t| match t.upgrade() {
                    Some(t) => {
                        t.note("panic", json!({ "msg": msg, "at": at, "thread": thread }));
                        true
                    }
                    None => false,
                });
            }
            before(info);
        }));
    });
}
