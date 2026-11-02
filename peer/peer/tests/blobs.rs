//! Journey 4, syncing a blob: ana adds a 100 MB file; sam fetches it over a Bulk connection,
//! pauses mid-transfer (what was verified stays), resumes (only the rest is fetched), and the
//! exported file is byte-identical. `have` names who holds it.

use std::io::Write;
use std::sync::Arc;
use std::time::Duration;

use peer::blobs::{RetryBudget, TransferState};
use peer::identity::MemoryKeychain;
use peer::{Config, Peer};

const SIZE: usize = 100 * 1024 * 1024;

fn config(name: &str) -> Config {
    let mut c = Config::new("blobs", name, &format!("{name}-dev"));
    c.nearby = false;
    c.portmap = false; // tests never map a port on the developer's router
    c
}

async fn until(what: &str, mut f: impl FnMut() -> bool) {
    for _ in 0..4000 {
        if f() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    panic!("timed out waiting for {what}");
}

#[tokio::test]
async fn hundred_megabytes_paused_and_resumed() {
    let (da, ds) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let ana = Peer::open(da.path().to_path_buf(), Arc::new(MemoryKeychain::default()), config("ana")).await.unwrap();
    let sam = Peer::open(ds.path().to_path_buf(), Arc::new(MemoryKeychain::default()), config("sam")).await.unwrap();
    ana.set_online(true);
    sam.set_online(true);
    sam.add(&ana.invite().unwrap()).await.unwrap();
    until("online", || sam.contacts()[0].devices.iter().any(|d| d.online)).await;

    // 100 MB of pseudo-random bytes, hashed independently.
    let src = da.path().join("big.bin");
    {
        let mut f = std::fs::File::create(&src).unwrap();
        let mut x: u64 = 0x9e3779b97f4a7c15;
        let mut buf = vec![0u8; 1 << 20];
        for _ in 0..(SIZE >> 20) {
            for w in buf.chunks_mut(8) {
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                w.copy_from_slice(&x.to_le_bytes()[..w.len()]);
            }
            f.write_all(&buf).unwrap();
        }
    }
    let expect = blake3::hash(&std::fs::read(&src).unwrap());
    let hash = ana.blobs().add_path(&src).await.unwrap();
    assert_eq!(hash.0, *expect.as_bytes(), "the blob hash is the file's blake3");
    assert!(ana.blobs().has(hash).await);
    assert_eq!(sam.blobs().have(hash).await, vec![ana.me().this_device], "have names who holds it");

    let out = ds.path().join("copy.bin");
    let t = sam.blobs().fetch(ana.me().this_device, hash, &out, None).await.unwrap();
    until("ten megabytes in", || t.progress().0 >= 10 * 1024 * 1024).await;
    t.pause();
    assert_eq!(t.state(), TransferState::Paused);
    let (at_pause, _) = t.progress();
    assert!(at_pause < SIZE as u64, "paused mid-transfer at {at_pause}");
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(t.progress().0, at_pause, "nothing moves while paused");
    assert!(!out.exists(), "nothing exported before the whole blob is verified");

    t.resume();
    until("done", || t.state() == TransferState::Done).await;
    assert_eq!(t.progress().0, SIZE as u64);
    assert_eq!(blake3::hash(&std::fs::read(&out).unwrap()), expect, "byte-identical");
    assert_eq!(sam.blobs().local_path(hash), Some(out.clone()));
    assert!(sam.blobs().has(hash).await);

    // Offload: ana forgets her copy; she no longer holds it, sam does; she fetches it back from sam.
    ana.blobs().forget(hash).await.unwrap();
    assert!(!ana.blobs().has(hash).await, "forgotten");
    assert_eq!(ana.blobs().local_path(hash), None);
    until("sam no longer counts ana as a holder", || true).await;
    assert_eq!(sam.blobs().have(hash).await, Vec::<peer::identity::DeviceId>::new(), "have stops naming a forgotten holder");
    assert_eq!(ana.blobs().have(hash).await, vec![sam.me().this_device]);
    let back = da.path().join("back.bin");
    let t2 = ana.blobs().fetch(sam.me().this_device, hash, &back, None).await.unwrap();
    until("fetched back", || t2.state() == TransferState::Done).await;
    assert!(ana.blobs().has(hash).await, "held again");
    assert_eq!(blake3::hash(&std::fs::read(&back).unwrap()), expect);
    assert_eq!(t2.progress(), (SIZE as u64, SIZE as u64), "total is known");

    // A hash nobody holds fails within the budget, with a reason, instead of waiting forever.
    sam.blobs().set_retry_budget(RetryBudget { attempts: 2, delay: Duration::from_millis(100), stall: Duration::from_secs(60) });
    let bogus = peer::blobs::Hash([3; 32]);
    let t3 = sam.blobs().fetch(ana.me().this_device, bogus, &ds.path().join("nope.bin"), None).await.unwrap();
    until("failed", || t3.state() == TransferState::Failed).await;
    assert!(t3.error().unwrap().contains("2 attempts"), "{:?}", t3.error());
    assert!(!ds.path().join("nope.bin").exists());

    // Forget an in-place entry, delete its file: a fresh fetch still works at once (scratch store).
    sam.blobs().forget(hash).await.unwrap();
    std::fs::remove_file(&out).unwrap();
    let again = ds.path().join("again.bin");
    let t4 = sam.blobs().fetch(ana.me().this_device, hash, &again, None).await.unwrap();
    until("re-fetched after the file vanished", || matches!(t4.state(), TransferState::Done | TransferState::Failed)).await;
    assert_eq!(t4.state(), TransferState::Done, "{:?}", t4.error());
    assert_eq!(blake3::hash(&std::fs::read(&again).unwrap()), expect);
    assert!(sam.blobs().has(hash).await);
    ana.close().await;
    sam.close().await;
}

/// An app that provides its library on every launch imports the same files again: an unchanged
/// path (same size and modification time) returns its hash without the file being read, across
/// a restart too; a touched file is imported again; concurrent imports of one path agree.
#[tokio::test]
async fn re_import_of_an_unchanged_path_reads_nothing() {
    let (dir, files) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let src = files.path().join("original.bin");
    std::fs::write(&src, vec![1u8; 1024 * 1024]).unwrap();
    let keys = Arc::new(MemoryKeychain::default());
    let ana = Peer::open(dir.path().to_path_buf(), keys.clone(), config("ana")).await.unwrap();
    let first = ana.blobs().add_path(&src).await.unwrap();
    let (a, b) = tokio::join!(ana.blobs().add_path(&src), ana.blobs().add_path(&src));
    assert_eq!((a.unwrap(), b.unwrap()), (first, first), "concurrent imports of one path agree");

    // Same size, same mtime, other bytes: only a read would notice, and none happens.
    let mtime = std::fs::metadata(&src).unwrap().modified().unwrap();
    std::fs::write(&src, vec![2u8; 1024 * 1024]).unwrap();
    std::fs::File::options().write(true).open(&src).unwrap().set_modified(mtime).unwrap();
    assert_eq!(ana.blobs().add_path(&src).await.unwrap(), first, "unchanged by size and mtime: not read");
    ana.close().await;

    let ana = Peer::open(dir.path().to_path_buf(), keys, config("ana")).await.unwrap();
    assert_eq!(ana.blobs().add_path(&src).await.unwrap(), first, "remembered across a restart");
    std::fs::File::options().write(true).open(&src).unwrap().set_modified(mtime + Duration::from_secs(1)).unwrap();
    let touched = ana.blobs().add_path(&src).await.unwrap();
    assert_eq!(touched, peer::blobs::Hash(*blake3::hash(&[2u8; 1024 * 1024]).as_bytes()), "a touched file is read again");
    ana.close().await;
}
