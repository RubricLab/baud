//! Bulk is a hash and a path: iroh-blobs with bao verification, served on the router behind the
//! same gate as everything else, fetched over a connection the Bulk policy allows. A paused
//! transfer keeps what it verified; resume asks only for what is missing, so a fetch survives
//! background windows and restarts. `have` asks connected peers over `peer/1`.

use std::collections::{HashMap, HashSet};
use std::ops::Range;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use iroh::endpoint::Connection;
use iroh_blobs::api::blobs::{AddPathOptions, ExportMode, ExportOptions, ImportMode};
use iroh_blobs::api::proto::BlobStatus;
use iroh_blobs::api::TempTag;
use iroh_blobs::api::remote::GetProgressItem;
use iroh_blobs::protocol::{ChunkRanges, ChunkRangesExt, ChunkRangesSeq, GetRequest};
use iroh_blobs::store::fs::FsStore;
use iroh_blobs::BlobFormat;
use n0_future::StreamExt;
use serde::{Deserialize, Serialize};

use crate::identity::DeviceId;
use crate::trace::Trace;
use crate::transport::BoxFuture;
use crate::{Error, Result};
use crate::sync::Locked;

#[derive(Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Debug)]
pub struct Hash(pub [u8; 32]);

impl From<Hash> for iroh_blobs::Hash {
    fn from(h: Hash) -> Self {
        iroh_blobs::Hash::from_bytes(h.0)
    }
}
impl From<iroh_blobs::Hash> for Hash {
    fn from(h: iroh_blobs::Hash) -> Self {
        Hash(*h.as_bytes())
    }
}
impl Hash {
    pub fn to_hex(&self) -> String {
        crate::identity::hex_of(&self.0)
    }
    pub fn from_hex(s: &str) -> Result<Hash> {
        crate::identity::unhex32(s).map(Hash)
    }
}

/// Bytes per bao chunk: byte ranges are rounded out to these.
pub const CHUNK: u64 = 1024;

fn tag_for(hash: Hash) -> String {
    format!("peer-{}", hash.to_hex())
}

/// What the node gives the blob store: a Bulk-class connection to a device, and who is connected.
pub trait BulkDialer: Send + Sync + 'static {
    /// A connection on the blobs ALPN that the Bulk policy allows right now, or why not.
    fn dial(&self, device: DeviceId) -> BoxFuture<'static, Result<Connection>>;
    /// Still allowed? Checked while a transfer runs; a third person's relay pauses it.
    fn allowed(&self, conn: &Connection, device: DeviceId) -> bool;
    /// Live crate connections, to ask who has a hash.
    fn ask_have(&self, hash: Hash) -> BoxFuture<'static, Vec<DeviceId>>;
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum TransferState {
    Running,
    /// The only path is one Bulk may not use, or the device is unreachable: waits and retries.
    Waiting,
    Paused,
    Done,
    Cancelled,
    /// Out of retries, or the export failed: `error()` says why. `resume` tries again.
    Failed,
}

/// How long a transfer keeps trying before it fails: attempts, and the wait between them.
#[derive(Clone, Copy, Debug)]
pub struct RetryBudget {
    pub attempts: u32,
    pub delay: Duration,
    /// Fail when nothing has moved for this long, whatever the attempt count.
    pub stall: Duration,
}

impl Default for RetryBudget {
    fn default() -> Self {
        RetryBudget { attempts: 10, delay: Duration::from_secs(5), stall: Duration::from_secs(300) }
    }
}

struct Inner {
    hash: Hash,
    from: DeviceId,
    to: PathBuf,
    range: Option<Range<u64>>,
    state: Mutex<TransferState>,
    error: Mutex<Option<String>>,
    done: AtomicU64,
    total: AtomicU64,
    attempts: Mutex<u32>,
    last_progress: Mutex<Instant>,
    budget: RetryBudget,
    task: Mutex<Option<tokio::task::JoinHandle<()>>>,
    /// Protects the partial data from GC while running or paused.
    temp_tag: Mutex<Option<TempTag>>,
    store: FsStore,
    /// A fresh store for a hash this store forgot but still claims: fetched here, exported, re-added.
    scratch: Mutex<Option<FsStore>>,
    root: PathBuf,
    dialer: Arc<dyn BulkDialer>,
    rt: tokio::runtime::Handle,
    exported: Arc<Mutex<HashMap<Hash, PathBuf>>>,
    forgotten: Arc<Mutex<HashSet<Hash>>>,
    trace: Arc<Trace>,
    /// When this run started and when its first byte arrived, for the `blob` line.
    timing: Mutex<(Option<Instant>, Option<Instant>, u64)>,
}

/// A fetch in flight: bytes done over total, pausable, resumable by hash across restarts.
#[derive(Clone)]
pub struct Transfer {
    inner: Arc<Inner>,
}

impl Transfer {
    pub fn hash(&self) -> Hash {
        self.inner.hash
    }
    pub fn from(&self) -> DeviceId {
        self.inner.from
    }
    pub fn state(&self) -> TransferState {
        *self.inner.state.locked()
    }
    /// Why it failed, once it has.
    pub fn error(&self) -> Option<String> {
        self.inner.error.locked().clone()
    }
    /// `(bytes verified locally, total bytes)`; total is 0 until the size is known.
    pub fn progress(&self) -> (u64, u64) {
        (self.inner.done.load(Ordering::Relaxed), self.inner.total.load(Ordering::Relaxed))
    }
    pub fn pause(&self) {
        if self.state() == TransferState::Running || self.state() == TransferState::Waiting {
            self.stop(TransferState::Paused);
        }
    }
    pub fn resume(&self) {
        if matches!(self.state(), TransferState::Paused | TransferState::Failed) {
            *self.inner.attempts.locked() = 0;
            *self.inner.last_progress.locked() = Instant::now();
            self.start();
        }
    }
    pub fn cancel(&self) {
        self.stop(TransferState::Cancelled);
        self.inner.temp_tag.locked().take();
    }

    fn stop(&self, state: TransferState) {
        if let Some(t) = self.inner.task.locked().take() {
            t.abort();
        }
        *self.inner.state.locked() = state;
    }

    fn fail(&self, reason: String) {
        *self.inner.error.locked() = Some(reason);
        *self.inner.state.locked() = TransferState::Failed;
        self.inner.temp_tag.locked().take();
    }

    /// Another go, unless the budget is spent.
    async fn retry(&self, reason: &str) -> bool {
        let i = &self.inner;
        let attempts = {
            let mut a = i.attempts.locked();
            *a += 1;
            *a
        };
        let stalled = i.last_progress.locked().elapsed() > i.budget.stall;
        if attempts >= i.budget.attempts || stalled {
            self.fail(format!("{reason} ({attempts} attempts{})", if stalled { ", stalled" } else { "" }));
            return false;
        }
        *i.state.locked() = TransferState::Waiting;
        tokio::time::sleep(i.budget.delay).await;
        true
    }

    /// Where this transfer fetches: the main store, or a scratch store for a hash the main one
    /// forgot but still claims complete (its file may be gone).
    async fn store(&self) -> FsStore {
        let i = &self.inner;
        if !i.forgotten.locked().contains(&i.hash) {
            return i.store.clone();
        }
        if let Some(s) = i.scratch.locked().clone() {
            return s;
        }
        let dir = i.root.join("scratch").join(i.hash.to_hex());
        match FsStore::load(&dir).await {
            Ok(s) => {
                *i.scratch.locked() = Some(s.clone());
                s
            }
            Err(_) => i.store.clone(),
        }
    }

    fn start(&self) {
        *self.inner.state.locked() = TransferState::Running;
        *self.inner.timing.locked() = (Some(Instant::now()), None, self.inner.done.load(Ordering::Relaxed));
        let me = self.clone();
        let handle = self.inner.rt.spawn(async move { me.run().await });
        *self.inner.task.locked() = Some(handle);
    }

    /// Dial, fetch what is missing, export; on a failure wait and try again from what is already
    /// verified, within the budget. Ends in `Done` or `Failed`.
    async fn run(self) {
        let i = &self.inner;
        let hash = iroh_blobs::Hash::from(i.hash);
        let store = self.store().await;
        // A temp tag keeps the partial data from GC while running or paused.
        if i.temp_tag.locked().is_none()
            && let Ok(t) = store.tags().temp_tag(hash).await
        {
            *i.temp_tag.locked() = Some(t);
        }
        loop {
            self.note_size(&store).await;
            if let Ok(info) = store.remote().local(hash).await {
                i.done.store(info.local_bytes(), Ordering::Relaxed);
                if info.is_complete() && i.range.is_none() {
                    self.finish(&store).await;
                    return;
                }
            }
            let conn = match i.dialer.dial(i.from).await {
                Ok(c) => c,
                Err(e) => {
                    if !self.retry(&format!("cannot reach {}: {e}", i.from.short())).await {
                        return;
                    }
                    continue;
                }
            };
            *i.state.locked() = TransferState::Running;
            let base = i.done.load(Ordering::Relaxed);
            let progress = match &i.range {
                Some(r) => store.remote().execute_get(conn.clone(), GetRequest::new(hash, ChunkRangesSeq::from_ranges([ChunkRanges::bytes(r.clone())]))),
                None => store.remote().fetch(conn.clone(), hash),
            };
            let mut stream = progress.stream();
            let mut outcome: Result<()> = Err(Error::Net("no answer".into()));
            while let Some(item) = stream.next().await {
                match item {
                    GetProgressItem::Progress(n) => {
                        if n > 0 {
                            *i.last_progress.locked() = Instant::now();
                            let mut timing = i.timing.locked();
                            if timing.1.is_none() {
                                timing.1 = Some(Instant::now());
                            }
                        }
                        i.done.store(base + n, Ordering::Relaxed);
                        if !i.dialer.allowed(&conn, i.from) {
                            // The path degraded to one Bulk may not use: keep what we have, wait.
                            outcome = Err(Error::PolicyRefused(crate::policy::Class::Bulk, crate::Path::Waiting));
                            break;
                        }
                    }
                    GetProgressItem::Done(_) => outcome = Ok(()),
                    GetProgressItem::Error(e) => outcome = Err(Error::Net(e.to_string())),
                }
            }
            match outcome {
                Ok(()) => {
                    self.finish(&store).await;
                    return;
                }
                Err(e) => {
                    if !self.retry(&e.to_string()).await {
                        return;
                    }
                }
            }
        }
    }

    async fn note_size(&self, store: &FsStore) {
        let i = &self.inner;
        if i.total.load(Ordering::Relaxed) == 0 {
            let size = match store.blobs().status(iroh_blobs::Hash::from(i.hash)).await {
                Ok(BlobStatus::Complete { size }) => Some(size),
                Ok(BlobStatus::Partial { size: Some(s) }) => Some(s),
                _ => None,
            };
            if let Some(s) = size.or_else(|| i.range.as_ref().map(|r| r.end - r.start)) {
                i.total.store(s, Ordering::Relaxed);
            }
        }
    }

    /// Export by reference (the store keeps no second copy), tag so GC keeps it, and only then
    /// `Done`. An export that fails is a failed transfer, not a done one.
    async fn finish(&self, store: &FsStore) {
        let i = &self.inner;
        let hash = iroh_blobs::Hash::from(i.hash);
        self.note_size(store).await;
        if i.range.is_none() {
            if let Some(parent) = i.to.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            let export = store.blobs().export_with_opts(ExportOptions { hash, mode: ExportMode::TryReference, target: i.to.clone() }).await;
            if let Err(e) = export {
                self.fail(format!("export to {}: {e}", i.to.display()));
                return;
            }
            let scratch = i.scratch.locked().take();
            if scratch.is_some() {
                // Fetched into scratch because this store had forgotten it: adopt the exported
                // file by reference, which makes it held here again.
                let _ = i.store.add_path_with_opts(AddPathOptions { path: i.to.clone(), format: BlobFormat::Raw, mode: ImportMode::TryReference }).with_tag().await;
                let _ = std::fs::remove_dir_all(i.root.join("scratch").join(i.hash.to_hex()));
            }
            let _ = i.store.tags().set(tag_for(i.hash), hash).await;
            i.forgotten.locked().remove(&i.hash);
            i.exported.locked().insert(i.hash, i.to.clone());
        }
        if let Ok(info) = store.remote().local(hash).await {
            i.done.store(info.local_bytes(), Ordering::Relaxed);
            i.total.store(info.local_bytes().max(i.total.load(Ordering::Relaxed)), Ordering::Relaxed);
        }
        i.temp_tag.locked().take();
        *i.state.locked() = TransferState::Done;
        let (started, first, base) = *i.timing.locked();
        if let Some(started) = started {
            let bytes = i.done.load(Ordering::Relaxed).saturating_sub(base);
            let secs = started.elapsed().as_secs_f64().max(1e-6);
            i.trace.emit(
                "blob",
                serde_json::json!({ "hash": &i.hash.to_hex()[..10], "first_byte_ms": first.map(|f| f.saturating_duration_since(started).as_millis() as u64), "ms": (secs * 1000.0) as u64, "bytes": bytes, "mbps": ((bytes as f64 * 8.0 / 1e6 / secs) * 10.0).round() / 10.0 }),
            );
        }
    }
}

pub struct Blobs {
    store: FsStore,
    root: PathBuf,
    dialer: Arc<dyn BulkDialer>,
    rt: tokio::runtime::Handle,
    exported: Arc<Mutex<HashMap<Hash, PathBuf>>>,
    /// Forgotten but possibly still claimed by the store until GC; never `has`, fetched to scratch.
    forgotten: Arc<Mutex<HashSet<Hash>>>,
    transfers: Mutex<Vec<Transfer>>,
    budget: Mutex<RetryBudget>,
    trace: Arc<Trace>,
    /// Paths imported by reference: (size, mtime ns, hash), so an unchanged file is not re-hashed.
    imported: Mutex<HashMap<PathBuf, (u64, i128, Hash)>>,
    importing: Mutex<HashMap<PathBuf, Arc<tokio::sync::Mutex<()>>>>,
    /// Imports that read a file run `IMPORTS_AT_ONCE` at a time.
    import_slots: tokio::sync::Semaphore,
}

/// How many path imports hash at once.
pub const IMPORTS_AT_ONCE: usize = 4;

/// Size and modification time (ns since the epoch), the cheap test of "unchanged".
fn file_stamp(path: &Path) -> Option<(u64, i128)> {
    let m = std::fs::metadata(path).ok()?;
    let mtime = m.modified().ok()?.duration_since(std::time::UNIX_EPOCH).ok()?.as_nanos() as i128;
    Some((m.len(), mtime))
}

impl Blobs {
    pub fn new(store: FsStore, root: PathBuf, dialer: Arc<dyn BulkDialer>, rt: tokio::runtime::Handle, trace: Arc<Trace>) -> Self {
        let forgotten: HashSet<Hash> = std::fs::read_to_string(root.join("forgotten")).unwrap_or_default().lines().filter_map(|l| Hash::from_hex(l.trim()).ok()).collect();
        let imported = std::fs::read_to_string(root.join("imported"))
            .unwrap_or_default()
            .lines()
            .filter_map(|l| {
                let mut f = l.splitn(4, '\t');
                let hash = Hash::from_hex(f.next()?).ok()?;
                let size = f.next()?.parse().ok()?;
                let mtime = f.next()?.parse().ok()?;
                Some((PathBuf::from(f.next()?), (size, mtime, hash)))
            })
            .collect();
        Blobs { store, root, dialer, rt, exported: Default::default(), forgotten: Arc::new(Mutex::new(forgotten)), transfers: Mutex::new(Vec::new()), budget: Mutex::new(RetryBudget::default()), trace, imported: Mutex::new(imported), importing: Default::default(), import_slots: tokio::sync::Semaphore::new(IMPORTS_AT_ONCE) }
    }

    /// How long transfers keep trying (tests shorten it).
    pub fn set_retry_budget(&self, budget: RetryBudget) {
        *self.budget.locked() = budget;
    }

    fn save_forgotten(&self) {
        let text: String = self.forgotten.locked().iter().map(|h| h.to_hex() + "\n").collect();
        let _ = std::fs::create_dir_all(&self.root);
        let _ = std::fs::write(self.root.join("forgotten"), text);
    }

    pub fn store(&self) -> &FsStore {
        &self.store
    }

    /// Import a file in place when the store can reference it, else by copy. Returns its hash.
    /// Idempotent: a path imported before, unchanged in size and modification time and still held,
    /// returns its hash without reading the file again (an app that re-provides its library on
    /// every launch must not hash every original every time).
    pub async fn add_path(&self, path: &Path) -> Result<Hash> {
        let path = std::path::absolute(path).map_err(|e| Error::Store(e.to_string()))?;
        // One import per path at a time: a second caller waits, then finds the first one's hash
        // instead of hashing (and holding open) the same file again alongside it.
        let gate = self.importing.locked().entry(path.clone()).or_default().clone();
        let res = {
            let _one = gate.lock().await;
            self.add_path_once(&path).await
        };
        drop(gate);
        self.importing.locked().retain(|p, g| p != &path || Arc::strong_count(g) > 1);
        res
    }

    async fn add_path_once(&self, path: &Path) -> Result<Hash> {
        let stamp = file_stamp(path);
        let known = self.imported.locked().get(path).copied();
        if let (Some((size, mtime, hash)), Some(now)) = (known, stamp)
            && (size, mtime) == now
            && self.has(hash).await
        {
            return Ok(hash);
        }
        // An import holds its file open while it hashes: a library provided at once must not
        // hold a thousand of them (nor run into the process's file limit).
        let _slot = self.import_slots.acquire().await.map_err(|e| Error::Store(e.to_string()))?;
        let opts = AddPathOptions { path: path.to_path_buf(), format: BlobFormat::Raw, mode: ImportMode::TryReference };
        let tag = self.store.add_path_with_opts(opts).with_tag().await.map_err(|e| Error::Store(e.to_string()))?;
        let hash: Hash = tag.hash.into();
        if let Some((size, mtime)) = stamp {
            self.imported.locked().insert(path.to_path_buf(), (size, mtime, hash));
            self.save_imported();
        }
        Ok(hash)
    }

    fn save_imported(&self) {
        let text: String = self.imported.locked().iter().map(|(p, (s, m, h))| format!("{}\t{s}\t{m}\t{}\n", h.to_hex(), p.display())).collect();
        let _ = std::fs::create_dir_all(&self.root);
        let _ = std::fs::write(self.root.join("imported"), text);
    }

    /// Held here: the bytes are present and a tag names them. A forgotten blob's bytes may linger
    /// until GC sweeps them, but it is no longer held.
    pub async fn has(&self, hash: Hash) -> bool {
        !self.forgotten.locked().contains(&hash) && self.store.blobs().has(iroh_blobs::Hash::from(hash)).await.unwrap_or(false) && self.tagged(hash).await
    }

    async fn tagged(&self, hash: Hash) -> bool {
        let want = iroh_blobs::Hash::from(hash);
        let Ok(mut tags) = self.store.tags().list().await else { return false };
        while let Some(t) = tags.next().await {
            if t.map(|t| t.hash == want).unwrap_or(false) {
                return true;
            }
        }
        false
    }

    /// Stop holding it: every tag naming the hash goes, `has` is false at once, `have` no longer
    /// names this device, and GC frees the bytes. A later `fetch` holds it again.
    pub async fn forget(&self, hash: Hash) -> Result<()> {
        let want = iroh_blobs::Hash::from(hash);
        let mut names = Vec::new();
        let mut tags = self.store.tags().list().await.map_err(|e| Error::Store(e.to_string()))?;
        while let Some(t) = tags.next().await {
            if let Ok(t) = t
                && t.hash == want
            {
                names.push(t.name);
            }
        }
        for n in names {
            let _ = self.store.tags().delete(n).await;
        }
        self.exported.locked().remove(&hash);
        self.forgotten.locked().insert(hash);
        self.save_forgotten();
        self.imported.locked().retain(|_, (_, _, h)| *h != hash);
        self.save_imported();
        Ok(())
    }

    /// Which connected peers hold it.
    pub async fn have(&self, hash: Hash) -> Vec<DeviceId> {
        self.dialer.ask_have(hash).await
    }

    /// Fetch `hash` from `from` into `to` (the whole blob, or a byte range kept in the store
    /// without export). Returns at once; the transfer runs, pauses, resumes and retries by itself.
    pub async fn fetch(&self, from: DeviceId, hash: Hash, to: &Path, range: Option<Range<u64>>) -> Result<Transfer> {
        let t = Transfer {
            inner: Arc::new(Inner {
                hash,
                from,
                to: to.to_path_buf(),
                range,
                state: Mutex::new(TransferState::Running),
                error: Mutex::new(None),
                done: AtomicU64::new(0),
                total: AtomicU64::new(0),
                attempts: Mutex::new(0),
                last_progress: Mutex::new(Instant::now()),
                budget: *self.budget.locked(),
                task: Mutex::new(None),
                temp_tag: Mutex::new(None),
                store: self.store.clone(),
                scratch: Mutex::new(None),
                root: self.root.clone(),
                dialer: self.dialer.clone(),
                rt: self.rt.clone(),
                exported: self.exported.clone(),
                forgotten: self.forgotten.clone(),
                trace: self.trace.clone(),
                timing: Mutex::new((None, None, 0)),
            }),
        };
        t.start();
        self.transfers.locked().push(t.clone());
        Ok(t)
    }

    pub fn transfers(&self) -> Vec<Transfer> {
        self.transfers.locked().clone()
    }

    /// Where a fetched blob was exported, or the path it was imported from in place.
    pub fn local_path(&self, hash: Hash) -> Option<PathBuf> {
        self.exported.locked().get(&hash).cloned()
    }

    /// Cancels transfers; the store itself is shut down by its protocol handler with the router.
    pub async fn shutdown(&self) {
        for t in self.transfers() {
            t.cancel();
        }
    }
}
