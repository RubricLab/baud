//! Where I am, for the people in a chat I chose to share it with, and where they are for me
//! (`Places.swift`). A share is per chat and has an end (an hour, the end of the day, or when I
//! stop). Each fix goes straight to the chat's online devices, sealed with the chat's key like a
//! message, and is never carried, kept in the chat's history, or sent anywhere else: a place is
//! news now or never, and a device that comes online gets the latest at once.

use std::collections::HashMap;

use crate::core::{Core, short};
use crate::store::now;
use crate::types::*;
use crate::wire::{Frame, WirePlace};

fn ms(s: f64) -> i64 {
    (s * 1000.0) as i64
}

impl Core {
    /// Share my location in this chat until then (ms; none: until I stop). The last fix goes at once.
    pub fn share_place(&self, conv: &str, until: Option<i64>) {
        let v = until.map(|u| crate::json::swift_double(u as f64 / 1000.0)).unwrap_or_else(|| "always".into());
        self.store.run("insert or replace into me(k,v) values(?,?)", &[&format!("share:{conv}"), &v]);
        self.log(format!("sharing my location in {} {}", short(conv), if until.is_some() { "for a while" } else { "until I stop" }));
        self.emit(Change::Places { conv: conv.into() });
        self.send_place(conv, None);
    }

    /// Stop sharing in this chat: everyone in it hears so, and my place leaves their screens.
    pub fn stop_sharing(&self, conv: &str) {
        if !self.shares().contains_key(conv) {
            return;
        }
        self.store.run("delete from me where k=?", &[&format!("share:{conv}")]);
        let fix = self.st().last_fix;
        if let Some((lat, lon, accuracy, _)) = fix {
            let t = now();
            let stop = WirePlace { user: self.user(), device: self.device(), lat, lon, accuracy, at: t, until: Some(t - 1.0) };
            self.post_place(stop, conv, None);
        }
        self.emit(Change::Places { conv: conv.into() });
    }

    /// The chats I share in, and until when in unix seconds (none: until I stop). A share whose
    /// time is up is gone.
    fn shares(&self) -> HashMap<ConversationId, Option<f64>> {
        let t = now();
        let mut out = HashMap::new();
        for r in self.store.query("select k, v from me where k like 'share:%'", &[]) {
            let (Some(k), Some(v)) = (r.string("k"), r.string("v")) else { continue };
            let until = if v == "always" { None } else { Some(v.parse::<f64>().unwrap_or(0.0)) };
            if until.map(|u| u > t).unwrap_or(true) {
                out.insert(k["share:".len()..].to_owned(), until);
            } else {
                self.store.run("delete from me where k=?", &[&k]);
            }
        }
        out
    }

    pub fn sharing(&self) -> Vec<Share> {
        let mut v: Vec<Share> = self.shares().into_iter().map(|(conv, u)| Share { conv, until: u.map(ms) }).collect();
        v.sort_by(|a, b| a.conv.cmp(&b.conv));
        v
    }

    /// Whether any chat wants my location: the app keeps its location service on only then.
    pub fn wants_place(&self) -> bool {
        !self.shares().is_empty()
    }

    /// A new fix from this device's location service: to every chat I share in.
    pub fn moved(&self, lat: f64, lon: f64, accuracy: f64) {
        self.st().last_fix = Some((lat, lon, accuracy, now()));
        for conv in self.shares().into_keys() {
            self.send_place(&conv, None);
        }
    }

    /// The people sharing their place with me in this chat, the latest of each, newest first.
    pub fn places(&self, conv: &str) -> Vec<Place> {
        let t = now();
        let mut st = self.st();
        let Some(all) = st.held_places.get_mut(conv) else { return vec![] };
        all.retain(|_, p| !p.over(t));
        let mut v: Vec<Place> = all.values().map(|p| Place { user: p.user.clone(), device: p.device.clone(), lat: p.lat, lon: p.lon, accuracy: p.accuracy, at: ms(p.at), until: p.until.map(ms) }).collect();
        v.sort_by(|a, b| b.at.cmp(&a.at));
        v
    }

    /// My latest fix to this chat's online devices (or only `to`, one that just came online).
    fn send_place(&self, conv: &str, to: Option<&str>) {
        let Some(until) = self.shares().get(conv).copied() else { return };
        let Some((lat, lon, accuracy, at)) = self.st().last_fix else { return };
        self.post_place(WirePlace { user: self.user(), device: self.device(), lat, lon, accuracy, at, until }, conv, to);
    }

    /// Direct only: a device that isn't online now gets the latest when it comes.
    fn post_place(&self, p: WirePlace, conv: &str, to: Option<&str>) {
        if !self.is_online() {
            return;
        }
        let me = self.device();
        let frame = Frame::Place(conv.to_owned(), p);
        for d in self.member_devices(conv) {
            if d == me || to.map(|t| t != d).unwrap_or(false) || !self.net.is_online(&d) {
                continue;
            }
            let bytes = self.seal(&frame, Some(conv), false);
            let core = self.arc();
            self.spawn(async move {
                core.send_to(&bytes, &d).await;
            });
        }
    }

    /// A member's place: only their own (the sender's user and device), only in a chat we are
    /// both in; kept until their share ends, gone when they stop.
    pub(crate) fn keep_place(&self, p: WirePlace, conv: &str, from: &str) {
        let member = |u: &str| self.store.int("select count(*) as n from members where conv=? and user=?", &[&conv, &u]) > 0;
        if self.user_of(from).as_deref() != Some(p.user.as_str()) || p.device != from || !member(&self.user()) || !member(&p.user) {
            self.log(format!("a place from {} refused", short(from)));
            return;
        }
        {
            let mut st = self.st();
            let held = st.held_places.entry(conv.to_owned()).or_default();
            if p.over(now()) {
                held.remove(&p.user);
            } else if held.get(&p.user).map(|h| h.at <= p.at).unwrap_or(true) {
                held.insert(p.user.clone(), p);
            }
        }
        self.emit(Change::Places { conv: conv.into() });
    }

    /// A device came online: the chats I share in that it's part of get my latest fix.
    pub(crate) fn places_on_connect(&self, d: &str) {
        for conv in self.shares().into_keys() {
            if self.member_devices(&conv).iter().any(|m| m == d) {
                self.send_place(&conv, Some(d));
            }
        }
    }
}
