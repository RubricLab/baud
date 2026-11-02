//! Status is a sentence (`Sentences.swift`): every word the apps show about reachability,
//! delivery and devices, made here once, so the phone says what the iPhone and the Mac say.

use crate::types::*;

pub fn path(p: &Path) -> String {
    match p {
        Path::Direct { ms: Some(ms) } => format!("Direct, {ms} ms"),
        Path::Direct { ms: None } => "Direct".into(),
        Path::Relay { name, .. } => format!("Relayed by {name}"),
        Path::Nearby => "Nearby".into(),
        Path::Waiting => "Waiting".into(),
        Path::Unreachable => "Unreachable".into(),
        Path::NotConnected => "Not connected".into(),
    }
}

pub fn is_live(p: &Path) -> bool {
    matches!(p, Path::Direct { .. } | Path::Relay { .. } | Path::Nearby)
}

/// "online, direct" · "last online 2 h ago" · "never online"
pub fn device(online: bool, p: &Path, last_online: Option<i64>) -> String {
    if online {
        return if is_live(p) { format!("online, {}", path(p).to_lowercase()) } else { "online".into() };
    }
    match last_online {
        Some(t) => format!("last online {}", ago(t)),
        None => "never online".into(),
    }
}

/// The row's second line: who is reachable and how.
pub fn contact(devices: &[Device]) -> String {
    let on: Vec<&Device> = devices.iter().filter(|d| d.online).collect();
    if let Some(d) = on.first() {
        return if on.len() > 1 { format!("online on {} devices", on.len()) } else { format!("online on their {}", d.kind.word()) };
    }
    match devices.iter().filter_map(|d| d.last_online).max() {
        Some(t) => format!("last online {}", ago(t)),
        None => "never online".into(),
    }
}

/// Under my last message: "read" · "delivered to Ana's iPhone" · "carried by Jo's Mac · waiting
/// for Ana's iPhone" · "sent, nobody online to carry it".
pub fn delivery(devices: &[DeviceDelivery]) -> String {
    if devices.is_empty() {
        return "only you".into();
    }
    let (mut read, mut carried) = (Vec::<String>::new(), Vec::<String>::new());
    let mut delivered_any = false;
    for d in devices {
        match &d.state {
            DeliveryState::Read => {
                if !read.contains(&d.person_name) {
                    read.push(d.person_name.clone());
                }
            }
            DeliveryState::Delivered => delivered_any = true,
            DeliveryState::Carried { .. } => {
                for c in &d.carriers {
                    if !carried.contains(c) {
                        carried.push(c.clone());
                    }
                }
            }
            DeliveryState::Sent => {}
        }
    }
    let mut people: Vec<&String> = devices.iter().map(|d| &d.person_name).collect();
    people.sort();
    people.dedup();
    let who = |d: &DeviceDelivery| format!("{}'s {}", d.person_name, d.device.kind.word());
    let mut parts: Vec<String> = vec![];
    if !read.is_empty() {
        parts.push(if people.len() == 1 { "read".into() } else { format!("read by {}", list(&read)) });
    }
    // A device that is read doesn't need to be listed as delivered or waiting.
    let unread: Vec<&DeviceDelivery> = devices.iter().filter(|d| !read.contains(&d.person_name)).collect();
    if !unread.is_empty() {
        let del: Vec<String> = unread.iter().filter(|d| d.state == DeliveryState::Delivered).map(|d| who(d)).collect();
        if !del.is_empty() {
            parts.push(format!("delivered to {}", list(&del)));
        }
        if !carried.is_empty() {
            parts.push(format!("carried by {}", list(&carried)));
        }
        let wait: Vec<String> = unread.iter().filter(|d| d.state != DeliveryState::Delivered).map(|d| who(d)).collect();
        if !wait.is_empty() {
            parts.push(format!("waiting for {}", list(&wait)));
        }
    }
    if parts.is_empty() {
        return "sent".into();
    }
    if read.is_empty() && !delivered_any && carried.is_empty() {
        return "sent, nobody online to carry it".into();
    }
    parts.join(" · ")
}

/// One word for the row: read > delivered > carried > sent.
pub fn best(devices: &[DeviceDelivery]) -> DeliveryState {
    if devices.iter().any(|d| d.state == DeliveryState::Read) {
        return DeliveryState::Read;
    }
    if devices.iter().any(|d| d.state == DeliveryState::Delivered) {
        return DeliveryState::Delivered;
    }
    devices.iter().find(|d| matches!(d.state, DeliveryState::Carried { .. })).map(|d| d.state.clone()).unwrap_or(DeliveryState::Sent)
}

/// The Network screen's row: "online, direct, 14 ms · record 3 s old via invite · holding 2 for you".
pub fn peer(p: &Peer) -> String {
    let mut parts = vec![p.device.sentence.clone()];
    if let Some(age) = p.record_age {
        let when = if age < 1000 { "fresh".to_owned() } else { ago(now_ms() - age) };
        parts.push(format!("record {when}{}", p.found_by.map(|f| format!(" via {}", f.as_str())).unwrap_or_default()));
    }
    if p.relaying {
        parts.push("relaying".into());
    }
    if p.holding_for_me > 0 {
        parts.push(format!("holding {} for you", p.holding_for_me));
    }
    if p.i_hold_for_it > 0 {
        parts.push(format!("you hold {} for it", p.i_hold_for_it));
    }
    parts.join(" · ")
}

pub fn carrying(envelopes: u32, bytes: u64, budget: u64, held: &[Held]) -> String {
    if envelopes == 0 {
        return "Holding nothing for anyone right now.".into();
    }
    let who: Vec<String> = held.iter().map(|h| format!("{} for {}", h.count, h.name)).collect();
    let whom = if who.is_empty() { String::new() } else { format!(": {}", list(&who)) };
    format!("Holding {envelopes} {} ({} of {}){whom}.", if envelopes == 1 { "envelope" } else { "envelopes" }, bytes_text(bytes), bytes_text(budget))
}

/// How long a disappearing message lasts, in the largest unit that fits it whole: "5 minutes",
/// "1 hour", "8 hours", "1 day", "1 week", "4 weeks".
pub fn disappear_after(seconds: i64) -> String {
    let (n, unit) = disappear_unit(seconds);
    format!("{n} {unit}{}", if n == 1 { "" } else { "s" })
}

/// The same, short, for a conversation's header: "5m", "1h", "8h", "1d", "1w", "4w".
pub fn disappear_short(seconds: i64) -> String {
    let (n, unit) = disappear_unit(seconds);
    format!("{n}{}", &unit[..1])
}

fn disappear_unit(seconds: i64) -> (i64, &'static str) {
    for (size, unit) in [(604_800, "week"), (86_400, "day"), (3600, "hour"), (60, "minute")] {
        if seconds >= size && seconds % size == 0 {
            return (seconds / size, unit);
        }
    }
    (seconds, "second")
}

/// The timeline's line when someone changes the setting: "Ana set messages to disappear 1 day
/// after they're read" · "You turned off disappearing messages".
pub fn disappear_line(by: &str, seconds: i64) -> String {
    if seconds > 0 { format!("{by} set messages to disappear {} after they're read", disappear_after(seconds)) } else { format!("{by} turned off disappearing messages") }
}

/// "a, b and c"
pub fn list(items: &[String]) -> String {
    match items.len() {
        0 => String::new(),
        1 => items[0].clone(),
        2 => format!("{} and {}", items[0], items[1]),
        n => format!("{} and {}", items[..n - 1].join(", "), items[n - 1]),
    }
}

pub fn now_ms() -> i64 {
    (crate::store::now() * 1000.0) as i64
}

pub fn ago(ms: i64) -> String {
    let s = (now_ms() - ms) as f64 / 1000.0;
    if s < 45.0 {
        "just now".into()
    } else if s < 5400.0 {
        format!("{} min ago", ((s / 60.0) as i64).max(1))
    } else if s < 86_400.0 {
        format!("{} h ago", (s / 3600.0) as i64)
    } else {
        format!("{} d ago", (s / 86_400.0) as i64)
    }
}

pub fn bytes_text(n: u64) -> String {
    let f = n as f64;
    if n < 1000 {
        format!("{n} B")
    } else if n < 1_000_000 {
        format!("{:.0} KB", f / 1000.0)
    } else if n < 1_000_000_000 {
        format!("{:.1} MB", f / 1_000_000.0)
    } else {
        format!("{:.2} GB", f / 1_000_000_000.0)
    }
}

/// "your Mac", "Ana's iPhone": a carrier's name, from its person and kind.
pub fn whose(mine: bool, person: &str, kind: &str) -> String {
    let word = DeviceKind::parse(kind).word();
    if mine { format!("your {word}") } else { format!("{person}'s {word}") }
}
