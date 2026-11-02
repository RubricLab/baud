/// Updates: the app asks its own site for `releases.json` when it opens and when Settings opens
/// (peer/DESIGN.md rule 1: update checks may run on open), and shows "0.2.1 available · Download" or
/// "Up to date". Download is a press: the DMG is fetched, its sha256 checked against the record,
/// and opened for the drag into Applications. Nothing downloads or installs by itself.
import AppKit
import CryptoKit
import Foundation
import Observation

@MainActor
@Observable
final class Updates {
	static let site = URL(string: "https://baud.rubric.sh/releases.json")!
	struct Release: Decodable { let version: String; let dmg: URL; let sha256: String? }
	enum State: Equatable { case idle, checking, latest(String), available(Release), downloading(Release), failed(String)
		static func == (a: State, b: State) -> Bool {
			switch (a, b) {
			case (.idle, .idle), (.checking, .checking): return true
			case (.latest(let x), .latest(let y)), (.failed(let x), .failed(let y)): return x == y
			case (.available(let x), .available(let y)), (.downloading(let x), .downloading(let y)): return x.version == y.version
			default: return false
			}
		}
	}
	var state: State = .idle
	static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

	/// When the last answer came.
	var checkedAt: Date?
	/// At most two words, for the app card: "Up to date · 3:41 PM", "0.2.1 available", "Checking…".
	var word: String {
		switch state {
		case .idle: return ""
		case .checking: return "Checking…"
		case .latest: return "Up to date" + (checkedAt.map { " · " + clock($0) } ?? "")
		case .available(let r): return "\(r.version) available"
		case .downloading: return "Downloading…"
		case .failed: return "Couldn't check" + (checkedAt.map { " · " + clock($0) } ?? "")
		}
	}
	var sentence: String { word }

	/// Ask the site for the newest version: on launch, on opening Settings, or when pressed. Off the
	/// main actor with a five-second limit, so it never hangs; it never downloads on its own.
	func check(quiet: Bool = false) {
		if state == .checking { return }
		if quiet, let at = checkedAt, Date().timeIntervalSince(at) < 300 { return }
		state = .checking
		Task {
			let result: Result<Release, Error> = await Task.detached {
				let c = URLSessionConfiguration.ephemeral
				c.timeoutIntervalForRequest = 5; c.timeoutIntervalForResource = 5
				c.requestCachePolicy = .reloadIgnoringLocalCacheData
				do {
					let (data, _) = try await URLSession(configuration: c).data(from: Updates.site)
					return .success(try JSONDecoder().decode(Release.self, from: data))
				} catch { return .failure(error) }
			}.value
			checkedAt = Date()
			switch result {
			case .success(let r): state = Self.newer(r.version, than: Self.current) ? .available(r) : .latest(Self.current)
			case .failure(let e): state = .failed("\(e)"); Measure.log("update check failed: \(e)")
			}
		}
	}

	func download() {
		guard case .available(let r) = state else { return }
		Measure.log("update: downloading \(r.version)")
		state = .downloading(r)
		Task {
			do {
				let (tmp, _) = try await URLSession.shared.download(from: r.dmg)
				let bytes = try Data(contentsOf: tmp)
				let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
				if let want = r.sha256, want.lowercased() != hash { state = .failed("The download's hash doesn't match what the site says it should be; not opening it."); return }
				let dest = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent(r.dmg.lastPathComponent)
				try? FileManager.default.removeItem(at: dest)
				try FileManager.default.moveItem(at: tmp, to: dest)
				NSWorkspace.shared.open(dest)
				state = .latest(r.version)
			} catch { state = .failed("The download failed: \(error.localizedDescription)") }
		}
	}

	/// "0.1.10" is newer than "0.1.7": compare number by number.
	static func newer(_ a: String, than b: String) -> Bool {
		let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
		for i in 0..<max(x.count, y.count) { let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0; if p != q { return p > q } }
		return false
	}
}
