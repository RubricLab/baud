//! How often a phone may be woken, without accounts: counters in memory only, keyed by a keyed
//! hash of the push token (never the token) and by the ticket's random id, each gone within the
//! hour. A restart forgets them all, which is the point.

use hmac::{Hmac, Mac};
use sha2::Sha256;
use std::collections::HashMap;
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind { Message, Call }

#[derive(Debug, PartialEq, Eq)]
pub enum Verdict {
    /// Ask Apple.
    Send,
    /// The phone was just woken for a message: this one rides on that wake.
    Folded,
    /// Too many, from this ticket or for this phone.
    TooMany,
}

/// Messages: 6 a minute per ticket, 60 an hour per phone. Calls: one every 15 s per ticket, 20 an
/// hour per phone. Message wakes for one phone within 3 s are one wake.
const MSG_PER_TICKET_MIN: u32 = 6;
const MSG_PER_PHONE_HOUR: u32 = 60;
const CALL_GAP: Duration = Duration::from_secs(15);
const CALLS_PER_PHONE_HOUR: u32 = 20;
const FOLD: Duration = Duration::from_secs(3);
const MINUTE: Duration = Duration::from_secs(60);
const HOUR: Duration = Duration::from_secs(3600);

#[derive(Default)]
struct Window { start: Option<Instant>, n: u32 }

impl Window {
    fn take(&mut self, now: Instant, span: Duration, most: u32) -> bool {
        if self.start.is_none_or(|s| now.duration_since(s) >= span) { *self = Window { start: Some(now), n: 0 } }
        if self.n >= most { return false }
        self.n += 1;
        true
    }
    fn stale(&self, now: Instant, span: Duration) -> bool { self.start.is_none_or(|s| now.duration_since(s) >= span) }
}

#[derive(Default)]
struct Phone { messages: Window, calls: Window, last_message: Option<Instant> }

#[derive(Default)]
struct PerTicket { messages: Window, last_call: Option<Instant> }

pub struct Limits {
    secret: [u8; 32],
    phones: HashMap<[u8; 16], Phone>,
    tickets: HashMap<[u8; 16], PerTicket>,
}

impl Limits {
    /// `secret` keys the token hash; a fresh one each start is fine, since nothing outlives the process.
    pub fn new(secret: [u8; 32]) -> Self { Limits { secret, phones: HashMap::new(), tickets: HashMap::new() } }

    fn phone_key(&self, token: &[u8]) -> [u8; 16] {
        let mut m = Hmac::<Sha256>::new_from_slice(&self.secret).expect("any key length");
        m.update(token);
        m.finalize().into_bytes()[..16].try_into().expect("16 of 32")
    }

    pub fn check(&mut self, kind: Kind, token: &[u8], ticket: [u8; 16], now: Instant) -> Verdict {
        let pk = self.phone_key(token);
        let phone = self.phones.entry(pk).or_default();
        let t = self.tickets.entry(ticket).or_default();
        match kind {
            Kind::Message => {
                if phone.last_message.is_some_and(|l| now.duration_since(l) < FOLD) { return Verdict::Folded }
                if !t.messages.take(now, MINUTE, MSG_PER_TICKET_MIN) { return Verdict::TooMany }
                if !phone.messages.take(now, HOUR, MSG_PER_PHONE_HOUR) { return Verdict::TooMany }
                phone.last_message = Some(now);
                Verdict::Send
            }
            Kind::Call => {
                if t.last_call.is_some_and(|l| now.duration_since(l) < CALL_GAP) { return Verdict::TooMany }
                if !phone.calls.take(now, HOUR, CALLS_PER_PHONE_HOUR) { return Verdict::TooMany }
                t.last_call = Some(now);
                Verdict::Send
            }
        }
    }

    /// Drop every counter whose window has passed.
    pub fn sweep(&mut self, now: Instant) {
        self.phones.retain(|_, p| !(p.messages.stale(now, HOUR) && p.calls.stale(now, HOUR) && p.last_message.is_none_or(|l| now.duration_since(l) >= FOLD)));
        self.tickets.retain(|_, t| !(t.messages.stale(now, MINUTE) && t.last_call.is_none_or(|l| now.duration_since(l) >= CALL_GAP)));
    }

    pub fn len(&self) -> usize { self.phones.len() + self.tickets.len() }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_burst_of_messages_is_one_wake() {
        let mut l = Limits::new([1; 32]);
        let now = Instant::now();
        assert_eq!(l.check(Kind::Message, b"phone", [1; 16], now), Verdict::Send);
        for i in 1..20 { assert_eq!(l.check(Kind::Message, b"phone", [1; 16], now + Duration::from_millis(100 * i)), Verdict::Folded) }
        assert_eq!(l.check(Kind::Message, b"phone", [2; 16], now + Duration::from_secs(1)), Verdict::Folded);
    }

    #[test]
    fn one_ticket_gets_six_wakes_a_minute() {
        let mut l = Limits::new([1; 32]);
        let t0 = Instant::now();
        let sent = (0..10).filter(|i| l.check(Kind::Message, b"phone", [1; 16], t0 + Duration::from_secs(4 * i)) == Verdict::Send).count();
        assert_eq!(sent, 6);
        assert_eq!(l.check(Kind::Message, b"phone", [1; 16], t0 + Duration::from_secs(64)), Verdict::Send);
    }

    #[test]
    fn calls_are_spaced_and_capped() {
        let mut l = Limits::new([1; 32]);
        let t0 = Instant::now();
        assert_eq!(l.check(Kind::Call, b"phone", [1; 16], t0), Verdict::Send);
        assert_eq!(l.check(Kind::Call, b"phone", [1; 16], t0 + Duration::from_secs(5)), Verdict::TooMany);
        assert_eq!(l.check(Kind::Call, b"phone", [1; 16], t0 + Duration::from_secs(16)), Verdict::Send);
        let mut n = 2;
        for i in 0..40u64 { if l.check(Kind::Call, b"phone", [9; 16], t0 + Duration::from_secs(20 + 16 * i)) == Verdict::Send { n += 1 } }
        assert_eq!(n, 20);
    }

    #[test]
    fn nothing_outlives_its_window() {
        let mut l = Limits::new([1; 32]);
        let t0 = Instant::now();
        l.check(Kind::Message, b"phone", [1; 16], t0);
        l.check(Kind::Call, b"phone", [2; 16], t0);
        l.sweep(t0 + Duration::from_secs(30));
        assert!(l.len() > 0);
        l.sweep(t0 + HOUR);
        assert_eq!(l.len(), 0);
    }
}
