//! JSON as Foundation's `JSONEncoder` writes it, so what leaves here reads like what the Swift
//! apps send: `/` escaped as `\/`, a whole double without `.0`, big and tiny ones as `1e+16` and
//! `1e-07`. Keys go in declaration order; Swift's own order is its dictionary's, random per
//! process, so no reader may depend on it, and none does.

use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::ser::{CharEscape, Formatter};
use std::io;

struct Swiftish;

impl Formatter for Swiftish {
    fn write_string_fragment<W: ?Sized + io::Write>(&mut self, w: &mut W, fragment: &str) -> io::Result<()> {
        let mut rest = fragment;
        while let Some(i) = rest.find('/') {
            w.write_all(rest[..i].as_bytes())?;
            w.write_all(b"\\/")?;
            rest = &rest[i + 1..];
        }
        w.write_all(rest.as_bytes())
    }

    fn write_char_escape<W: ?Sized + io::Write>(&mut self, w: &mut W, e: CharEscape) -> io::Result<()> {
        let s: &[u8] = match e {
            CharEscape::Quote => b"\\\"",
            CharEscape::ReverseSolidus => b"\\\\",
            CharEscape::Solidus => b"\\/",
            CharEscape::Backspace => b"\\b",
            CharEscape::FormFeed => b"\\f",
            CharEscape::LineFeed => b"\\n",
            CharEscape::CarriageReturn => b"\\r",
            CharEscape::Tab => b"\\t",
            CharEscape::AsciiControl(b) => return write!(w, "\\u{:04x}", b),
        };
        w.write_all(s)
    }

    fn write_f64<W: ?Sized + io::Write>(&mut self, w: &mut W, v: f64) -> io::Result<()> {
        w.write_all(swift_double(v).as_bytes())
    }

    fn write_f32<W: ?Sized + io::Write>(&mut self, w: &mut W, v: f32) -> io::Result<()> {
        w.write_all(swift_double(v as f64).as_bytes())
    }
}

/// Swift's `Double.description` with a trailing `.0` dropped: the shortest digits that read back
/// the same, plain between 1e-4 and 1e16, else `d.ddde±XX`.
pub fn swift_double(v: f64) -> String {
    if !v.is_finite() {
        return "0".into();
    }
    let a = v.abs();
    if a == 0.0 || (1e-4..1e16).contains(&a) {
        return format!("{v}");
    }
    let e = format!("{v:e}");
    let (m, x) = e.split_once('e').unwrap_or((&e, "0"));
    let x: i32 = x.parse().unwrap_or(0);
    format!("{m}e{}{:02}", if x < 0 { '-' } else { '+' }, x.abs())
}

/// One value as the Swift apps write it.
pub fn encode<T: Serialize + ?Sized>(v: &T) -> String {
    let mut out = Vec::with_capacity(128);
    let mut ser = serde_json::Serializer::with_formatter(&mut out, Swiftish);
    if v.serialize(&mut ser).is_err() {
        return String::new();
    }
    String::from_utf8(out).unwrap_or_default()
}

pub fn encode_bytes<T: Serialize + ?Sized>(v: &T) -> Vec<u8> {
    encode(v).into_bytes()
}

/// None when it doesn't read: a frame from a newer version, a body of another type.
pub fn decode<T: DeserializeOwned>(s: &str) -> Option<T> {
    serde_json::from_str(s).ok()
}

pub fn decode_bytes<T: DeserializeOwned>(b: &[u8]) -> Option<T> {
    serde_json::from_slice(b).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn doubles_read_like_swift() {
        // From `JSONEncoder().encode([…])` on macOS 26.
        let swift = "[1,0.1,1760632800,1e-07,1e+21,1.2345678901234568e+17,0.000123,1760632800.5,-0,3.14159265358979,1e+16,1000000000000000.5]";
        let v = [1.0, 0.1, 1760632800.0, 1e-7, 1e21, 123456789012345678.0, 0.000123, 1760632800.5, -0.0, 3.14159265358979, 1e16, 1e15 + 0.5];
        assert_eq!(encode(&v), swift);
    }

    #[test]
    fn strings_read_like_swift() {
        let s = "a/b é \"q\" \n\t\u{1}\u{2028} 😀";
        assert_eq!(encode(s), "\"a\\/b é \\\"q\\\" \\n\\t\\u0001\u{2028} 😀\"");
    }
}
