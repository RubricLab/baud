//! The link format, owned here and nowhere else. `https://<host>/add#<frag>` or `<scheme>://add#<frag>`;
//! everything after `#` never reaches a server. Two kinds, one use, one hour, carrying the inviter's
//! name and a device to meet at (a helper when one exists, so the chat that carried the link never
//! learns the inviter's IP); and a third, a reply to a friend link that could not reach its maker
//! (`Kind::Reply`). `vectors/links.json` is the contract; `js/parse-link.js` reads the same
//! vectors without the native module.
//!
//! Three spellings of one link, all read by `parse`: dotted (`peer1.f.…`, the first), dotless (one
//! base64url token, 0.2.10) and grouped (`Link::grouped`, 0.2.19), which `format` writes. Only the
//! grouped one survives the apps people send links through: Apple's link detector (Messages, Mail,
//! Notes) drops everything after the last break before a run of more than 301 letters and digits,
//! and a link naming a relay had runs of 400 and more, so it arrived cut after its expiry or its
//! `#` ("not a baud link").

use std::net::{IpAddr, SocketAddr};

use data_encoding::{BASE32_NOPAD, BASE64URL_NOPAD as B64};
use serde::{Deserialize, Serialize};

use crate::identity::{DeviceId, Secret, Sig, UserId, hex};
use crate::{Error, Result};

pub const VERSION: &str = "peer1";
pub const MAX_NAME_BYTES: usize = 64;
/// The dotless form's first byte: `VERSION` (`Link::dotless`).
const DOTLESS: u8 = 1;
/// The grouped form's first byte (`Link::grouped`): the dotless fields with `meet` packed.
const GROUPED: u8 = 2;
/// Letters and digits between dashes in the grouped form: far under the 301 a detector allows,
/// and 30 bytes each.
const GROUP: usize = 48;
/// Friend links: one hour. Device links: ten minutes; the person is standing at both screens.
pub const FRIEND_TTL_SECS: u64 = 3600;
pub const DEVICE_TTL_SECS: u64 = 600;
/// Replies: fifteen minutes, and never past the link they answer.
pub const REPLY_TTL_SECS: u64 = 900;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Kind {
    /// Two people become contacts. Mutual, always.
    Friend,
    /// The opener becomes one of the inviter's own devices, after confirmation on the inviter's screen.
    Device,
    /// The answer to a friend link whose maker its redeemer could not reach: the redeemer's name,
    /// user and a device to meet at, with `reply_secret` of the link's secret, so only a device
    /// of its maker's that holds that invite accepts it. Opening it, the maker dials the redeemer
    /// while the redeemer dials the maker, and both networks open toward each other.
    Reply,
}

impl Kind {
    fn tag(self) -> &'static str {
        match self {
            Kind::Friend => "f",
            Kind::Device => "m",
            Kind::Reply => "r",
        }
    }
    fn from_tag(s: &str) -> Result<Self> {
        match s {
            "f" => Ok(Kind::Friend),
            "m" => Ok(Kind::Device),
            "r" => Ok(Kind::Reply),
            _ => Err(Error::Encoding),
        }
    }
}

/// The device to dial to redeem the link, and how. `addrs` are `ip:port`, `[v6]:port` or
/// `relay=<url>`; the crate turns them into an iroh `EndpointAddr`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Meet {
    pub device: DeviceId,
    pub addrs: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Link {
    pub kind: Kind,
    pub name: String,
    pub user: UserId,
    /// Unix seconds.
    pub expires: u64,
    pub meet: Meet,
    pub secret: [u8; 32],
}

impl Link {
    pub fn expired(&self, now_secs: u64) -> bool {
        now_secs >= self.expires
    }

    /// The fragment alone, without a host. A name over 64 bytes is cut at a UTF-8 boundary.
    pub fn fragment(&self) -> String {
        let name = truncate(&self.name);
        let meet = self.meet_text();
        [
            VERSION.to_owned(),
            self.kind.tag().to_owned(),
            B64.encode(name.as_bytes()),
            B64.encode(&self.user.0),
            self.expires.to_string(),
            B64.encode(meet.as_bytes()),
            B64.encode(&self.secret),
        ]
        .join(".")
    }

    /// The same fields as one base64url token (0.2.10), with no dot for a chat app or an
    /// autolinker to take for the end of a sentence: `DOTLESS`, the kind's tag, the name's length
    /// and bytes, user, expires (big-endian), secret, then `meet` to the end. `parse` reads it.
    pub fn dotless(&self) -> String {
        let name = truncate(&self.name).as_bytes();
        let mut b = vec![DOTLESS, self.kind.tag().as_bytes()[0], name.len() as u8];
        b.extend_from_slice(name);
        b.extend_from_slice(&self.user.0);
        b.extend_from_slice(&self.expires.to_be_bytes());
        b.extend_from_slice(&self.secret);
        b.extend_from_slice(self.meet_text().as_bytes());
        B64.encode(&b)
    }

    /// The form `format` writes (0.2.19): `GROUPED`, the kind's tag, the name's length and bytes,
    /// user, expires (big-endian), secret, then `meet` packed (`pack_meet`), as lowercase base32
    /// in dash-joined groups of `GROUP`. Letters and digits only between the dashes: no dot or
    /// underscore for a chat app, an autolinker or Markdown to end the link at or format, any case
    /// reads, and with a relay in it under half the length of the other two.
    pub fn grouped(&self) -> String {
        let name = truncate(&self.name).as_bytes();
        let mut b = vec![GROUPED, self.kind.tag().as_bytes()[0], name.len() as u8];
        b.extend_from_slice(name);
        b.extend_from_slice(&self.user.0);
        b.extend_from_slice(&self.expires.to_be_bytes());
        b.extend_from_slice(&self.secret);
        b.extend_from_slice(&pack_meet(&self.meet, self.expires));
        let t = BASE32_NOPAD.encode(&b).to_ascii_lowercase();
        t.as_bytes().chunks(GROUP).map(|c| std::str::from_utf8(c).expect("base32 is ascii")).collect::<Vec<_>>().join("-")
    }

    /// `device;addr;addr…`, the device in hex.
    fn meet_text(&self) -> String {
        let mut s = self.meet.device.to_hex();
        for a in &self.meet.addrs {
            s.push(';');
            s.push_str(a);
        }
        s
    }
}

/// `prefix` is `https://baud.rubric.sh/add` or `baud://add`; the fragment follows `#`, grouped.
pub fn format(link: &Link, prefix: &str) -> String {
    format!("{prefix}#{}", link.grouped())
}

/// Accepts a full URL, a scheme URL or a bare fragment, grouped, dotted or dotless. Does not check
/// expiry: `Link::expired` does.
pub fn parse(s: &str) -> Result<Link> {
    let frag = s.trim();
    let frag = match frag.rfind('#') {
        Some(i) => &frag[i + 1..],
        None => frag,
    };
    if let Some(b) = unbase32(frag).filter(|b| b.first() == Some(&GROUPED)) {
        return parse_grouped(&b);
    }
    if !frag.contains('.') {
        return parse_dotless(frag);
    }
    let fields: Vec<&str> = frag.split('.').collect();
    if fields.len() != 7 {
        return Err(Error::Encoding);
    }
    if fields[0] != VERSION {
        return Err(Error::Encoding);
    }
    let kind = Kind::from_tag(fields[1])?;
    let name = B64.decode(fields[2].as_bytes()).map_err(|_| Error::Encoding)?;
    if name.len() > MAX_NAME_BYTES {
        return Err(Error::Encoding);
    }
    let name = String::from_utf8(name).map_err(|_| Error::Encoding)?;
    let user = bytes32(fields[3])?;
    let expires: u64 = fields[4].parse().map_err(|_| Error::Encoding)?;
    if fields[4] != expires.to_string() {
        return Err(Error::Encoding);
    }
    let meet = B64.decode(fields[5].as_bytes()).map_err(|_| Error::Encoding)?;
    let meet = meet_of(&String::from_utf8(meet).map_err(|_| Error::Encoding)?)?;
    let secret = bytes32(fields[6])?;
    Ok(Link { kind, name, user: UserId(user), expires, meet, secret })
}

fn parse_dotless(frag: &str) -> Result<Link> {
    let b = B64.decode(frag.as_bytes()).map_err(|_| Error::Encoding)?;
    let [version, tag, n, rest @ ..] = b.as_slice() else { return Err(Error::Encoding) };
    let n = *n as usize;
    if *version != DOTLESS || n > MAX_NAME_BYTES || rest.len() < n + 32 + 8 + 32 {
        return Err(Error::Encoding);
    }
    let kind = Kind::from_tag(std::str::from_utf8(&[*tag]).map_err(|_| Error::Encoding)?)?;
    let (name, rest) = rest.split_at(n);
    let name = String::from_utf8(name.to_vec()).map_err(|_| Error::Encoding)?;
    let (user, rest) = rest.split_at(32);
    let (expires, rest) = rest.split_at(8);
    let (secret, meet) = rest.split_at(32);
    let meet = meet_of(std::str::from_utf8(meet).map_err(|_| Error::Encoding)?)?;
    let bytes = |b: &[u8]| -> [u8; 32] { b.try_into().expect("split at 32") };
    Ok(Link { kind, name, user: UserId(bytes(user)), expires: u64::from_be_bytes(expires.try_into().expect("split at 8")), meet, secret: bytes(secret) })
}

/// The grouped form's bytes: base32 in one case, the dashes (and any spaces or line breaks a
/// copy picked up) dropped. None for anything else, a dotless token among them: its first two
/// characters, `A` and a capital, decode to 5, never `GROUPED`.
fn unbase32(frag: &str) -> Option<Vec<u8>> {
    let t: String = frag.chars().filter(|c| *c != '-' && !c.is_whitespace()).collect();
    let lower = t.bytes().all(|c| matches!(c, b'a'..=b'z' | b'2'..=b'7'));
    let upper = t.bytes().all(|c| matches!(c, b'A'..=b'Z' | b'2'..=b'7'));
    if t.is_empty() || !(lower || upper) {
        return None;
    }
    BASE32_NOPAD.decode(t.to_ascii_uppercase().as_bytes()).ok()
}

fn parse_grouped(b: &[u8]) -> Result<Link> {
    let [_, tag, n, rest @ ..] = b else { return Err(Error::Encoding) };
    let n = *n as usize;
    if n > MAX_NAME_BYTES || rest.len() < n + 32 + 8 + 32 + 32 + 1 {
        return Err(Error::Encoding);
    }
    let kind = Kind::from_tag(std::str::from_utf8(&[*tag]).map_err(|_| Error::Encoding)?)?;
    let (name, rest) = rest.split_at(n);
    let name = String::from_utf8(name.to_vec()).map_err(|_| Error::Encoding)?;
    let (user, rest) = rest.split_at(32);
    let (expires, rest) = rest.split_at(8);
    let (secret, meet) = rest.split_at(32);
    let expires = u64::from_be_bytes(expires.try_into().expect("split at 8"));
    let bytes = |b: &[u8]| -> [u8; 32] { b.try_into().expect("split at 32") };
    Ok(Link { kind, name, user: UserId(bytes(user)), expires, meet: unpack_meet(meet, expires)?, secret: bytes(secret) })
}

/// `meet` in the grouped form: the device (32), the meet token its relay URLs carry, once, then
/// each address in a few bytes. The token: 0, none; 1 and its signature, when its device is the
/// meet device and its expiry the link's (`meet_token`); 2 and all 104 bytes. An address: 4 or 6
/// and the IP and port (`ip:port`, `[v6]:port`); 0x14/0x16 the same as `relay=http://…/`, 0x34/
/// 0x36 with `?m=<token>`; 1, a two-byte length and the text, for any address that doesn't come
/// back from those byte for byte.
fn pack_meet(meet: &Meet, expires: u64) -> Vec<u8> {
    let mut b = meet.device.0.to_vec();
    let token = meet.addrs.iter().find_map(|a| a.split_once("?m=").map(|(_, t)| t)).filter(|t| B64.decode(t.as_bytes()).is_ok_and(|t| t.len() == 104));
    match token.map(|t| B64.decode(t.as_bytes()).expect("checked")) {
        Some(t) if t[..32] == meet.device.0 && t[32..40] == expires.to_le_bytes() => {
            b.push(1);
            b.extend_from_slice(&t[40..]);
        }
        Some(t) => {
            b.push(2);
            b.extend_from_slice(&t);
        }
        None => b.push(0),
    }
    for a in &meet.addrs {
        match pack_addr(a, token).filter(|p| unpack_addr(p, token).is_some_and(|(back, _)| back == *a)) {
            Some(p) => b.extend_from_slice(&p),
            None => {
                b.push(1);
                b.extend_from_slice(&(a.len().min(u16::MAX as usize) as u16).to_be_bytes());
                b.extend_from_slice(&a.as_bytes()[..a.len().min(u16::MAX as usize)]);
            }
        }
    }
    b
}

/// An address in a few bytes, if it has one of the short shapes; `pack_meet` keeps it only if it
/// comes back the same.
fn pack_addr(a: &str, token: Option<&str>) -> Option<Vec<u8>> {
    let sock = |s: SocketAddr, tag: u8| {
        let mut b = vec![tag | if s.is_ipv4() { 4 } else { 6 }];
        match s.ip() {
            IpAddr::V4(ip) => b.extend_from_slice(&ip.octets()),
            IpAddr::V6(ip) => b.extend_from_slice(&ip.octets()),
        }
        b.extend_from_slice(&s.port().to_be_bytes());
        b
    };
    if let Some(url) = a.strip_prefix("relay=http://") {
        let (host, tagged) = match url.split_once("/?m=") {
            Some((host, t)) if Some(t) == token => (host, 0x30),
            Some(_) => return None,
            None => (url.strip_suffix('/')?, 0x10),
        };
        return host.parse().ok().map(|s| sock(s, tagged));
    }
    a.parse().ok().map(|s| sock(s, 0))
}

/// One address back, and the bytes it took.
fn unpack_addr(b: &[u8], token: Option<&str>) -> Option<(String, usize)> {
    let (&tag, rest) = b.split_first()?;
    if tag == 1 {
        let n = u16::from_be_bytes(rest.get(..2)?.try_into().ok()?) as usize;
        return Some((String::from_utf8(rest.get(2..2 + n)?.to_vec()).ok()?, 3 + n));
    }
    let len = match tag & 0x0f {
        4 => 4,
        6 => 16,
        _ => return None,
    };
    let ip: IpAddr = if len == 4 { <[u8; 4]>::try_from(rest.get(..4)?).ok()?.into() } else { <[u8; 16]>::try_from(rest.get(..16)?).ok()?.into() };
    let port = u16::from_be_bytes(rest.get(len..len + 2)?.try_into().ok()?);
    let s = SocketAddr::new(ip, port);
    let text = match tag & 0xf0 {
        0x00 => s.to_string(),
        0x10 => format!("relay=http://{s}/"),
        0x30 => format!("relay=http://{s}/?{MEET_PARAM}={}", token?),
        _ => return None,
    };
    Some((text, 1 + len + 2))
}

fn unpack_meet(b: &[u8], expires: u64) -> Result<Meet> {
    let device = DeviceId(b.get(..32).ok_or(Error::Encoding)?.try_into().expect("32"));
    let (token, mut rest) = match b.get(32) {
        Some(0) => (None, &b[33..]),
        Some(1) => {
            let sig = b.get(33..97).ok_or(Error::Encoding)?;
            (Some([&device.0[..], &expires.to_le_bytes(), sig].concat()), &b[97..])
        }
        Some(2) => (Some(b.get(33..137).ok_or(Error::Encoding)?.to_vec()), &b[137..]),
        _ => return Err(Error::Encoding),
    };
    let token = token.map(|t| B64.encode(&t));
    let mut addrs = Vec::new();
    while !rest.is_empty() {
        let (a, used) = unpack_addr(rest, token.as_deref()).ok_or(Error::Encoding)?;
        // The addresses the other spellings allow, no more.
        if a.contains(';') || !addr_ok(&a) {
            return Err(Error::Encoding);
        }
        addrs.push(a);
        rest = &rest[used..];
    }
    Ok(Meet { device, addrs })
}

/// `device;addr;addr…`: a hex device id, then socket addresses or `relay=` URLs.
fn meet_of(text: &str) -> Result<Meet> {
    let mut parts = text.split(';');
    let device = DeviceId::from_hex(parts.next().unwrap_or_default())?;
    let mut addrs = Vec::new();
    for a in parts {
        if !addr_ok(a) {
            return Err(Error::Encoding);
        }
        addrs.push(a.to_owned());
    }
    Ok(Meet { device, addrs })
}

fn addr_ok(a: &str) -> bool {
    !a.is_empty() && (a.parse::<SocketAddr>().is_ok() || a.starts_with("relay="))
}

/// The longest prefix of `s` within `MAX_NAME_BYTES` that ends on a character boundary.
pub fn truncate(s: &str) -> &str {
    if s.len() <= MAX_NAME_BYTES {
        return s;
    }
    let mut end = MAX_NAME_BYTES;
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    &s[..end]
}

fn bytes32(field: &str) -> Result<[u8; 32]> {
    let v = B64.decode(field.as_bytes()).map_err(|_| Error::Encoding)?;
    v.try_into().map_err(|_| Error::Encoding)
}

/// The query parameter a meeting device's relay URL carries in a link: the inviting device's
/// word that whoever presents it may use that relay until the link expires, to reach the
/// inviter. The helper admits only its cardholders otherwise; a redeemer is a stranger to it.
pub const MEET_PARAM: &str = "m";

/// `device ‖ expires ‖ sig(device, "peer meet v1" ‖ helper ‖ expires)`, base64url: 104 bytes.
pub fn meet_token(inviter: &Secret, helper: &DeviceId, expires: u64) -> String {
    let sig = inviter.sign(&meet_message(helper, expires));
    let mut b = Vec::with_capacity(104);
    b.extend_from_slice(&inviter.device_id().0);
    b.extend_from_slice(&expires.to_le_bytes());
    b.extend_from_slice(&sig.0);
    B64.encode(&b)
}

/// The helper's check: the inviting device it vouches for and when its link expires, when the
/// token is for this helper, unexpired and signed by that device. Whether that device is a
/// cardholder is the caller's.
pub fn check_meet_token(token: &str, helper: &DeviceId, now_secs: u64) -> Option<(DeviceId, u64)> {
    let b = B64.decode(token.as_bytes()).ok()?;
    if b.len() != 104 {
        return None;
    }
    let device = DeviceId(b[..32].try_into().ok()?);
    let expires = u64::from_le_bytes(b[32..40].try_into().ok()?);
    let sig = Sig(b[40..].try_into().ok()?);
    if now_secs >= expires {
        return None;
    }
    device.verify(&meet_message(helper, expires), &sig).ok()?;
    Some((device, expires))
}

/// The token out of a URL's query (`…?m=<token>`), if it has one.
pub fn meet_token_of(query: Option<&str>) -> Option<&str> {
    query?.split('&').find_map(|kv| kv.strip_prefix(MEET_PARAM).and_then(|v| v.strip_prefix('=')))
}

fn meet_message(helper: &DeviceId, expires: u64) -> Vec<u8> {
    let mut m = b"peer meet v1".to_vec();
    m.extend_from_slice(&helper.0);
    m.extend_from_slice(&expires.to_le_bytes());
    m
}

/// The 6-digit code both screens show while a device link waits for confirmation.
pub fn code(secret: &[u8; 32], new_device: &DeviceId, old_device: &DeviceId) -> String {
    let h = blake3::Hasher::new().update(b"peer link code v1").update(secret).update(&new_device.0).update(&old_device.0).finalize();
    let n = u32::from_le_bytes(h.as_bytes()[..4].try_into().unwrap());
    format!("{:06}", n % 1_000_000)
}

/// A reply's secret (`Kind::Reply`): bound to the invite it answers, and telling nobody who does
/// not hold that invite what it was.
pub fn reply_secret(invite: &[u8; 32]) -> [u8; 32] {
    *blake3::Hasher::new().update(b"peer reply v1").update(invite).finalize().as_bytes()
}

/// For logs: never the secret.
pub fn describe(link: &Link) -> String {
    format!("{:?} link from {} via {}", link.kind, link.name, hex(&link.meet.device.0[..5]))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::Secret;

    fn sample() -> Link {
        Link {
            kind: Kind::Friend,
            name: "Dexter".into(),
            user: Secret::from_bytes(&[7; 32]).user_id(),
            expires: 1_791_000_000,
            meet: Meet { device: DeviceId([9; 32]), addrs: vec!["192.168.1.2:4101".into(), "relay=http://192.168.1.2:4101".into()] },
            secret: [42; 32],
        }
    }

    #[test]
    fn meet_tokens_name_one_helper_until_expiry() {
        let inviter = Secret::generate();
        let (helper, other) = (DeviceId([1; 32]), DeviceId([2; 32]));
        let t = meet_token(&inviter, &helper, 1000);
        assert_eq!(check_meet_token(&t, &helper, 999), Some((inviter.device_id(), 1000)));
        assert_eq!(check_meet_token(&t, &helper, 1000), None, "expired");
        assert_eq!(check_meet_token(&t, &other, 999), None, "another helper's");
        let mut forged = B64.decode(t.as_bytes()).unwrap();
        forged[32] ^= 1; // a later expiry
        assert_eq!(check_meet_token(&B64.encode(&forged), &helper, 999), None);
        let url = format!("http://10.0.0.1:4101/?{MEET_PARAM}={t}");
        let parsed: iroh::RelayUrl = url.parse().unwrap();
        assert_eq!(meet_token_of(parsed.query()), Some(t.as_str()));
        assert_eq!(meet_token_of(Some("x=1")), None);
    }

    #[test]
    fn a_reply_round_trips_and_is_bound_to_its_invite() {
        let mut r = sample();
        r.kind = Kind::Reply;
        r.secret = reply_secret(&sample().secret);
        assert_eq!(parse(&format(&r, "https://baud.rubric.sh/add")).unwrap(), r);
        assert_eq!(parse(&r.dotless()).unwrap(), r);
        assert_eq!(reply_secret(&sample().secret), r.secret);
        assert_ne!(reply_secret(&[43; 32]), r.secret);
        assert_ne!(r.secret, sample().secret);
    }

    #[test]
    fn round_trip_every_form() {
        let l = sample();
        for prefix in ["https://baud.rubric.sh/add", "baud://add", ""] {
            let s = if prefix.is_empty() { l.fragment() } else { format(&l, prefix) };
            assert_eq!(parse(&s).unwrap(), l, "{s}");
            let dotless = if prefix.is_empty() { l.dotless() } else { format!("{prefix}#{}", l.dotless()) };
            assert!(!dotless.rsplit('#').next().unwrap().contains('.'));
            assert_eq!(parse(&dotless).unwrap(), l, "{dotless}");
        }
    }

    /// A link as `make_link` writes one through a helper: its relay URLs (iroh's `RelayUrl`
    /// spelling, a trailing slash) each with the meet token.
    fn via_helper() -> Link {
        let inviter = Secret::generate();
        let expires = 1_791_003_600;
        let token = meet_token(&inviter, &DeviceId([5; 32]), expires);
        let urls = ["http://198.51.100.34:4101", "http://[2001:db8:5b2c:1e00:8d3:2f1a:91c4:7e22]:4101", "http://192.168.1.23:4101"];
        let addrs = urls.iter().map(|u| format!("relay={}?{MEET_PARAM}={token}", u.parse::<iroh::RelayUrl>().unwrap())).collect();
        Link { kind: Kind::Friend, name: "Dexter Storey".into(), user: Secret::generate().user_id(), expires, meet: Meet { device: inviter.device_id(), addrs }, secret: rand::random() }
    }

    #[test]
    fn grouped_round_trips_every_shape_of_meet() {
        let helper = via_helper();
        let mut handed = helper.clone();
        handed.meet.device = DeviceId([8; 32]); // `hand_invite`: the token's device isn't the meet device
        let mut raw = sample();
        raw.meet.addrs = vec![
            "relay=http://192.168.1.2:4101/".into(),
            "198.51.100.34:61234".into(),
            "[2001:db8:5b2c:1e00:8d3:2f1a:91c4:7e22]:61234".into(),
            "[fe80::1%4]:61234".into(),
            "relay=https://relay.example.com/".into(),
            "relay=http://192.168.1.2:4101".into(),
        ];
        let mut bare = sample();
        bare.meet.addrs.clear();
        bare.name.clear();
        let mut reply = via_helper();
        reply.kind = Kind::Reply;
        for l in [helper, handed, raw, bare, reply, sample()] {
            for prefix in ["https://baud.rubric.sh/add", "baud://add", ""] {
                let s = if prefix.is_empty() { l.grouped() } else { format(&l, prefix) };
                assert_eq!(parse(&s).unwrap(), l, "{s}");
            }
        }
    }

    #[test]
    fn grouped_is_whole_wherever_it_is_sent() {
        let l = via_helper();
        let url = format(&l, "https://baud.rubric.sh/add");
        let frag = url.rsplit('#').next().unwrap();
        // Apple's detector ends a link before a run of more than 301 letters and digits; Markdown
        // and autolinkers end one at a trailing dot or underscore, or format it at `_` and `*`.
        assert!(frag.split('-').all(|g| !g.is_empty() && g.len() <= GROUP), "{frag}");
        assert!(frag.bytes().all(|c| c == b'-' || c.is_ascii_lowercase() || c.is_ascii_digit()), "{frag}");
        assert!(frag.as_bytes().last().unwrap().is_ascii_alphanumeric());
        // The token once, the addresses packed: under half the dotted form.
        assert!(url.len() * 2 < format!("https://baud.rubric.sh/add#{}", l.fragment()).len(), "{} chars", url.len());
        assert!(url.len() < 400, "{} chars: {url}", url.len());
    }

    #[test]
    fn grouped_reads_however_it_was_copied() {
        let l = via_helper();
        let g = l.grouped();
        assert_eq!(parse(&g.to_ascii_uppercase()).unwrap(), l, "any case");
        assert_eq!(parse(&g.replace('-', "")).unwrap(), l, "no dashes");
        assert_eq!(parse(&g.replace('-', "\n")).unwrap(), l, "a line break for each dash");
        assert_eq!(parse(&format!("  https://baud.rubric.sh/add#{}  ", g.replace('-', " - "))).unwrap(), l, "spaces");
        // A dotless token is never taken for a grouped one, nor a dotted.
        assert_eq!(parse(&l.dotless()).unwrap(), l);
        assert_eq!(parse(&l.fragment()).unwrap(), l);
    }

    #[test]
    fn rejects_bad_grouped_shapes() {
        let g = via_helper().grouped();
        let bytes = BASE32_NOPAD.decode(g.replace('-', "").to_ascii_uppercase().as_bytes()).unwrap();
        let token = |b: &[u8]| BASE32_NOPAD.encode(b).to_ascii_lowercase();
        assert!(parse(&g[..g.len() - 1]).is_err(), "cut by one");
        assert!(parse(&token(&bytes[..bytes.len() - 1])).is_err(), "an address cut short");
        assert!(parse(&token(&bytes[..3 + 13 + 32 + 8 + 32 + 32])).is_err(), "no token byte");
        let mut v = bytes.clone();
        v[1] = b'x';
        assert!(parse(&token(&v)).is_err(), "unknown kind");
        let mut v = bytes.clone();
        v[2] = 65;
        assert!(parse(&token(&v)).is_err(), "name over 64 bytes");
        let mut v = bytes.clone();
        v[3 + 13 + 32 + 8 + 32 + 32] = 9;
        assert!(parse(&token(&v)).is_err(), "unknown token form");
        let mut v = bytes.clone();
        v.extend_from_slice(&[1, 0, 3, b'a', b';', b'b']);
        assert!(parse(&token(&v)).is_err(), "a text address that isn't one");
        let mut v = bytes.clone();
        v.push(0x44);
        assert!(parse(&token(&v)).is_err(), "unknown address tag");
        assert!(parse(&format!("{}A", g)).is_err(), "mixed case");
    }

    #[test]
    fn rejects_bad_dotless_shapes() {
        let b = B64.decode(sample().dotless().as_bytes()).unwrap();
        let token = |b: &[u8]| B64.encode(b);
        assert!(parse(&token(&b[..74])).is_err(), "cut short");
        let mut v = b.clone();
        v[0] = 2;
        assert!(parse(&token(&v)).is_err(), "another version");
        let mut v = b.clone();
        v[1] = b'x';
        assert!(parse(&token(&v)).is_err(), "unknown kind");
        let mut v = b.clone();
        v[2] = 65;
        assert!(parse(&token(&v)).is_err(), "name over 64 bytes");
        assert!(parse("").is_err());
        assert!(parse("notbase64!").is_err());
    }

    #[test]
    fn rejects_bad_shapes() {
        let l = sample();
        let f = l.fragment();
        let mut fields: Vec<String> = f.split('.').map(String::from).collect();
        assert!(parse(&fields[..6].join(".")).is_err());
        fields[1] = "x".into();
        assert!(parse(&fields.join(".")).is_err());
        let mut long = l.clone();
        long.name = format!("{}é", "x".repeat(63)); // 65 bytes; é is two
        assert_eq!(parse(&long.fragment()).unwrap().name, "x".repeat(63), "cut at a UTF-8 boundary, never mid-character");
        assert!(parse("peer1.f.RGV4dGVy.notbase64!.1.AA.AA").is_err());
    }

    #[test]
    fn vectors() {
        let json: serde_json::Value = serde_json::from_str(include_str!("../vectors/links.json")).unwrap();
        for case in json["cases"].as_array().unwrap() {
            let name = case["name"].as_str().unwrap();
            let input = case["input"].as_str().unwrap();
            match parse(input) {
                Ok(link) => {
                    let want = &case["expect"];
                    assert!(want.get("error").is_none(), "{name}: expected error {:?}", want["error"]);
                    assert_eq!(link.kind.tag(), want["kind"].as_str().unwrap(), "{name}");
                    assert_eq!(link.name, want["name"].as_str().unwrap(), "{name}");
                    assert_eq!(link.user.to_hex(), want["user"].as_str().unwrap(), "{name}");
                    assert_eq!(link.expires, want["expires"].as_u64().unwrap(), "{name}");
                    assert_eq!(link.meet.device.to_hex(), want["meetDevice"].as_str().unwrap(), "{name}");
                    let addrs: Vec<String> = want["meetAddrs"].as_array().unwrap().iter().map(|v| v.as_str().unwrap().to_owned()).collect();
                    assert_eq!(link.meet.addrs, addrs, "{name}");
                    assert_eq!(hex(&link.secret), want["secret"].as_str().unwrap(), "{name}");
                    assert_eq!(link.expired(json["now"].as_u64().unwrap()), want["expired"].as_bool().unwrap(), "{name}");
                    // format is the inverse of parse: the fragment is byte-identical, any form.
                    let frag = input.rsplit('#').next().unwrap();
                    let again = if frag.starts_with("peer1.") || frag.contains('.') {
                        link.fragment()
                    } else if frag.starts_with('a') {
                        link.grouped()
                    } else {
                        link.dotless()
                    };
                    assert_eq!(again, frag, "{name}");
                }
                Err(_) => assert!(case["expect"].get("error").is_some(), "{name}: unexpected parse failure"),
            }
        }
    }

    #[test]
    fn code_is_six_digits_and_symmetric() {
        let c = code(&[1; 32], &DeviceId([2; 32]), &DeviceId([3; 32]));
        assert_eq!(c.len(), 6);
        assert_eq!(c, code(&[1; 32], &DeviceId([2; 32]), &DeviceId([3; 32])));
        assert_ne!(c, code(&[1; 32], &DeviceId([3; 32]), &DeviceId([2; 32])));
    }
}

#[cfg(test)]
mod js_tests {
    /// The JS parser must agree with the vectors too. Skipped when neither bun nor node is installed.
    #[test]
    fn js_parser_passes_the_vectors() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("js");
        for runtime in ["bun", "node"] {
            if let Ok(out) = std::process::Command::new(runtime).arg("test.mjs").current_dir(&dir).output() {
                assert!(out.status.success(), "{runtime}: {}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
                return;
            }
        }
        eprintln!("no bun or node; JS vectors not run");
    }
}
