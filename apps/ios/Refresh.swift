/// The iPhone in the background, with no push of any kind (there is no server to push from):
/// every moment iOS gives, baud goes online, dials what it knows (own devices first), takes what
/// carriers hold for it, hands over what it holds, and notifies on the lock screen for whatever
/// arrived (`Notifier`). Three kinds of moment:
/// - Leaving the app (`linger`): one background task, so a message sent just before locking the
///   phone goes, and a reply in flight lands; up to 25 s, sooner once the network is quiet.
/// - `BGAppRefreshTask`, asked for at shared wall-clock slots (every quarter hour, plus a few
///   seconds of per-device jitter) so a person's devices tend to wake in the same window; 25 s.
/// - `BGProcessingTask` (`catchup`), asked for an hour out, on power and network: iOS grants it
///   mostly overnight while charging, and gives it minutes; two of them here.
/// iOS decides when, and whether, to grant each; `log` keeps what it actually did, for Settings. A force-quit app gets none of these until it's opened again.
import BackgroundTasks
import BaudCore
import Foundation
import UIKit

enum Refresh {
	static let id = "sh.rubric.baud.refresh"
	static let catchupID = "sh.rubric.baud.catchup"
	static let slot: TimeInterval = 15 * 60
	static let budget: TimeInterval = 25
	static let catchupBudget: TimeInterval = 120
	nonisolated(unsafe) static weak var model: AppModel?

	/// Registered before the app finishes launching, as BGTaskScheduler requires.
	static func register() {
		BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { task in
			let box = Box(task)
			Task { @MainActor in schedule(); await run(box.task, budget: budget, kind: "ran") }
		}
		BGTaskScheduler.shared.register(forTaskWithIdentifier: catchupID, using: nil) { task in
			let box = Box(task)
			Task { @MainActor in scheduleCatchup(); await run(box.task, budget: catchupBudget, kind: "caught up") }
		}
	}

	/// The next quarter-hour boundary after `now`, plus this device's jitter. Devices of one
	/// person share the slots; the jitter (0–8 s, from the device key) keeps a thousand phones on
	/// one network from all dialing at once while keeping each person's pair within seconds.
	static func nextSlot(after now: Date = Date(), jitter: TimeInterval) -> Date {
		let t = now.timeIntervalSince1970
		let next = (floor(t / slot) + 1) * slot
		return Date(timeIntervalSince1970: next + jitter)
	}
	@MainActor static var jitter: TimeInterval {
		let id = model?.me.thisDevice ?? ""
		let h = id.utf8.reduce(UInt32(2166136261)) { ($0 ^ UInt32($1)) &* 16777619 }
		return TimeInterval(h % 8000) / 1000
	}

	/// Asked every time the app leaves the foreground, and again from inside a run.
	@MainActor static func schedule() {
		let req = BGAppRefreshTaskRequest(identifier: id)
		req.earliestBeginDate = nextSlot(jitter: jitter)
		do { try BGTaskScheduler.shared.submit(req); note("asked for \(clock(req.earliestBeginDate!))") }
		catch { note("could not ask: \(error.localizedDescription)") }
	}

	/// The longer wake, an hour out at the earliest, on power and network.
	@MainActor static func scheduleCatchup() {
		let req = BGProcessingTaskRequest(identifier: catchupID)
		req.requiresNetworkConnectivity = true
		req.requiresExternalPower = true
		req.earliestBeginDate = Date().addingTimeInterval(3600)
		do { try BGTaskScheduler.shared.submit(req) } catch { note("could not ask for a catch-up: \(error.localizedDescription)") }
	}

	/// Leaving the foreground: stay online while the moment lasts (iOS gives about thirty seconds
	/// to the whole app; this keeps to twenty-five), then offline, unless the person came back.
	@MainActor static func linger() {
		guard let model else { return }
		let app = UIApplication.shared
		let state = Lingering()
		state.id = app.beginBackgroundTask(withName: "baud: finish sending and receiving") { Task { @MainActor in state.expired = true } }
		Task { @MainActor in
			let started = Date()
			let watch = Watch()
			let sub = model.core.subscribe { _ in Task { @MainActor in watch.last = Date(); watch.events += 1 } }
			while !state.expired, app.applicationState != .active, Date().timeIntervalSince(started) < budget {
				try? await Task.sleep(for: .milliseconds(500))
				if Date().timeIntervalSince(started) > 4, Date().timeIntervalSince(watch.last) > 3 { break }
			}
			sub.cancel()
			if app.applicationState != .active, !model.calls.holdsOnline { model.core.setOnline(false) }
			note("lingered \(Int(Date().timeIntervalSince(started))) s after leaving: \(watch.events) events\(state.expired ? ", cut short by iOS" : "")")
			if state.id != .invalid { app.endBackgroundTask(state.id); state.id = .invalid }
		}
	}
	@MainActor final class Lingering { var id = UIBackgroundTaskIdentifier.invalid; var expired = false }

	/// One wake: online, then wait for the network to go quiet (three seconds with no event) or
	/// the budget to run out, then offline. The crate dials cached records on `setOnline(true)`,
	/// takes held envelopes on each connection and hands over what it carries; the app's feeds sync
	/// on connect. Nothing else to do but wait and tell the truth about it.
	@MainActor static func run(_ task: RefreshTask, budget: TimeInterval = budget, kind: String = "ran") async {
		guard let model = model ?? AppModel.current else { task.setTaskCompleted(success: false); return }
		let started = Date()
		let watch = Watch()
		let sub = model.core.subscribe { _ in Task { @MainActor in watch.last = Date(); watch.events += 1 } }
		task.expirationHandler = { Task { @MainActor in watch.expired = true } }
		model.core.setOnline(true)
		while !watch.expired, Date().timeIntervalSince(started) < budget {
			try? await Task.sleep(for: .milliseconds(500))
			if Date().timeIntervalSince(started) > 4, Date().timeIntervalSince(watch.last) > 3 { break }
		}
		sub.cancel()
		let online = model.core.peers().filter(\.device.online).count
		if UIApplication.shared.applicationState != .active, !model.calls.holdsOnline { model.core.setOnline(false) }
		let took = Int(Date().timeIntervalSince(started))
		note("\(kind) at \(clock(started)) for \(took) s: \(online) device\(online == 1 ? "" : "s") online, \(watch.events) events\(watch.expired ? ", cut short by iOS" : "")")
		task.setTaskCompleted(success: !watch.expired)
	}

	/// What a run watches: the last event, how many, whether iOS cut it short.
	@MainActor final class Watch { var last = Date(); var events = 0; var expired = false }
	/// The task crosses from the scheduler's queue to the main actor; it is only ever touched there.
	final class Box: @unchecked Sendable { let task: BGTask; init(_ t: BGTask) { task = t } }
	/// `BAUD_REFRESH_AT=<seconds>`: the simulator cannot schedule (BGTaskScheduler says
	/// unavailable), so the smoke runs the same `run` on a stand-in task that many seconds after
	/// the app goes to the background. What iOS grants is measured on a device, not here.
	@MainActor final class Stub: RefreshTask { var expirationHandler: (() -> Void)?; func setTaskCompleted(success: Bool) { note("stand-in task completed, success \(success)") } }
	@MainActor static func stubIfAsked() {
		guard let s = ProcessInfo.processInfo.environment["BAUD_REFRESH_AT"], let secs = Double(s) else { return }
		// The simulator suspends a backgrounded app at once, so the stand-in runs in the
		// foreground, from offline, the way a real wake starts: what it measures is our part.
		Task { try? await Task.sleep(for: .seconds(secs)); model?.core.setOnline(false); try? await Task.sleep(for: .seconds(3)); note("stand-in task fires (BAUD_REFRESH_AT=\(s)), from offline"); await run(Stub()) }
	}

	// MARK: the record

	static var log: [String] { UserDefaults.standard.stringArray(forKey: "refreshLog") ?? [] }
	static func note(_ s: String) {
		var l = log; l.append("\(stamp()) \(s)"); if l.count > 200 { l.removeFirst(l.count - 200) }
		UserDefaults.standard.set(l, forKey: "refreshLog")
		Measure.log("refresh: \(s)")
	}
	/// Settings' one line about it.
	static var sentence: String {
		let runs = log.filter { $0.contains(" ran at ") }
		guard let lastRun = runs.last else { return "Background refresh: asked for every quarter hour; iOS hasn't granted one yet." }
		let today = runs.filter { $0.hasPrefix(String(stamp().prefix(10))) }.count
		return "Background refresh: last \(lastRun.dropFirst(17)); \(today) run\(today == 1 ? "" : "s") today. iOS decides when; messages wait on your Mac meanwhile."
	}
	private static func clock(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: d) }
	private static func stamp() -> String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f.string(from: Date()) }
}

/// What `run` needs of a task, so a stand-in can drive it where the scheduler cannot.
@MainActor protocol RefreshTask: AnyObject {
	var expirationHandler: (() -> Void)? { get set }
	func setTaskCompleted(success: Bool)
}
extension BGTask: RefreshTask {}
