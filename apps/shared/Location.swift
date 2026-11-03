/// Location in a chat, from first principles: what people do is say where they are once ("here"),
/// let others follow them for a while (on the way, meeting up), and see where everyone is. One sheet
/// from the composer's + does the first two; a place sent once is a small map in the chat; and while
/// anyone shares live, a slim bar under the header opens one map of all of them.
import BaudCore
import CoreLocation
import MapKit
import SwiftUI

// MARK: a place, once

/// A place sent once is a message in plain words (a pin and an Apple Maps link), so every baud
/// reads it, old or new, on any device: this one draws it as a map, an older one shows the link.
enum PlaceText {
	static let prefix = "📍 https://maps.apple.com/?ll="
	static func make(_ c: CLLocationCoordinate2D) -> String { prefix + String(format: "%.5f,%.5f", c.latitude, c.longitude) }
	static func parse(_ s: String?) -> CLLocationCoordinate2D? {
		guard let s, s.hasPrefix(prefix) else { return nil }
		let parts = s.dropFirst(prefix.count).split(separator: ",")
		guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]), abs(lat) <= 90, abs(lon) <= 180 else { return nil }
		return CLLocationCoordinate2D(latitude: lat, longitude: lon)
	}
}

/// A still of the map around a place, made once and kept: a live map in every bubble of a long chat
/// would cost far more than a picture.
@MainActor enum MapShot {
	private static var made: [String: Image] = [:]
	static func image(_ c: CLLocationCoordinate2D, size: CGSize, dark: Bool) async -> Image? {
		let key = String(format: "%.5f,%.5f,%.0fx%.0f,%d", c.latitude, c.longitude, size.width, size.height, dark ? 1 : 0)
		if let i = made[key] { return i }
		let o = MKMapSnapshotter.Options()
		o.region = MKCoordinateRegion(center: c, latitudinalMeters: 650, longitudinalMeters: 650)
		o.size = size
		o.pointOfInterestFilter = .excludingAll
		#if os(iOS)
		o.traitCollection = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
		#else
		o.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		#endif
		guard let shot = try? await MKMapSnapshotter(options: o).start() else { return nil }
		#if os(iOS)
		let i = Image(uiImage: shot.image)
		#else
		let i = Image(nsImage: shot.image)
		#endif
		made[key] = i
		return i
	}
}

/// A place in the chat: the map around it, washed in the chat's colour, the sender's face at the
/// spot, and whose it is. A tap opens it big, with a way to Apple Maps.
struct PlaceBubble: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	@Environment(\.colorScheme) private var scheme
	let event: Event
	let at: CLLocationCoordinate2D
	@State private var still: Image?
	@State private var open = false
	static let size = CGSize(width: 236, height: 148)
	var body: some View {
		let name = event.mine ? model.me.name : model.name(of: event.user)
		let hash = event.mine ? model.me.avatar : model.contacts.first { $0.user == event.user }?.avatar
		Button { open = true } label: {
			VStack(alignment: .leading, spacing: 6) {
				ZStack {
					if let still { still.resizable().scaledToFill().saturation(0).overlay(tones.surface.blendMode(.color)) }
					else { Rectangle().fill(tones.quiet) }
					PinFace(name: name, hash: hash, size: 28)
				}
				.frame(width: Self.size.width, height: Self.size.height)
				.clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
				HStack(spacing: 5) {
					Image(systemName: "mappin").font(.system(size: Theme.small, weight: .semibold))
					Text(event.mine ? "Your location" : "\(name.split(separator: " ").first.map(String.init) ?? name)'s location").font(Theme.smallFont.weight(.semibold))
				}
				.foregroundStyle(event.mine ? tones.onMine : tones.text)
				.padding(.horizontal, 3)
			}
		}
		.buttonStyle(.plain)
		.accessibilityLabel(event.mine ? "Your location" : "\(name)'s location")
		.task(id: scheme) { still = await MapShot.image(at, size: Self.size, dark: scheme == .dark) }
		.sheet(isPresented: $open) {
			PlaceOpen(pin: Pin(id: event.id, name: name, hash: hash, lat: at.latitude, lon: at.longitude), when: event.at).environment(\.tones, tones)
		}
	}
}

/// A place opened: the map, big, and a way out to Apple Maps for directions (a tap there is the
/// only time the place leaves baud).
private struct PlaceOpen: View {
	@Environment(\.tones) private var tones
	@Environment(\.openURL) private var openURL
	@Environment(\.dismiss) private var dismiss
	let pin: Pin
	let when: Date
	var body: some View {
		VStack(spacing: 0) {
			HueMap(pins: [pin]).ignoresSafeArea(edges: .top)
			VStack(alignment: .leading, spacing: 12) {
				HStack(spacing: 10) {
					Avatar(name: pin.name, hash: pin.hash, size: Rows.face)
					VStack(alignment: .leading, spacing: 1) {
						Text(pin.name).font(Theme.font.weight(.semibold))
						Text("Sent \(when.formatted(date: .abbreviated, time: .shortened))").font(Theme.smallFont).foregroundStyle(tones.secondary)
					}
					Spacer()
				}
				Button {
					if let u = URL(string: String(format: "https://maps.apple.com/?ll=%.5f,%.5f&q=%@", pin.lat, pin.lon, pin.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")) { openURL(u) }
				} label: { Label("Open in Maps", systemImage: "map").frame(maxWidth: .infinity) }
				.buttonStyle(Quiet(strong: true, large: true))
			}
			.padding(Parts.side)
			.background(tones.surface)
		}
		#if os(macOS)
		.frame(minWidth: 520, minHeight: 480)
		.overlay(alignment: .topTrailing) { IconButton(symbol: "xmark", help: "Close", size: 11) { dismiss() }.padding(10) }
		#else
		.presentationDragIndicator(.visible)
		#endif
	}
}

// MARK: the sheet

/// Location, from the composer's +: the map around me, then the two things to do with it. Sending
/// it once is first (it's what "where are you?" wants); sharing live, for how long, under it; and
/// who sees it, said plainly.
struct LocationSheet: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	@Environment(\.dismiss) private var dismiss
	@Environment(\.openURL) private var openURL
	let conv: ConversationId
	@State private var fix: CLLocation?
	@State private var finding = true

	var body: some View {
		let c = model.conversation(conv)
		let until = model.sharingPlaces[conv]
		let who = c.map { $0.isDirect ? "Only \(model.title($0)) sees it." : "Everyone in \(model.title($0)) sees it, and nobody else." } ?? "Only this chat sees it."
		VStack(spacing: 0) {
			ZStack {
				if let fix { HueMap(pins: [Pin(id: "me", name: model.me.name, hash: model.me.avatar, lat: fix.coordinate.latitude, lon: fix.coordinate.longitude)], interactive: false) }
				else {
					Rectangle().fill(tones.quiet)
					if finding { ProgressView().controlSize(.large) }
				}
			}
			.frame(height: 240)
			.clipped()
			.overlay(alignment: .topTrailing) {
				IconButton(symbol: "xmark", help: "Close", size: 13) { dismiss() }
					.background(Circle().fill(tones.surface.opacity(0.9))).padding(12)
			}
			ScrollView {
				VStack(alignment: .leading, spacing: Parts.gap) {
					if Whereabouts.shared.denied {
						ListCard(footer: "baud looks for where you are only when you send it or share it.") {
							Button {
								#if os(iOS)
								if let u = URL(string: UIApplication.openSettingsURLString) { openURL(u) }
								#else
								if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") { openURL(u) }
								#endif
							} label: { ActionRow(symbol: "location.slash", title: "Turn on Location for baud") }
							.buttonStyle(RowStyle())
						}
					} else {
						ListCard {
							Button { sendOnce() } label: {
								ActionRow(symbol: "mappin", title: "Send where you are", value: fix.map { "within \(distance($0.horizontalAccuracy))" } ?? (finding ? "Finding you…" : nil))
							}
							.buttonStyle(RowStyle()).disabled(fix == nil)
						}
						if let until {
							ListCard(title: "Sharing live", footer: "Your place updates here as you move.") {
								ActionRow(symbol: "location.fill", title: until == .distantFuture ? "Until you stop" : "Until \(clock(until))")
								Button { model.local.stopSharing(conv); dismiss() } label: { ActionRow(symbol: "location.slash", title: "Stop sharing", danger: true) }.buttonStyle(RowStyle())
							}
						} else {
							ListCard(title: "Share live", footer: "Your place updates as you move, until then, and stops by itself.") {
								live("For 1 hour", symbol: "clock", until: Date().addingTimeInterval(3600))
								live("Until tonight", symbol: "moon", until: Calendar.current.startOfDay(for: Date()).addingTimeInterval(86_400))
								live("Until you stop", symbol: "infinity", until: nil)
							}
						}
					}
					Text("\(who) It goes straight to their devices, through no server.")
						.font(Theme.smallFont).foregroundStyle(tones.secondary).padding(.horizontal, 4)
				}
				.padding(.horizontal, Parts.side).padding(.vertical, Parts.gap)
			}
		}
		.background(tones.surface.ignoresSafeArea())
		.task { fix = await Whereabouts.shared.once(); finding = false }
		#if os(macOS)
		.frame(width: 420, height: 600)
		#else
		.presentationDetents([.large]).presentationDragIndicator(.visible)
		#endif
	}

	private func live(_ title: String, symbol: String, until: Date?) -> some View {
		Button { model.local.share(place: conv, until: until); dismiss() } label: { ActionRow(symbol: symbol, title: title) }.buttonStyle(RowStyle())
	}

	private func sendOnce() {
		guard let fix else { return }
		model.send(conv, Draft(text: PlaceText.make(fix.coordinate)))
		Haptic.send()
		dismiss()
	}
}

/// "120 m", "1.2 km", or miles where the person reads miles.
func distance(_ metres: Double) -> String {
	Measurement(value: max(5, metres), unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road))
}

// MARK: live

/// While anyone shares live in this chat: their faces and who, in one line under the header, and
/// my own share's stop right there. A tap opens everyone on one map.
struct LiveBar: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	let conv: ConversationId
	@State private var open = false
	var body: some View {
		let _ = model.placesTick
		let theirs = model.local.places(conv)
		let mine = model.sharingPlaces[conv]
		if !theirs.isEmpty || mine != nil {
			HStack(spacing: 10) {
				Button { open = true } label: {
					HStack(spacing: 10) {
						ZStack(alignment: .leading) {
							ForEach(Array(theirs.prefix(3).enumerated()), id: \.offset) { i, p in
								Avatar(name: model.name(of: p.user), hash: model.contacts.first { $0.user == p.user }?.avatar, size: 24)
									.background(Circle().fill(tones.surface).padding(-1.5))
									.offset(x: CGFloat(i) * 15)
							}
							if theirs.isEmpty { Image(systemName: "location.fill").font(.system(size: 13, weight: .semibold)).frame(width: 24, height: 24) }
						}
						.frame(width: 24 + CGFloat(max(0, min(3, theirs.count) - 1)) * 15, alignment: .leading)
						Text(line(theirs, mine)).font(Theme.smallFont.weight(.semibold)).foregroundStyle(tones.text).lineLimit(1)
						Spacer(minLength: 4)
						if mine == nil { Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(tones.tertiary) }
					}
					.frame(maxHeight: .infinity).contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				if mine != nil {
					Button("Stop") { model.local.stopSharing(conv) }
						.font(Theme.smallFont.weight(.bold)).foregroundStyle(tones.danger)
						.buttonStyle(.plain).frame(minWidth: 44, minHeight: 36).contentShape(Rectangle())
				}
			}
			.padding(.horizontal, 12).frame(height: 44)
			.glass(corner: 14)
			.padding(.horizontal, 12).padding(.top, 6)
			.transition(.move(edge: .top).combined(with: .opacity))
			.sheet(isPresented: $open) { LiveMap(conv: conv).environment(model).environment(\.tones, tones) }
		}
	}

	private func line(_ theirs: [Place], _ mine: Date?) -> String {
		let names = theirs.map { model.name(of: $0.user).split(separator: " ").first.map(String.init) ?? "" }
		if names.isEmpty, let mine { return mine == .distantFuture ? "You're sharing live" : "You're sharing live until \(clock(mine))" }
		return "\(list(names)) \(names.count == 1 ? "is" : "are") sharing live" + (mine != nil ? " · you too" : "")
	}
}

/// Everyone sharing live in the chat, on one map, and under it each of them: how fresh, how far.
/// My own share is there too, with its stop, or a way to start one.
struct LiveMap: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	@Environment(\.dismiss) private var dismiss
	let conv: ConversationId
	@State private var locating = false
	var body: some View {
		let _ = model.placesTick
		let theirs = model.local.places(conv)
		let mine = model.sharingPlaces[conv]
		let me = Whereabouts.shared.lastFix
		let pins = theirs.map { p in Pin(id: p.user, name: model.name(of: p.user), hash: model.contacts.first { $0.user == p.user }?.avatar, lat: p.lat, lon: p.lon) }
			+ (mine != nil ? me.map { [Pin(id: "me", name: model.me.name, hash: model.me.avatar, lat: $0.coordinate.latitude, lon: $0.coordinate.longitude)] } ?? [] : [])
		VStack(spacing: 0) {
			HueMap(pins: pins).ignoresSafeArea(edges: .top)
			VStack(alignment: .leading, spacing: 0) {
				ForEach(theirs, id: \.user) { p in
					HStack(spacing: 10) {
						Avatar(name: model.name(of: p.user), hash: model.contacts.first { $0.user == p.user }?.avatar, size: Rows.face)
						VStack(alignment: .leading, spacing: 1) {
							Text(model.name(of: p.user)).font(Theme.font.weight(.medium)).lineLimit(1)
							Text(ago(p.date) + (p.until.map { " · until \(clock(Date(timeIntervalSince1970: $0)))" } ?? "")).font(Theme.smallFont).foregroundStyle(tones.secondary)
						}
						Spacer(minLength: 8)
						if let me { Text(distance(me.distance(from: CLLocation(latitude: p.lat, longitude: p.lon)))).font(Theme.smallFont.weight(.semibold)).foregroundStyle(tones.secondary) }
					}
					.frame(height: Rows.chat)
				}
				Hairline().padding(.vertical, 4)
				if let mine {
					HStack {
						Text(mine == .distantFuture ? "You're sharing until you stop" : "You're sharing until \(clock(mine))").font(Theme.font)
						Spacer()
						Button("Stop") { model.local.stopSharing(conv) }.buttonStyle(Quiet(danger: true))
					}
					.frame(minHeight: Rows.chat)
				} else {
					Button { locating = true } label: { Label("Share yours", systemImage: "location").frame(maxWidth: .infinity) }
						.buttonStyle(Quiet(strong: true, large: true)).padding(.vertical, 8)
				}
			}
			.padding(.horizontal, Parts.side).padding(.vertical, 8)
			.background(tones.surface)
		}
		.sheet(isPresented: $locating) { LocationSheet(conv: conv).environment(model).environment(\.tones, tones) }
		#if os(macOS)
		.frame(minWidth: 560, minHeight: 520)
		.overlay(alignment: .topTrailing) { IconButton(symbol: "xmark", help: "Close", size: 11) { dismiss() }.padding(10) }
		#else
		.presentationDragIndicator(.visible)
		#endif
	}
	private func ago(_ d: Date) -> String {
		let s = Int(Date().timeIntervalSince(d))
		return s < 60 ? "Just now" : s < 3600 ? "\(s / 60) min ago" : "At \(clock(d))"
	}
}
