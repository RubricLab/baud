/// Disappearing messages. The setting is a state line ("disappear", in seconds); each message
/// written while it is on carries its own `ttl`, so when it goes never depends on the order the
/// setting arrived in. My own messages go `ttl` after they were sent; anyone else's `ttl` after
/// any device of mine first read them (the earliest read receipt of mine at or past it), and an
/// unread one waits. Each device does this on its own: the message is blanked as a redaction
/// blanks one, with its edits, its pin and its files, and its feed row stays so the clocks stay
/// whole and nobody sends it again.
import Foundation

extension LocalCore {
	/// When a message goes from this device: mine at `at + ttl`, anyone else's `ttl` after my
	/// first read of it; nil without a `ttl`, or while it's unread. Under the lock.
	func expiry(of e: WireEvent) -> Double? {
		guard e.type == .message, let ttl = decode(MessageBody.self, e.body)?.ttl, ttl > 0 else { return nil }
		if e.user == user { return e.at + Double(ttl) }
		guard let read = store.one("select min(at) as t from receipts where conv=? and user=? and kind='read' and lamport>=?", [e.conv, user, e.lamport])?.double("t") else { return nil }
		return read + Double(ttl)
	}

	/// A message already blanked here (gone, or redacted). Under the lock.
	func gone(_ id: EventId) -> Bool {
		store.one("select body from events where id=? and type='message'", [id])?.string("body") == "{}"
	}

	/// My read of a conversation up to `lamport`, at `at`, on this device or another of mine:
	/// the clock starts on everyone else's disappearing messages it covers, and an earlier read
	/// that arrives late moves it sooner. Whatever is past its time goes at once.
	func startClocks(_ conv: ConversationId, upTo lamport: Int, at: Double) {
		let changed = lock.withLock {
			store.run("update events set expires_at=?+\(Self.ttl) where conv=? and type='message' and user<>? and lamport<=? and body like '%\"ttl\":%' and \(Self.ttl)>0 and (expires_at is null or expires_at>?+\(Self.ttl))", [at, conv, user, lamport, at])
		}
		if changed > 0 { expire() }
	}

	/// A message body's `ttl` in SQL, as the decoder reads it: a whole number, or null for a body
	/// that isn't JSON (which `json_extract` would fail the whole statement on) or has none.
	static let ttl = "(case when json_valid(body) then (case when json_type(body,'$.ttl')='integer' then json_extract(body,'$.ttl') end) end)"

	/// Every disappearing message whose time has come goes from this device: its words and files
	/// blanked as `redact` blanks them (text null, body '{}', out of search), the edits that carry
	/// its words too, its pin, and each file no message still here names (nor anyone's photo).
	/// The timelines and the list redraw; `.expired` takes their notifications away. Then the
	/// sweep waits for the next one.
	@discardableResult
	func expire(now: Date = Date()) -> Int {
		var files = Set<BlobHash>()
		var byConv: [ConversationId: [EventId]] = [:]
		lock.withLock {
			let due = store.query("select id, conv, body from events where type='message' and expires_at<=? and body<>'{}' order by lamport", [now.timeIntervalSince1970])
			guard !due.isEmpty else { return }
			store.transaction {
				for r in due {
					guard let id = r.string("id"), let conv = r.string("conv") else { continue }
					for a in decode(MessageBody.self, r.string("body"))?.attachments ?? [] { files.insert(a.hash) }
					store.run("delete from fts where event=?", [id])
					store.run("update events set text=null, body='{}' where id=? or (type='edit' and target=?)", [id, id])
					store.run("delete from pins where event=?", [id])
					byConv[conv, default: []].append(id)
				}
			}
			for h in files where store.int("select count(*) as n from events where type='message' and instr(body, ?) > 0", [h]) == 0 && store.int("select count(*) as n from people where avatar=?", [h]) == 0 {
				try? FileManager.default.removeItem(at: blobPath(h))
			}
		}
		if !byConv.isEmpty {
			trace("expired \(byConv.values.map(\.count).reduce(0, +)) in \(byConv.count) conversations")
			for (c, ids) in byConv { emit(.expired(c, ids)); emit(.conversation(c)) }
			emit(.conversations)
		}
		scheduleExpiry()
		return byConv.values.map(\.count).reduce(0, +)
	}

	/// The sweep waits for the next message due to go, while this core runs; a sooner one
	/// arriving moves it up.
	func scheduleExpiry() {
		lock.withLock {
			let next = store.one("select min(expires_at) as t from events where type='message' and expires_at is not null and body<>'{}'")?.double("t")
			guard next != expiryDue else { return }
			expiryTimer?.cancel()
			expiryDue = next
			guard let next else { expiryTimer = nil; return }
			expiryTimer = Task { [weak self] in
				try? await Task.sleep(for: .seconds(max(0, next - Date().timeIntervalSince1970)))
				guard !Task.isCancelled, let self else { return }
				self.lock.withLock { self.expiryTimer = nil; self.expiryDue = nil }
				self.expire()
			}
		}
	}
}
