/// Where a call sounds on the iPhone: the earpiece, the speaker, or a headset (AirPods, a car,
/// wired headphones). With only the iPhone itself, the call's middle button is a speaker switch;
/// with a headset around, it shows where the sound is now and opens a list to move it, the way
/// Signal and FaceTime do. Off the speaker, the call goes back to wherever the system routes it
/// (the headset if one is on, else the earpiece). Where the person put it stays put: the system
/// moves the sound on its own now and then (the call's audio starting again can drop it back on
/// the earpiece), and it's put back; a headset arriving or leaving, or the lock screen's own
/// speaker button, is a new choice and is followed.
#if os(iOS)
import AVFoundation
import Observation
import UIKit

@MainActor @Observable
final class AudioRoutes {
	enum Kind: Equatable { case phone, speaker, headphones, bluetooth, car }

	struct Route: Identifiable, Equatable {
		/// The port's id, or "phone" and "speaker" for the iPhone's own.
		let id: String
		let kind: Kind
		let name: String
		var symbol: String {
			switch kind {
			case .phone: return "iphone"
			case .speaker: return "speaker.wave.2.fill"
			case .headphones: return "headphones"
			case .car: return "car.fill"
			case .bluetooth:
				let n = name.lowercased()
				return n.contains("airpods max") ? "airpods.max" : n.contains("airpods pro") ? "airpods.pro" : n.contains("airpods") ? "airpods" : n.contains("beats") ? "beats.headphones" : "headphones"
			}
		}
	}

	/// Every place the sound can go now, the iPhone and its speaker first.
	private(set) var available: [Route] = []
	/// Where it goes now.
	private(set) var current: Route?
	/// Something besides the iPhone and its speaker: the button opens a list.
	var choosable: Bool { available.count > 2 }
	var onSpeaker: Bool { current?.kind == .speaker }
	/// Told when the route moves, by the person or the system (the proximity sensor follows it).
	@ObservationIgnored var onChange: (() -> Void)?
	/// A video call: the speaker when there's nothing better (no headset), as FaceTime does.
	@ObservationIgnored var preferSpeaker = false
	@ObservationIgnored private var observer: NSObjectProtocol?
	/// Where the person (or the call's start) put the sound, by route id, and when.
	@ObservationIgnored private var chosen: String?
	@ObservationIgnored private var chosenAt = Date.distantPast
	@ObservationIgnored private var restored: [Date] = []

	init() {
		observer = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
			let why = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
			MainActor.assumeIsolated { self?.moved(why) }
		}
		refresh()
	}

	/// A new call: nothing chosen yet.
	func reset() { chosen = nil; restored = []; preferSpeaker = false }

	private func moved(_ why: AVAudioSession.RouteChangeReason?) {
		refresh()
		switch why {
		case .newDeviceAvailable?:
			// AirPods in, a headset plugged in: the sound follows it.
			chosen = nil
		case .oldDeviceUnavailable?:
			chosen = nil
			if preferSpeaker, current?.kind == .phone { useSpeaker() }
		case .override?:
			// Mine land here too, a moment after; anyone else's (the lock screen's) is the choice now.
			if Date().timeIntervalSince(chosenAt) > 1 { chosen = current?.id }
		default:
			keep()
		}
	}

	/// Put the sound back where it was chosen, if the system moved it: three times in three seconds
	/// at most, so a route that won't hold isn't fought forever.
	func keep() {
		refresh()
		guard let want = chosen, let now = current, now.id != want, let r = available.first(where: { $0.id == want }) else { return }
		let t = Date()
		restored = restored.filter { t.timeIntervalSince($0) < 3 }
		guard restored.count < 3 else { return }
		restored.append(t)
		callLog("audio: the sound moved on its own; back to \(r.kind == .bluetooth ? "the headset" : r.name)")
		apply(r)
	}

	/// The speaker, as a choice (a video call starting on the iPhone alone).
	func useSpeaker() {
		refresh()
		if let r = available.first(where: { $0.kind == .speaker }) { choose(r) }
	}

	/// The sound plays through the iPhone's earpiece right now: nothing else is plugged in or paired.
	static var onReceiver: Bool {
		AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .builtInReceiver }
	}

	func refresh() {
		let session = AVAudioSession.sharedInstance()
		let inputs = session.availableInputs ?? []
		let outputs = session.currentRoute.outputs
		let wired = inputs.contains { $0.portType == .headsetMic } || outputs.contains { $0.portType == .headphones }
		var list = [
			wired ? Route(id: "phone", kind: .headphones, name: "Headphones") : Route(id: "phone", kind: .phone, name: "iPhone"),
			Route(id: "speaker", kind: .speaker, name: "Speaker"),
		]
		for p in inputs {
			switch p.portType {
			case .bluetoothHFP, .bluetoothLE: list.append(Route(id: p.uid, kind: .bluetooth, name: p.portName))
			case .carAudio: list.append(Route(id: p.uid, kind: .car, name: p.portName))
			case .usbAudio: list.append(Route(id: p.uid, kind: .headphones, name: p.portName))
			default: break
			}
		}
		var now: Route?
		if let out = outputs.first {
			switch out.portType {
			case .builtInSpeaker: now = list[1]
			case .builtInReceiver, .headphones: now = list[0]
			case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE, .carAudio, .usbAudio, .airPlay, .HDMI:
				now = list.first { $0.id == out.uid || ($0.kind != .phone && $0.kind != .speaker && $0.name == out.portName) }
				if now == nil {
					// Sound-only (a speaker or headphones without a microphone): shown while it plays, not offered.
					let r = Route(id: out.uid, kind: out.portType == .carAudio ? .car : .bluetooth, name: out.portName)
					list.append(r); now = r
				}
			default: now = list[0]
			}
		}
		if list != available { available = list }
		if now != current { current = now; onChange?() }
	}

	/// Move the sound there. The speaker is an override; anything else is the microphone chosen,
	/// which takes the sound with it.
	func choose(_ r: Route) {
		chosen = r.id; chosenAt = Date()
		apply(r)
	}

	private func apply(_ r: Route) {
		let session = AVAudioSession.sharedInstance()
		do {
			if r.kind == .speaker {
				try session.overrideOutputAudioPort(.speaker)
			} else if r.id == "phone" {
				try session.overrideOutputAudioPort(.none)
				let own = session.availableInputs?.first { $0.portType == .headsetMic } ?? session.availableInputs?.first { $0.portType == .builtInMic }
				try session.setPreferredInput(own)
			} else {
				try session.overrideOutputAudioPort(.none)
				if let p = session.availableInputs?.first(where: { $0.uid == r.id }) { try session.setPreferredInput(p) }
			}
			callLog("audio: moved to \(r.kind == .bluetooth ? "a headset" : r.name)")
		} catch {
			callLog("audio: couldn't move to \(r.name): \(error)")
		}
		refresh()
	}

	/// The speaker on or off, for the button when there's nowhere else to go.
	func toggleSpeaker() {
		guard let target = onSpeaker ? available.first : available.first(where: { $0.kind == .speaker }) else { return }
		choose(target)
	}
}
#endif
