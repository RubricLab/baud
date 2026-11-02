/// Calls on the wire. A call is a mesh: each pair of devices in it holds its own live connection
/// (ALPN `baud-call/1`), one stream for the signals (ring, accept, roster, join, leave, mute,
/// keyframe, stats) as length-prefixed JSON, datagrams for the media: an Opus frame every 20 ms,
/// and each H.264 frame cut into pieces no bigger than a datagram. Two people are a mesh of one
/// link. Pure values here, so what drops, reorders and reassembles is tested without a camera, a
/// microphone or a network.
import Foundation

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

/// What a datagram carries, by its first byte.
public enum MediaKind: UInt8, Sendable { case audio = 1, video = 2, relay = 3 }

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
public struct VideoFragment: Equatable, Sendable {
	public static let header = 10
	public var frame: UInt32
	public var index: UInt16
	public var count: UInt16
	public var key: Bool
	public var parity: Bool
	public var group: Int
	public var payload: Data
	public init(frame: UInt32, index: UInt16, count: UInt16, key: Bool, parity: Bool = false, group: Int = 0, payload: Data) {
		self.frame = frame; self.index = index; self.count = count; self.key = key; self.parity = parity; self.group = group; self.payload = payload
	}
	public var data: Data {
		var d = Data([MediaKind.video.rawValue])
		d.append(contentsOf: be32(frame)); d.append(contentsOf: be16(index)); d.append(contentsOf: be16(count))
		d.append((key ? 1 : 0) | (parity ? 2 : 0) | UInt8(min(63, group)) << 2)
		d.append(payload)
		return d
	}
	public init?(_ d: Data) {
		let b = [UInt8](d)
		guard b.count > Self.header, b[0] == MediaKind.video.rawValue else { return nil }
		frame = u32(b, 1); index = UInt16(b[5]) << 8 | UInt16(b[6]); count = UInt16(b[7]) << 8 | UInt16(b[8])
		key = b[9] & 1 == 1; parity = b[9] & 2 == 2; group = Int(b[9] >> 2)
		payload = Data(b[Self.header...])
		guard count > 0, parity ? group > 0 : index < count else { return nil }
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
/// three later frames are whole; after a gap only a keyframe can be decoded, so frames wait for one
/// (and `needsKeyframe` says to ask). A keyframe that completes ahead of a gap jumps it.
public struct VideoReassembler: Sendable {
	public struct Frame: Equatable, Sendable { public var id: UInt32; public var key: Bool; public var bytes: Data }
	private var partial: [UInt32: [UInt16: Data]] = [:]
	private var parities: [UInt32: [Int: Data]] = [:]
	private var counts: [UInt32: (count: UInt16, key: Bool, group: Int)] = [:]
	/// Pieces rebuilt from parity.
	public private(set) var recovered = 0
	private var ready: [UInt32: Frame] = [:]
	private var next: UInt32?
	public private(set) var needsKeyframe = true
	public private(set) var delivered = 0
	public private(set) var lost = 0
	public init() {}

	public mutating func add(_ f: VideoFragment) -> [Frame] {
		if let n = next, f.frame < n { return [] }
		if ready[f.frame] != nil { return [] }
		if partial[f.frame] == nil { partial[f.frame] = [:] }
		if f.parity { parities[f.frame, default: [:]][Int(f.index)] = f.payload } else { partial[f.frame]![f.index] = f.payload }
		counts[f.frame] = (f.count, f.key, f.group)
		if f.group > 0 { rebuild(f.frame) }
		if let parts = partial[f.frame], parts.count == Int(f.count) {
			var bytes = Data()
			for i in 0..<f.count { bytes += parts[i] ?? Data() }
			ready[f.frame] = Frame(id: f.frame, key: f.key, bytes: bytes)
			partial[f.frame] = nil; counts[f.frame] = nil; parities[f.frame] = nil
		}
		return drain()
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
			} else if let newest = ready.keys.max(), newest >= n &+ 3 {
				// Three frames past a hole: the hole is lost, and so is decoding until a keyframe.
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
/// shrinks it again after a calm stretch, and drops the oldest when it runs too far ahead.
public struct JitterBuffer: Sendable {
	public enum Pull: Equatable, Sendable { case frame(Data, level: UInt8), missing, idle }
	public private(set) var target: Int
	private var frames: [UInt32: (Data, UInt8)] = [:]
	private var next: UInt32?
	private var playing = false
	private var calm = 0
	private var gap = 0
	public private(set) var received = 0, played = 0, concealed = 0, late = 0, dropped = 0, rescued = 0
	private var first: UInt32?, highest: UInt32?
	/// Every frame the other side has sent so far, by sequence number (what `received` is out of).
	public var expected: Int { guard let first, let highest else { return 0 }; return Int(highest &- first) + 1 }
	let low: Int, high: Int

	public init(target: Int = 3, low: Int = 2, high: Int = 12) { self.target = target; self.low = low; self.high = high }

	public var depth: Int { frames.count }

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
		next = n &+ 1
		if let (f, level) = frames.removeValue(forKey: n) {
			gap = 0
			played += 1
			calm += 1
			if calm >= 500, target > low { target -= 1; calm = 0 }   // ten calm seconds: a frame less delay
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

private func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
private func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xff)] }
private func u32(_ b: [UInt8], _ i: Int) -> UInt32 { UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3]) }
