/// The numbers, measured in the real build: cold open to first frame, keypress to the next frame,
/// and frames per second through a scripted scroll of the biggest channel. `BAUD_MEASURE=1`
/// prints them to stderr; the release notes copy them.
import Foundation
import QuartzCore

enum Measure {
	static let on = ProcessInfo.processInfo.environment["BAUD_MEASURE"] != nil
	nonisolated(unsafe) static var firstFrame: Date?
	nonisolated(unsafe) static var keyAt: CFTimeInterval?
	nonisolated(unsafe) static var frames = 0
	nonisolated(unsafe) static var scrollStart: CFTimeInterval = 0
	nonisolated(unsafe) static var worst: CFTimeInterval = 0
	nonisolated(unsafe) static var lastFrame: CFTimeInterval = 0

	/// Seconds since the process started lead every line, so two logs can be read against each other.
	static func log(_ s: String) {
		let line = Data("baud: \(String(format: "%7.2f", Date().timeIntervalSince(launchedAt))) \(s)\n".utf8)
		// The throwing writes: the old ones raise an Objective-C exception, which no Swift code can
		// catch, when stderr is a pipe whose reader went away (a debug console closed), and that
		// ended the app (0.2.6 on an iPhone). A log line is never worth a crash.
		try? FileHandle.standardError.write(contentsOf: line)
		// `BAUD_LOG_FILE=path` keeps a copy where the simulator's stderr can't be read.
		if let h = logFile { _ = try? h.seekToEnd(); try? h.write(contentsOf: line) }
	}
	nonisolated(unsafe) static let logFile: FileHandle? = {
		guard let p = ProcessInfo.processInfo.environment["BAUD_LOG_FILE"] else { return nil }
		if !FileManager.default.fileExists(atPath: p) { FileManager.default.createFile(atPath: p, contents: nil) }
		return FileHandle(forWritingAtPath: p)
	}()

	static func opened() {
		guard firstFrame == nil else { return }
		firstFrame = Date()
		let ms = Int(Date().timeIntervalSince(launchedAt) * 1000)
		if on { log("cold open \(ms) ms (process start to first frame)") }
		UserDefaults.standard.set(ms, forKey: "coldOpenMs")
	}
	nonisolated(unsafe) static var armed = false
	static func keypress() { if on && armed { keyAt = CACurrentMediaTime() } }

	/// Called from the display link every frame while measuring.
	static func frame(_ now: CFTimeInterval) {
		if let k = keyAt { log("keypress to frame \(Int((now - k) * 1000)) ms"); keyAt = nil }
		if scrollStart > 0 {
			frames += 1
			if lastFrame > 0 { worst = max(worst, now - lastFrame) }
			lastFrame = now
		}
	}
	static func scrollBegan() { scrollStart = CACurrentMediaTime(); frames = 0; worst = 0; lastFrame = 0 }
	static func scrollEnded(rows: Int) {
		let s = CACurrentMediaTime() - scrollStart
		log("scroll through \(rows) rows: \(frames) frames in \(String(format: "%.1f", s)) s = \(Int(Double(frames) / s)) fps, worst frame \(Int(worst * 1000)) ms")
		scrollStart = 0
	}

	static var launchedAt: Date {
		var info = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.stride
		var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
		sysctl(&mib, 4, &info, &size, nil, 0)
		let t = info.kp_proc.p_starttime
		return Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1e6)
	}
}
