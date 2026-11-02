# The catalog format

The op log behind `peer::catalog`. The format came from darkroom, which implements it in
TypeScript, and it is shared byte for byte with other apps' implementations. The test vectors in
`catalog-vectors.json` beside this file are generated from darkroom's TypeScript implementation;
every implementation must reproduce each case's `expect` for every listed arrival order.

## Op

One op is one field write on one row of one table in one group (darkroom: space).

```
Op {
  id:        ulid (string, unique per op)
  space:     group id (string)
  device:    hex of the writing device's Ed25519 public key (64 chars)
  hlc:       "<unix ms, 14 digits zero-padded>:<counter, 6 digits>:<device hex>"
  table:     table name (string; must be in the app's synced-table list)
  row:       row key (string; see Row keys)
  field:     camelCase field name, or "__row" for a tombstone
  value:     JSON value (null is a legal value); null for a tombstone
  tombstone: bool
  sig:       base64 Ed25519 signature by `device` over canonical(op)
}
canonical(op) = JSON.stringify([id, space, device, hlc, table, row, field, value, tombstone])
```

- **HLC** is a string and compares as a string. Monotonic per device: if the wall clock is at or
  before the last ms used, keep the ms and bump the counter. Observing a remote HLC with a larger
  ms advances the local clock to it. Equal ms resolve by counter, then by device hex, which makes
  every comparison total and every device agree on winners.
- **Field names** travel in camelCase; storage columns are snake_case. The converter is
  `replace(/[A-Z]/g, c => "_" + lower(c))`.
- **Values** are JSON. Objects and arrays are stored as JSON text; dates as unix ms.

## Row keys

Default key column is `id`. Composite keys are the key values joined by `|`, in the table's
declared key order:

| table | key |
|---|---|
| analysis, edit | asset_id |
| collection_asset | collection_id, asset_id |
| collection_member | collection_id, user_id |
| entity_link | entity_id, instance_id |
| holding | device, hash |
| rendition | original, kind, params |
| space_member | space, user |
| tag | asset_id, name |
| claim | asset_id, lane |
| stream | asset_id, kind |
| device (one row per space) | `<space>/<device>` as `id` |

An app's `peer::catalog` configuration is exactly: the synced tables, their key columns, and the
schema (SQL) that creates them. Nothing else about the app enters the crate.

## Apply (per row, all delivered ops for that row together)

1. For each field in the batch (tombstone counts as field `__row`): the op with the greatest HLC
   among the batch and the stored `field_clock` wins. Store the winner's HLC in `field_clock`.
2. **Liveness** is decided from clocks alone, so arrival order never matters: the row is live iff
   the newest non-`__row` field clock is greater than the `__row` clock. A later edit beats an
   earlier delete and revives the row with all its winning fields; a delete newer than every
   edit removes the row, and an older edit arriving afterwards does not bring it back.
3. Live: upsert the row with the winning fields (a new row is one INSERT carrying every winning
   field so NOT NULL columns hold). Dead: delete the row. Either way record `(table, row, space,
   deleted)` in `row_space`.
4. A batch applies as one transaction. If a row cannot be created yet (a NOT NULL column has not
   arrived) the batch fails and **every op in it is held**, to be retried together with later
   deliveries. Holding is not an error.
5. Every applied op is appended to the local `op` log (idempotent on `id`); applying the same op
   twice changes nothing.

## Marks and exchange

- Each node keeps, per (space, device), the HLC up to which it holds every op of that device
  **contiguously**: `marks(space) → { device: hlc }`.
- Pull: send your marks; the peer answers `since(space, marks, limit)`: its ops newer than your
  mark per device, in HLC order, with `more` when the limit cut it.
- Push: on local write, send the ops to every online peer of the space at once; pulls catch
  whoever missed them.
- Ops that fail verification for a reason that may change (certificate not yet known, role not
  yet granted, HLC too far in the future) are **held** in `sync_held` and re-verified when
  membership or time catches up; forgeries are dropped.

## Authorization (darkroom's rules; the crate's group member list replaces the space tables)

- `device` must carry a certificate signed by a user key; the signature over `canonical(op)` must
  verify.
- A device may write its own `device` row in any space it is in; a `holding` row for its own
  device as any member; `space`/`space_member`/`device` rows as admin (a member may null their own
  role or set their own name); `user` rows only in their personal space as admin; everything else
  as admin or editor. Viewers' writes are refused.
- Role is evaluated **at the op's HLC** from the member row's history, so a demotion does not
  retroactively invalidate earlier ops.

## Vectors (catalog-vectors.json)

Six cases, each applied one op per delivery in four arrival orders (forward, reverse, two seeded
shuffles) with held-and-retry as above; every order yields the same `expect`
(`rows` per table without local wall-clock defaults, `clocks` = field_clock, `live` = row_space):

1. `lww-same-field`: three devices write one field; the greatest HLC wins.
2. `lww-tiebreak-counter-then-device`: same millisecond; counter then device hex decides.
3. `edit-after-delete-revives`: tombstone then a later edit; row live with the edit.
4. `delete-after-edits-stays-dead`: edit, tombstone, then an older edit arriving late; row gone.
5. `composite-keys`: `collection_asset` and `tag` rows with `|` keys; position updated by LWW.
6. `idempotent-and-json-values`: every op delivered twice; an object value stored as JSON text.

The vectors are regenerated from darkroom's implementation; a new case is added there first,
never by hand here.

## Comparison rule for the vectors

An implementation passes a case when, for every arrival order, its `clocks` (field_clock) and
`live` (row_space) equal `expect` whole, and its `rows` equal `expect.rows` on the columns the
case's ops set (camelCase → snake_case, objects as JSON text). Local wall-clock defaults
(`created_at`, `added_at`) are left out on both sides. A schemaless implementation has no
NOT NULL holds and simply applies every op; a typed one (TypeScript, Rust) must hold a batch whose
row cannot exist yet and retry it with later deliveries. Implementations that pass: darkroom's
TypeScript (the generator), a Swift one, and `peer::catalog` in Rust (`peer/tests/catalog_vectors.rs`).
