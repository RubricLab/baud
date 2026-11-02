//! darkroom's cross-implementation vectors (`notes/catalog-vectors.json`): every case, every
//! arrival order, one op per delivery with hold-and-retry, must reproduce `expect`.

use std::collections::HashMap;

use peer::catalog::{Catalog, Config, Op, Table, Verdict};
use serde_json::Value;

/// darkroom's tables as the vectors need them (foreign keys left out; they are the app's).
fn config() -> Config {
    Config {
        tables: vec![
            Table { name: "asset".into(), keys: vec!["id".into()] },
            Table { name: "collection_asset".into(), keys: vec!["collection_id".into(), "asset_id".into()] },
            Table { name: "tag".into(), keys: vec!["asset_id".into(), "name".into()] },
        ],
        schema: "
            create table asset (bytes integer not null, captured_at integer, class text not null, client_id text,
                created_at integer default (cast(unixepoch('subsec') * 1000 as integer)) not null, deleted_at integer, duration real,
                error text, fingerprint text, flag text, format text not null, height integer, id text primary key not null, label text,
                metadata text default '{}' not null, mime text not null, name text not null, original_hash text, owner_id text not null,
                public_expires_at integer, public_token text, rating integer default 0 not null, space text, stack_id text,
                status text default 'uploading' not null, updated_at integer default (cast(unixepoch('subsec') * 1000 as integer)) not null, width integer);
            create table tag (asset_id text not null, confidence real default 1 not null, name text not null, source text default 'ai' not null, primary key (asset_id, name));
            create table collection_asset (added_at integer default (cast(unixepoch('subsec') * 1000 as integer)) not null, asset_id text not null,
                collection_id text not null, position integer default 0 not null, primary key (collection_id, asset_id));"
            .into(),
    }
}

fn snapshot(c: &Catalog) -> (Vec<Value>, Vec<Value>, HashMap<String, Vec<HashMap<String, Value>>>) {
    let db = c.connection();
    let mut clocks = Vec::new();
    let mut st = db.prepare("select tbl, row, field, hlc from field_clock order by tbl, row, field").unwrap();
    for r in st.query_map([], |r| Ok(serde_json::json!({"tbl": r.get::<_, String>(0)?, "row": r.get::<_, String>(1)?, "field": r.get::<_, String>(2)?, "hlc": r.get::<_, String>(3)?}))).unwrap() {
        clocks.push(r.unwrap());
    }
    let mut live = Vec::new();
    let mut st = db.prepare("select tbl, row, deleted from row_space order by tbl, row").unwrap();
    for r in st.query_map([], |r| Ok(serde_json::json!({"tbl": r.get::<_, String>(0)?, "row": r.get::<_, String>(1)?, "deleted": r.get::<_, i64>(2)?}))).unwrap() {
        live.push(r.unwrap());
    }
    let mut rows = HashMap::new();
    for t in ["asset", "collection_asset", "tag"] {
        let mut st = db.prepare(&format!("select * from \"{t}\" order by 1, 2")).unwrap();
        let names: Vec<String> = st.column_names().iter().map(|s| s.to_string()).collect();
        let mut out = Vec::new();
        for r in st.query_map([], |r| {
            let mut m = HashMap::new();
            for (i, n) in names.iter().enumerate() {
                let v = match r.get::<_, rusqlite::types::Value>(i)? {
                    rusqlite::types::Value::Null => continue,
                    rusqlite::types::Value::Integer(i) => Value::from(i),
                    rusqlite::types::Value::Real(f) => Value::from(f),
                    rusqlite::types::Value::Text(s) => Value::from(s),
                    rusqlite::types::Value::Blob(_) => continue,
                };
                if n != "created_at" && n != "added_at" {
                    m.insert(n.clone(), v);
                }
            }
            Ok(m)
        }).unwrap() {
            out.push(r.unwrap());
        }
        if !out.is_empty() {
            rows.insert(t.to_string(), out);
        }
    }
    (clocks, live, rows)
}

#[test]
fn every_case_in_every_arrival_order() {
    let v: Value = serde_json::from_str(include_str!("../../notes/catalog-vectors.json")).unwrap();
    let mut cases = 0;
    for case in v["cases"].as_array().unwrap() {
        let name = case["name"].as_str().unwrap();
        let ops: Vec<Op> = serde_json::from_value(case["ops"].clone()).unwrap();
        let expect = &case["expect"];
        for (order_name, order) in case["orders"].as_object().unwrap() {
            let mut c = Catalog::in_memory(config()).unwrap();
            for i in order.as_array().unwrap() {
                let op = ops[i.as_u64().unwrap() as usize].clone();
                c.apply(vec![op], |_| None, |_, _| Verdict::Apply).unwrap();
            }
            assert_eq!(c.held(), 0, "{name}/{order_name}: ops never applied");
            let (clocks, live, rows) = snapshot(&c);
            assert_eq!(serde_json::to_value(&clocks).unwrap(), expect["clocks"], "{name}/{order_name}: clocks");
            assert_eq!(serde_json::to_value(&live).unwrap(), expect["live"], "{name}/{order_name}: live");
            let want: HashMap<String, Vec<HashMap<String, Value>>> = serde_json::from_value(expect["rows"].clone()).unwrap();
            assert_eq!(rows.keys().collect::<std::collections::BTreeSet<_>>(), want.keys().collect(), "{name}/{order_name}: tables with rows");
            for (t, wrows) in &want {
                assert_eq!(rows[t].len(), wrows.len(), "{name}/{order_name}: {t} row count");
                for (got, w) in rows[t].iter().zip(wrows) {
                    for (k, wv) in w {
                        assert_eq!(got.get(k), Some(wv), "{name}/{order_name}: {t}.{k}");
                    }
                }
            }
            cases += 1;
        }
    }
    assert_eq!(cases, 24, "six cases, four orders each");
}
