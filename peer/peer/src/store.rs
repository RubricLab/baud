//! The sealed store: SQLite through rusqlite's bundled SQLCipher, keyed by `store-key` from the
//! keychain. Cards, petnames, membership, records, envelopes, pending links. Schema here; the
//! queries land with the node.

use std::path::Path;

use rusqlite::{Connection, params};

use crate::Result;
use crate::card::Card;
use crate::identity::UserId;
use crate::record::{FoundBy, SignedRecord};

pub const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value BLOB NOT NULL);
CREATE TABLE IF NOT EXISTS card (user BLOB PRIMARY KEY, seq INTEGER NOT NULL, bytes BLOB NOT NULL);
CREATE TABLE IF NOT EXISTS contact (user BLOB PRIMARY KEY, petname TEXT NOT NULL, verified INTEGER NOT NULL DEFAULT 0,
    relay_only INTEGER NOT NULL DEFAULT 0, met_at INTEGER NOT NULL, removed_at INTEGER);
CREATE TABLE IF NOT EXISTS adopted (user BLOB PRIMARY KEY, petname TEXT NOT NULL, card_at INTEGER NOT NULL, devices BLOB NOT NULL);
CREATE TABLE IF NOT EXISTS member (grp BLOB NOT NULL, user BLOB NOT NULL, PRIMARY KEY (grp, user));
CREATE TABLE IF NOT EXISTS record (device BLOB PRIMARY KEY, seq INTEGER NOT NULL, bytes BLOB NOT NULL,
    found_by TEXT NOT NULL, received_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS envelope (id BLOB PRIMARY KEY, recipient BLOB NOT NULL, expires INTEGER NOT NULL, hops INTEGER NOT NULL,
    bytes BLOB NOT NULL, kind INTEGER NOT NULL, carried_by BLOB, received_at INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS pending_link (secret BLOB PRIMARY KEY, kind TEXT NOT NULL, expires INTEGER NOT NULL);
";

pub struct Store {
    pub conn: Connection,
}

impl Store {
    /// Let go of the file (a closed node): later calls fail. An open database cannot be deleted
    /// on Windows, and an app that closes a node may remove its directory next.
    pub fn close(&mut self) {
        if let Ok(empty) = Connection::open_in_memory() {
            let _ = std::mem::replace(&mut self.conn, empty).close();
        }
    }

    /// Open or create, sealed under `key`. Opening with the wrong key fails on the first read.
    pub fn open(path: &Path, key: &[u8; 32]) -> Result<Store> {
        let conn = Connection::open(path)?;
        conn.pragma_update(None, "key", format!("x'{}'", crate::identity::hex(key)))?;
        conn.pragma_update(None, "journal_mode", "wal")?;
        // A table from an older cut whose columns moved is recreated; its rows were unusable anyway.
        let had_envelope = conn.prepare("select count(*) from sqlite_master where name = 'envelope'")?.query_row([], |r| r.get::<_, i64>(0))? > 0;
        let has_kind = conn.prepare("select count(*) from pragma_table_info('envelope') where name = 'kind'")?.query_row([], |r| r.get::<_, i64>(0))? > 0;
        if had_envelope && !has_kind {
            tracing::warn!("envelope table from an older cut: recreated");
            conn.execute_batch("drop table envelope;")?;
        }
        conn.execute_batch(SCHEMA)?;
        Ok(Store { conn })
    }

    pub fn meta(&self, key: &str) -> Result<Option<Vec<u8>>> {
        let mut st = self.conn.prepare("SELECT value FROM meta WHERE key = ?1")?;
        let mut rows = st.query([key])?;
        Ok(rows.next()?.map(|r| r.get(0)).transpose()?)
    }

    pub fn set_meta(&self, key: &str, value: &[u8]) -> Result<()> {
        self.conn.execute("INSERT INTO meta (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value", (key, value))?;
        Ok(())
    }

    pub fn put_card(&self, card: &Card) -> Result<()> {
        self.conn.execute(
            "INSERT INTO card (user, seq, bytes) VALUES (?1, ?2, ?3) ON CONFLICT(user) DO UPDATE SET seq = excluded.seq, bytes = excluded.bytes",
            params![card.user().0.as_slice(), card.body.seq as i64, card.to_bytes()],
        )?;
        Ok(())
    }

    pub fn remove_card(&self, user: &UserId) -> Result<()> {
        self.conn.execute("DELETE FROM card WHERE user = ?1", [user.0.as_slice()])?;
        Ok(())
    }

    /// Drop every card, contact, record and membership: a store whose card format moved.
    pub fn reset_book(&self) -> Result<()> {
        self.conn.execute_batch("delete from card; delete from contact; delete from record; delete from member; delete from adopted; delete from envelope; delete from pending_link;")?;
        Ok(())
    }

    pub fn cards(&self) -> Result<Vec<Card>> {
        let mut st = self.conn.prepare("SELECT bytes FROM card")?;
        let rows = st.query_map([], |r| r.get::<_, Vec<u8>>(0))?;
        let mut out = Vec::new();
        for bytes in rows {
            if let Ok(card) = Card::from_bytes(&bytes?) {
                out.push(card);
            }
        }
        Ok(out)
    }

    pub fn put_contact(&self, user: &UserId, petname: &str, verified: bool, relay_only: bool, met_at: u64) -> Result<()> {
        self.conn.execute(
            "INSERT INTO contact (user, petname, verified, relay_only, met_at) VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT(user) DO UPDATE SET petname = excluded.petname, verified = excluded.verified, relay_only = excluded.relay_only, removed_at = NULL",
            params![user.0.as_slice(), petname, verified as i64, relay_only as i64, met_at as i64],
        )?;
        Ok(())
    }

    pub fn remove_contact(&self, user: &UserId, now: u64) -> Result<()> {
        self.conn.execute("UPDATE contact SET removed_at = ?2 WHERE user = ?1", params![user.0.as_slice(), now as i64])?;
        Ok(())
    }

    /// `(user, removed_at)` for every contact removed here: own devices learn removals from it.
    pub fn removed_contacts(&self) -> Result<Vec<(UserId, u64)>> {
        let mut st = self.conn.prepare("SELECT user, removed_at FROM contact WHERE removed_at IS NOT NULL")?;
        let rows = st.query_map([], |r| Ok((r.get::<_, Vec<u8>>(0)?, r.get::<_, i64>(1)? as u64)))?;
        let mut out = Vec::new();
        for row in rows {
            let (user, at) = row?;
            if let Ok(user) = <[u8; 32]>::try_from(user.as_slice()) {
                out.push((UserId(user), at));
            }
        }
        Ok(out)
    }

    /// `(user, petname, verified, relay_only, met_at)` for every contact not removed.
    pub fn contacts(&self) -> Result<Vec<(UserId, String, bool, bool, u64)>> {
        let mut st = self.conn.prepare("SELECT user, petname, verified, relay_only, met_at FROM contact WHERE removed_at IS NULL")?;
        let rows = st.query_map([], |r| {
            let user: Vec<u8> = r.get(0)?;
            Ok((user, r.get::<_, String>(1)?, r.get::<_, i64>(2)? != 0, r.get::<_, i64>(3)? != 0, r.get::<_, i64>(4)? as u64))
        })?;
        let mut out = Vec::new();
        for row in rows {
            let (user, petname, verified, relay_only, met_at) = row?;
            if let Ok(user) = <[u8; 32]>::try_from(user.as_slice()) {
                out.push((UserId(user), petname, verified, relay_only, met_at));
            }
        }
        Ok(out)
    }

    /// An adopted contact: petname and devices with addresses, until a real card replaces it.
    pub fn put_adopted(&self, user: &UserId, petname: &str, card_at: u64, devices: &[crate::AdoptedDevice]) -> Result<()> {
        let bytes = postcard::to_allocvec(devices).map_err(|_| crate::Error::Encoding)?;
        self.conn.execute(
            "INSERT OR REPLACE INTO adopted (user, petname, card_at, devices) VALUES (?1, ?2, ?3, ?4)",
            params![user.0.as_slice(), petname, card_at as i64, bytes],
        )?;
        Ok(())
    }

    pub fn remove_adopted(&self, user: &UserId) -> Result<()> {
        self.conn.execute("DELETE FROM adopted WHERE user = ?1", [user.0.as_slice()])?;
        Ok(())
    }

    pub fn adopted(&self) -> Result<Vec<(UserId, String, u64, Vec<crate::AdoptedDevice>)>> {
        let mut st = self.conn.prepare("SELECT user, petname, card_at, devices FROM adopted")?;
        let rows = st.query_map([], |r| Ok((r.get::<_, Vec<u8>>(0)?, r.get::<_, String>(1)?, r.get::<_, i64>(2)? as u64, r.get::<_, Vec<u8>>(3)?)))?;
        let mut out = Vec::new();
        for row in rows {
            let (u, petname, at, bytes) = row?;
            if let (Ok(u), Ok(devices)) = (<[u8; 32]>::try_from(u.as_slice()), postcard::from_bytes::<Vec<crate::AdoptedDevice>>(&bytes)) {
                out.push((UserId(u), petname, at, devices));
            }
        }
        Ok(out)
    }

    pub fn put_member(&self, group: &crate::identity::GroupId, user: &UserId) -> Result<()> {
        self.conn.execute("INSERT OR IGNORE INTO member (grp, user) VALUES (?1, ?2)", params![group.0.as_slice(), user.0.as_slice()])?;
        Ok(())
    }

    pub fn remove_member(&self, group: &crate::identity::GroupId, user: &UserId) -> Result<()> {
        self.conn.execute("DELETE FROM member WHERE grp = ?1 AND user = ?2", params![group.0.as_slice(), user.0.as_slice()])?;
        Ok(())
    }

    pub fn members(&self) -> Result<Vec<(crate::identity::GroupId, UserId)>> {
        let mut st = self.conn.prepare("SELECT grp, user FROM member")?;
        let rows = st.query_map([], |r| Ok((r.get::<_, Vec<u8>>(0)?, r.get::<_, Vec<u8>>(1)?)))?;
        let mut out = Vec::new();
        for row in rows {
            let (g, u) = row?;
            if let (Ok(g), Ok(u)) = (<[u8; 32]>::try_from(g.as_slice()), <[u8; 32]>::try_from(u.as_slice())) {
                out.push((crate::identity::GroupId(g), UserId(u)));
            }
        }
        Ok(out)
    }

    pub fn put_record(&self, rec: &SignedRecord, found_by: FoundBy, received_at: u64) -> Result<()> {
        let bytes = postcard::to_allocvec(rec).map_err(|_| crate::Error::Encoding)?;
        self.conn.execute(
            "INSERT INTO record (device, seq, bytes, found_by, received_at) VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT(device) DO UPDATE SET seq = excluded.seq, bytes = excluded.bytes, found_by = excluded.found_by, received_at = excluded.received_at",
            params![rec.record.device.0.as_slice(), rec.record.seq as i64, bytes, found_by.as_str(), received_at as i64],
        )?;
        Ok(())
    }

    pub fn records(&self) -> Result<Vec<(SignedRecord, FoundBy, u64)>> {
        let mut st = self.conn.prepare("SELECT bytes, found_by, received_at FROM record")?;
        let rows = st.query_map([], |r| Ok((r.get::<_, Vec<u8>>(0)?, r.get::<_, String>(1)?, r.get::<_, i64>(2)? as u64)))?;
        let mut out = Vec::new();
        for row in rows {
            let (bytes, found_by, at) = row?;
            if let Ok(rec) = postcard::from_bytes::<SignedRecord>(&bytes) {
                out.push((rec, FoundBy::parse(&found_by), at));
            }
        }
        Ok(out)
    }

    /// `kind`: 0 held for someone else, 1 posted by me and undelivered, 2 in my inbox.
    pub fn put_envelope(&self, env: &crate::helper::Envelope, kind: u8, carried_by: &[crate::identity::DeviceId], received_at: u64) -> Result<()> {
        let carried = postcard::to_allocvec(carried_by).map_err(|_| crate::Error::Encoding)?;
        self.conn.execute(
            "INSERT OR REPLACE INTO envelope (id, recipient, expires, hops, bytes, kind, carried_by, received_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![env.id.as_slice(), env.to.0.as_slice(), env.expires as i64, env.hops as i64, env.ciphertext, kind as i64, carried, received_at as i64],
        )?;
        Ok(())
    }

    pub fn delete_envelope(&self, id: &[u8; 32]) -> Result<()> {
        self.conn.execute("DELETE FROM envelope WHERE id = ?1", [id.as_slice()])?;
        Ok(())
    }

    /// `(envelope, kind, carried_by, received_at)` for every envelope held.
    pub fn envelopes(&self) -> Result<Vec<(crate::helper::Envelope, u8, Vec<crate::identity::DeviceId>, u64)>> {
        let mut st = self.conn.prepare("SELECT id, recipient, expires, hops, bytes, kind, carried_by, received_at FROM envelope")?;
        let rows = st.query_map([], |r| {
            Ok((r.get::<_, Vec<u8>>(0)?, r.get::<_, Vec<u8>>(1)?, r.get::<_, i64>(2)? as u64, r.get::<_, i64>(3)? as u8, r.get::<_, Vec<u8>>(4)?, r.get::<_, i64>(5)? as u8, r.get::<_, Option<Vec<u8>>>(6)?, r.get::<_, i64>(7)? as u64))
        })?;
        let mut out = Vec::new();
        for row in rows {
            let (id, to, expires, hops, bytes, kind, carried, at) = row?;
            let (Ok(id), Ok(to)) = (<[u8; 32]>::try_from(id.as_slice()), <[u8; 32]>::try_from(to.as_slice())) else { continue };
            let carried_by = carried.and_then(|c| postcard::from_bytes(&c).ok()).unwrap_or_default();
            out.push((crate::helper::Envelope { id, to: crate::identity::DeviceId(to), expires, hops, ciphertext: bytes }, kind, carried_by, at));
        }
        Ok(out)
    }

    pub fn add_pending(&self, secret: &[u8; 32], kind: &str, expires: u64) -> Result<()> {
        self.conn.execute("INSERT OR REPLACE INTO pending_link (secret, kind, expires) VALUES (?1, ?2, ?3)", params![secret.as_slice(), kind, expires as i64])?;
        Ok(())
    }

    /// The unexpired secrets of one kind, with their expiry: which invite a reply answers
    /// (`link::reply_secret`) is found by trying each.
    pub fn pending_of(&self, kind: &str, now_secs: u64) -> Result<Vec<([u8; 32], u64)>> {
        let mut st = self.conn.prepare("SELECT secret, expires FROM pending_link WHERE kind = ?1 AND expires > ?2")?;
        let rows = st.query_map(params![kind, now_secs as i64], |r| Ok((r.get::<_, Vec<u8>>(0)?, r.get::<_, i64>(1)? as u64)))?;
        let mut out = Vec::new();
        for row in rows {
            let (secret, expires) = row?;
            if let Ok(secret) = <[u8; 32]>::try_from(secret.as_slice()) {
                out.push((secret, expires));
            }
        }
        Ok(out)
    }

    /// Burns the secret: one use. Returns `(kind, expires)` if it existed.
    pub fn take_pending(&self, secret: &[u8; 32]) -> Result<Option<(String, u64)>> {
        let mut st = self.conn.prepare("SELECT kind, expires FROM pending_link WHERE secret = ?1")?;
        let found = st.query_row([secret.as_slice()], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)? as u64))).ok();
        if found.is_some() {
            self.conn.execute("DELETE FROM pending_link WHERE secret = ?1", [secret.as_slice()])?;
        }
        Ok(found)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sealed_under_the_key() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("peer.db");
        let s = Store::open(&path, &[1; 32]).unwrap();
        s.set_meta("name", b"ana").unwrap();
        drop(s);
        assert_eq!(Store::open(&path, &[1; 32]).unwrap().meta("name").unwrap().unwrap(), b"ana");
        assert!(Store::open(&path, &[2; 32]).is_err(), "wrong key must not open the store");
    }
}
