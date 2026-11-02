/// Sharing where I am, the app's side (BaudCore's Places.swift has the rules). The location service
/// runs only while a share is on, and sends a fix when I've moved 25 m or 20 s have passed; it
/// stops the moment the last share ends. A share is started from the pin in a chat's header, for
/// an hour, until the end of the day, or until I stop; the people sharing in a chat show on a map
/// card at its top, in the chat's own colour, their faces as the pins.
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

	private func send(_ l: CLLocation) {
		guard l.horizontalAccuracy >= 0 else { return }
		if let (p, at) = last, l.distance(from: p) < 25, Date().timeIntervalSince(at) < 20 { return }
		last = (l, Date())
		model?.local.moved(lat: l.coordinate.latitude, lon: l.coordinate.longitude, accuracy: l.horizontalAccuracy)
	}

	nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
		guard let l = locations.last else { return }
		Task { @MainActor in send(l) }
	}
	nonisolated func locationManagerDidChangeAuthorization(_ changed: CLLocationManager) {
		Task { @MainActor in
			guard on else { return }
			#if os(iOS)
			// A share that should keep going in the background asks for Always once When In Use is given.
			if manager.authorizationStatus == .authorizedWhenInUse { manager.requestAlwaysAuthorization() }
			manager.allowsBackgroundLocationUpdates = manager.authorizationStatus == .authorizedAlways
			#endif
			if let l = manager.location { send(l) }
		}
	}
	nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

/// The pin in a chat's header: start sharing, for how long, or stop.
struct ShareSpot: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	let conv: ConversationId
	var body: some View {
		let until = model.sharingPlaces[conv]
		Menu {
			if let until {
				Text(until == .distantFuture ? "Sharing until you stop" : "Sharing until \(clock(until))")
				Button("Stop sharing", role: .destructive) { model.local.stopSharing(conv) }
			} else {
				Section("Share your location here") {
					Button("For 1 hour") { model.local.share(place: conv, until: Date().addingTimeInterval(3600)) }
					Button("Until the end of the day") { model.local.share(place: conv, until: Calendar.current.startOfDay(for: Date()).addingTimeInterval(86_400)) }
					Button("Until I stop") { model.local.share(place: conv, until: nil) }
				}
			}
		} label: {
			Image(systemName: until == nil ? "location" : "location.fill").font(.system(size: 14, weight: .semibold))
				.frame(width: 30, height: 30)
				.foregroundStyle(until == nil ? tones.secondary : tones.onMine)
				.background { if until != nil { Circle().fill(tones.mine) } }
		}
		.menuIndicator(.hidden)
		.buttonStyle(.plain)
		.help(until == nil ? "Share your location" : "Sharing your location")
		.accessibilityLabel(until == nil ? "Share your location" : "Sharing your location")
	}
}

/// The people sharing where they are in this chat, on a small map at the top; me too, when I am.
struct PlacesCard: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	let conv: ConversationId
	@State private var open = false
	var body: some View {
		let _ = model.placesTick
		let theirs = model.local.places(conv)
		let mine = model.sharingPlaces[conv]
		if !theirs.isEmpty || mine != nil {
			Button { open = true } label: {
				VStack(alignment: .leading, spacing: 0) {
					if !theirs.isEmpty { PlacesMap(places: theirs, interactive: false).frame(height: 128) }
					HStack(spacing: 8) {
						Image(systemName: "location.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(tones.secondary)
						Text(line(theirs, mine)).font(Theme.smallFont).foregroundStyle(tones.text).lineLimit(1)
						Spacer(minLength: 4)
						if mine != nil { Button("Stop") { model.local.stopSharing(conv) }.buttonStyle(.plain).font(Theme.smallFont.weight(.semibold)).foregroundStyle(tones.text) }
					}
					.padding(.horizontal, 12).padding(.vertical, 9)
				}
				.clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
				.glass(corner: 16)
			}
			.buttonStyle(.plain)
			.padding(.horizontal, 16).padding(.top, 8)
			.disabled(theirs.isEmpty)
			.sheet(isPresented: $open) {
				PlacesMap(places: model.local.places(conv), interactive: true)
					.ignoresSafeArea()
					#if os(macOS)
					.frame(minWidth: 560, minHeight: 440)
					#endif
					.presentationDragIndicator(.visible)
			}
		}
	}

	private func line(_ theirs: [Place], _ mine: Date?) -> String {
		let names = theirs.map { model.name(of: $0.user).split(separator: " ").first.map(String.init) ?? "" }
		var parts: [String] = []
		if !names.isEmpty {
			let newest = theirs.map(\.at).max().map { Date(timeIntervalSince1970: $0) } ?? Date()
			parts.append("\(list(names)) \(names.count == 1 ? "is" : "are") sharing · \(ago(newest))")
		}
		if let mine { parts.append(mine == .distantFuture ? "You're sharing" : "You're sharing until \(clock(mine))") }
		return parts.joined(separator: " · ")
	}
	private func ago(_ d: Date) -> String {
		let s = Int(Date().timeIntervalSince(d))
		return s < 60 ? "now" : s < 3600 ? "\(s / 60) min ago" : clock(d)
	}
}

/// A map in the app's colour: Apple's map drained of its own colours and washed in the hue, each
/// person's face where they are.
struct PlacesMap: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	let places: [Place]
	let interactive: Bool
	/// One person: their neighbourhood, about two kilometres across. Several: all of them.
	private var start: MapCameraPosition {
		guard places.count == 1, let p = places.first else { return .automatic }
		return .camera(MapCamera(centerCoordinate: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon), distance: 2200))
	}
	var body: some View {
		Map(initialPosition: start, interactionModes: interactive ? .all : []) {
			ForEach(places, id: \.user) { p in
				Annotation(model.name(of: p.user), coordinate: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon), anchor: .center) {
					Avatar(name: model.name(of: p.user), hash: model.contacts.first { $0.user == p.user }?.avatar, size: 30)
						.padding(2).background(Circle().fill(tones.mine)).shadow(color: tones.shade, radius: 6, y: 3)
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
