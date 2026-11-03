/// Where I am, in a chat, the app's side (BaudCore's Places.swift has the rules for live shares).
/// Three things people do, from the composer's + (Location):
/// - send where they are once: a message of its own words (a pin and a map link, so any baud, old
///   or new, can read it), drawn here as a small map with their face on it;
/// - share live, for an hour, until tonight, or until they stop: the location service runs only
///   while a share is on, a fix when I've moved 25 m or 20 s have passed, and stops with the last;
/// - see everyone sharing live in the chat: a slim bar under its header while anyone is, opening
///   one map of all of them, with how far and how fresh, and my own share's stop.
import BaudCore
import CoreLocation
import MapKit
import SwiftUI

@MainActor
final class Whereabouts: NSObject, CLLocationManagerDelegate {
	static let shared = Whereabouts()
	private let manager = CLLocationManager()
	private weak var model: AppModel?
	private var on = false
	private var last: (CLLocation, Date)?

	func attach(_ model: AppModel) {
		self.model = model
		manager.delegate = self
		manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
		manager.distanceFilter = 25
		follow()
	}

	/// On while any chat wants my location, off when none does.
	func follow() {
		guard let model else { return }
		let want = model.local.wantsPlace
		if want && !on {
			on = true
			switch manager.authorizationStatus {
			case .notDetermined: manager.requestWhenInUseAuthorization()
			case .denied, .restricted: model.error = "baud can't see where you are. Turn on Location for baud in Settings to share it."
			default: break
			}
			#if os(iOS)
			// Moving while baud is in the background: significant changes wake it (with Always).
			manager.allowsBackgroundLocationUpdates = manager.authorizationStatus == .authorizedAlways
			manager.startMonitoringSignificantLocationChanges()
			#endif
			manager.startUpdatingLocation()
			if let l = manager.location { send(l) }
		} else if !want && on {
			on = false
			manager.stopUpdatingLocation()
			#if os(iOS)
			manager.stopMonitoringSignificantLocationChanges()
			#endif
			last = nil
		}
	}

	// MARK: once

	private var waiting: [CheckedContinuation<CLLocation?, Never>] = []
	var denied: Bool { manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted }
	/// Where I was last seen by the location service, if it's been on.
	var lastFix: CLLocation? { manager.location }

	/// One fix now, for a place sent once: a recent one if there is one, else the service asked
	/// for one (and for permission, the first time), ten seconds at most.
	func once() async -> CLLocation? {
		if let l = manager.location, Date().timeIntervalSince(l.timestamp) < 30, l.horizontalAccuracy >= 0, l.horizontalAccuracy < 100 { return l }
		if denied { return nil }
		manager.delegate = self
		return await withCheckedContinuation { c in
			waiting.append(c)
			if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() } else { manager.requestLocation() }
			Task { try? await Task.sleep(for: .seconds(10)); self.answer(self.manager.location) }
		}
	}
	private func answer(_ l: CLLocation?) {
		let w = waiting; waiting = []
		w.forEach { $0.resume(returning: l) }
	}

	private func send(_ l: CLLocation) {
		guard l.horizontalAccuracy >= 0 else { return }
		if let (p, at) = last, l.distance(from: p) < 25, Date().timeIntervalSince(at) < 20 { return }
		last = (l, Date())
		model?.local.moved(lat: l.coordinate.latitude, lon: l.coordinate.longitude, accuracy: l.horizontalAccuracy)
	}

	nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
		guard let l = locations.last else { return }
		Task { @MainActor in if !waiting.isEmpty { answer(l) }; if on { send(l) } }
	}
	nonisolated func locationManagerDidChangeAuthorization(_ changed: CLLocationManager) {
		Task { @MainActor in
			if !waiting.isEmpty {
				if denied { answer(nil) } else if manager.authorizationStatus != .notDetermined { manager.requestLocation() }
			}
			guard on else { return }
			#if os(iOS)
			// A share that should keep going in the background asks for Always once When In Use is given.
			if manager.authorizationStatus == .authorizedWhenInUse { manager.requestAlwaysAuthorization() }
			manager.allowsBackgroundLocationUpdates = manager.authorizationStatus == .authorizedAlways
			#endif
			if let l = manager.location { send(l) }
		}
	}
	nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
		Task { @MainActor in if !waiting.isEmpty, denied { answer(nil) } }
	}
}

/// Someone on a map: their face where they are.
struct Pin: Identifiable, Hashable {
	let id: String
	let name: String
	let hash: BlobHash?
	let lat: Double, lon: Double
	var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

/// A map in the app's colour: Apple's map drained of its own colours and washed in the hue, each
/// person's face where they are.
struct HueMap: View {
	@Environment(\.tones) private var tones
	let pins: [Pin]
	var interactive = true
	/// A tap on a face picks that person (their card); nil: the faces are only pictures.
	var picked: Binding<String?>? = nil
	/// One person: their neighbourhood, about two kilometres across. Several: all of them.
	private var start: MapCameraPosition {
		guard pins.count == 1, let p = pins.first else { return .automatic }
		return .camera(MapCamera(centerCoordinate: p.coordinate, distance: 2200))
	}
	var body: some View {
		Map(initialPosition: start, interactionModes: interactive ? .all : []) {
			ForEach(pins) { p in
				Annotation(p.name, coordinate: p.coordinate, anchor: .center) {
					PinFace(name: p.name, hash: p.hash)
						.onTapGesture { if let picked { picked.wrappedValue = picked.wrappedValue == p.id ? nil : p.id } }
						.accessibilityAddTraits(picked != nil ? .isButton : [])
				}
			}
		}
		.mapStyle(.standard(pointsOfInterest: .excludingAll))
		.mapControls { if interactive { MapCompass(); MapScaleView() } }
		.saturation(0)
		.overlay(tones.surface.blendMode(.color).allowsHitTesting(false))
		.compositingGroup()
	}
}

/// A face as a pin: ringed in the chat's strongest colour, lifted off the map.
struct PinFace: View {
	@Environment(\.tones) private var tones
	let name: String
	let hash: BlobHash?
	var size: CGFloat = 32
	var body: some View {
		Avatar(name: name, hash: hash, size: size)
			.padding(2.5).background(Circle().fill(tones.mine)).shadow(color: tones.shade, radius: 6, y: 3)
	}
}
