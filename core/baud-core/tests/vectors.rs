//! Golden vectors from the Swift apps (`BaudCore/Tests/BaudCoreTests/VectorTests.swift` writes
//! `vectors/swift.json`): every frame, body and packet decodes here and re-encodes to the same
//! JSON, ids, links and the disappearing lines compute alike. Then the reverse: this writes
//! `vectors/rust.json`, which the Swift test decodes. Swift orders keys at random per process, so
//! JSON is compared as values, with keys sorted and written the Swift way (`\/`, `1e+16`): the
//! same bytes but for order.

use baud_core::ids::{fingerprint, home_id, stable_id};
use baud_core::json::{decode, encode};
use baud_core::link::parse_code;
use baud_core::sentences::{disappear_after, disappear_line, disappear_short};
use baud_core::types::LinkKind;
use baud_core::wire::*;
use serde_json::Value;

fn vectors() -> Value {
    let p = concat!(env!("CARGO_MANIFEST_DIR"), "/../vectors/swift.json");
    serde_json::from_str(&std::fs::read_to_string(p).expect("vectors/swift.json")).unwrap()
}

/// Keys sorted at every level, then written as Swift writes: equal bytes mean equal JSON.
fn canonical(s: &str) -> String {
    fn sort(v: Value) -> Value {
        match v {
            Value::Object(m) => {
                let mut kv: Vec<(String, Value)> = m.into_iter().map(|(k, v)| (k, sort(v))).collect();
                kv.sort_by(|a, b| a.0.cmp(&b.0));
                Value::Object(kv.into_iter().collect())
            }
            Value::Array(a) => Value::Array(a.into_iter().map(sort).collect()),
            v => v,
        }
    }
    encode(&sort(serde_json::from_str(s).unwrap_or_else(|e| panic!("not json: {e}: {s}"))))
}

fn str_of<'a>(v: &'a Value, k: &str) -> &'a str {
    v[k].as_str().unwrap_or_else(|| panic!("{k} in {v}"))
}

#[test]
fn frames_decode_and_reencode() {
    let v = vectors();
    let frames = v["frames"].as_array().unwrap();
    assert!(frames.len() >= 40);
    for f in frames {
        let (name, json) = (str_of(f, "name"), str_of(f, "json"));
        let frame: Frame = decode(json).unwrap_or_else(|| panic!("{name} doesn't decode: {json}"));
        assert_eq!(canonical(&encode(&frame)), canonical(json), "{name}");
        // Every event body inside reads as its type and writes back the same.
        if let Frame::Events(es) = &frame {
            for e in es {
                let ok = match e.kind {
                    baud_core::types::EventType::Message => decode::<MessageBody>(&e.body).map(|b| encode(&b)),
                    baud_core::types::EventType::Edit => decode::<EditBody>(&e.body).map(|b| encode(&b)),
                    baud_core::types::EventType::Reaction => decode::<ReactionBody>(&e.body).map(|b| encode(&b)),
                    baud_core::types::EventType::Redact => decode::<RedactBody>(&e.body).map(|b| encode(&b)),
                    baud_core::types::EventType::Member => decode::<MemberBody>(&e.body).map(|b| encode(&b)),
                    baud_core::types::EventType::State => decode::<StateBody>(&e.body).map(|b| encode(&b)),
                    baud_core::types::EventType::Create => decode::<CreateBody>(&e.body).map(|b| encode(&b)),
                    baud_core::types::EventType::Card => decode::<WireCard>(&e.body).map(|b| encode(&b)),
                    _ => Some(e.body.clone()),
                };
                let again = ok.unwrap_or_else(|| panic!("{name}: body of {:?} doesn't decode: {}", e.kind, e.body));
                assert_eq!(canonical(&again), canonical(&e.body), "{name}: body");
            }
        }
    }
}

#[test]
fn bodies_decode_and_reencode() {
    let v = vectors();
    for b in v["bodies"].as_array().unwrap() {
        let (name, json) = (str_of(b, "name"), str_of(b, "json"));
        let again = match name.split('-').next().unwrap() {
            "MessageBody" => decode::<MessageBody>(json).map(|x| encode(&x)),
            "EditBody" => decode::<EditBody>(json).map(|x| encode(&x)),
            "ReactionBody" => decode::<ReactionBody>(json).map(|x| encode(&x)),
            "RedactBody" => decode::<RedactBody>(json).map(|x| encode(&x)),
            "MemberBody" => decode::<MemberBody>(json).map(|x| encode(&x)),
            "StateBody" => decode::<StateBody>(json).map(|x| encode(&x)),
            "CreateBody" => decode::<CreateBody>(json).map(|x| encode(&x)),
            "CallRecord" => decode::<CallRecord>(json).map(|x| encode(&x)),
            "ChannelRefs" => decode::<Vec<ChannelRef>>(json).map(|x| encode(&x)),
            other => panic!("no body type {other}"),
        };
        let again = again.unwrap_or_else(|| panic!("{name} doesn't decode: {json}"));
        assert_eq!(canonical(&again), canonical(json), "{name}");
    }
}

fn b64(s: &str) -> Vec<u8> {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.decode(s).unwrap()
}

#[test]
fn packets_open_and_seal_alike() {
    let v = vectors();
    for p in v["packets"].as_array().unwrap() {
        let name = str_of(p, "name");
        let frame_json = str_of(p, "frame");
        let packet: Packet = decode(str_of(p, "packet")).unwrap_or_else(|| panic!("{name}: packet"));
        assert_eq!(packet.v, Some(WIRE_VERSION));
        let plain = match (&packet.conv, &packet.nonce) {
            (Some(_), Some(nonce)) => {
                let key: [u8; 32] = b64(str_of(p, "key")).try_into().unwrap();
                if p["joiner"].as_bool().unwrap() {
                    assert_eq!(packet.key.as_deref(), Some(&key[..]), "{name}: a joiner's packet carries the key");
                }
                open_box(&key, nonce, &packet.body).unwrap_or_else(|| panic!("{name}: doesn't open"))
            }
            _ => packet.body.clone(),
        };
        let frame: Frame = baud_core::json::decode_bytes(&plain).unwrap_or_else(|| panic!("{name}: frame"));
        assert_eq!(canonical(&encode(&frame)), canonical(frame_json), "{name}");
        // Sealed again with the same key and nonce: the same ciphertext once the plaintext is the
        // same bytes, which it is when the frame JSON is Swift's own.
        if let (Some(conv), Some(nonce)) = (&packet.conv, &packet.nonce) {
            let key: [u8; 32] = b64(str_of(p, "key")).try_into().unwrap();
            let n: [u8; 12] = nonce.clone().try_into().unwrap();
            assert_eq!(seal_box(&key, &n, frame_json.as_bytes()), packet.body, "{name}: ciphertext");
            let ours: Packet = decode(&String::from_utf8(seal_packet(&frame, Some((conv, &key)), packet.key.is_some(), n)).unwrap()).unwrap();
            assert_eq!(ours.conv, packet.conv);
            assert_eq!(ours.key, packet.key);
            assert_eq!(ours.nonce, packet.nonce);
        }
    }
}

#[test]
fn ids_compute_alike() {
    let v = vectors();
    for i in v["ids"].as_array().unwrap() {
        assert_eq!(stable_id(str_of(i, "input")), str_of(i, "stableId"), "{i}");
    }
    for h in v["homes"].as_array().unwrap() {
        assert_eq!(home_id(str_of(h, "user")), str_of(h, "home"));
    }
    for f in v["fingerprints"].as_array().unwrap() {
        assert_eq!(fingerprint(str_of(f, "user")), str_of(f, "fingerprint"));
    }
}

#[test]
fn links_parse_alike() {
    let v = vectors();
    for l in v["links"].as_array().unwrap() {
        let input = str_of(l, "input");
        let got = parse_code(input);
        match l["url"].as_str() {
            None => assert!(got.is_none(), "{input} should not parse"),
            Some(url) => {
                let got = got.unwrap_or_else(|| panic!("{input} should parse"));
                assert_eq!(got.url, url, "{input}");
                assert_eq!(got.name, str_of(l, "name"), "{input}");
                assert_eq!(got.kind, if str_of(l, "kind") == "m" { LinkKind::Device } else { LinkKind::Friend });
                assert_eq!(got.expires, (l["expires"].as_f64().unwrap() * 1000.0) as i64);
            }
        }
    }
}

/// Disappearing messages: a message's own `ttl` and the setting's state line read as Swift
/// wrote them, and the line the timeline shows for it is the same sentence on both sides.
#[test]
fn disappearing_reads_alike() {
    let v = vectors();
    let frame = |name: &str| -> WireEvent {
        let f = v["frames"].as_array().unwrap().iter().find(|f| str_of(f, "name") == name).unwrap_or_else(|| panic!("{name}"));
        match decode::<Frame>(str_of(f, "json")) {
            Some(Frame::Events(es)) => es[0].clone(),
            other => panic!("{name}: {other:?}"),
        }
    };
    let m = frame("events-message-ttl");
    assert_eq!(decode::<MessageBody>(&m.body).and_then(|b| b.ttl), Some(86_400));
    for (name, value) in [("events-state-disappear", "86400"), ("events-state-disappear-off", "0")] {
        let s = decode::<StateBody>(&frame(name).body).unwrap();
        assert_eq!((s.key.as_str(), s.value.as_str()), ("disappear", value), "{name}");
    }
    let body = v["bodies"].as_array().unwrap().iter().find(|b| str_of(b, "name") == "MessageBody-ttl").unwrap();
    assert_eq!(decode::<MessageBody>(str_of(body, "json")).and_then(|b| b.ttl), Some(300));
    assert!(!encode(&MessageBody { text: Some("x".into()), ..Default::default() }).contains("ttl"), "off: no key at all");
    let rows = v["sentences"].as_array().expect("sentences");
    assert!(rows.len() >= 20);
    for r in rows {
        let (by, s) = (str_of(r, "by"), r["seconds"].as_i64().unwrap());
        assert_eq!(disappear_line(by, s), str_of(r, "line"), "{r}");
        assert_eq!(disappear_after(s), str_of(r, "after"), "{r}");
        assert_eq!(disappear_short(s), str_of(r, "short"), "{r}");
    }
}

/// The reverse: frames, packets and sentences as this side writes them, for the Swift test to read.
#[test]
fn write_rust_vectors() {
    let v = vectors();
    let mut frames = vec![];
    for f in v["frames"].as_array().unwrap() {
        let frame: Frame = decode(str_of(f, "json")).unwrap();
        frames.push(serde_json::json!({ "name": str_of(f, "name"), "json": encode(&frame) }));
    }
    let key: [u8; 32] = std::array::from_fn(|i| (i * 11 + 5) as u8);
    let nonce: [u8; 12] = std::array::from_fn(|i| (0x30 + i) as u8);
    let conv = "e5".repeat(32);
    let events: Frame = decode(str_of(&v["frames"][0], "json")).unwrap();
    let want = Frame::Want("ab".repeat(32));
    let k = base64::engine::general_purpose::STANDARD;
    use base64::Engine;
    let packets = vec![
        serde_json::json!({ "name": "sealed", "key": k.encode(key), "nonce": k.encode(nonce), "conv": conv, "joiner": false,
            "frame": encode(&events), "packet": String::from_utf8(seal_packet(&events, Some((&conv, &key)), false, nonce)).unwrap() }),
        serde_json::json!({ "name": "sealed-joiner", "key": k.encode(key), "nonce": k.encode(nonce), "conv": conv, "joiner": true,
            "frame": encode(&events), "packet": String::from_utf8(seal_packet(&events, Some((&conv, &key)), true, nonce)).unwrap() }),
        serde_json::json!({ "name": "open", "key": null, "nonce": null, "conv": null, "joiner": false,
            "frame": encode(&want), "packet": String::from_utf8(seal_packet(&want, None, false, nonce)).unwrap() }),
    ];
    let sentences: Vec<Value> = v["sentences"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| {
            let (by, s) = (str_of(r, "by"), r["seconds"].as_i64().unwrap());
            serde_json::json!({ "by": by, "seconds": s, "line": disappear_line(by, s), "after": disappear_after(s), "short": disappear_short(s) })
        })
        .collect();
    let out = serde_json::json!({ "frames": frames, "packets": packets, "sentences": sentences });
    let p = concat!(env!("CARGO_MANIFEST_DIR"), "/../vectors/rust.json");
    std::fs::write(p, serde_json::to_string_pretty(&out).unwrap() + "\n").unwrap();
}

/// peer's own link vectors (`peer/peer/vectors/links.json`): every link peer accepts
/// reads here with the same kind, name and expiry, replies (`r`) included, dotted and dotless.
#[test]
fn peer_links_parse_alike() {
    let p = concat!(env!("CARGO_MANIFEST_DIR"), "/../../peer/peer/vectors/links.json");
    let v: Value = serde_json::from_str(&std::fs::read_to_string(p).expect("peer's link vectors")).unwrap();
    let mut kinds = std::collections::BTreeSet::new();
    for c in v["cases"].as_array().unwrap() {
        let Some(want) = c.get("expect").filter(|e| e.get("kind").is_some()) else { continue };
        let input = str_of(c, "input");
        let got = parse_code(input).unwrap_or_else(|| panic!("{} should parse", str_of(c, "name")));
        let kind = match str_of(want, "kind") {
            "f" => LinkKind::Friend,
            "m" => LinkKind::Device,
            "r" => LinkKind::Reply,
            k => panic!("kind {k}"),
        };
        assert_eq!(got.kind, kind, "{}", str_of(c, "name"));
        assert_eq!(got.name, str_of(want, "name"), "{}", str_of(c, "name"));
        assert_eq!(got.expires, want["expires"].as_i64().unwrap() * 1000, "{}", str_of(c, "name"));
        kinds.insert(str_of(want, "kind").to_owned());
    }
    assert_eq!(kinds.into_iter().collect::<Vec<_>>(), ["f", "m", "r"]);
}
