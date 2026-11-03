/// Where a call sounds on the iPhone: the earpiece, the speaker, or a headset (AirPods, a car,
/// wired headphones). With only the iPhone itself, the call's middle button is a speaker switch;
/// with a headset around, it shows where the sound is now and opens a list to move it, the way
/// Signal and FaceTime do. Off the speaker, the call goes back to wherever the system routes it
/// (the headset if one is on, else the earpiece).
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
	@ObservationIgnored private var observer: NSObjectProtocol?

	init() {
		observer = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
			MainActor.assumeIsolated { self?.refresh() }
		}
		refresh()
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
