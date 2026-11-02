/// Wakes from Apple, the iPhone's side of the wake relay (`wake/`). baud asks Apple for two push
/// addresses, one for alerts and one for VoIP, and seals them into the tickets it hands to the
/// devices it connects to (BaudCore's Wake.swift). Two wakes can come back, both carrying nothing:
/// a message ("New message" on the lock screen, while baud comes online for half a minute, takes
/// what's waiting and posts the real notification in its place) and a call (baud must ring at once
/// through CallKit; the ring itself arrives peer to peer a moment later and names the caller).
import BaudCore
import PushKit
import UIKit
import UserNotifications

final class PushDelegate: NSObject, UIApplicationDelegate, @preconcurrency PKPushRegistryDelegate {
	private var voip: PKPushRegistry?
	nonisolated(unsafe) private static var alert: Data?
	nonisolated(unsafe) private static var voipToken: Data?

	func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
		application.registerForRemoteNotifications()
		// PushKit's delegate must be in place before launch ends: a call push may be why we launched.
		let r = PKPushRegistry(queue: .main)
		r.delegate = self
		r.desiredPushTypes = [.voIP]
		voip = r
		return true
	}

	func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
		Self.alert = deviceToken
		Self.apply()
	}

	func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
		Measure.log("push: no alert address: \(error.localizedDescription)")
	}

	/// A message wake: online for the refresh's budget, then let iOS put us away again.
	func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
		await MainActor.run { Refresh.note("woken for a message") }
		let task = await PushTask()
		await Refresh.run(task, kind: "woken")
		// Nothing unread after all (it came some other way first): the stand-in has nothing to stand for.
		if await MainActor.run(body: { AppModel.current?.unread ?? 0 }) == 0 {
			let c = UNUserNotificationCenter.current()
			let stand = await c.deliveredNotifications().filter { $0.request.content.threadIdentifier == "wake" }.map(\.request.identifier)
			c.removeDeliveredNotifications(withIdentifiers: stand)
		}
		return .newData
	}

	// MARK: PushKit

	func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
		Self.voipToken = pushCredentials.token
		Self.apply()
	}

	func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
		Self.voipToken = nil
		Self.apply()
	}

	/// A call wake. iOS requires a call reported to CallKit before this returns, every time, or it
	/// stops delivering them: so it rings now, as "baud", and the caller's name comes with the ring.
	func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
		MainActor.assumeIsolated {
			if let model = AppModel.current { model.calls.wokenForCall() } else { CallKitBridge.ringUnattached() }
		}
		completion()
	}

	/// Both addresses into the core, once there's a core to take them.
	static func apply() {
		Task { @MainActor in
			guard let model = AppModel.current else { return }
			model.local.setWakeTokens(alert == nil && voipToken == nil ? nil : WakeTokens(alert: alert, voip: voipToken, sandbox: sandbox))
		}
	}

	/// A development build (signed for this phone, with a provisioning profile inside) talks to
	/// Apple's sandbox; TestFlight and the App Store carry no profile and use production.
	static let sandbox: Bool = {
		guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"), let d = try? Data(contentsOf: url) else { return false }
		let s = String(decoding: d, as: UTF8.self)
		guard let r = s.range(of: "<key>aps-environment</key>") else { return true }
		return s[r.upperBound...].prefix(80).contains("development")
	}()
}

/// The refresh's task, for a wake that came by push: iOS gives about 30 seconds and asks for no
/// completion beyond the handler's return.
@MainActor final class PushTask: RefreshTask {
	var expirationHandler: (() -> Void)?
	func setTaskCompleted(success: Bool) {}
}
