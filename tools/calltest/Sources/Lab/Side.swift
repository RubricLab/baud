/// One end of a calltest call, whichever media engine it runs: the setup signals as the harness
/// speaks them, the media started and stopped, and its counters, read once a second.
import CoreVideo
import Foundation

public enum Setup: Sendable { case ring, ringing, accept, end }

public struct Counters: Sendable {
	/// Encoded video handed out, and the encoder's target.
	public var videoBytes = 0, encoded = 0, keyframes = 0, targetKbps = 0
	public var codec = "", size = ""
	/// Frames this end's decoder turned into pictures.
	public var decoded = 0
	/// Audio from the other end.
	public var audioReceived = 0, audioExpected = 0, audioPlayed = 0, audioConcealed = 0
	/// The engine's own word on its latency (capture to shown, as it measures it), if it has one.
	public var latency: [Double] = []
	/// Anything else the engine wants on the line.
	public var note = ""
	public init() {}
}

public protocol CallSide: AnyObject, Sendable {
	var engine: String { get }
	var onSetup: (@Sendable (Setup) -> Void)? { get set }
	func send(_ s: Setup) async
	/// Media on: `onFrame` gets every picture shown, as it's shown.
	func startMedia(me: String, onFrame: @escaping @Sendable (CVPixelBuffer) -> Void) throws
	func counters() -> Counters
	var rtt: Int? { get }
	/// Bytes that went out on the wire (media datagrams, all kinds).
	var wire: Uplink { get }
	func stop()
}

/// Datagrams out: counted, and through the shaper when there is one.
public final class Uplink: @unchecked Sendable {
	public let shaper: Shaper?
	private let out: @Sendable (Data) -> Void
	private let lock = NSLock()
	private var count = 0
	public var bytes: Int { lock.withLock { count } }
	public init(_ spec: Shaper.Spec?, out: @escaping @Sendable (Data) -> Void) {
		self.out = out
		shaper = spec.map { Shaper($0, deliver: out) }
	}
	public func send(_ d: Data) {
		lock.withLock { count += d.count }
		if let shaper { shaper.send(d) } else { out(d) }
	}
	public func stop() { shaper?.stop() }
}
