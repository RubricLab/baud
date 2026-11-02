/// baud opens at login on the Mac, from the first run (a Mac that's on carries messages for the
/// phone and for friends), until the person turns it off in Settings. macOS says so when it's
/// added. Never for a lab copy or a smoke run, which have a store of their own.
import Foundation
import ServiceManagement

enum LoginItem {
	static func firstRun() {
		guard ProcessInfo.processInfo.environment["BAUD_DIR"] == nil, !UserDefaults.standard.bool(forKey: "loginItemSet") else { return }
		UserDefaults.standard.set(true, forKey: "loginItemSet")
		set(true)
	}

	static func set(_ on: Bool) {
		do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
		catch { Measure.log("login item: \(on ? "add" : "remove") failed: \(error)") }
	}
}
