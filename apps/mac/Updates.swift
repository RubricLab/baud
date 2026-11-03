/// Updates without a store and without a server of ours. The site's release record
/// (baud.rubric.sh/releases.json, a plain file) is signed with baud's release key, and it is read
/// when the app opens, when it comes to the front (at most every six hours), and when asked. A
/// newer version shows as a bar at the foot of the sidebar. One press downloads it and checks three
/// things: the record's signature, the download's hash against the record, and that the app inside
/// is signed by baud's Apple team. The new app then waits, checked, in baud's caches (named so macOS
/// never takes it for a second baud), and goes in place of this one when baud quits or Restart is
/// pressed: never under the running app, whose signature macOS keeps checking against what's on
/// disk (a mismatch can cost a call its microphone). With "Download and install updates
/// automatically" on (the default, the person's choice in Settings ▸ Updates), the press happens by
/// itself; nothing ever restarts by itself. Off, nothing downloads before the press.
/// Where this copy can't replace itself (a folder it may not write, a build run from Xcode, a beta
/// copy), it only offers, and the press opens the disk image for the drag into Applications. An
/// unsigned or wrongly signed record is never offered.
import AppKit
import CryptoKit
import Foundation
import Observation
import Security
import SwiftUI

@MainActor
@Observable
final class Updates {
	static let site = URL(string: "https://baud.rubric.sh/releases.json")!
	/// The public half of baud's release key (P-256, DER); the private half never leaves the
	/// keychain of the Mac that ships (scripts/sign-release.swift).
	nonisolated static let key = try! P256.Signing.PublicKey(derRepresentation: Data(base64Encoded: "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEriUc8b5dsaezePo8u/ieXmNxRM2le8HIbUS6Q1W7fqpeU3G2mXRZLv2ZDy2wJ7KccvS+m4hUPQYrTqqiEPmRYQ==")!)
	/// Who must have signed the app inside a download: baud's Mac app, by its Apple team.
	nonisolated static let requirement = "anchor apple generic and identifier \"sh.rubric.baud.mac\" and certificate leaf[subject.OU] = \"J43C4UHCR4\""

	struct Release: Decodable {
		let version: String
		let dmg: String
		let sha256: String?
		let sig: String?
		let android: Android?
		struct Android: Decodable { let version: String?; let apk: String?; let sha256: String? }
		var url: URL? { URL(string: dmg) }
		/// What the release key signed: these fields, in this order, on every platform.
		var signed: String { ["baud release 1", version, dmg, sha256 ?? "", android?.version ?? "", android?.apk ?? "", android?.sha256 ?? ""].joined(separator: "\n") }
		var genuine: Bool {
			guard let s = sig.flatMap({ Data(base64Encoded: $0) }), let sig = try? P256.Signing.ECDSASignature(derRepresentation: s) else { return false }
			return Updates.key.isValidSignature(sig, for: Data(signed.utf8))
		}
	}
	enum State: Equatable {
		case idle, checking, latest(String), available(String), downloading(String), ready(String), failed(String)
	}
	var state: State = .idle
	private var release: Release?
	/// The new version, checked and waiting to go in place of this one.
	private var staged: URL?
	static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

	/// When the last answer came.
	var checkedAt: Date?
	/// Download, check and put a new version in place without a press (never restart). On unless
	/// the person turns it off.
	var auto: Bool = UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true {
		didSet { UserDefaults.standard.set(auto, forKey: "autoUpdate"); takeIfAuto() }
	}
	/// Only the installed app in a folder it may write takes an update by itself: anywhere else the
	/// press would open a disk image, and that waits for a person.
	nonisolated static var replacesItself: Bool {
		Bundle.main.bundleIdentifier == "sh.rubric.baud.mac" && FileManager.default.isWritableFile(atPath: Bundle.main.bundleURL.deletingLastPathComponent().path)
	}
	private func takeIfAuto() {
		guard auto, Self.replacesItself, case .available = state else { return }
		Measure.log("update: taking it by itself")
		install()
	}
	/// At most a few words, for the app card: "Up to date · 3:41 PM", "0.2.1 available", "Checking…".
	var word: String {
		switch state {
		case .idle: return ""
		case .checking: return "Checking…"
		case .latest: return "Up to date" + (checkedAt.map { " · " + clock($0) } ?? "")
		case .available(let v): return "\(v) available"
		case .downloading: return "Updating…"
		case .ready(let v): return "\(v) ready: restart to update"
		case .failed: return "Couldn't update" + (checkedAt.map { " · " + clock($0) } ?? "")
		}
	}
	var sentence: String { if case .failed(let why) = state { return why }; return word }
	/// Something to show in the window, not only in Settings.
	var offering: Bool { switch state { case .available, .downloading, .ready: return true; default: return false } }

	init() {
		// Quitting: the waiting version goes in place, for the next launch. (Killed or crashed, it's
		// still waiting at the next launch, and goes at the next quit.)
		NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
			MainActor.assumeIsolated {
				guard let self, let staged = self.staged else { return }
				Measure.log("update: quitting, putting the new version in place")
				_ = Self.swap(staged)
			}
		}
		// One left waiting by an earlier run: ready again if it's newer and still baud's, else gone.
		Task {
			let found = await Task.detached { Self.waiting() }.value
			guard let (url, version) = found, staged == nil else { return }
			switch state { case .idle, .checking, .latest, .failed: break; default: return }
			staged = url; state = .ready(version)
		}
		// Brought to the front after a while away: look again, at most every six hours.
		NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
			MainActor.assumeIsolated {
				guard let self, self.checkedAt.map({ Date().timeIntervalSince($0) > 6 * 3600 }) ?? true else { return }
				self.check(quiet: true)
			}
		}
	}

	/// Ask the site for the newest version: on launch, on coming to the front, on opening Settings,
	/// or when pressed. Off the main actor with a five-second limit, so it never hangs.
	func check(quiet: Bool = false) {
		switch state { case .checking, .downloading, .ready: return; default: break }
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
			case .success(let r):
				guard Self.newer(r.version, than: Self.current) else { state = .latest(Self.current); return }
				guard r.genuine else {
					state = .failed("The site offers \(r.version), but it isn't signed with baud's release key, so baud won't take it.")
					Measure.log("update: \(r.version) offered without a good signature; ignored")
					return
				}
				release = r; state = .available(r.version)
				takeIfAuto()
			case .failure(let e): state = .failed("Couldn't reach baud's site to check."); Measure.log("update check failed: \(e)")
			}
		}
	}

	/// The press: download, check, put in place. Then `restart`.
	func install() {
		guard case .available = state, let r = release, let url = r.url else { return }
		Measure.log("update: downloading \(r.version)")
		state = .downloading(r.version)
		Task {
			do {
				let (tmp, _) = try await URLSession.shared.download(from: url)
				let hash = SHA256.hash(data: try Data(contentsOf: tmp, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
				guard let want = r.sha256, want.lowercased() == hash else {
					state = .failed("The download isn't the one baud's signed record names, so baud won't open it."); return
				}
				let dmg = FileManager.default.temporaryDirectory.appendingPathComponent("baud-\(r.version).dmg")
				try? FileManager.default.removeItem(at: dmg)
				try FileManager.default.moveItem(at: tmp, to: dmg)
				let version = r.version
				switch await Task.detached(operation: { Self.stage(dmg, version: version) }).value {
				case .success(let app):
					try? FileManager.default.removeItem(at: dmg)
					staged = app; state = .ready(r.version)
					Measure.log("update: \(r.version) checked and waiting")
				case .failure(let why):
					// Not ours to replace in place: the disk image, for the drag into Applications.
					Measure.log("update: \(why.message); opening the disk image")
					let keep = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent(dmg.lastPathComponent)
					try? FileManager.default.removeItem(at: keep)
					try? FileManager.default.moveItem(at: dmg, to: keep)
					NSWorkspace.shared.open(keep)
					state = .latest(Self.current)
				}
			} catch { state = .failed("The download didn't finish: \(error.localizedDescription)") }
		}
	}

	/// The new version in place of this one, then opened as this one closes.
	func restart() {
		guard case .ready = state, let new = staged else { return }
		if case .failure(let why) = Self.swap(new) {
			staged = nil
			state = .failed("The new version couldn't be put in place: \(why.message).")
			return
		}
		staged = nil
		let p = Process()
		p.executableURL = URL(fileURLWithPath: "/bin/sh")
		p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundleURL.path]
		try? p.run()
		NSApp.terminate(nil)
	}

	struct Refusal: Error { let message: String }

	/// Where a new version waits: baud's caches, on the same disk as Applications (so going in
	/// place is a rename), without ".app" in its name (so macOS never opens it as another baud).
	nonisolated static var waitingRoom: URL {
		FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("sh.rubric.baud.mac/update")
	}

	/// The disk image's app, copied whole into the waiting room, only if it is baud's, signed by
	/// baud's team, the version the record names, and this copy is the installed one in a folder it
	/// may write.
	nonisolated static func stage(_ dmg: URL, version: String) -> Result<URL, Refusal> {
		let folder = Bundle.main.bundleURL.deletingLastPathComponent()
		guard Bundle.main.bundleIdentifier == "sh.rubric.baud.mac", FileManager.default.isWritableFile(atPath: folder.path) else {
			return .failure(Refusal(message: "this copy can't replace itself"))
		}
		let mount = FileManager.default.temporaryDirectory.appendingPathComponent("baud-update-\(UUID().uuidString)")
		guard run("/usr/bin/hdiutil", "attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path) == 0 else {
			return .failure(Refusal(message: "the disk image wouldn't open"))
		}
		defer { _ = run("/usr/bin/hdiutil", "detach", mount.path, "-force") }
		let app = mount.appendingPathComponent("baud.app")
		guard signedByBaud(app) else { return .failure(Refusal(message: "the app inside isn't signed by baud's team")) }
		let room = waitingRoom
		try? FileManager.default.removeItem(at: room)
		try? FileManager.default.createDirectory(at: room, withIntermediateDirectories: true)
		let staged = room.appendingPathComponent("baud-\(version).staged")
		guard run("/usr/bin/ditto", app.path, staged.path) == 0, signedByBaud(staged), self.version(of: staged) == version else {
			try? FileManager.default.removeItem(at: room)
			return .failure(Refusal(message: "the new app couldn't be copied whole"))
		}
		return .success(staged)
	}

	/// The waiting version in place of this app: a rename on the same disk.
	nonisolated static func swap(_ staged: URL) -> Result<Void, Refusal> {
		do {
			_ = try FileManager.default.replaceItemAt(Bundle.main.bundleURL, withItemAt: staged)
			try? FileManager.default.removeItem(at: waitingRoom)
			return .success(())
		} catch { return .failure(Refusal(message: error.localizedDescription)) }
	}

	/// A version left waiting by an earlier run, if it's newer than this one and still baud's.
	/// Anything else in the waiting room goes.
	nonisolated static func waiting() -> (URL, String)? {
		// Only the shipped app looks: a dev build shares the folder's name and must leave it be.
		guard Bundle.main.bundleIdentifier == "sh.rubric.baud.mac" else { return nil }
		let room = waitingRoom
		guard let found = try? FileManager.default.contentsOfDirectory(at: room, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "staged" }) else { return nil }
		let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
		if let v = version(of: found), newer(v, than: current), signedByBaud(found) { return (found, v) }
		try? FileManager.default.removeItem(at: room)
		return nil
	}

	nonisolated static func version(of app: URL) -> String? {
		(NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?["CFBundleShortVersionString"] as? String
	}

	nonisolated static func signedByBaud(_ app: URL) -> Bool {
		var code: SecStaticCode?, req: SecRequirement?
		guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
			SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, let req else { return false }
		return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode), req) == errSecSuccess
	}

	nonisolated private static func run(_ tool: String, _ args: String...) -> Int32 {
		let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
		p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
		do { try p.run() } catch { return -1 }
		p.waitUntilExit()
		return p.terminationStatus
	}

	/// "0.1.10" is newer than "0.1.7": compare number by number.
	nonisolated static func newer(_ a: String, than b: String) -> Bool {
		let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
		for i in 0..<max(x.count, y.count) { let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0; if p != q { return p > q } }
		return false
	}
}

/// The bar at the foot of the sidebar while a newer baud is waiting: what it is and the one press.
struct UpdateBar: View {
	@Environment(Updates.self) private var updates
	@Environment(\.tones) private var tones
	var body: some View {
		HStack(spacing: 8) {
			Image(systemName: "arrow.down.circle.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(tones.strong)
			VStack(alignment: .leading, spacing: 1) {
				Text(title).font(Theme.smallFont.weight(.semibold)).lineLimit(1)
				Text(detail).font(Theme.smallFont).foregroundStyle(tones.secondary).lineLimit(1)
			}
			Spacer(minLength: 4)
			switch updates.state {
			case .available: Button("Update") { updates.install() }.buttonStyle(Quiet(strong: true))
			case .ready: Button("Restart") { updates.restart() }.buttonStyle(Quiet(strong: true))
			// Downloading: the words under the name say so; no spinner.
			default: EmptyView()
			}
		}
		.padding(.horizontal, 10).padding(.vertical, 8)
		.glass(corner: Radius.card)
	}
	private var title: String {
		switch updates.state {
		case .available(let v), .downloading(let v), .ready(let v): return "baud \(v)"
		default: return "baud"
		}
	}
	private var detail: String {
		switch updates.state {
		case .available: return "A new version is out"
		case .downloading: return "Updating…"
		case .ready: return "Restart to update"
		default: return ""
		}
	}
}
