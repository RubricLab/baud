//! Links and codes (`Code.swift`, `parseLink`): `baud://add#…`, `baud://link#…`, the https form,
//! a pasted code, and the dotless token (peer's `Link::dotless`). Read without the network: the
//! kind, whose, the expiry. Redeeming one is peer's.

use base64::Engine;
use base64::alphabet;
use base64::engine::{DecodePaddingMode, GeneralPurpose, GeneralPurposeConfig};

use crate::types::{Link, LinkKind};

/// Foundation's `Data(base64Encoded:)`: padded, and lenient about the bits after the last byte,
/// which is how a plain name in an old dotted link reads as two bytes of base64 (Swift does it;
/// so does this, to name a link the same on both).
const LENIENT: GeneralPurpose = GeneralPurpose::new(
    &alphabet::STANDARD,
    GeneralPurposeConfig::new().with_decode_allow_trailing_bits(true).with_decode_padding_mode(DecodePaddingMode::RequireCanonical),
);

fn unurl64(s: &str) -> Option<Vec<u8>> {
    let mut b = s.replace('-', "+").replace('_', "/");
    while b.len() % 4 != 0 {
        b.push('=');
    }
    LENIENT.decode(b).ok()
}

pub const WEB: &str = "https://baud.rubric.sh/";

fn make(url: &str, kind: LinkKind, name: String, expires_secs: f64) -> Link {
    // Before the `#` in lower case: a copy may have shouted it.
    let url = match url.find('#') {
        Some(i) => url[..i].to_lowercase() + &url[i..],
        None => url.to_owned(),
    };
    let url = url.replace(WEB, "baud://");
    let code = url.rsplit('#').next().unwrap_or(&url).to_owned();
    Link { web: url.replace("baud://", WEB), code, url, kind, name, expires: (expires_secs * 1000.0) as i64 }
}

fn kind_of(s: &str) -> Option<LinkKind> {
    match s {
        "f" => Some(LinkKind::Friend),
        "m" => Some(LinkKind::Device),
        "r" => Some(LinkKind::Reply),
        _ => None,
    }
}

/// `baud://add#…`, `baud://link#…` or the https form: the seven fields after the hash, the
/// dotless form, one base64url token of the same, or the grouped form peer writes (0.2.19), which
/// is peer's to read.
pub fn parse_url(url: &str) -> Option<Link> {
    old_forms(url).or_else(|| {
        let l = peer::link::parse(url).ok()?;
        let kind = match l.kind {
            peer::link::Kind::Friend => LinkKind::Friend,
            peer::link::Kind::Device => LinkKind::Device,
            peer::link::Kind::Reply => LinkKind::Reply,
        };
        Some(make(url, kind, l.name, l.expires as f64))
    })
}

fn old_forms(url: &str) -> Option<Link> {
    let frag = url.rsplit('#').next().unwrap_or("");
    if !frag.is_empty() && !frag.contains('.') {
        return dotless(frag, url);
    }
    let parts: Vec<&str> = frag.split('.').collect();
    if parts.len() != 7 || parts[0] != "peer1" {
        return None;
    }
    let kind = kind_of(parts[1])?;
    let t: f64 = parts[4].parse().ok()?;
    // The crate writes the inviter's name base64url (utf-8); the stub wrote it plain. Read both.
    let name = unurl64(parts[2])
        .and_then(|b| String::from_utf8(b).ok())
        .filter(|n| !n.is_empty() && !n.chars().any(|c| matches!(c, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}' | '\0')))
        .unwrap_or_else(|| parts[2].to_owned());
    Some(make(url, kind, name, t))
}

/// `1 | kind | name length, name | user (32) | expires (8, big-endian seconds) | secret (32) | meet`.
fn dotless(token: &str, url: &str) -> Option<Link> {
    let d = unurl64(token)?;
    if d.len() <= 3 || d[0] != 1 {
        return None;
    }
    let kind = kind_of(&(d[1] as char).to_string())?;
    let n = d[2] as usize;
    let at = 3 + n + 32;
    if d.len() < at + 8 + 32 {
        return None;
    }
    let name = String::from_utf8(d[3..3 + n].to_vec()).ok()?;
    let t = d[at..at + 8].iter().fold(0u64, |a, b| a << 8 | *b as u64);
    Some(make(url, kind, name, t as f64))
}

/// A pasted code, a `baud://add#…`/`baud://link#…` URL, or the https form: all become a link.
pub fn parse_code(text: &str) -> Option<Link> {
    let t: String = text.chars().filter(|c| !c.is_whitespace()).collect();
    let t = t.trim_matches(|c| ".,;:!?()<>\"'".contains(c));
    if t.contains('#') {
        return parse_url(&t);
    }
    // A bare grouped or dotless token: its own kind says which door it is.
    if !t.contains('.') {
        let l = parse_url(&t)?;
        return parse_url(&format!("baud://{}#{t}", if l.kind == LinkKind::Device { "link" } else { "add" }));
    }
    let parts: Vec<&str> = t.split('.').collect();
    if parts.len() != 7 || parts[0] != "peer1" {
        return None;
    }
    parse_url(&format!("baud://{}#{t}", if parts[1] == "m" { "link" } else { "add" }))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A grouped link copied by hand: capitals, broken over lines, the sentence's brackets and full stop.
    #[test]
    fn grouped_however_it_was_copied() {
        let g = "https://baud.rubric.sh/add#ajtamrdfpb2gk4qaaebagbafaydqqcikbmga2dqpcaireeyu-culbogazdinryhi6d4aaaaaanlaixuccijbeeqscijbeeqsc-ijbeeqscijbeeqscijbeeqscijbeeqscilg43tonzxg43ton-zxg43tonzxg43tonzxg43tonzxg43tonzxg42ak2ljnfuws2-ljnfuws2ljnfuws2ljnfuws2ljnfuws2ljnfuws2ljnfuws2-ljnfuws2ljnfuws2ljnfuws2ljnfuws2ljnfuws2ljnfungl-abyqoeafgyqacdnyaaaaaaaaaaaaaaaaaadrabjuycuacfaq-au";
        for copy in [g.to_owned(), g.to_uppercase(), g.replace('-', "-\n"), format!("({g})."), g.rsplit('#').next().unwrap().to_owned()] {
            let l = parse_code(&copy).unwrap_or_else(|| panic!("{copy}"));
            assert_eq!((l.kind, l.name.as_str(), l.expires), (LinkKind::Friend, "Dexter", 1_791_003_600_000), "{copy}");
            assert!(l.url.starts_with("baud://add#"));
        }
    }
}
