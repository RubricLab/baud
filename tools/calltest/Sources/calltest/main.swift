/// Ana calls Bo. Two peer nodes open in memory (memory keychains, a temporary store, no nearby
/// discovery, no router mapping, no relay), Bo adds Ana by a real invite link, Bo rings Ana's
/// device over a Live connection, Ana answers, and the two run synthetic voice and video at each
/// other for `duration` seconds, dropping `drop` of every outgoing datagram. It prints what arrived each
/// second, then a summary for each direction.
/// `CALLTEST_SHAPE=rate=3mbit,delay=40ms,loss=1%,queue=150ms,step=15s:2mbit`: both directions go
/// through that path (Lab/Shaper). `CALLTEST_ANA=0.2.15` or `CALLTEST_BO=0.2.15`: that end runs
/// the media of baud 0.2.15 (Sources/Legacy) instead of this checkout's. `BAUD_CALL_SPEAKER=silent`:
/// both play through the real speaker, at zero volume (still no microphone); `CALLTEST_BREAK=s`:
/// Bo's engine stops that far in, the way the system stops it when the devices change, and the
/// call has to heal (`CALLTEST_QUIET=1`: with no notice of it). Latency is read off the decoded
/// pictures (Lab/Barcode): the time drawn into each, against the clock when it's shown.
/// `CALLTEST_MESH=1`: a call of three instead (Mesh.swift); `CALLTEST_DATAGRAMS=20`: the transport
/// alone, 20 Mbps of stamped datagrams and how late they come (Datagrams.swift).
import CoreVideo
import Foundation
import Lab
import Legacy
import PeerKit

let args = CommandLine.arguments
let env = ProcessInfo.processInfo.environment
let duration = args.count > 1 ? Double(args[1]) ?? 10 : 10
let drop = args.count > 2 ? Double(args[2]) ?? 0 : 0
let shape = env["CALLTEST_SHAPE"].flatMap { s -> Shaper.Spec? in
	guard let spec = Shaper.Spec.parse(s) else { print("CALLTEST_SHAPE: can't read \(s)"); exit(2) }
	return spec
}
let anaEngine = env["CALLTEST_ANA"] ?? "new", boEngine = env["CALLTEST_BO"] ?? "new"
let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("baud-calltest-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: root) }

final class Events: Listener, @unchecked Sendable {
	var inbound: (@Sendable (UInt64) -> Void)?
	func on(event: PeerEvent) {
		if case .inbound(let c, let alpn) = event, alpn == CallLink.alpn { inbound?(c) }
	}
}

func node(_ name: String) async throws -> (PeerKit.Peer, Events) {
	let p = try await PeerKit.Peer.open(dir: root.appendingPathComponent(name).path, keychain: MemoryKeychain(),
		config: Config(app: "baud-calltest", name: name, deviceName: "\(name)'s Mac", linkScheme: "baud://add", nearby: false,
			alpns: [CallLink.alpn], deviceKind: "mac", vpn: false, portmap: false, relay: false, public: false))
	let e = Events(); p.subscribe(listener: e)
	return (p, e)
}

func ms(_ since: Date) -> Int { Int(Date().timeIntervalSince(since) * 1000) }

/// What one end sees of the other's picture: when each frame was shown, how old it was, how big.
final class Screen: @unchecked Sendable {
	private let lock = NSLock()
	private let start: Double
	private(set) var shown: [Double] = []
	private(set) var latency: [(t: Double, ms: Double)] = []
	private(set) var sizes: [(t: Double, size: String)] = []
	init(start: Double) { self.start = start }
	func frame(_ pb: CVPixelBuffer) {
		let t = Shaper.now() - start
		let stamp = Barcode.read(pb)
		let size = "\(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb))"
		lock.withLock {
			shown.append(t)
			if let stamp { let age = Barcode.age(stamp); if age >= 0, age < 10_000 { latency.append((t, age)) } }
			if sizes.last?.size != size { sizes.append((t, size)) }
		}
	}
	func snapshot() -> (shown: [Double], latency: [(t: Double, ms: Double)], sizes: [(t: Double, size: String)]) { lock.withLock { (shown, latency, sizes) } }
}

func pct(_ xs: [Double], _ p: Double) -> Double {
	guard !xs.isEmpty else { return .nan }
	let s = xs.sorted()
	return s[min(s.count - 1, Int(Double(s.count - 1) * p + 0.5))]
}
func f0(_ x: Double) -> String { x.isNaN ? "-" : String(format: "%.0f", x) }

if env["CALLTEST_MESH"] == "1" {
	try await meshTest(root: root, shape: shape, duration: duration)
	exit(0)
}

let t0 = Date()
let (ana, anaEvents) = try await node("Ana")
let (bo, _) = try await node("Bo")
print("nodes open in \(ms(t0)) ms")
let t1 = Date()
_ = try await bo.add(link: try ana.invite())
for _ in 0..<100 where !ana.contacts().contains(where: { $0.user == bo.me().user }) { try await Task.sleep(for: .milliseconds(50)) }
print("paired in \(ms(t1)) ms · Ana runs \(anaEngine), Bo runs \(boEngine) · path: \(shape?.description ?? "loopback, unshaped")")

if let mbps = env["CALLTEST_DATAGRAMS"].flatMap(Double.init) {
	try await datagramBench(bo: bo, ana: ana, anaEvents: anaEvents, mbps: mbps, duration: duration, burst: env["CALLTEST_BURST"] == "1")
	await ana.close(); await bo.close()
	exit(0)
}

callLog = { print("    " + $0) }
let start = Shaper.now()
let anaScreen = Screen(start: start), boScreen = Screen(start: start)

// Ana's side: answer the first ring, then run media.
nonisolated(unsafe) var anaSide: CallSide?
anaEvents.inbound = { conn in
	Task {
		do {
			let side: CallSide = anaEngine == "0.2.15" ? try await LegacySide.accept(ana, conn: conn, shape: shape, drop: drop) : try await NewSide.accept(ana, conn: conn, shape: shape, drop: drop)
			anaSide = side
			side.onSetup = { s in
				guard s == .ring else { return }
				print("Ana: ring")
				Task {
					await side.send(.ringing)
					do { try side.startMedia(me: ana.me().thisDevice) { anaScreen.frame($0) } } catch { print("Ana: media failed: \(error)") }
					await side.send(.accept)
				}
			}
		} catch { print("Ana: accept failed: \(error)") }
	}
}

// Bo rings Ana's device.
let t2 = Date()
let boSide: CallSide = boEngine == "0.2.15" ? try await LegacySide.dial(bo, device: ana.me().thisDevice, shape: shape, drop: drop) : try await NewSide.dial(bo, device: ana.me().thisDevice, shape: shape, drop: drop)
print("Bo: live connection in \(ms(t2)) ms, rtt \(boSide.rtt.map(String.init) ?? "-") ms")
let accepted = DispatchSemaphore(value: 0)
let t3 = Date()
boSide.onSetup = { s in
	switch s {
	case .ringing: print("Bo: ringing after \(ms(t3)) ms")
	case .accept: print("Bo: answered after \(ms(t3)) ms"); accepted.signal()
	default: break
	}
}
await boSide.send(.ring)
_ = await Task.detached { () -> DispatchTimeoutResult in accepted.wait(timeout: .now() + 10) }.value
try boSide.startMedia(me: bo.me().thisDevice) { boScreen.frame($0) }
if let s = env["CALLTEST_BREAK"].flatMap(Double.init), let n = boSide as? NewSide {
	Task { try await Task.sleep(for: .seconds(s)); print("Bo: the engine stops"); n.media?.audio.breakEngine(quietly: env["CALLTEST_QUIET"] == "1") }
}

// Each second: what each end sent, and what the other showed of it.
struct Second { var t: Double; var from: Counters; var to: Counters; var wire: Int }
var rows: (bo: [Second], ana: [Second]) = ([], [])
let begun = Shaper.now()
while Shaper.now() - begun < duration {
	try await Task.sleep(for: .seconds(1))
	guard let a = anaSide else { continue }
	let t = Shaper.now() - start
	let (bc, ac) = (boSide.counters(), a.counters())
	rows.bo.append(Second(t: t, from: bc, to: ac, wire: boSide.wire.bytes))
	rows.ana.append(Second(t: t, from: ac, to: bc, wire: a.wire.bytes))
	func line(_ name: String, _ r: [Second], _ screen: Screen) -> String {
		guard let now = r.last else { return "" }
		let prev = r.count > 1 ? r[r.count - 2] : Second(t: now.t - 1, from: Counters(), to: Counters(), wire: 0)
		let snap = screen.snapshot()
		let lat = snap.latency.filter { $0.t > now.t - 1 }.map(\.ms)
		let shownNow = snap.shown.filter { $0 > now.t - 1 }.count
		let size = snap.sizes.last?.size ?? "-"
		return String(format: "%@ %3.0fs %@ %@ target %5d kbps · enc %5d · wire %5d · fps %2d→%2d · lat %@/%@ ms · key %d · audio concealed %d %@",
			name, now.t, now.from.codec, size, now.from.targetKbps, (now.from.videoBytes - prev.from.videoBytes) * 8 / 1000, (now.wire - prev.wire) * 8 / 1000,
			now.from.encoded - prev.from.encoded, shownNow, f0(pct(lat, 0.5)), f0(pct(lat, 0.95)), now.from.keyframes - prev.from.keyframes,
			now.to.audioConcealed - prev.to.audioConcealed, now.from.note)
	}
	print(line("Bo→Ana", rows.bo, anaScreen))
	print(line("Ana→Bo", rows.ana, boScreen))
}

// The summary, per direction.
func summary(_ name: String, _ r: [Second], _ screen: Screen, sender: CallSide) {
	guard let last = r.last, r.count >= 3 else { print("\(name): too short to say"); return }
	let snap = screen.snapshot()
	var enc: [Double] = [], wire: [Double] = []
	for i in r.indices {
		let p = i == 0 ? Second(t: 0, from: Counters(), to: Counters(), wire: 0) : r[i - 1]
		enc.append(Double(r[i].from.videoBytes - p.from.videoBytes) * 8 / 1000)
		wire.append(Double(r[i].wire - p.wire) * 8 / 1000)
	}
	let tail = Array(enc.suffix(max(1, enc.count / 3)))
	let reached = pct(tail, 0.5)
	let reachedAt = enc.firstIndex { $0 >= reached * 0.9 }.map { r[$0].t } ?? .nan
	let warm = snap.latency.filter { $0.t > 2 }.map(\.ms)
	var gaps: [Double] = []
	for i in snap.shown.indices.dropFirst() { let g = snap.shown[i] - snap.shown[i - 1]; if g > 0.1 { gaps.append(g) } }
	let half = last.t / 2
	let fpsShown = Double(snap.shown.filter { $0 > half }.count) / max(0.001, last.t - half)
	let firstHalf = r.first { $0.t > half } ?? r[0]
	let fpsSent = Double(last.from.encoded - firstHalf.from.encoded) / max(0.001, last.t - firstHalf.t)
	let sizes = Dictionary(grouping: snap.sizes.filter { $0.t > half }, by: \.size).keys.sorted().joined(separator: ", ")
	let heard = last.to
	let concealed = heard.audioPlayed + heard.audioConcealed == 0 ? 0 : Double(heard.audioConcealed) / Double(heard.audioPlayed + heard.audioConcealed) * 100
	print("\(name) [\(sender.engine)]: \(last.from.codec) \(sizes.isEmpty ? snap.sizes.last?.size ?? "-" : sizes) · fps sent \(f0(fpsSent)) shown \(f0(fpsShown)) (second half)")
	print(String(format: "    video %@ kbps encoded (wire %@ kbps), 90%% of it by %@ s · target at the end %d kbps · %d keyframes",
		f0(reached), f0(pct(Array(wire.suffix(max(1, wire.count / 3))), 0.5)), reachedAt.isNaN ? "-" : String(format: "%.0f", reachedAt), last.from.targetKbps, last.from.keyframes))
	print("    latency, drawn to shown: p50 \(f0(pct(warm, 0.5))) p95 \(f0(pct(warm, 0.95))) max \(f0(warm.max() ?? .nan)) ms over \(warm.count) frames" +
		(last.from.latency.isEmpty ? "" : " · the engine's own: p50 \(f0(pct(last.to.latency, 0.5))) p95 \(f0(pct(last.to.latency, 0.95))) ms"))
	print(String(format: "    freezes over 100 ms: %d, %.0f ms in all, longest %.0f ms · audio heard %d/%d, concealed %.2f%%",
		gaps.count, gaps.reduce(0, +) * 1000, (gaps.max() ?? 0) * 1000, heard.audioReceived, heard.audioExpected, concealed))
	if let spec = shape, let step = spec.steps.first {
		let before = snap.latency.filter { $0.t > step.at - 5 && $0.t < step.at }.map(\.ms)
		let after = snap.latency.filter { $0.t >= step.at }
		let bar = pct(before, 0.95) * 1.5 + 10
		// Settled: the first second after the step from which every frame is under the bar again.
		let late = after.filter { $0.ms > bar }.map(\.t).max()
		print(String(format: "    after the step at %.0f s: latency peaked at %@ ms; under %@ ms (1.5 × p95 before, + 10) again %@",
			step.at, f0(after.map(\.ms).max() ?? .nan), f0(bar), late.map { String(format: "%.1f s after it", $0 - step.at) } ?? "at once"))
	}
	if let s = sender.wire.shaper {
		print(String(format: "    path: %d datagrams in, %d through, %d over the queue, %d lost at random, deepest queue %.0f ms", s.sent, s.delivered, s.overflowed, s.lost, s.maxQueue * 1000))
	}
}

print("")
summary("Bo→Ana", rows.bo, anaScreen, sender: boSide)
if let a = anaSide { summary("Ana→Bo", rows.ana, boScreen, sender: a) }
print("rtt \(boSide.rtt.map(String.init) ?? "-") ms")
await boSide.send(.end)
boSide.stop(); anaSide?.stop()
await ana.close(); await bo.close()
