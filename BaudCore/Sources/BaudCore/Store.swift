/// The thinnest wrapper over the system SQLite the stub needs, and its schema. FTS5 is in
/// Apple's libsqlite3, so search is real. The crate's store (rusqlite, SQLCipher) replaces this
/// whole file; nothing above it knows SQL.
import Foundation
import SQLite3

public final class Store: @unchecked Sendable {
	let handle: OpaquePointer
	let lock = NSRecursiveLock()

	public init(path: String) throws {
		var h: OpaquePointer?
		guard sqlite3_open_v2(path, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let h else {
			throw CoreError.store("Couldn't open the store at \(path).")
		}
		handle = h
		if path != ":memory:" { exec("pragma journal_mode = wal; pragma synchronous = normal;") }
		exec(Store.schema)
		exec("alter table people add column avatar text")  // older stores; a no-op error when it exists
		exec("alter table people add column peer_card blob")
		exec("alter table people add column vouched integer default 0")
		exec("alter table events add column via text")
		// Disappearing messages: the conversation's setting in seconds (0, off), and when each
		// message goes on this device, once that is known.
		exec("alter table conversations add column disappear int default 0")
		exec("alter table events add column expires_at real")
		exec("create index if not exists events_expires on events(expires_at) where expires_at is not null")
	}
	deinit { sqlite3_close(handle) }

	/// Every conversation and message, deleted without being read, and the file rewritten so the
	/// bytes are gone too. People, devices, links and my name stay.
	func wipeMessages() {
		exec("""
		pragma secure_delete = on;
		begin;
		delete from events; delete from fts; delete from receipts; delete from reads; delete from envelopes;
		delete from handed; delete from pins; delete from members; delete from conversations;
		delete from me where k like 'key:%' or k like 'hidden:%' or k like 'cleared:%';
		delete from devices where user in (select user from people where demo=1);
		delete from people where demo=1;
		commit;
		""")
		exec("vacuum")
	}

	func exec(_ sql: String) { lock.withLock { _ = sqlite3_exec(handle, sql, nil, nil, nil) } }

	@discardableResult
	func run(_ sql: String, _ args: [Bindable?] = []) -> Int {
		lock.withLock {
			let s = prepare(sql, args)
			defer { sqlite3_finalize(s) }
			sqlite3_step(s)
			return Int(sqlite3_changes(handle))
		}
	}
	func query(_ sql: String, _ args: [Bindable?] = []) -> [Row] {
		lock.withLock {
			let s = prepare(sql, args)
			defer { sqlite3_finalize(s) }
			var rows: [Row] = []
			let n = sqlite3_column_count(s)
			while sqlite3_step(s) == SQLITE_ROW {
				var r: [String: Bindable?] = [:]
				for i in 0..<n {
					let name = String(cString: sqlite3_column_name(s, i))
					switch sqlite3_column_type(s, i) {
					case SQLITE_INTEGER: r[name] = Int(sqlite3_column_int64(s, i))
					case SQLITE_FLOAT: r[name] = sqlite3_column_double(s, i)
					case SQLITE_TEXT: r[name] = String(cString: sqlite3_column_text(s, i))
					case SQLITE_BLOB: if let b = sqlite3_column_blob(s, i) { r[name] = Data(bytes: b, count: Int(sqlite3_column_bytes(s, i))) } else { r[name] = Data() }
					default: r[name] = nil
					}
				}
				rows.append(Row(r))
			}
			return rows
		}
	}
	func one(_ sql: String, _ args: [Bindable?] = []) -> Row? { query(sql, args).first }
	func int(_ sql: String, _ args: [Bindable?] = []) -> Int { one(sql, args)?.int("n") ?? 0 }
	func transaction<T>(_ body: () throws -> T) rethrows -> T {
		try lock.withLock {
			exec("begin")
			do { let r = try body(); exec("commit"); return r } catch { exec("rollback"); throw error }
		}
	}

	private func prepare(_ sql: String, _ args: [Bindable?]) -> OpaquePointer {
		var s: OpaquePointer?
		guard sqlite3_prepare_v2(handle, sql, -1, &s, nil) == SQLITE_OK, let s else {
			fatalError("sqlite: \(String(cString: sqlite3_errmsg(handle))) in \(sql)")
		}
		let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
		for (i, a) in args.enumerated() {
			let n = Int32(i + 1)
			switch a {
			case nil: sqlite3_bind_null(s, n)
			case let v as Int: sqlite3_bind_int64(s, n, Int64(v))
			case let v as Double: sqlite3_bind_double(s, n, v)
			case let v as String: sqlite3_bind_text(s, n, v, -1, transient)
			case let v as Bool: sqlite3_bind_int64(s, n, v ? 1 : 0)
			case let v as Date: sqlite3_bind_double(s, n, v.timeIntervalSince1970)
			case let v as Data: _ = v.withUnsafeBytes { sqlite3_bind_blob(s, n, $0.baseAddress, Int32(v.count), transient) }
			default: fatalError("sqlite: unbindable \(type(of: a!))")
			}
		}
		return s
	}

	static let schema = """
	create table if not exists me(k text primary key, v text);
	create table if not exists people(user text primary key, name text, fingerprint text, verified int default 0, contact int default 0, met_at real, demo int default 0, avatar text);
	create table if not exists devices(id text primary key, user text, name text, kind text, added_at real, last_online real);
	create table if not exists conversations(id text primary key, kind text, name text, topic text, space text, created_at real, is_default int default 0, demo int default 0);
	create table if not exists members(conv text, user text, admin int default 0, joined_at real, primary key(conv, user));
	create table if not exists events(id text primary key, conv text, device text, seq int, user text, at real, lamport int, type text, text text, reply text, thread text, target text, body text, carried_by text);
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
	"""
}

public struct Row {
	let d: [String: Bindable?]
	init(_ d: [String: Bindable?]) { self.d = d }
	func string(_ k: String) -> String? { d[k] as? String }
	func int(_ k: String) -> Int? { (d[k] as? Int) ?? (d[k] as? Double).map(Int.init) }
	func double(_ k: String) -> Double? { (d[k] as? Double) ?? (d[k] as? Int).map(Double.init) }
	func date(_ k: String) -> Date? { double(k).map { Date(timeIntervalSince1970: $0) } }
	func bool(_ k: String) -> Bool { (int(k) ?? 0) != 0 }
}

public protocol Bindable {}
extension Int: Bindable {}
extension Double: Bindable {}
extension String: Bindable {}
extension Bool: Bindable {}
extension Date: Bindable {}
extension Data: Bindable {}
