/// Files between devices. A message names its files by hash; the bytes stay on the device that
/// wrote them until another needs them. It sends `want` to the devices of everyone who shares a
/// conversation naming that hash; any of them holding it answers `offer` with the id the crate's
/// blob store gives it, and the asker fetches it from there: verified by the store on the way and
/// by this hash when it lands. A device is only offered what it could already see in one of its
/// conversations (or my photo, which is on my card). Small files are fetched as their message
/// arrives, so every device of mine holds what the others do.
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One file being asked for: who is waiting for it, who offered it, whether a fetch is running.
final class BlobWait {
	var waiters: [CheckedContinuation<URL?, Never>] = []
	var offers: [(device: DeviceId, id: String)] = []
	var fetching = false
}

extension LocalCore {
	/// Files this size and under come to every device as their message does; bigger ones when opened.
	static let prefetchLimit = 50 << 20

	/// Here, or fetched from a device that has it; nil when nobody who has it answers in time.
	func fetchBlob(_ hash: BlobHash) async -> URL? {
		let mine = blobPath(hash)
		if FileManager.default.fileExists(atPath: mine.path) { return mine }
		guard let t = transport else { return nil }
		let fresh: BlobWait? = lock.withLock {
			guard blobWaits[hash] == nil else { return nil }
			let w = BlobWait(); blobWaits[hash] = w; return w
		}
		if let fresh {
			let to = blobSources(hash).filter { t.isOnline($0) }
			let want = seal(.want(hash), conv: nil)
			trace("want \(hash.prefix(8)) from \(to.map { $0.prefix(8) }) (of \(blobSources(hash).count) that may have it)")
			for d in to { Task { _ = await t.send(want, to: d) } }
			// Nobody offered it in time: the ones waiting hear nil, and the next look asks again.
			Task { [weak self] in
				try? await Task.sleep(for: .seconds(to.isEmpty ? 0 : 20))
				self?.giveUp(hash, fresh)
			}
		}
		return await withCheckedContinuation { c in
			let now: URL?? = lock.withLock {
				if FileManager.default.fileExists(atPath: mine.path) { return .some(mine) }
				guard let w = blobWaits[hash] else { return .some(nil) }
				w.waiters.append(c)
				return .none
			}
			if let now { c.resume(returning: now) }
		}
	}

	private func giveUp(_ hash: BlobHash, _ w: BlobWait) {
		let waiters: [CheckedContinuation<URL?, Never>] = lock.withLock {
			guard blobWaits[hash] === w, !w.fetching else { return [] }
			blobWaits.removeValue(forKey: hash)
			return w.waiters
		}
		for c in waiters { c.resume(returning: nil) }
	}

	/// Every device, not this one, of someone who shares a conversation naming the file, or whose photo it is.
	func blobSources(_ hash: BlobHash) -> [DeviceId] {
		lock.withLock {
			store.query("""
				select distinct d.id from devices d where d.id<>? and (
					d.user in (select m.user from members m where m.conv in (select conv from events where type='message' and instr(body, ?) > 0))
					or d.user in (select user from people where avatar=?))
				""", [device, hash, hash]).compactMap { $0.string("id") }
		}
	}

	/// Whether `d` may have the file: a device of mine, or of someone in a conversation that names
	/// it, or it is my photo.
	func mayHave(_ hash: BlobHash, _ d: DeviceId) -> Bool {
		guard let u = user(of: d) else { return false }
		if u == user { return true }
		return lock.withLock {
			store.int("select count(*) as n from people where user=? and avatar=?", [user, hash]) > 0
				|| store.int("select count(*) as n from events e join members m on m.conv=e.conv where m.user=? and e.type='message' and instr(e.body, ?) > 0", [u, hash]) > 0
		}
	}

	/// They asked for a file: offer it if it's here and theirs to have.
	func wanted(_ hash: BlobHash, by d: DeviceId) {
		guard let t = transport else { return }
		let here = FileManager.default.fileExists(atPath: blobPath(hash).path), may = mayHave(hash, d)
		trace("\(d.prefix(8)) wants \(hash.prefix(8)): \(here ? "here" : "not here"), \(may ? "theirs to have" : "not theirs")")
		// Theirs, but not here yet (it is on its way to me too): offered the moment it lands.
		if !here, may { lock.withLock { _ = wantedBy[hash, default: []].insert(d) } }
		guard here, may else { return }
		let path = blobPath(hash)
		Task { [weak self] in
			guard let self, let id = await t.provide(path) else { return }
			_ = await t.send(self.seal(.offer(hash, id), conv: nil), to: d)
		}
	}

	/// A device has the file I asked for: fetch it, or queue the offer behind the fetch running.
	func offered(_ hash: BlobHash, id: String, by d: DeviceId) {
		trace("\(d.prefix(8)) offers \(hash.prefix(8))")
		// An offer after I stopped waiting (it came to them after I asked): still taken, if a
		// conversation of mine names it and it isn't here.
		let named = !FileManager.default.fileExists(atPath: blobPath(hash).path) && !blobSources(hash).isEmpty
		let start: Bool = lock.withLock {
			if blobWaits[hash] == nil, named { blobWaits[hash] = BlobWait() }
			guard let w = blobWaits[hash] else { return false }
			w.offers.append((d, id))
			guard !w.fetching else { return false }
			w.fetching = true
			return true
		}
		if start { Task { await fetchOffered(hash) } }
	}

	private func fetchOffered(_ hash: BlobHash) async {
		guard let t = transport else { return }
		// Straight to its place: the crate's store keeps a fetched file by referring to where it
		// exported it, so a file moved afterwards can't be handed on (it reset every fetch from a
		// device that had fetched it itself). The crate exports only once all of it is verified.
		let dest = blobPath(hash)
		while !FileManager.default.fileExists(atPath: dest.path),
			  let o = lock.withLock({ () -> (device: DeviceId, id: String)? in
				  guard let w = blobWaits[hash], !w.offers.isEmpty else { return nil }
				  return w.offers.removeFirst()
			  }) {
			if await t.fetch(o.id, from: o.device, to: dest), (try? fileHash(dest)) == hash { break }
			try? FileManager.default.removeItem(at: dest)
		}
		let url = FileManager.default.fileExists(atPath: dest.path) ? dest : nil
		let waiters = lock.withLock { blobWaits.removeValue(forKey: hash)?.waiters ?? [] }
		for c in waiters { c.resume(returning: url) }
		trace("\(hash.prefix(8)) \(url == nil ? "didn't come" : "is here")")
		// Whoever asked me while it was on its way gets it now.
		if url != nil { for d in lock.withLock({ wantedBy.removeValue(forKey: hash) ?? [] }) { wanted(hash, by: d) } }
	}

	/// A device that may hold files I lack came online: ask again for the small ones it may have
	/// (sent while it, or whoever had them, was away).
	func retryMissing(from d: DeviceId) {
		guard transport != nil else { return }
		let rows: [String] = lock.withLock {
			store.query("select e.body from events e join members m on m.conv=e.conv join devices v on v.user=m.user where v.id=? and e.type='message' and instr(e.body, '\"attachments\"') > 0 order by e.at desc limit 200", [d]).compactMap { $0.string("body") }
		}
		let missing = Set(rows.flatMap { decode(MessageBody.self, $0)?.attachments ?? [] }
			.filter { $0.size <= Self.prefetchLimit && !FileManager.default.fileExists(atPath: blobPath($0.hash).path) }.map(\.hash))
		guard !missing.isEmpty else { return }
		trace("\(d.prefix(8)) is here: asking again for \(missing.count) files")
		for h in missing { Task { [weak self] in _ = await self?.fetchBlob(h) } }
	}

	/// Files in arriving messages, small enough to come along: fetched now, so they're here when looked at.
	func prefetch(_ events: [WireEvent]) {
		guard transport != nil else { return }
		let files = events.filter { $0.type == .message }.flatMap { decode(MessageBody.self, $0.body)?.attachments ?? [] }
		for a in files where a.size <= Self.prefetchLimit && !FileManager.default.fileExists(atPath: blobPath(a.hash).path) {
			Task { [weak self] in _ = await self?.fetchBlob(a.hash) }
		}
	}

	/// A file into the store: hashed as it streams, copied once, its type and (for an image) its size read.
	func addBlob(_ url: URL) throws -> Attachment {
		let hash = try fileHash(url)
		let dest = blobPath(hash)
		if !FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.copyItem(at: url, to: dest) }
		let type = UTType(filenameExtension: url.pathExtension.lowercased())
		let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? 0
		var a = Attachment(hash: hash, key: hex(randomBytes(8)), mime: type?.preferredMIMEType ?? "application/octet-stream", size: size, name: url.lastPathComponent)
		if type?.conforms(to: .image) == true, let (w, h) = pixelSize(dest) { a.width = w; a.height = h }
		return a
	}
}

/// SHA-256 of a file, a megabyte at a time.
public func fileHash(_ url: URL) throws -> String {
	let h = try FileHandle(forReadingFrom: url)
	defer { try? h.close() }
	var sha = SHA256()
	while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { sha.update(data: chunk) }
	return sha.finalize().map { String(format: "%02x", $0) }.joined()
}

/// An image's size as it is shown: width and height swapped when its orientation turns it.
func pixelSize(_ url: URL) -> (Int, Int)? {
	guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
		  let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
		  let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
	return (p[kCGImagePropertyOrientation] as? Int ?? 1) >= 5 ? (h, w) : (w, h)
}
