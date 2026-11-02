//! `peer::catalog`: the op log that syncs app tables, lifted from darkroom's Rust
//! (`core/src/catalog` on `epic/phone-node`) and kept byte-compatible with the TypeScript and
//! Swift copies (`notes/catalog.md`, `notes/catalog-vectors.json`). The app brings its tables,
//! their key columns and the SQL that creates them; the crate brings signed ops, the hybrid
//! logical clock, field-level last-writer-wins, tombstones, marks and `since`, and a
//! verification hook that hands the app `(device, user, group)` per op so its own roles can
//! refuse or hold an op. Held ops are retried with every later delivery.

use std::collections::HashMap;
use std::path::Path;

use rusqlite::types::Value as Sql;
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::identity::{DeviceId, Secret, Sig, UserId};
use crate::{Error, Result};

/// A synced table: its name and key columns. A composite row id is the key values joined by `|`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Table {
    pub name: String,
    pub keys: Vec<String>,
}

/// Everything the app tells the catalog: the synced tables and the SQL that creates them.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Config {
    pub tables: Vec<Table>,
    pub schema: String,
}

/// `<unix ms, 14 digits>:<counter, 6 digits>:<device hex>`: sortable as a string.
pub type Hlc = String;
/// Newest HLC held per device (hex) in a group.
pub type Marks = HashMap<String, Hlc>;

/// One field write on one row of one table in one group. `group` travels as `space`, as
/// darkroom wrote it. `sig` is base64url (no padding) of the device's signature over
/// `canonical()`, which is `JSON.stringify` of the array with object keys in insertion order.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Op {
    pub id: String,
    #[serde(rename = "space")]
    pub group: String,
    pub device: String,
    pub hlc: Hlc,
    pub table: String,
    pub row: String,
    pub field: String,
    pub value: Value,
    pub tombstone: bool,
    #[serde(default)]
    pub sig: String,
}

impl Op {
    /// The bytes a device signs: `JSON.stringify([id, space, device, hlc, table, row, field, value, tombstone])`.
    pub fn canonical(&self) -> String {
        serde_json::json!([self.id, self.group, self.device, self.hlc, self.table, self.row, self.field, self.value, self.tombstone]).to_string()
    }

    pub fn sign(&mut self, device: &Secret) {
        self.device = device.device_id().to_hex();
        self.sig = data_encoding::BASE64URL_NOPAD.encode(&device.sign(self.canonical().as_bytes()).0);
    }

    /// Does `sig` verify under `device`? Empty is never ok.
    pub fn sig_ok(&self) -> bool {
        let (Ok(device), Ok(sig)) = (DeviceId::from_hex(&self.device), data_encoding::BASE64URL_NOPAD.decode(self.sig.as_bytes())) else { return false };
        let Ok(sig) = <[u8; 64]>::try_from(sig.as_slice()) else { return false };
        device.verify(self.canonical().as_bytes(), &Sig(sig)).is_ok()
    }
}

/// The local clock: monotonic even when the wall clock steps back; remote HLCs pull it forward.
#[derive(Default, Debug)]
pub struct Clock {
    ms: u64,
    n: u64,
}

impl Clock {
    pub fn next(&mut self, device: &str, now_ms: u64) -> Hlc {
        if now_ms > self.ms {
            (self.ms, self.n) = (now_ms, 0);
        } else {
            self.n += 1;
        }
        format!("{:014}:{:06}:{device}", self.ms, self.n)
    }
    pub fn observe(&mut self, hlc: &str) {
        let ms = hlc.get(..14).and_then(|s| s.parse().ok()).unwrap_or(0);
        if ms > self.ms {
            (self.ms, self.n) = (ms, 0);
        }
    }
}

/// What the app says about one op, given who wrote it. `Hold` keeps it for a later delivery
/// (a role not yet granted, a certificate not yet known); `Reject` drops it for good.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Verdict {
    Apply,
    Hold,
    Reject,
}

/// What the hook sees per op. `user` is who the crate knows the device belongs to, if anyone.
pub struct Writer {
    pub device: DeviceId,
    pub user: Option<UserId>,
    pub group: String,
    pub sig_ok: bool,
}

/// The crate's default: a good signature applies, a bad one is rejected. Apps add roles on top.
pub fn signed_only(_op: &Op, w: &Writer) -> Verdict {
    if w.sig_ok { Verdict::Apply } else { Verdict::Reject }
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Applied {
    /// Ops that changed a winner (the rest were older, duplicates, or no-ops).
    pub changed: usize,
    pub held: usize,
    pub rejected: usize,
}

pub struct Catalog {
    db: Connection,
    config: Config,
    clock: Clock,
}

const ROW: &str = "__row";

impl Catalog {
    /// Open or create the catalog in `path` (the app's own SQLite file is fine: the catalog
    /// adds `op`, `field_clock`, `row_space`, `held` and runs `config.schema`).
    pub fn open(path: &Path, config: Config) -> Result<Catalog> {
        let db = Connection::open(path)?;
        Self::with_connection(db, config)
    }

    pub fn in_memory(config: Config) -> Result<Catalog> {
        Self::with_connection(Connection::open_in_memory()?, config)
    }

    pub fn with_connection(db: Connection, config: Config) -> Result<Catalog> {
        // A copy built field by field from ops can never satisfy a foreign key mid-batch, and a
        // failing one would hold the whole batch for good: the app's schema may declare them, the
        // catalog never enforces them.
        db.execute_batch("pragma foreign_keys = off;")?;
        db.execute_batch(
            "create table if not exists op (
                id text primary key, space text not null, device text not null, hlc text not null,
                tbl text not null, row text not null, field text not null, value text, tombstone integer not null default 0,
                sig text not null default '');
             create index if not exists op_space_hlc on op(space, hlc);
             create index if not exists op_space_device_hlc on op(space, device, hlc);
             create index if not exists op_row on op(tbl, row, field, hlc);
             create table if not exists field_clock (tbl text not null, row text not null, field text not null, hlc text not null, primary key (tbl, row, field));
             create table if not exists row_space (tbl text not null, row text not null, space text not null, deleted integer not null default 0, primary key (tbl, row));
             create table if not exists held (id text primary key, op text not null);",
        )?;
        db.execute_batch(&config.schema)?;
        Ok(Catalog { db, config, clock: Clock::default() })
    }

    pub fn connection(&self) -> &Connection {
        &self.db
    }

    fn keys(&self, table: &str) -> Result<&[String]> {
        self.config.tables.iter().find(|t| t.name == table).map(|t| t.keys.as_slice()).ok_or_else(|| Error::Store(format!("not a synced table: {table}")))
    }

    /// A local write: one signed op, applied here, returned for pushing to peers.
    pub fn write(&mut self, device: &Secret, group: &str, table: &str, row: &str, field: &str, value: Value, tombstone: bool, now_ms: u64) -> Result<Op> {
        self.keys(table)?;
        let device_hex = device.device_id().to_hex();
        let hlc = self.clock.next(&device_hex, now_ms);
        let id = format!("{}-{}", &hlc[..21], crate::identity::hex_of(&rand::random::<[u8; 8]>()));
        let mut op = Op { id, group: group.into(), device: device_hex, hlc, table: table.into(), row: row.into(), field: if tombstone { ROW.into() } else { field.into() }, value: if tombstone { Value::Null } else { value }, tombstone, sig: String::new() };
        op.sign(device);
        // My own op alone: held ops from others wait for `apply`, where the hook sees them again.
        self.apply_batch(std::slice::from_ref(&op))?;
        Ok(op)
    }

    /// Remote ops in. Each is shown to `verify` with its writer, held ops from before included
    /// (the hook judges them again every time); a batch whose row cannot exist yet (a NOT NULL
    /// column not yet arrived) is held whole, to be retried with the next delivery. Holding is
    /// not an error.
    pub fn apply(&mut self, ops: Vec<Op>, resolve_user: impl Fn(&DeviceId) -> Option<UserId>, verify: impl Fn(&Op, &Writer) -> Verdict) -> Result<Applied> {
        let mut out = Applied::default();
        let mut batch = Vec::new();
        let mut hold_now = Vec::new();
        let mut all = self.take_held();
        all.extend(ops);
        for op in all {
            let device = DeviceId::from_hex(&op.device).unwrap_or(DeviceId([0; 32]));
            let w = Writer { device, user: resolve_user(&device), group: op.group.clone(), sig_ok: op.sig_ok() };
            match verify(&op, &w) {
                Verdict::Apply => batch.push(op),
                Verdict::Hold => hold_now.push(op),
                Verdict::Reject => out.rejected += 1,
            }
        }
        match self.apply_batch(&batch) {
            Ok(changed) => out.changed = changed,
            Err(_) => hold_now.extend(batch),
        }
        out.held = hold_now.len();
        self.hold(&hold_now)?;
        Ok(out)
    }

    /// Ops kept for a later delivery.
    pub fn held(&self) -> usize {
        self.db.query_row("select count(*) from held", [], |r| r.get::<_, i64>(0)).unwrap_or(0) as usize
    }

    fn take_held(&mut self) -> Vec<Op> {
        let ops: Vec<Op> = self
            .db
            .prepare("select op from held")
            .and_then(|mut s| s.query_map([], |r| r.get::<_, String>(0)).map(|rows| rows.filter_map(|r| r.ok()).filter_map(|s| serde_json::from_str(&s).ok()).collect()))
            .unwrap_or_default();
        let _ = self.db.execute("delete from held", []);
        ops
    }

    fn hold(&self, ops: &[Op]) -> Result<()> {
        for op in ops {
            self.db.execute("insert or replace into held (id, op) values (?1, ?2)", params![op.id, serde_json::to_string(op).map_err(|_| Error::Encoding)?])?;
        }
        Ok(())
    }

    /// The newest HLC held per device in a group.
    pub fn marks(&self, group: &str) -> Result<Marks> {
        Ok(self.db.prepare("select device, max(hlc) from op where space = ? group by device")?.query_map([group], |r| Ok((r.get(0)?, r.get(1)?)))?.collect::<std::result::Result<_, _>>()?)
    }

    /// Ops in `group` newer than the caller's mark per device (every op of an unmarked device),
    /// in HLC order, at most `limit`; `more` when the limit cut it.
    pub fn since(&self, group: &str, marks: &Marks, limit: usize) -> Result<(Vec<Op>, bool)> {
        let mut st = self.db.prepare("select id, space, device, hlc, tbl, row, field, value, tombstone, sig from op where space = ? order by hlc")?;
        let rows = st.query_map([group], |r| {
            Ok(Op {
                id: r.get(0)?,
                group: r.get(1)?,
                device: r.get(2)?,
                hlc: r.get(3)?,
                table: r.get(4)?,
                row: r.get(5)?,
                field: r.get(6)?,
                value: r.get::<_, Option<String>>(7)?.and_then(|s| serde_json::from_str(&s).ok()).unwrap_or(Value::Null),
                tombstone: r.get::<_, i64>(8)? != 0,
                sig: r.get(9)?,
            })
        })?;
        let mut out = Vec::new();
        for op in rows {
            let op = op?;
            if marks.get(&op.device).is_none_or(|m| op.hlc > *m) {
                if out.len() == limit {
                    return Ok((out, true));
                }
                out.push(op);
            }
        }
        Ok((out, false))
    }

    /// Everything, in one transaction; the number of ops that changed a winner.
    fn apply_batch(&mut self, ops: &[Op]) -> Result<usize> {
        if ops.is_empty() {
            return Ok(0);
        }
        let tx = self.db.transaction()?;
        let mut order: Vec<(String, String)> = vec![];
        let mut groups: HashMap<(String, String), Vec<Op>> = HashMap::new();
        for op in ops {
            tx.prepare_cached("insert or ignore into op (id, space, device, hlc, tbl, row, field, value, tombstone, sig) values (?,?,?,?,?,?,?,?,?,?)")?
                .execute(params![op.id, op.group, op.device, op.hlc, op.table, op.row, op.field, op.value.to_string(), op.tombstone as i64, op.sig])?;
            let k = (op.table.clone(), op.row.clone());
            groups.entry(k.clone()).or_insert_with(|| {
                order.push(k);
                vec![]
            }).push(op.clone());
        }
        let mut changed = 0;
        for k in order {
            let keys = self.config.tables.iter().find(|t| t.name == k.0).map(|t| t.keys.clone()).ok_or_else(|| Error::Store(format!("not a synced table: {}", k.0)))?;
            changed += apply_row(&tx, &mut self.clock, &k.0, &keys, &k.1, &groups[&k])?;
        }
        tx.commit()?;
        Ok(changed)
    }
}

fn snake(f: &str) -> String {
    f.chars().fold(String::new(), |mut s, c| {
        if c.is_ascii_uppercase() {
            s.push('_');
            s.push(c.to_ascii_lowercase());
        } else {
            s.push(c);
        }
        s
    })
}

/// bun:sqlite's binding of a JSON value: objects and arrays as JSON text, booleans as 0/1.
fn to_driver(v: &Value) -> Sql {
    match v {
        Value::Null => Sql::Null,
        Value::Bool(b) => Sql::Integer(*b as i64),
        Value::Number(n) => n.as_i64().map(Sql::Integer).unwrap_or_else(|| Sql::Real(n.as_f64().unwrap_or(0.0))),
        Value::String(s) => Sql::Text(s.clone()),
        other => Sql::Text(other.to_string()),
    }
}

/// Every op for one row together: per-field winners by HLC; liveness from the clocks alone (live
/// iff the newest field op is newer than the tombstone). Returns how many ops changed a winner.
fn apply_row(db: &Connection, clock: &mut Clock, table: &str, keys: &[String], row: &str, ops: &[Op]) -> Result<usize> {
    let key_vals: Vec<Sql> = row.split('|').map(|s| Sql::Text(s.into())).collect();
    if key_vals.len() != keys.len() {
        return Err(Error::Store(format!("row `{row}` does not match the keys of {table}")));
    }
    let wh = keys.iter().map(|c| format!("\"{c}\" = ?")).collect::<Vec<_>>().join(" and ");
    let clocks: HashMap<String, Hlc> = db.prepare_cached("select field, hlc from field_clock where tbl = ? and row = ?")?.query_map(params![table, row], |r| Ok((r.get(0)?, r.get(1)?)))?.collect::<std::result::Result<_, _>>()?;
    let mut winners: HashMap<String, &Op> = HashMap::new();
    for op in ops {
        clock.observe(&op.hlc);
        let f = if op.tombstone { ROW } else { op.field.as_str() };
        let prev = winners.get(f).map(|o| o.hlc.as_str()).or(clocks.get(f).map(String::as_str)).unwrap_or("");
        if op.hlc.as_str() > prev {
            winners.insert(f.to_string(), op);
        }
    }
    if winners.is_empty() {
        return Ok(0);
    }
    for (f, op) in &winners {
        db.prepare_cached("insert into field_clock (tbl, row, field, hlc) values (?, ?, ?, ?) on conflict do update set hlc = excluded.hlc")?.execute(params![table, row, f, op.hlc])?;
    }
    let tomb_at = winners.get(ROW).map(|o| o.hlc.as_str()).or(clocks.get(ROW).map(String::as_str)).unwrap_or("");
    let newest = clocks.iter().filter(|(f, _)| *f != ROW).map(|(_, h)| h.as_str()).chain(winners.iter().filter(|(f, _)| *f != ROW).map(|(_, o)| o.hlc.as_str())).max().unwrap_or("");
    let live = newest > tomb_at;
    let changed: Vec<Op> = winners.values().map(|o| (*o).clone()).collect();
    db.prepare_cached("insert into row_space (tbl, row, space, deleted) values (?, ?, ?, ?) on conflict(tbl, row) do update set deleted = excluded.deleted")?.execute(params![table, row, changed[0].group, !live as i64])?;
    if !live {
        db.execute(&format!("delete from \"{table}\" where {wh}"), rusqlite::params_from_iter(&key_vals))?;
        return Ok(changed.len());
    }
    let exists = db.query_row(&format!("select 1 from \"{table}\" where {wh}"), rusqlite::params_from_iter(&key_vals), |_| Ok(())).optional()?.is_some();
    if exists && !winners.contains_key(ROW) {
        for op in &changed {
            let mut p = vec![to_driver(&op.value)];
            p.extend(key_vals.iter().cloned());
            db.execute(&format!("update \"{table}\" set \"{}\" = ? where {wh}", snake(&op.field)), rusqlite::params_from_iter(p))?;
        }
        return Ok(changed.len());
    }
    // Create (or revive) the row from the winning op of every field it has ever had.
    let mut cols: Vec<(String, Sql)> = keys.iter().cloned().zip(key_vals.iter().cloned()).collect();
    let mut q = db.prepare_cached("select field, value from op o where tbl = ? and row = ? and tombstone = 0 and hlc = (select max(hlc) from op where tbl = o.tbl and row = o.row and field = o.field)")?;
    for r in q.query_map(params![table, row], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))? {
        let (field, value) = r?;
        let col = snake(&field);
        if !cols.iter().any(|(c, _)| *c == col) {
            cols.push((col, to_driver(&serde_json::from_str(&value).unwrap_or(Value::Null))));
        }
    }
    let names = cols.iter().map(|(c, _)| format!("\"{c}\"")).collect::<Vec<_>>().join(", ");
    let marks = vec!["?"; cols.len()].join(", ");
    db.execute(&format!("insert or replace into \"{table}\" ({names}) values ({marks})"), rusqlite::params_from_iter(cols.into_iter().map(|(_, v)| v)))?;
    Ok(changed.len())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn config() -> Config {
        Config {
            tables: vec![Table { name: "asset".into(), keys: vec!["id".into()] }, Table { name: "tag".into(), keys: vec!["asset_id".into(), "name".into()] }],
            schema: "create table if not exists asset (id text primary key, name text, rating integer, meta text);
                     create table if not exists tag (asset_id text not null, name text not null, color text, primary key (asset_id, name));"
                .into(),
        }
    }

    fn dump(c: &Catalog) -> Vec<String> {
        let mut out = vec![];
        for q in ["select id, name, rating, meta from asset order by id", "select asset_id, name, color, null from tag order by 1, 2", "select tbl, row, space, deleted from row_space order by 1, 2", "select tbl, row, field, hlc from field_clock order by 1, 2, 3"] {
            let mut s = c.db.prepare(q).unwrap();
            let rows = s.query_map([], |r| Ok((0..4).map(|i| format!("{:?}", r.get::<_, rusqlite::types::Value>(i).unwrap())).collect::<Vec<_>>().join(",")));
            out.extend(rows.unwrap().map(|r| r.unwrap()));
        }
        out
    }

    struct Rng(u64);
    impl Rng {
        fn next(&mut self, n: u64) -> u64 {
            self.0 ^= self.0 << 13;
            self.0 ^= self.0 >> 7;
            self.0 ^= self.0 << 17;
            self.0 % n
        }
    }

    fn op(i: usize, clock: &mut Clock, device: &str, ms: u64, table: &str, row: &str, field: &str, value: Value, tombstone: bool) -> Op {
        let hlc = clock.next(device, ms);
        Op { id: format!("{device}-{i}"), group: "s".into(), device: device.into(), hlc, table: table.into(), row: row.into(), field: field.into(), value, tombstone, sig: String::new() }
    }

    fn random_ops(seed: u64, n: usize) -> Vec<Op> {
        let mut rng = Rng(seed);
        let devices = ["d1", "d2", "d3"];
        let mut clocks: Vec<Clock> = devices.iter().map(|_| Clock::default()).collect();
        (0..n)
            .map(|i| {
                let d = rng.next(3) as usize;
                let ms = 1_000 + rng.next(40);
                let a = format!("a{}", rng.next(5));
                match rng.next(10) {
                    0 => op(i, &mut clocks[d], devices[d], ms, "asset", &a, "", Value::Null, true),
                    1 => op(i, &mut clocks[d], devices[d], ms, "tag", &format!("{a}|red"), "color", json!("#f00"), false),
                    2 => op(i, &mut clocks[d], devices[d], ms, "tag", &format!("{a}|red"), "", Value::Null, true),
                    3 => op(i, &mut clocks[d], devices[d], ms, "asset", &a, "meta", json!({"iso": rng.next(6400)}), false),
                    4..=6 => op(i, &mut clocks[d], devices[d], ms, "asset", &a, "rating", json!(rng.next(6)), false),
                    _ => op(i, &mut clocks[d], devices[d], ms, "asset", &a, "name", json!(format!("n{}", rng.next(100))), false),
                }
            })
            .collect()
    }

    fn unsigned_ok(_: &Op, _: &Writer) -> Verdict {
        Verdict::Apply
    }

    #[test]
    fn converges_in_any_order() {
        for seed in 1..=20u64 {
            let ops = random_ops(seed * 7919, 300);
            let (mut a, mut b, mut c) = (Catalog::in_memory(config()).unwrap(), Catalog::in_memory(config()).unwrap(), Catalog::in_memory(config()).unwrap());
            a.apply(ops.clone(), |_| None, unsigned_ok).unwrap();
            let mut rev = ops.clone();
            rev.reverse();
            for chunk in rev.chunks(7) {
                b.apply(chunk.to_vec(), |_| None, unsigned_ok).unwrap();
            }
            let mut rng = Rng(seed);
            let mut shuffled = ops.clone();
            for i in (1..shuffled.len()).rev() {
                shuffled.swap(i, rng.next(i as u64 + 1) as usize);
            }
            for o in &shuffled {
                c.apply(vec![o.clone()], |_| None, unsigned_ok).unwrap();
            }
            assert_eq!(dump(&a), dump(&b), "seed {seed}: reverse batches diverged");
            assert_eq!(dump(&a), dump(&c), "seed {seed}: shuffled singles diverged");
            assert_eq!(a.apply(ops.clone(), |_| None, unsigned_ok).unwrap().changed, 0, "redelivery changes nothing");
        }
    }

    #[test]
    fn signed_writes_verify_and_forgeries_are_rejected() {
        let dev = Secret::generate();
        let mut a = Catalog::in_memory(config()).unwrap();
        let op = a.write(&dev, "s", "asset", "x", "name", json!("one"), false, 10).unwrap();
        assert!(op.sig_ok());
        assert_eq!(a.marks("s").unwrap()[&dev.device_id().to_hex()], op.hlc);
        let mut b = Catalog::in_memory(config()).unwrap();
        let r = b.apply(vec![op.clone()], |_| None, signed_only).unwrap();
        assert_eq!((r.changed, r.rejected), (1, 0));
        let mut forged = op.clone();
        forged.value = json!("two");
        forged.hlc = "99999999999999:000000:x".into();
        let r = b.apply(vec![forged], |_| None, signed_only).unwrap();
        assert_eq!(r.rejected, 1);
        let name: String = b.db.query_row("select name from asset where id = 'x'", [], |r| r.get(0)).unwrap();
        assert_eq!(name, "one");
        let (since, more) = b.since("s", &HashMap::new(), 10).unwrap();
        assert_eq!((since.len(), more), (1, false));
        assert!(b.since("s", &b.marks("s").unwrap(), 10).unwrap().0.is_empty(), "nothing newer than my own marks");
    }

    #[test]
    fn held_ops_wait_for_the_app_and_for_missing_columns() {
        let dev = Secret::generate();
        let mut a = Catalog::in_memory(config()).unwrap();
        let op = a.write(&dev, "s", "asset", "x", "name", json!("one"), false, 10).unwrap();
        let mut b = Catalog::in_memory(config()).unwrap();
        let r = b.apply(vec![op.clone()], |_| None, |_, _| Verdict::Hold).unwrap();
        assert_eq!((r.changed, r.held, b.held()), (0, 1, 1));
        let r = b.apply(vec![], |_| None, |_, _| Verdict::Hold).unwrap();
        assert_eq!((r.changed, r.held, b.held()), (0, 1, 1), "a held op meets the hook again and stays held");
        let r = b.apply(vec![], |_| None, signed_only).unwrap();
        assert_eq!((r.changed, b.held()), (1, 0), "held ops ride along once the hook allows");
        // A table whose NOT NULL column has not arrived holds the batch, not an error.
        let strict = Config { tables: vec![Table { name: "asset".into(), keys: vec!["id".into()] }], schema: "create table asset (id text primary key, name text not null, rating integer);".into() };
        let mut c = Catalog::in_memory(strict).unwrap();
        let rating = Op { field: "rating".into(), value: json!(3), ..op.clone() };
        let r = c.apply(vec![Op { id: "r1".into(), ..rating.clone() }], |_| None, unsigned_ok).unwrap();
        assert_eq!((r.changed, r.held), (0, 1));
        let r = c.apply(vec![op.clone()], |_| None, unsigned_ok).unwrap();
        assert_eq!((r.changed, c.held()), (2, 0));
    }

    /// The signed vector: darkroom signs `JSON.stringify([...])` with object keys in insertion
    /// order, base64url without padding. A fixed key makes the signature itself a constant.
    #[test]
    fn signed_vector_is_byte_compatible() {
        let dev = Secret::from_bytes(&[7u8; 32]);
        let mut op = Op {
            id: "op-sig-1".into(),
            group: "g".into(),
            device: String::new(),
            hlc: "01700000000000:000003:x".into(),
            table: "asset".into(),
            row: "A1".into(),
            field: "metadata".into(),
            value: serde_json::from_str(r#"{"zeta":1,"alpha":{"b":true,"a":null}}"#).unwrap(),
            tombstone: false,
            sig: String::new(),
        };
        op.sign(&dev);
        assert_eq!(op.device, dev.device_id().to_hex());
        assert_eq!(op.canonical(), format!(r#"["op-sig-1","g","{}","01700000000000:000003:x","asset","A1","metadata",{{"zeta":1,"alpha":{{"b":true,"a":null}}}},false]"#, op.device));
        assert!(!op.sig.contains('=') && !op.sig.contains('+') && !op.sig.contains('/'), "base64url, no padding: {}", op.sig);
        assert!(op.sig_ok());
        println!("SIGVECTOR device={} sig={}", op.device, op.sig);
        assert_eq!(op.sig, PINNED_SIG, "the signature over these exact bytes is a constant");
    }

    const PINNED_SIG: &str = "mGD6xv49kTWRtHhWGgXPsKKQGL103EnKDXCxhTjS8ymuBYiuRnJsVvPXdEr_GYG-E9o08RIz5LMj4vgAmyVSBg";

    #[test]
    fn hlc_is_the_ts_format() {
        let mut k = Clock::default();
        assert_eq!(k.next("dev", 1_700_000_000_000), "01700000000000:000000:dev");
        assert_eq!(k.next("dev", 1_600_000_000_000), "01700000000000:000001:dev");
        k.observe("01800000000000:000009:other");
        assert_eq!(k.next("dev", 1), "01800000000000:000001:dev");
    }
}

