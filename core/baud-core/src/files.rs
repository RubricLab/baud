//! Files between devices (`Files.swift`). A message names its files by SHA-256; the bytes stay
//! on the device that wrote them until another needs them. It sends `want` to the devices of
//! everyone who shares a conversation naming that hash; any of them holding it answers `offer`
//! with the id peer's blob store gives it, and the asker fetches it from there, verified by the
//! store on the way and by this hash when it lands. A device is only offered what it could
//! already see in one of its conversations, or my photo. Small files come along with their
//! message, so every device of mine holds what the others do.

use std::collections::VecDeque;
use std::io::Read;
use std::path::{Path as FsPath, PathBuf};
use std::time::Duration;

use sha2::{Digest, Sha256};
use tokio::sync::oneshot;

use crate::core::{Core, short};
use crate::ids::random_hex;
use crate::json::decode;
use crate::types::*;
use crate::wire::*;

/// One file being asked for: who is waiting for it, who offered it, whether a fetch is running.
#[derive(Default)]
pub(crate) struct BlobWait {
    id: u64,
    waiters: Vec<oneshot::Sender<Option<PathBuf>>>,
    offers: VecDeque<(DeviceId, String)>,
    fetching: bool,
}

/// Files this size and under come to every device as their message does; bigger ones when opened.
const PREFETCH_LIMIT: u64 = 50 << 20;

impl Core {
    /// Here, or fetched from a device that has it; none when nobody who has it answers in time.
    pub(crate) async fn fetch_blob(&self, hash: &str) -> Option<PathBuf> {
        let mine = self.blob_path(hash);
        if mine.exists() {
            return Some(mine);
        }
        if self.is_closed() {
            return None;
        }
        let fresh = {
            let mut st = self.st();
            if st.blob_waits.contains_key(hash) {
                None
            } else {
                let id = rand::random();
                st.blob_waits.insert(hash.to_owned(), BlobWait { id, ..Default::default() });
                Some(id)
            }
        };
        if let Some(id) = fresh {
            let sources = self.blob_sources(hash);
            let to: Vec<String> = sources.iter().filter(|d| self.net.is_online(d)).cloned().collect();
            let want = self.seal(&Frame::Want(hash.to_owned()), None, false);
            self.log(format!("want {} from {:?} (of {} that may have it)", short(hash), to.iter().map(|d| short(d)).collect::<Vec<_>>(), sources.len()));
            for d in &to {
                let (core, d, want) = (self.arc(), d.clone(), want.clone());
                self.spawn(async move {
                    core.send_to(&want, &d).await;
                });
            }
            // Nobody offered it in time: the ones waiting hear none, and the next look asks again.
            let (core, h, wait) = (self.arc(), hash.to_owned(), if to.is_empty() { 0 } else { 20 });
            self.spawn(async move {
                tokio::time::sleep(Duration::from_secs(wait)).await;
                core.give_up(&h, id);
            });
        }
        let rx = {
            let mut st = self.st();
            if mine.exists() {
                return Some(mine);
            }
            let w = st.blob_waits.get_mut(hash)?;
            let (tx, rx) = oneshot::channel();
            w.waiters.push(tx);
            rx
        };
        rx.await.ok().flatten()
    }

    fn give_up(&self, hash: &str, id: u64) {
        let waiters = {
            let mut st = self.st();
            match st.blob_waits.get(hash) {
                Some(w) if w.id == id && !w.fetching => st.blob_waits.remove(hash).map(|w| w.waiters).unwrap_or_default(),
                _ => vec![],
            }
        };
        for w in waiters {
            let _ = w.send(None);
        }
    }

    /// Every device, not this one, of someone who shares a conversation naming the file, or
    /// whose photo it is.
    fn blob_sources(&self, hash: &str) -> Vec<DeviceId> {
        self.store
            .query(
                "select distinct d.id from devices d where d.id<>? and (
                    d.user in (select m.user from members m where m.conv in (select conv from events where type='message' and instr(body, ?) > 0))
                    or d.user in (select user from people where avatar=?))",
                &[&self.device(), &hash, &hash],
            )
            .iter()
            .filter_map(|r| r.string("id"))
            .collect()
    }

    /// Whether `d` may have the file: a device of mine, or of someone in a conversation that
    /// names it, or it is my photo.
    fn may_have(&self, hash: &str, d: &str) -> bool {
        let Some(u) = self.user_of(d) else { return false };
        let me = self.user();
        u == me
            || self.store.int("select count(*) as n from people where user=? and avatar=?", &[&me, &hash]) > 0
            || self.store.int("select count(*) as n from events e join members m on m.conv=e.conv where m.user=? and e.type='message' and instr(e.body, ?) > 0", &[&u, &hash]) > 0
    }

    /// They asked for a file: offer it if it's here and theirs to have.
    pub(crate) fn wanted(&self, hash: &str, d: &str) {
        let path = self.blob_path(hash);
        let (here, may) = (path.exists(), self.may_have(hash, d));
        self.log(format!("{} wants {}: {}, {}", short(d), short(hash), if here { "here" } else { "not here" }, if may { "theirs to have" } else { "not theirs" }));
        // Theirs, but not here yet (it is on its way to me too): offered the moment it lands.
        if !here && may {
            self.st().wanted_by.entry(hash.to_owned()).or_default().insert(d.to_owned());
        }
        if !(here && may) {
            return;
        }
        let (core, hash, d) = (self.arc(), hash.to_owned(), d.to_owned());
        self.spawn(async move {
            let Some(id) = core.net.provide(&path).await else { return };
            let offer = core.seal(&Frame::Offer(hash, id), None, false);
            core.send_to(&offer, &d).await;
        });
    }

    /// A device has the file I asked for: fetch it, or queue the offer behind the fetch running.
    pub(crate) fn offered(&self, hash: &str, id: &str, d: &str) {
        self.log(format!("{} offers {}", short(d), short(hash)));
        // An offer after I stopped waiting (it came to them after I asked): still taken, if a
        // conversation of mine names it and it isn't here.
        let named = !self.blob_path(hash).exists() && !self.blob_sources(hash).is_empty();
        let start = {
            let mut st = self.st();
            if !st.blob_waits.contains_key(hash) && named {
                st.blob_waits.insert(hash.to_owned(), BlobWait { id: rand::random(), ..Default::default() });
            }
            match st.blob_waits.get_mut(hash) {
                None => false,
                Some(w) => {
                    w.offers.push_back((d.to_owned(), id.to_owned()));
                    !std::mem::replace(&mut w.fetching, true)
                }
            }
        };
        if start {
            let (core, hash) = (self.arc(), hash.to_owned());
            self.spawn(async move { core.fetch_offered(&hash).await });
        }
    }

    async fn fetch_offered(&self, hash: &str) {
        // Straight to its place: peer's store keeps a fetched file by referring to where it
        // exported it, so it is never moved afterwards.
        let dest = self.blob_path(hash);
        while !dest.exists() {
            let Some((d, id)) = self.st().blob_waits.get_mut(hash).and_then(|w| w.offers.pop_front()) else { break };
            if self.net.fetch(&id, &d, &dest).await && file_hash(&dest).ok().as_deref() == Some(hash) {
                break;
            }
            let _ = std::fs::remove_file(&dest);
        }
        let got = dest.exists().then(|| dest.clone());
        let waiters = self.st().blob_waits.remove(hash).map(|w| w.waiters).unwrap_or_default();
        for w in waiters {
            let _ = w.send(got.clone());
        }
        self.log(format!("{} {}", short(hash), if got.is_some() { "is here" } else { "didn't come" }));
        if got.is_some() {
            // Whoever asked me while it was on its way gets it now.
            let askers = self.st().wanted_by.remove(hash).unwrap_or_default();
            for d in askers {
                self.wanted(hash, &d);
            }
            // The timeline shows the photo now.
            for r in self.store.query("select distinct conv from events where type='message' and instr(body, ?) > 0", &[&hash]) {
                if let Some(c) = r.string("conv") {
                    self.emit(Change::Conversation { id: c });
                }
            }
        }
    }

    /// A device that may hold files I lack came online: ask again for the small ones it may
    /// have (sent while it, or whoever had them, was away).
    pub(crate) fn retry_missing(&self, d: &str) {
        let bodies = self.store.query(
            "select e.body from events e join members m on m.conv=e.conv join devices v on v.user=m.user where v.id=? and e.type='message' and instr(e.body, '\"attachments\"') > 0 order by e.at desc limit 200",
            &[&d],
        );
        let mut missing: Vec<String> = bodies
            .iter()
            .filter_map(|r| r.string("body"))
            .flat_map(|b| decode::<MessageBody>(&b).and_then(|b| b.attachments).unwrap_or_default())
            .filter(|a| a.size <= PREFETCH_LIMIT && !self.blob_path(&a.hash).exists())
            .map(|a| a.hash)
            .collect();
        missing.sort();
        missing.dedup();
        if missing.is_empty() {
            return;
        }
        self.log(format!("{} is here: asking again for {} files", short(d), missing.len()));
        for h in missing {
            let core = self.arc();
            self.spawn(async move {
                core.fetch_blob(&h).await;
            });
        }
    }

    /// Files in arriving messages, small enough to come along: fetched now.
    pub(crate) fn prefetch(&self, events: &[WireEvent]) {
        for e in events.iter().filter(|e| e.kind == EventType::Message) {
            for a in decode::<MessageBody>(&e.body).and_then(|b| b.attachments).unwrap_or_default() {
                if a.size <= PREFETCH_LIMIT && !self.blob_path(&a.hash).exists() {
                    let core = self.arc();
                    self.spawn(async move {
                        core.fetch_blob(&a.hash).await;
                    });
                }
            }
        }
    }

    /// A file into the store: hashed as it streams, copied once, its type and (for an image)
    /// its size as shown read.
    pub(crate) fn add_blob(&self, path: &FsPath) -> crate::Result<Attachment> {
        let hash = file_hash(path)?;
        let dest = self.blob_path(&hash);
        if !dest.exists() {
            std::fs::copy(path, &dest)?;
        }
        let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase();
        let mime = mime_of(&ext).to_owned();
        let size = std::fs::metadata(&dest).map(|m| m.len()).unwrap_or(0);
        let (width, height) = if mime.starts_with("image/") { pixel_size(&dest).map(|(w, h)| (Some(w), Some(h))).unwrap_or((None, None)) } else { (None, None) };
        Ok(Attachment { hash, key: random_hex(8), mime, size, name: path.file_name().map(|n| n.to_string_lossy().into_owned()), width, height, duration: None })
    }
}

/// SHA-256 of a file, a megabyte at a time.
pub fn file_hash(path: &FsPath) -> std::io::Result<String> {
    let mut f = std::fs::File::open(path)?;
    let mut sha = Sha256::new();
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        sha.update(&buf[..n]);
    }
    Ok(crate::ids::hex(&sha.finalize()))
}

/// The MIME type a file's extension names, as the Apple apps' `UTType` would say it.
pub fn mime_of(ext: &str) -> &'static str {
    match ext {
        "jpg" | "jpeg" => "image/jpeg",
        "png" => "image/png",
        "heic" => "image/heic",
        "heif" => "image/heif",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "mp4" => "video/mp4",
        "mov" => "video/quicktime",
        "m4v" => "video/x-m4v",
        "m4a" => "audio/x-m4a",
        "mp3" => "audio/mpeg",
        "aac" => "audio/aac",
        "wav" => "audio/wav",
        "pdf" => "application/pdf",
        "txt" => "text/plain",
        "zip" => "application/zip",
        _ => "application/octet-stream",
    }
}

/// An image's size as it is shown: width and height swapped when its EXIF orientation turns it.
/// PNG, GIF and JPEG headers; anything else has no size until it is drawn.
pub fn pixel_size(path: &FsPath) -> Option<(u32, u32)> {
    let mut b = vec![];
    std::fs::File::open(path).ok()?.take(1 << 20).read_to_end(&mut b).ok()?;
    if b.starts_with(b"\x89PNG\r\n\x1a\n") && b.len() >= 24 {
        return Some((u32::from_be_bytes(b[16..20].try_into().ok()?), u32::from_be_bytes(b[20..24].try_into().ok()?)));
    }
    if b.starts_with(b"GIF8") && b.len() >= 10 {
        return Some((u16::from_le_bytes([b[6], b[7]]) as u32, u16::from_le_bytes([b[8], b[9]]) as u32));
    }
    if b.len() >= 30 && &b[0..4] == b"RIFF" && &b[8..12] == b"WEBP" {
        return webp_size(&b);
    }
    if b.len() >= 12 && &b[4..8] == b"ftyp" {
        return heif_size(&b);
    }
    if !b.starts_with(&[0xFF, 0xD8]) {
        return None;
    }
    let (mut i, mut orientation, mut size) = (2usize, 1u16, None);
    while i + 4 <= b.len() && size.is_none() {
        if b[i] != 0xFF {
            i += 1;
            continue;
        }
        let marker = b[i + 1];
        if marker == 0xD8 || marker == 0x01 || (0xD0..=0xD7).contains(&marker) {
            i += 2;
            continue;
        }
        let len = u16::from_be_bytes([b[i + 2], b[i + 3]]) as usize;
        let seg = b.get(i + 4..i + 2 + len)?;
        if marker == 0xE1 && seg.starts_with(b"Exif\0\0") {
            orientation = exif_orientation(&seg[6..]).unwrap_or(1);
        }
        if matches!(marker, 0xC0..=0xC3 | 0xC5..=0xC7 | 0xC9..=0xCB | 0xCD..=0xCF) && seg.len() >= 5 {
            size = Some((u16::from_be_bytes([seg[3], seg[4]]) as u32, u16::from_be_bytes([seg[1], seg[2]]) as u32));
        }
        i += 2 + len;
    }
    let (w, h) = size?;
    Some(if orientation >= 5 { (h, w) } else { (w, h) })
}

/// WebP's three headers: lossy, lossless, extended.
fn webp_size(b: &[u8]) -> Option<(u32, u32)> {
    let le = |o: usize, n: usize| -> u32 { (0..n).fold(0u32, |a, i| a | (b[o + i] as u32) << (8 * i)) };
    match &b[12..16] {
        b"VP8 " if b.len() >= 30 => Some((le(26, 2) & 0x3fff, le(28, 2) & 0x3fff)),
        b"VP8L" if b.len() >= 25 => {
            let v = le(21, 4);
            Some(((v & 0x3fff) + 1, ((v >> 14) & 0x3fff) + 1))
        }
        b"VP8X" if b.len() >= 30 => Some((le(24, 3) + 1, le(27, 3) + 1)),
        _ => None,
    }
}

/// HEIC/HEIF (an iPhone's photos): the largest `ispe` is the picture (the others are its tiles
/// and thumbnail), turned by `irot` when it says a quarter turn.
fn heif_size(b: &[u8]) -> Option<(u32, u32)> {
    let be = |o: usize| -> Option<u32> { Some(u32::from_be_bytes(b.get(o..o + 4)?.try_into().ok()?)) };
    let mut best: Option<(u32, u32)> = None;
    let mut turn = 0u8;
    for i in 4..b.len().saturating_sub(4) {
        match &b[i..i + 4] {
            b"ispe" => {
                if let (Some(w), Some(h)) = (be(i + 8), be(i + 12)) {
                    if best.map(|(bw, bh)| (w as u64) * (h as u64) > (bw as u64) * (bh as u64)).unwrap_or(true) {
                        best = Some((w, h));
                    }
                }
            }
            b"irot" => turn = b.get(i + 4).copied().unwrap_or(0) & 3,
            _ => {}
        }
    }
    best.map(|(w, h)| if turn % 2 == 1 { (h, w) } else { (w, h) })
}

fn exif_orientation(t: &[u8]) -> Option<u16> {
    let le = t.get(0..2)? == b"II";
    let u16_at = |o: usize| -> Option<u16> { let s = t.get(o..o + 2)?; Some(if le { u16::from_le_bytes([s[0], s[1]]) } else { u16::from_be_bytes([s[0], s[1]]) }) };
    let u32_at = |o: usize| -> Option<u32> { let s = t.get(o..o + 4)?; let a = [s[0], s[1], s[2], s[3]]; Some(if le { u32::from_le_bytes(a) } else { u32::from_be_bytes(a) }) };
    let ifd = u32_at(4)? as usize;
    let n = u16_at(ifd)? as usize;
    (0..n).find_map(|k| {
        let e = ifd + 2 + k * 12;
        (u16_at(e)? == 0x0112).then(|| u16_at(e + 8)).flatten()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sized(bytes: &[u8]) -> Option<(u32, u32)> {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("x");
        std::fs::write(&p, bytes).unwrap();
        pixel_size(&p)
    }

    #[test]
    fn webp_and_heif_sizes() {
        // VP8X: 4032×3024.
        let mut w = b"RIFF\0\0\0\0WEBPVP8X\x0a\0\0\0\0\0\0\0".to_vec();
        w.extend_from_slice(&[(4031 & 0xff) as u8, (4031 >> 8) as u8, 0, (3023 & 0xff) as u8, (3023 >> 8) as u8, 0]);
        assert_eq!(sized(&w), Some((4032, 3024)));
        // HEIF: a thumbnail ispe and the picture's, a quarter turn.
        let mut h = b"\0\0\0\x18ftypheic\0\0\0\0mif1heic".to_vec();
        for (wd, ht) in [(320u32, 240u32), (4032, 3024)] {
            h.extend_from_slice(&20u32.to_be_bytes());
            h.extend_from_slice(b"ispe\0\0\0\0");
            h.extend_from_slice(&wd.to_be_bytes());
            h.extend_from_slice(&ht.to_be_bytes());
        }
        h.extend_from_slice(b"\0\0\0\x09irot\x01");
        assert_eq!(sized(&h), Some((3024, 4032)));
        // A real one, when there is one to read (`BAUD_IMG=path WxH`).
        if let Ok(v) = std::env::var("BAUD_IMG") {
            let (p, want) = v.split_once(' ').unwrap();
            let got = pixel_size(FsPath::new(p)).map(|(a, b)| format!("{a}x{b}"));
            assert_eq!(got.as_deref(), Some(want), "{p}");
        }
    }
}
