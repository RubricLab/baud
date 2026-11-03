//! The thinnest wrapper over SQLite the core needs, and the schema: `Store.swift`'s, table for
//! table, so the queries port as they are. Times are unix seconds as REAL, like the Swift store;
//! the API turns them into milliseconds. One connection behind a re-entrant lock: a query can
//! run inside another's row loop on the same thread, as under Swift's `NSRecursiveLock`.

use parking_lot::ReentrantMutex;
use rusqlite::types::{ToSql, Value};
use rusqlite::{Connection, OpenFlags};

pub use rusqlite::params;

pub struct Store {
    conn: ReentrantMutex<Connection>,
}

/// One row by column name.
#[derive(Clone, Debug, Default)]
pub struct Row(Vec<(String, Value)>);

impl Row {
    fn get(&self, k: &str) -> Option<&Value> {
        self.0.iter().find(|(n, _)| n == k).map(|(_, v)| v)
    }
    pub fn string(&self, k: &str) -> Option<String> {
        match self.get(k)? {
            Value::Text(s) => Some(s.clone()),
            Value::Integer(i) => Some(i.to_string()),
            Value::Real(f) => Some(f.to_string()),
            _ => None,
        }
    }
    pub fn int(&self, k: &str) -> Option<i64> {
        match self.get(k)? {
            Value::Integer(i) => Some(*i),
            Value::Real(f) => Some(*f as i64),
            Value::Text(s) => s.parse().ok(),
            _ => None,
        }
    }
    pub fn double(&self, k: &str) -> Option<f64> {
        match self.get(k)? {
            Value::Real(f) => Some(*f),
            Value::Integer(i) => Some(*i as f64),
            _ => None,
        }
    }
    pub fn bool(&self, k: &str) -> bool {
        self.int(k).unwrap_or(0) != 0
    }
    pub fn blob(&self, k: &str) -> Option<Vec<u8>> {
        match self.get(k)? {
            Value::Blob(b) => Some(b.clone()),
            _ => None,
        }
    }
    /// Seconds in the store, milliseconds out.
    pub fn ms(&self, k: &str) -> Option<i64> {
        self.double(k).map(|s| (s * 1000.0) as i64)
    }
}

/// Unix seconds now, as the store keeps time.
pub fn now() -> f64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

impl Store {
    pub fn open(path: Option<&std::path::Path>) -> rusqlite::Result<Store> {
        let conn = match path {
            Some(p) => Connection::open_with_flags(p, OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_CREATE | OpenFlags::SQLITE_OPEN_FULL_MUTEX)?,
            None => Connection::open_in_memory()?,
        };
        if path.is_some() {
            let _ = conn.execute_batch("pragma journal_mode = wal; pragma synchronous = normal;");
        }
        conn.execute_batch(SCHEMA)?;
        let store = Store { conn: ReentrantMutex::new(conn) };
        // Disappearing messages, into stores from before them: the conversation's setting in
        // seconds (0, off), and when each message goes on this device, once that is known.
        store.exec("alter table conversations add column disappear int default 0");
        store.exec("alter table events add column expires_at real");
        store.exec("alter table members add column label text");
        store.exec("create index if not exists events_expires on events(expires_at) where expires_at is not null");
        Ok(store)
    }

    /// Several statements, no rows; errors are the caller's to ignore (`alter table` on a store
    /// that has the column).
    pub fn exec(&self, sql: &str) {
        let c = self.conn.lock();
        if let Err(e) = c.execute_batch(sql) {
            tracing::debug!("sqlite: {e} in {sql}");
        }
    }

    pub fn run(&self, sql: &str, args: &[&dyn ToSql]) -> usize {
        let c = self.conn.lock();
        match c.prepare_cached(sql).and_then(|mut s| s.execute(args)) {
            Ok(n) => n,
            Err(e) => {
                tracing::warn!("sqlite: {e} in {sql}");
                0
            }
        }
    }

    pub fn query(&self, sql: &str, args: &[&dyn ToSql]) -> Vec<Row> {
        let c = self.conn.lock();
        let r = (|| -> rusqlite::Result<Vec<Row>> {
            let mut s = c.prepare_cached(sql)?;
            let names: Vec<String> = s.column_names().into_iter().map(String::from).collect();
            let mut rows = s.query(args)?;
            let mut out = vec![];
            while let Some(r) = rows.next()? {
                let mut row = Vec::with_capacity(names.len());
                for (i, n) in names.iter().enumerate() {
                    row.push((n.clone(), r.get::<_, Value>(i)?));
                }
                out.push(Row(row));
            }
            Ok(out)
        })();
        r.unwrap_or_else(|e| {
            tracing::warn!("sqlite: {e} in {sql}");
            vec![]
        })
    }

    pub fn one(&self, sql: &str, args: &[&dyn ToSql]) -> Option<Row> {
        self.query(sql, args).into_iter().next()
    }

    /// The `n` column of the first row, 0 when there is none.
    pub fn int(&self, sql: &str, args: &[&dyn ToSql]) -> i64 {
        self.one(sql, args).and_then(|r| r.int("n")).unwrap_or(0)
    }

    /// Several writes as one: all or nothing, and one fsync.
    pub fn transaction<T>(&self, f: impl FnOnce() -> T) -> T {
        let _held = self.conn.lock();
        self.exec("begin");
        let r = f();
        self.exec("commit");
        r
    }

    /// Every conversation and message, deleted without being read.
    pub fn wipe_messages(&self) {
        self.exec(
            "pragma secure_delete = on; begin;
             delete from events; delete from fts; delete from receipts; delete from reads; delete from envelopes;
             delete from handed; delete from pins; delete from members; delete from conversations;
             delete from me where k like 'key:%' or k like 'hidden:%' or k like 'cleared:%';
             commit;",
        );
    }
}

const SCHEMA: &str = "
create table if not exists me(k text primary key, v text);
create table if not exists people(user text primary key, name text, fingerprint text, verified int default 0, contact int default 0, met_at real, demo int default 0, avatar text, peer_card blob, vouched integer default 0);
create table if not exists devices(id text primary key, user text, name text, kind text, added_at real, last_online real);
create table if not exists conversations(id text primary key, kind text, name text, topic text, space text, created_at real, is_default int default 0, demo int default 0, disappear int default 0);
create table if not exists members(conv text, user text, admin int default 0, joined_at real, primary key(conv, user));
create table if not exists events(id text primary key, conv text, device text, seq int, user text, at real, lamport int, type text, text text, reply text, thread text, target text, body text, carried_by text, via text, expires_at real);
create unique index if not exists events_feed on events(conv, device, seq);
create index if not exists events_conv on events(conv, lamport, id);
create index if not exists events_thread on events(thread, lamport);
create index if not exists events_target on events(target);
create index if not exists events_conv_type on events(conv, type, lamport);
create virtual table if not exists fts using fts5(text, event unindexed, conv unindexed, user unindexed, tokenize='unicode61', prefix='2 3');
create table if not exists receipts(conv text, device text, user text, event text, lamport int, kind text, at real, primary key(conv, device, event, kind));
create index if not exists receipts_read on receipts(conv, user, kind, lamport);
create table if not exists reads(conv text primary key, event text, lamport int);
create table if not exists envelopes(id text primary key, to_device text, from_device text, conv text, frame text, size int, expires real, hops int, held_at real);
create table if not exists handed(event text, to_device text, carrier text, at real, primary key(event, to_device, carrier));
create table if not exists links(secret text primary key, kind text, expires real, used int default 0);
create table if not exists pins(conv text, event text, primary key(conv, event));
";
