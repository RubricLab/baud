/// CallKit for baud's calls: the system's incoming-call screen and banner, the call in the status
/// bar and on the lock screen, Bluetooth and the audio session handled the way the phone handles
/// any call. A sleeping iPhone is woken by a VoIP push through the wake relay: that call is
/// reported at once as "baud", and the ring that follows peer to peer takes it over and names the
/// caller. Calls stay out of the Phone app's Recents: they're baud's, not the phone's.
import AVFoundation
import CallKit
import UIKit

@MainActor
final class CallKitBridge: NSObject, CXProviderDelegate {
	private let provider: CXProvider
	private let controller = CXCallController()
	private weak var center: CallCenter?
	private(set) var audioActive = false
	/// A call reported at its push, waiting for its ring; answered or ended there before it came.
	private var pending: (uuid: UUID, at: Date, answered: Bool, ended: Bool)?
	/// A wake reported a call and its ring hasn't come yet.
	var waiting: Bool { pending.map { Date().timeIntervalSince($0.at) < 20 } ?? false }

	init(center: CallCenter) {
		let c = CXProviderConfiguration()
		c.supportsVideo = true
		c.maximumCallGroups = 1
		c.maximumCallsPerCallGroup = 1
		c.supportedHandleTypes = [.generic]
		c.includesCallsInRecents = false
		if let mark = UIImage(named: "CallMark") { c.iconTemplateImageData = mark.pngData() }
		provider = CXProvider(configuration: c)
		self.center = center
		super.init()
		provider.setDelegate(self, queue: nil)
	}

	private func update(_ s: CallCenter.Session) -> CXCallUpdate {
		let u = CXCallUpdate()
		u.remoteHandle = CXHandle(type: .generic, value: s.name)
		u.localizedCallerName = s.name
		u.hasVideo = s.video
		u.supportsHolding = false; u.supportsGrouping = false; u.supportsUngrouping = false; u.supportsDTMF = false
		return u
	}

	/// The audio session's shape, set before CallKit activates it: the same for voice and video, so
	/// nothing about it changes mid-call (a change stops the audio engine). Video calls start on the
	/// speaker by an override once the audio is ours (`startRoute`), never by the video-chat mode,
	/// whose built-in speaker default can't be turned off for the earpiece.
	private func prepareAudio(video: Bool) {
		try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP])
	}

	/// The call's first route: a video call on the speaker, unless a headset is on (AirPods stay
	/// AirPods); a voice call wherever the system put it (the earpiece, or the headset).
	private func startRoute(_ s: CallCenter.Session) {
		guard let routes = center?.routes else { return }
		routes.reset()
		routes.preferSpeaker = s.video
		if s.video, AudioRoutes.onReceiver { routes.useSpeaker() } else { routes.refresh() }
	}

	func incoming(_ s: CallCenter.Session) {
		prepareAudio(video: s.video)
		provider.reportNewIncomingCall(with: s.uuid, update: update(s)) { error in
			// The system wouldn't ring it (Do Not Disturb, a Focus): never a decline, which the
			// caller would hear at once. It rings, silently, in baud's own window instead.
			guard let error else { return }
			Task { @MainActor in s.callKit = false; callLog("call \(s.id.prefix(8)): CallKit wouldn't ring it: \(error)") }
		}
	}

	/// A call push: report a call now, as iOS requires for every one. Its ring should follow within
	/// seconds; if none does, it ends as missed.
	func wakeCall() {
		// Its ring got here first: reported under the same call, which CallKit refuses as a
		// duplicate, and that counts as reporting it.
		if let s = center?.session, !s.phase.over {
			provider.reportNewIncomingCall(with: s.uuid, update: update(s)) { _ in }
			return
		}
		let id = UUID()
		let u = CXCallUpdate()
		u.remoteHandle = CXHandle(type: .generic, value: "baud")
		u.localizedCallerName = "baud"
		u.supportsHolding = false; u.supportsGrouping = false; u.supportsUngrouping = false; u.supportsDTMF = false
		prepareAudio(video: false)
		// One call at a time: a push while one is going on still reports (and so ends at once).
		if pending == nil, center?.session == nil { pending = (id, Date(), false, false) }
		provider.reportNewIncomingCall(with: id, update: u) { error in
			guard let error else { return }
			Task { @MainActor in callLog("call wake: CallKit wouldn't ring it: \(error)"); if self.pending?.uuid == id { self.pending = nil } }
		}
		Task { @MainActor in
			try? await Task.sleep(for: .seconds(15))
			guard pending?.uuid == id else { return }
			pending = nil
			provider.reportCall(with: id, endedAt: Date(), reason: .unanswered)
			callLog("call wake: no ring came")
		}
	}

	/// The ring for a call its push already reported: the session takes that call's place, under
	/// the caller's name; answered or ended there already, it goes the same way here.
	func adopt(_ s: CallCenter.Session) -> Bool {
		guard let p = pending, Date().timeIntervalSince(p.at) < 20 else { return false }
		pending = nil
		s.uuid = p.uuid
		if p.ended { center?.decline(); return true }
		provider.reportCall(with: p.uuid, updated: update(s))
		if p.answered { center?.accept(camera: true) }
		return true
	}

	/// No app model to hand it to (it should always be there): ring and end at once, as iOS requires.
	nonisolated(unsafe) private static var spare: CXProvider?
	static func ringUnattached() {
		let p = CXProvider(configuration: CXProviderConfiguration())
		spare = p
		let id = UUID(), u = CXCallUpdate()
		u.localizedCallerName = "baud"
		p.reportNewIncomingCall(with: id, update: u) { _ in p.reportCall(with: id, endedAt: Date(), reason: .failed) }
	}

	func outgoing(_ s: CallCenter.Session) {
		prepareAudio(video: s.video)
		let start = CXStartCallAction(call: s.uuid, handle: CXHandle(type: .generic, value: s.name))
		start.isVideo = s.video
		controller.request(CXTransaction(action: start)) { error in
			guard let error else { return }
			Task { @MainActor in
				Measure.log("call \(s.id.prefix(8)): CallKit wouldn't start it: \(error)")
				// My media may already be running, waiting on an audio session CallKit won't give.
				self.center?.callKitRefused(s)
			}
		}
	}

	/// A call CallKit isn't carrying: the audio session is baud's to take, and to give back.
	func takeAudio(_ s: CallCenter.Session) {
		prepareAudio(video: s.video)
		try? AVAudioSession.sharedInstance().setActive(true)
		audioActive = true
		startRoute(s)
	}

	func connected(_ s: CallCenter.Session) {
		if s.outgoing { provider.reportOutgoingCall(with: s.uuid, connectedAt: Date()) }
	}

	func muted(_ s: CallCenter.Session) {
		controller.request(CXTransaction(action: CXSetMutedCallAction(call: s.uuid, muted: s.muted))) { _ in }
	}

	/// Over, for whatever reason, from baud's side: CallKit hears it and lets go of the audio.
	func ended(_ s: CallCenter.Session) {
		if !s.callKit {
			try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
			audioActive = false
			return
		}
		let reason: CXCallEndedReason
		switch s.phase {
		case .ended(let why) where why.hasPrefix("Answered on another"): reason = .answeredElsewhere
		case .ended(let why) where why.hasPrefix("Missed") || why == "No answer": reason = .unanswered
		case .ended(let why) where why.hasPrefix("Declined"): reason = .declinedElsewhere
		case .ended(let why) where why.contains("dropped") || why.hasPrefix("Couldn't"): reason = .failed
		default: reason = .remoteEnded
		}
		provider.reportCall(with: s.uuid, endedAt: Date(), reason: reason)
	}

	// MARK: CXProviderDelegate (on the main queue: the delegate was set with no queue of its own)

	nonisolated func providerDidReset(_ provider: CXProvider) {
		MainActor.assumeIsolated { center?.end() }
	}

	nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
		provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
		action.fulfill()
	}

	nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
		let id = action.callUUID
		MainActor.assumeIsolated { if pending?.uuid == id { pending?.answered = true } else { center?.accept(camera: true) } }
		action.fulfill()
	}

	nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
		let id = action.callUUID
		MainActor.assumeIsolated {
			if pending?.uuid == id { pending?.ended = true }
			else if let s = center?.session, s.uuid == id, !s.phase.over { center?.end() }
		}
		action.fulfill()
	}

	nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
		let muted = action.isMuted
		MainActor.assumeIsolated { if let s = center?.session, s.muted != muted { center?.setMuted(muted) } }
		action.fulfill()
	}

	nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
		MainActor.assumeIsolated {
			audioActive = true
			if let s = center?.session { startRoute(s) }
			center?.audioActivated()
		}
	}

	nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
		MainActor.assumeIsolated { audioActive = false }
	}
}
