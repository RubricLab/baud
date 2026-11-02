/// Calls on the wire. A call is a mesh: each pair of devices in it holds its own live connection
/// (ALPN `baud-call/1`), one stream for the signals (ring, accept, roster, join, leave, mute,
/// keyframe, stats, caps) as length-prefixed JSON, datagrams for the media: an Opus frame every 20
/// ms, and each video frame cut into pieces no bigger than a datagram. Two people are a mesh of one
/// link. Each end says first what its media can do (`caps`); a device that never says (baud 0.2.15
/// and before, which drop a signal they can't read) is sent only what those understand: H.264,
/// the first frame form, plain datagrams. One that says media 2 gets its datagrams numbered and
/// stamped (`Sequenced`), says back what arrived (`Feedback`), and is sent timed frames (`VideoFrame`)
/// in HEVC when it decodes that. Pure values here, so what drops, reorders and reassembles is
/// tested without a camera, a microphone or a network.
import Foundation

/// What a device's call media can do, said first on every call link.
public struct MediaCaps: Codable, Hashable, Sendable {
	/// 2: sequenced datagrams and feedback, timed frames, refreshes in place of keyframes.
	public var media: Int
	/// Encodes and decodes HEVC in hardware.
	public var hevc: Bool
	public init(media: Int, hevc: Bool) { self.media = media; self.hevc = hevc }
}

/// A device in a call, and whose it is.
public struct CallPeer: Codable, Hashable, Sendable {
	public var device: DeviceId
	public var user: UserId
	public var name: String
	public init(device: DeviceId, user: UserId, name: String) { self.device = device; self.user = user; self.name = name }
}

/// "There's a call in this chat, and these are in it": sent by everyone in a call to the chat's
/// other online devices now and then, so a member who wasn't rung (or missed it) can join. Empty
/// `peers` means it's over; `until` is when to stop believing it without hearing again.
public struct CallPresence: Codable, Hashable, Sendable {
	public var id: String
	public var video: Bool
	public var peers: [CallPeer]
	public var until: Double
	public init(id: String, video: Bool, peers: [CallPeer], until: Double) { self.id = id; self.video = video; self.peers = peers; self.until = until }
}

public indirect enum CallSignal: Codable, Hashable, Sendable {
	/// The caller's device, to each online device of each person it calls.
	case ring(id: String, conv: ConversationId, video: Bool, user: UserId, name: String)
	/// To a device that just answered: everyone else already in the call, to connect to.
	case roster([CallPeer])
	/// The first signal on a link a newcomer opens to someone already in the call.
	case join(id: String, user: UserId, name: String, video: Bool)
	/// The callee's device is showing it.
	case ringing
	/// Answered on this device; `video` when its camera comes on.
	case accept(video: Bool)
	case decline
	/// Already on a call.
	case busy
	/// The caller stopped ringing this device: "elsewhere" (answered on another), "hangup", "timeout".
	case cancel(reason: String)
	/// This device is leaving the call (the others carry on without it).
	case end
	/// Mic and camera, whenever either changes.
	case state(muted: Bool, camera: Bool)
	/// The decoder lost its place: the next frame should be a keyframe.
	case keyframe
	/// Once a second, what arrived: the sender adapts its video to it.
	case stats(audioLoss: Double, videoFps: Double, videoLoss: Double)
	/// For a device I can't reach directly, through one in the call that reaches us both: it passes
	/// the signal on to `to`, which takes it as from `from`.
	case forward(from: DeviceId, to: DeviceId, signal: CallSignal)
	/// What my media can do: the first thing on a link, from both ends. Devices from before it was
	/// said drop it unread, and so stay on what they understand.
	case caps(MediaCaps)

	/// Four bytes of length, big-endian, then the JSON.
	public var framed: Data {
		let body = (try? JSONEncoder().encode(self)) ?? Data()
		var n = UInt32(body.count).bigEndian
		return Data(bytes: &n, count: 4) + body
	}
}

/// Signals out of a byte stream that arrives in pieces of any size.
public struct SignalReader: Sendable {
	private var buffer = Data()
	public init() {}
	public mutating func add(_ bytes: Data) -> [CallSignal] {
		buffer += bytes
		var out: [CallSignal] = []
		while buffer.count >= 4 {
			let n = Int(buffer.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
			guard n < 1 << 20 else { buffer.removeAll(); break }
			guard buffer.count >= 4 + n else { break }
			let body = buffer.dropFirst(4).prefix(n)
			if let s = try? JSONDecoder().decode(CallSignal.self, from: Data(body)) { out.append(s) }
			buffer = Data(buffer.dropFirst(4 + n))
		}
		return out
	}
}

/// What a datagram carries, by its first byte. A device on media 1 drops the kinds it doesn't know;
/// it's never sent them.
public enum MediaKind: UInt8, Sendable {
	case audio = 1, video = 2, relay = 3
	/// Media 2: a numbered, stamped datagram around one of the others (or padding).
	case sequenced = 4
	/// Media 2: what arrived, back to the sender.
	case feedback = 5
	/// Media 2: bytes that only probe the path, inside a sequenced datagram.
	case padding = 6
	/// Media 2: a piece of a video frame with Reed-Solomon parity (`VideoFragment.code`).
	case coded = 7
}

/// A datagram for a device the sender can't reach directly, through one that reaches both:
/// [3][from: 8 bytes][to: 8 bytes][the datagram]. Devices by the first 8 bytes of their id.
public struct RelayPacket: Equatable, Sendable {
	public static let header = 17
	public var from: Data
	public var to: Data
	public var inner: Data
	public init(from: DeviceId, to: DeviceId, inner: Data) { self.from = Self.short(from); self.to = Self.short(to); self.inner = inner }
	public init?(_ d: Data) {
		guard d.count > Self.header, d.first == MediaKind.relay.rawValue else { return nil }
		let b = d.startIndex
		from = Data(d[(b + 1)..<(b + 9)]); to = Data(d[(b + 9)..<(b + 17)]); inner = Data(d[(b + 17)...])
	}
	public var data: Data { Data([MediaKind.relay.rawValue]) + from + to + inner }
	/// A device id (hex) as the 8 bytes a relay packet names it by.
	public static func short(_ device: DeviceId) -> Data {
		var out = Data()
		var chars = Array(device.utf8.prefix(16))
		while chars.count < 16 { chars.append(UInt8(ascii: "0")) }
		for i in stride(from: 0, to: 16, by: 2) {
			let hi = hexValue(chars[i]), lo = hexValue(chars[i + 1])
			out.append(hi << 4 | lo)
		}
		return out
	}
	private static func hexValue(_ c: UInt8) -> UInt8 {
		switch c { case 48...57: return c - 48; case 97...102: return c - 87; case 65...70: return c - 55; default: return 0 }
	}
}

/// One Opus frame, and the one before it again: [1][seq u32][level u8][len u16][opus…][previous…].
/// The level (0–255) is the speaker's loudness, so the other side can draw it without decoding;
/// the previous frame (about 80 bytes) means one lost datagram costs nothing.
public struct AudioPacket: Equatable, Sendable {
	public var seq: UInt32
	public var level: UInt8
	public var payload: Data
	public var previous: Data?
	public init(seq: UInt32, level: UInt8, payload: Data, previous: Data? = nil) { self.seq = seq; self.level = level; self.payload = payload; self.previous = previous }
	public var data: Data {
		var d = Data([MediaKind.audio.rawValue])
		d.append(contentsOf: be32(seq)); d.append(level); d.append(contentsOf: be16(UInt16(payload.count))); d.append(payload)
		if let previous { d.append(previous) }
		return d
	}
	public init?(_ d: Data) {
		let b = [UInt8](d)
		guard b.count > 8, b[0] == MediaKind.audio.rawValue else { return nil }
		seq = u32(b, 1); level = b[5]
		let n = Int(b[6]) << 8 | Int(b[7])
		guard n > 0, 8 + n <= b.count else { return nil }
		payload = Data(b[8..<8 + n])
		previous = 8 + n < b.count ? Data(b[(8 + n)...]) : nil
	}
}

/// One piece of a video frame: [2][frame u32][index u16][count u16][flags u8][bytes…]. Flags: bit 0
/// keyframe; bit 1 parity; bits 2–7 the group size k. Data pieces are numbered 0..<count; after
/// every k of them comes a parity piece (index = the group's number), the XOR of the group's
/// length-prefixed payloads, which rebuilds any one piece of the group that doesn't arrive.
/// Media 2's coded form: [7][frame u32][index u16][count u16][flags u8: key, parity][block u8]
/// [rows u8][bytes…]: data pieces in blocks of `block`, each block followed by `rows` Reed-Solomon
/// parity pieces (index = block × rows + row), any `block` of which bring the block back.
public struct VideoFragment: Equatable, Sendable {
	public static let header = 10
	public static let codedHeader = 12
	public var frame: UInt32
	public var index: UInt16
	public var count: UInt16
	public var key: Bool
	public var parity: Bool
	/// XOR: the group size; coded: the block size.
	public var group: Int
	/// Coded: parity pieces per block (0 for the XOR form).
	public var rows: Int
	public var payload: Data
	public init(frame: UInt32, index: UInt16, count: UInt16, key: Bool, parity: Bool = false, group: Int = 0, rows: Int = 0, payload: Data) {
		self.frame = frame; self.index = index; self.count = count; self.key = key; self.parity = parity; self.group = group; self.rows = rows; self.payload = payload
	}
	public var data: Data {
		var d = Data(capacity: Self.codedHeader + payload.count)
		d.append(rows > 0 ? MediaKind.coded.rawValue : MediaKind.video.rawValue)
		d.append(contentsOf: be32(frame)); d.append(contentsOf: be16(index)); d.append(contentsOf: be16(count))
		if rows > 0 {
			d.append((key ? 1 : 0) | (parity ? 2 : 0)); d.append(UInt8(group)); d.append(UInt8(rows))
		} else {
			d.append((key ? 1 : 0) | (parity ? 2 : 0) | UInt8(min(63, group)) << 2)
		}
		d.append(payload)
		return d
	}
	public init?(_ d: Data) {
		let b = [UInt8](d)
		guard b.count > Self.header, b[0] == MediaKind.video.rawValue || b[0] == MediaKind.coded.rawValue else { return nil }
		frame = u32(b, 1); index = UInt16(b[5]) << 8 | UInt16(b[6]); count = UInt16(b[7]) << 8 | UInt16(b[8])
		key = b[9] & 1 == 1; parity = b[9] & 2 == 2
		if b[0] == MediaKind.coded.rawValue {
			guard b.count > Self.codedHeader else { return nil }
			group = Int(b[10]); rows = Int(b[11])
			payload = Data(b[Self.codedHeader...])
			guard count > 0, group > 0, parity ? rows > 0 : index < count else { return nil }
		} else {
			group = Int(b[9] >> 2); rows = 0
			payload = Data(b[Self.header...])
			guard count > 0, parity ? group > 0 : index < count else { return nil }
		}
	}

	/// A frame cut into datagrams of at most `mtu` bytes, with a parity piece after every `group`
	/// data pieces (0: none).
	public static func cut(frame: UInt32, key: Bool, bytes: Data, mtu: Int, group: Int = 0) -> [Data] {
		let room = max(64, mtu - header - 2)
		let n = max(1, (bytes.count + room - 1) / room)
		guard n <= Int(UInt16.max) else { return [] }
		var out: [Data] = []
		var parity = Data()
		for i in 0..<n {
			let s = bytes.startIndex + i * room
			let piece = Data(bytes[s..<min(bytes.endIndex, s + room)])
			out.append(VideoFragment(frame: frame, index: UInt16(i), count: UInt16(n), key: key, group: group, payload: piece).data)
			guard group > 0 else { continue }
			parity = xor(parity, prefixed(piece))
			if (i + 1) % group == 0 || i == n - 1 {
				out.append(VideoFragment(frame: frame, index: UInt16(i / group), count: UInt16(n), key: key, parity: true, group: group, payload: parity).data)
				parity = Data()
			}
		}
		return out
	}

	/// Media 2: a frame cut into datagrams of at most `mtu` bytes, in blocks of up to
	/// `Erasure.block` (as even as they come), each followed by enough Reed-Solomon parity for the
	/// `loss` the path shows (`Erasure.parity(for:loss:)`; none at all when `loss` is nil).
	public static func code(frame: UInt32, key: Bool, bytes: Data, mtu: Int, loss: Double?) -> [Data] {
		let room = max(64, mtu - codedHeader - 2)
		let n = max(1, (bytes.count + room - 1) / room)
		guard n <= Int(UInt16.max) else { return [] }
		let blocks = (n + Erasure.block - 1) / Erasure.block
		let size = (n + blocks - 1) / blocks
		let rows = loss.map { Erasure.parity(for: size, loss: $0) } ?? 0
		var out: [Data] = []
		for b in 0..<blocks {
			let range = (b * size)..<min(n, (b + 1) * size)
			let pieces = range.map { i in Data(bytes[(bytes.startIndex + i * room)..<min(bytes.endIndex, bytes.startIndex + (i + 1) * room)]) }
			for (i, p) in zip(range, pieces) { out.append(VideoFragment(frame: frame, index: UInt16(i), count: UInt16(n), key: key, group: size, rows: max(1, rows), payload: p).data) }
			guard rows > 0 else { continue }
			for (j, p) in Erasure.parity(pieces, m: rows).enumerated() {
				out.append(VideoFragment(frame: frame, index: UInt16(b * rows + j), count: UInt16(n), key: key, parity: true, group: size, rows: rows, payload: p).data)
			}
		}
		return out
	}
}

/// One encoded picture, whole, as it travels before it's cut into fragments. The first form, which
/// every version decodes: [flags: bit 0 key][if key: count u8, then each parameter set as u16 length
/// and bytes][the NAL units, each with a 4-byte length]. The timed form (flag bit 3), only for a
/// device on media 2, puts the moment of capture after the flags (u32 µs, the sender's clock), and
/// may be HEVC (bit 1) or a refresh (bit 2: a P frame that refers only to a picture every receiver
/// said it has, so it decodes after a loss with no keyframe).
public struct VideoFrame: Equatable, Sendable {
	public var key: Bool
	public var hevc: Bool
	public var refresh: Bool
	/// nil for the first form.
	public var capture: UInt32?
	/// SPS and PPS (and VPS first, for HEVC), on a keyframe.
	public var sets: [Data]
	public var nals: Data
	public init(key: Bool, hevc: Bool = false, refresh: Bool = false, capture: UInt32? = nil, sets: [Data] = [], nals: Data) {
		self.key = key; self.hevc = hevc; self.refresh = refresh; self.capture = capture; self.sets = sets; self.nals = nals
	}

	public var data: Data {
		var d = Data([(key ? 1 : 0) | (hevc ? 2 : 0) | (refresh ? 4 : 0) | (capture != nil ? 8 : 0)])
		if let capture { d.append(contentsOf: be32(capture)) }
		if key {
			d.append(UInt8(sets.count))
			for s in sets { d.append(contentsOf: be16(UInt16(s.count))); d.append(s) }
		}
		d.append(nals)
		return d
	}

	public init?(_ d: Data) {
		let b = [UInt8](d)
		guard b.count > 1 else { return nil }
		key = b[0] & 1 == 1; hevc = b[0] & 2 == 2; refresh = b[0] & 4 == 4
		var i = 1
		if b[0] & 8 == 8 { guard b.count >= 5 else { return nil }; capture = u32(b, 1); i = 5 } else { capture = nil }
		sets = []
		if key {
			guard i < b.count else { return nil }
			let count = Int(b[i]); i += 1
			for _ in 0..<count {
				guard i + 2 <= b.count else { return nil }
				let n = Int(b[i]) << 8 | Int(b[i + 1]); i += 2
				guard i + n <= b.count else { return nil }
				sets.append(Data(b[i..<i + n])); i += n
			}
		}
		guard i < b.count else { return nil }
		nals = Data(b[i...])
	}
}

/// A payload with its length in front, so one rebuilt from parity knows where it ends.
func prefixed(_ d: Data) -> Data { Data(be16(UInt16(d.count))) + d }
/// XOR, the shorter padded with zeros.
func xor(_ a: Data, _ b: Data) -> Data {
	var out = [UInt8](a.count >= b.count ? a : b)
	let other = [UInt8](a.count >= b.count ? b : a)
	for i in 0..<other.count { out[i] ^= other[i] }
	return Data(out)
}

/// Frames back from their pieces, in order. A frame whose pieces never all came is skipped once
/// `patience` later frames are whole (three, by default); after a gap only a keyframe can be
/// decoded, so frames wait for one (and `needsKeyframe` says to ask). A keyframe that completes
/// ahead of a gap jumps it. For media 2 a refresh comes marked as a keyframe: it decodes after a gap.
public struct VideoReassembler: Sendable {
	public struct Frame: Equatable, Sendable { public var id: UInt32; public var key: Bool; public var bytes: Data }
	private var partial: [UInt32: [UInt16: Data]] = [:]
	private var parities: [UInt32: [Int: Data]] = [:]
	private var counts: [UInt32: (count: UInt16, key: Bool, group: Int, rows: Int)] = [:]
	/// Pieces rebuilt from parity.
	public private(set) var recovered = 0
	private var ready: [UInt32: Frame] = [:]
	private var next: UInt32?
	public private(set) var needsKeyframe = true
	public private(set) var delivered = 0
	public private(set) var lost = 0
	private let patience: UInt32
	public init(patience: Int = 3) { self.patience = UInt32(max(1, patience)) }

	public mutating func add(_ f: VideoFragment) -> [Frame] {
		if let n = next, f.frame < n { return [] }
		if ready[f.frame] != nil { return [] }
		if partial[f.frame] == nil { partial[f.frame] = [:] }
		if f.parity { parities[f.frame, default: [:]][Int(f.index)] = f.payload } else { partial[f.frame]![f.index] = f.payload }
		counts[f.frame] = (f.count, f.key, f.group, f.rows)
		if f.rows > 0 { decode(f.frame) } else if f.group > 0 { rebuild(f.frame) }
		if let parts = partial[f.frame], parts.count == Int(f.count) {
			var bytes = Data()
			for i in 0..<f.count { bytes += parts[i] ?? Data() }
			ready[f.frame] = Frame(id: f.frame, key: f.key, bytes: bytes)
			partial[f.frame] = nil; counts[f.frame] = nil; parities[f.frame] = nil
		}
		return drain()
	}

	/// Coded: any block of this frame with pieces missing and as many pieces in all (data and
	/// parity) as it has data: solve for the rest.
	private mutating func decode(_ frame: UInt32) {
		guard let c = counts[frame], c.rows > 0, c.group > 0, let ps = parities[frame], var parts = partial[frame] else { return }
		let blocks = (Int(c.count) + c.group - 1) / c.group
		for b in 0..<blocks {
			let range = (b * c.group)..<min(Int(c.count), (b + 1) * c.group)
			let missing = range.filter { parts[UInt16($0)] == nil }
			guard !missing.isEmpty else { continue }
			let parity = Dictionary(uniqueKeysWithValues: (0..<c.rows).compactMap { j in ps[b * c.rows + j].map { (j, $0) } })
			guard parity.count >= missing.count else { continue }
			var have: [Int: Data] = [:]
			for i in range { if let d = parts[UInt16(i)] { have[i - range.lowerBound] = d } }
			guard let back = Erasure.recover(k: range.count, have: have, parity: parity) else { continue }
			for (i, d) in back { parts[UInt16(range.lowerBound + i)] = d; recovered += 1 }
		}
		partial[frame] = parts
	}

	/// Any group of this frame missing exactly one data piece, with its parity here: rebuild it.
	private mutating func rebuild(_ frame: UInt32) {
		guard let c = counts[frame], c.group > 0, let ps = parities[frame], var parts = partial[frame] else { return }
		for (g, parity) in ps {
			let range = (g * c.group)..<min(Int(c.count), (g + 1) * c.group)
			let missing = range.filter { parts[UInt16($0)] == nil }
			guard missing.count == 1 else { continue }
			var x = parity
			for i in range where i != missing[0] { x = xor(x, prefixed(parts[UInt16(i)]!)) }
			let b = [UInt8](x)
			guard b.count >= 2 else { continue }
			let n = Int(b[0]) << 8 | Int(b[1])
			guard 2 + n <= b.count else { continue }
			parts[UInt16(missing[0])] = Data(b[2..<2 + n])
			recovered += 1
		}
		partial[frame] = parts
	}

	private mutating func drain() -> [Frame] {
		var out: [Frame] = []
		if next == nil, let first = ready.keys.min() { next = first }
		// A whole keyframe ahead of where we are: everything before it no longer matters.
		if let n = next, let key = ready.values.filter({ $0.key && $0.id > n }).map(\.id).max(), ready[n] == nil {
			lost += Int(key - n); forget(below: key); next = key
		}
		while let n = next {
			if let f = ready.removeValue(forKey: n) {
				if f.key { needsKeyframe = false }
				if needsKeyframe { lost += 1 } else { out.append(f); delivered += 1 }
				next = n &+ 1
			} else if let newest = ready.keys.max(), newest >= n &+ patience {
				// Frames past a hole: the hole is lost, and so is decoding until a keyframe.
				lost += 1; needsKeyframe = true; partial[n] = nil; counts[n] = nil; parities[n] = nil
				next = n &+ 1
			} else { break }
		}
		return out
	}

	private mutating func forget(below id: UInt32) {
		for k in partial.keys where k < id { partial[k] = nil; counts[k] = nil; parities[k] = nil }
		for k in ready.keys where k < id { ready[k] = nil }
	}
}

/// Opus frames played out at a steady 20 ms from packets that arrive unevenly. It starts once it
/// holds `target` frames, conceals a missing one, grows its target when packets come too late and
/// shrinks it again after a calm stretch, and drops the oldest when it runs too far ahead. Given
/// when each packet came (`put(_:at:)`), it sizes itself instead: each packet's lateness against
/// the earliest of the last three seconds, the 98th percentile of that and 8 ms, in frames (one at
/// least), and it moves there at once rather than when it runs dry: a frame short, it holds
/// playout for one (a concealed frame); two over for half a second, it drops one, a quiet one if
/// one comes along.
public struct JitterBuffer: Sendable {
	public enum Pull: Equatable, Sendable { case frame(Data, level: UInt8), missing, idle }
	public private(set) var target: Int
	private var frames: [UInt32: (Data, UInt8)] = [:]
	private var next: UInt32?
	private var playing = false
	private var calm = 0
	private var gap = 0
	public private(set) var received = 0, played = 0, concealed = 0, late = 0, dropped = 0, rescued = 0
	/// Sizing itself: frames held back to grow, and dropped to shrink.
	public private(set) var stretched = 0, skipped = 0
	private var first: UInt32?, highest: UInt32?
	private var lateness: [(at: Double, d: Double)] = []
	private var adaptive = false
	private var over = 0, sinceStretch = 0
	/// Every frame the other side has sent so far, by sequence number (what `received` is out of).
	public var expected: Int { guard let first, let highest else { return 0 }; return Int(highest &- first) + 1 }
	let low: Int, high: Int

	public init(target: Int = 3, low: Int = 2, high: Int = 12) { self.target = target; self.low = low; self.high = high }

	public var depth: Int { frames.count }

	/// A packet, and when it came (seconds, any clock that only goes forward).
	public mutating func put(_ p: AudioPacket, at t: Double) {
		adaptive = true
		if first == nil { first = p.seq }
		let d = t - Double(Int32(bitPattern: p.seq &- first!)) * 0.02
		lateness.append((t, d))
		if let f = lateness.first, t - f.at > 3 { lateness.removeAll { t - $0.at > 3 } }
		put(p)
		let base = lateness.map(\.d).min() ?? d
		let sorted = lateness.map { $0.d - base }.sorted()
		let j = sorted[min(sorted.count - 1, sorted.count * 98 / 100)]
		target = min(high, max(1, Int(((j + 0.008) / 0.02).rounded(.up))))
	}

	public mutating func put(_ p: AudioPacket) {
		// The previous frame rides along: it fills its own hole if that datagram never came.
		if let prev = p.previous, p.seq > 0, frames[p.seq - 1] == nil, next.map({ p.seq - 1 >= $0 }) ?? false {
			frames[p.seq - 1] = (prev, p.level); rescued += 1
		}
		received += 1
		if first == nil { first = p.seq }
		highest = max(highest ?? p.seq, p.seq)
		if let n = next, p.seq < n {
			// Too late to play: wait longer from now on.
			late += 1; calm = 0
			target = min(high, target + 1)
			return
		}
		frames[p.seq] = (p.payload, p.level)
		if next == nil { next = p.seq }
		// Far ahead of where playout is: catch up, or the delay only grows.
		while frames.count > target + 6, let n = next {
			if frames.removeValue(forKey: n) != nil { dropped += 1 }
			next = n &+ 1
		}
	}

	/// The next 20 ms.
	public mutating func pull() -> Pull {
		guard let n = next else { return .idle }
		if !playing {
			guard frames.count >= target else { return .idle }
			playing = true
		}
		if adaptive, let h = highest, h >= n {
			let ahead = Int(h &- n) + 1
			sinceStretch += 1
			// A frame short of the target: hold playout one frame to make room.
			if ahead < target, sinceStretch >= 2 { sinceStretch = 0; stretched += 1; return .missing }
			// Two over for half a second: drop one, a quiet one if one comes in the next second.
			over = ahead > target + 1 ? over + 1 : 0
			if over >= 25, let (_, level) = frames[n], level < 40 || over >= 75 {
				frames[n] = nil; skipped += 1; over = 0
				next = n &+ 1
				return pull()
			}
		}
		next = n &+ 1
		if let (f, level) = frames.removeValue(forKey: n) {
			gap = 0
			played += 1
			calm += 1
			if !adaptive, calm >= 500, target > low { target -= 1; calm = 0 }   // ten calm seconds: a frame less delay
			return .frame(f, level: level)
		}
		concealed += 1
		gap += 1
		if frames.isEmpty && gap > target {
			// Ran dry: rebuffer before playing again.
			playing = false; gap = 0
			next = nil
			return .idle
		}
		return .missing
	}

	/// Loss as the receiver saw it: concealed out of what should have played.
	public var loss: Double { let all = played + concealed; return all == 0 ? 0 : Double(concealed) / Double(all) }
}

/// Media 2: a datagram numbered and stamped the moment it leaves, so the receiver can say what came
/// and when: [4][seq u16][sent u32 µs, the sender's clock][the datagram it carries].
public struct Sequenced: Equatable, Sendable {
	public static let header = 7
	public var seq: UInt16
	public var sent: UInt32
	public var inner: Data
	public init(seq: UInt16, sent: UInt32, inner: Data) { self.seq = seq; self.sent = sent; self.inner = inner }
	public var data: Data {
		var d = Data(capacity: Self.header + inner.count)
		d.append(MediaKind.sequenced.rawValue); d.append(contentsOf: be16(seq)); d.append(contentsOf: be32(sent)); d.append(inner)
		return d
	}
	public init?(_ d: Data) {
		guard d.count > Self.header, d.first == MediaKind.sequenced.rawValue else { return nil }
		let b = d.startIndex
		seq = UInt16(d[b + 1]) << 8 | UInt16(d[b + 2])
		sent = UInt32(d[b + 3]) << 24 | UInt32(d[b + 4]) << 16 | UInt32(d[b + 5]) << 8 | UInt32(d[b + 6])
		inner = Data(d[(b + Self.header)...])
	}
}

/// Media 2: what arrived, back to the sender every 50 ms or so. Which of its sequenced datagrams
/// came and when (this end's clock), a clock echo (the newest stamp it had, and how long it held it)
/// for the round trip and the offset between the two clocks, and where its decoding of the sender's
/// video stands: the newest frame decoded, the frame its unbroken run began at (a keyframe or a
/// refresh: every frame from there to `decoded` decoded), and whether it needs a refresh or a key.
/// [5][first u16][count u16][now u32][echo u32][held u32][decoded u32][chain u32][flags u8]
/// [base u32][count × arrival u16, tenths of a millisecond after base; 0xFFFF never came]
public struct Feedback: Equatable, Sendable {
	public enum Want: UInt8, Sendable { case nothing = 0, refresh = 1, keyframe = 2 }
	public static let header = 30
	public var first: UInt16
	/// One per datagram from `first` on: when it came (µs, this end's clock), or nil.
	public var arrivals: [UInt32?]
	public var now: UInt32
	public var echo: UInt32
	public var held: UInt32
	/// The video, when there's any: nil before the first frame.
	public var decoded: UInt32?
	public var chain: UInt32
	public var want: Want
	public init(first: UInt16, arrivals: [UInt32?], now: UInt32, echo: UInt32, held: UInt32, decoded: UInt32?, chain: UInt32, want: Want) {
		self.first = first; self.arrivals = arrivals; self.now = now; self.echo = echo; self.held = held; self.decoded = decoded; self.chain = chain; self.want = want
	}

	/// The most arrivals one feedback holds in `room` bytes.
	public static func most(_ room: Int) -> Int { max(1, (room - header) / 2) }

	public var data: Data {
		var d = Data(capacity: Self.header + arrivals.count * 2)
		d.append(MediaKind.feedback.rawValue)
		d.append(contentsOf: be16(first)); d.append(contentsOf: be16(UInt16(min(arrivals.count, 0xFFFF))))
		for v in [now, echo, held, decoded ?? 0, chain] { d.append(contentsOf: be32(v)) }
		d.append((decoded != nil ? 1 : 0) | want.rawValue << 1)
		// The earliest arrival as base, so every other fits in two bytes (six and a half seconds).
		let base = arrivals.compactMap { $0 }.min { Int32(bitPattern: $0 &- $1) < 0 } ?? now
		d.append(contentsOf: be32(base))
		for a in arrivals.prefix(0xFFFF) {
			guard let a else { d.append(contentsOf: [0xFF, 0xFF]); continue }
			d.append(contentsOf: be16(UInt16(min(0xFFFE, (a &- base) / 100))))
		}
		return d
	}

	public init?(_ d: Data) {
		let b = [UInt8](d)
		guard b.count >= Self.header, b[0] == MediaKind.feedback.rawValue else { return nil }
		first = UInt16(b[1]) << 8 | UInt16(b[2])
		let n = Int(b[3]) << 8 | Int(b[4])
		guard b.count >= Self.header + n * 2 else { return nil }
		now = u32(b, 5); echo = u32(b, 9); held = u32(b, 13)
		let dec = u32(b, 17); chain = u32(b, 21)
		decoded = b[25] & 1 == 1 ? dec : nil
		want = Want(rawValue: b[25] >> 1 & 3) ?? .nothing
		let base = u32(b, 26)
		arrivals = (0..<n).map { i in
			let v = UInt16(b[30 + 2 * i]) << 8 | UInt16(b[31 + 2 * i])
			return v == 0xFFFF ? nil : base &+ UInt32(v) * 100
		}
	}
}

private func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
private func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xff)] }
private func u32(_ b: [UInt8], _ i: Int) -> UInt32 { UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3]) }
