/// Settings, in sections: You (face, name, colour), Devices, Notifications, Calls, Connection,
/// Updates and Data (with starting over, last). On the Mac they are the main window's pane, a list
/// of sections beside the one open; on the iPhone, You lists them and each opens as a page.
/// Friends aren't here: they have a page of their own, nowhere near adding a device.
import AVFoundation
import BaudCore
import PhotosUI
import SwiftUI
import UserNotifications
#if os(macOS)
import ServiceManagement
#else
import UIKit
#endif

enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
	case you, devices, notifications, calls, connection, updates, data
	var id: String { rawValue }
	var title: String {
		switch self {
		case .you: "You"
		case .devices: "Devices"
		case .notifications: "Notifications"
		case .calls: "Calls"
		case .connection: "Connection"
		case .updates: "Updates"
		case .data: "Data"
		}
	}
	var symbol: String {
		switch self {
		case .you: "person.crop.circle"
		case .devices: "laptopcomputer.and.iphone"
		case .notifications: "bell"
		case .calls: "phone"
		case .connection: "point.3.connected.trianglepath.dotted"
		case .updates: "arrow.down.circle"
		case .data: "internaldrive"
		}
	}
	/// A section asked for by an older name (a menu, a link, `BAUD_SECTION`).
	init?(asked: String) {
		switch asked {
		case "you", "colour": self = .you
		case "devices": self = .devices
		case "notifications": self = .notifications
		case "calls": self = .calls
		case "network", "connection": self = .connection
		case "app", "updates": self = .updates
		case "data": self = .data
		default: return nil
		}
	}
}

struct SettingsView: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	#if os(macOS)
	@Environment(Updates.self) private var updates
	@State private var section: SettingsSection = .you
	#endif

	var body: some View {
		#if os(macOS)
		HStack(spacing: 0) {
			SettingsList(selected: $section).frame(width: 220).background(tones.raised)
			Rectangle().fill(tones.hairline).frame(width: 1)
			VStack(spacing: 0) {
				SheetHeader(title: section.title, close: { model.pane = nil }, help: "Back")
				ScrollView {
					SectionContent(section: section)
						.padding(.horizontal, Settings.side).padding(.vertical, Space.section)
						.frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity)
				}
			}
		}
		.background(tones.surface)
		.onAppear { take(model.settingsSection); updates.check(quiet: true) }
		.onChange(of: model.settingsSection) { _, s in take(s) }
		#else
		ScrollView {
			VStack(alignment: .leading, spacing: Space.section) {
				ListCard {
					NavigationLink(value: SettingsSection.you) {
						HStack(spacing: Rows.gap) {
							Avatar(name: model.me.name, hash: model.me.avatar, size: 56)
							VStack(alignment: .leading, spacing: 2) {
								Text(model.me.name).font(Theme.titleFont).lineLimit(1)
								Text("Face, name and colour").font(Theme.smallFont).foregroundStyle(tones.secondary)
							}
							Spacer(minLength: 8)
							Image(systemName: "chevron.right").font(Icon.font(Icon.inline)).foregroundStyle(tones.tertiary)
						}
						.frame(minHeight: 72)
					}
					.buttonStyle(RowStyle())
				}
				ListCard { ForEach([SettingsSection.devices, .notifications, .calls, .connection]) { row($0) } }
				ListCard { ForEach([SettingsSection.updates, .data]) { row($0) } }
			}
			.padding(.horizontal, Settings.side).padding(.vertical, Space.section)
		}
		.background(tones.surface.ignoresSafeArea())
		.navigationDestination(for: SettingsSection.self) { SettingsPageOf(section: $0) }
		#endif
	}

	#if os(macOS)
	private func take(_ asked: String?) {
		guard let asked else { return }
		if let s = SettingsSection(asked: asked) { section = s }
		model.settingsSection = nil
	}
	#else
	private func row(_ s: SettingsSection) -> some View {
		NavigationLink(value: s) {
			HStack(spacing: Rows.gap) {
				Image(systemName: s.symbol).font(Icon.font(Icon.row)).foregroundStyle(tones.secondary).frame(width: Rows.personFace)
				Text(s.title).font(Theme.font.weight(.medium))
				Spacer(minLength: 8)
				SectionValue(section: s)
				Image(systemName: "chevron.right").font(Icon.font(Icon.inline)).foregroundStyle(tones.tertiary)
			}
			.frame(minHeight: Rows.line)
		}
		.buttonStyle(RowStyle())
	}
	#endif
}

/// The quiet value beside a section's name: how many devices, the connection's word.
struct SectionValue: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	let section: SettingsSection
	var body: some View {
		switch section {
		case .devices: Text("\(model.me.devices.count)").font(Theme.font).foregroundStyle(tones.secondary)
		case .connection: Text(model.netState.words(connecting: model.connecting)).font(Theme.font).foregroundStyle(tones.secondary).lineLimit(1)
		default: EmptyView()
		}
	}
}

#if os(macOS)
/// The Mac's list of sections: me at the top (my face, my name), then each section, the open one lit.
struct SettingsList: View {
	@Environment(AppModel.self) private var model
	@Environment(Updates.self) private var updates
	@Environment(\.tones) private var tones
	@Binding var selected: SettingsSection
	var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			Button { selected = .you } label: {
				HStack(spacing: Rows.gap) {
					Avatar(name: model.me.name, hash: model.me.avatar, size: 32)
					VStack(alignment: .leading, spacing: 1) {
						Text(model.me.name).font(Theme.font.weight(.semibold)).lineLimit(1)
						Text("Face, name and colour").font(Theme.smallFont).foregroundStyle(tones.secondary).lineLimit(1)
					}
				}
				.frame(minHeight: 48)
			}
			.buttonStyle(RowStyle(selected: selected == .you))
			.padding(.bottom, 6)
			ForEach(SettingsSection.allCases.dropFirst()) { s in
				Button { selected = s } label: {
					HStack(spacing: Rows.gap) {
						Image(systemName: s.symbol).font(Icon.font(Icon.row)).frame(width: 20)
						Text(s.title).font(Theme.font)
						Spacer(minLength: 4)
						// An update waiting shows here, as it does at the sidebar's foot.
						if s == .updates, updates.offering { Circle().fill(tones.strong).frame(width: 8, height: 8).accessibilityLabel("Update waiting") }
					}
					.frame(minHeight: Rows.line)
				}
				.buttonStyle(RowStyle(selected: selected == s))
			}
			Spacer()
		}
		.padding(.top, 12)
	}
}
#else
/// One section, as a page of its own (the iPhone).
struct SettingsPageOf: View {
	@Environment(\.tones) private var tones
	let section: SettingsSection
	var body: some View {
		ScrollView {
			SectionContent(section: section).padding(.horizontal, Settings.side).padding(.vertical, Space.section)
		}
		.background(tones.surface.ignoresSafeArea())
		.navigationTitle(section.title).navigationBarTitleDisplayMode(.inline)
		.modifier(Bars())
	}
}
#endif

/// What a section holds.
struct SectionContent: View {
	let section: SettingsSection
	var body: some View {
		VStack(alignment: .leading, spacing: Space.section) {
			switch section {
			case .you: MeCard()
			case .devices: DevicesSection()
			case .notifications: NotifyCard()
			case .calls: CallsCard()
			case .connection:
				ConnectionDetails()
				#if os(macOS)
				AtLoginCard()
				#endif
			case .updates: UpdatesCard()
			case .data: DataCard()
			}
		}
	}
}

/// Every section, one under the other: the offscreen picture of Settings whole.
struct SettingsPage: View {
	var body: some View {
		VStack(alignment: .leading, spacing: Space.section * 1.5) {
			ForEach(SettingsSection.allCases) { s in
				VStack(alignment: .leading, spacing: Space.title) {
					Text(s.title).font(Theme.headingFont)
					SectionContent(section: s)
				}
			}
		}
		.padding(.horizontal, Settings.side).padding(.vertical, Space.section)
		.frame(maxWidth: 640, alignment: .leading)
	}
}

enum Settings {
	#if os(macOS)
	static let side: CGFloat = 24, top: CGFloat = 16, face: CGFloat = 64
	#else
	static let side: CGFloat = 16, top: CGFloat = 16, face: CGFloat = 72
	#endif
}

/// A titled card that holds a picture rather than rows: padded all round.
struct Card<Content: View>: View {
	@Environment(\.tones) private var tones
	let title: String
	@ViewBuilder var content: Content
	var body: some View {
		VStack(alignment: .leading, spacing: Space.title) {
			SectionTitle(title)
			VStack(alignment: .leading, spacing: 0) { content }
				.padding(Space.side)
				.frame(maxWidth: .infinity, alignment: .leading)
				.glass(corner: Radius.card)
		}
	}
}

/// A row of a settings card: its glyph, its words, and on the right what it is now and what to do.
struct SettingRow<Trailing: View>: View {
	@Environment(\.tones) private var tones
	let symbol: String
	let title: String
	var detail: String? = nil
	@ViewBuilder var trailing: Trailing
	var body: some View {
		HStack(spacing: Rows.gap) {
			Image(systemName: symbol).font(Icon.font(Icon.row)).foregroundStyle(tones.secondary).frame(width: Rows.personFace)
			VStack(alignment: .leading, spacing: 2) {
				Text(title).font(Theme.font.weight(.medium))
				if let detail { Text(detail).font(Theme.smallFont).foregroundStyle(tones.secondary).fixedSize(horizontal: false, vertical: true) }
			}
			Spacer(minLength: 8)
			trailing
		}
		.frame(minHeight: detail == nil ? Rows.line : Rows.person)
		.cardRow()
	}
}

// MARK: notifications

/// Whether baud may say a message came (and, on the iPhone, wake for it), and the way to turn it on.
struct NotifyCard: View {
	@Environment(\.tones) private var tones
	@Environment(\.scenePhase) private var phase
	@State private var off = false
	@State private var noRefresh = false
	var body: some View {
		ListCard(footer: "A muted chat comes in quietly: mute one from its menu or its page.") {
			SettingRow(symbol: off ? "bell.slash" : "bell", title: "Notifications", detail: off ? "Off: baud can't tell you a message came" : "On") {
				if off, let url = Notifier.settings { Link("Turn on", destination: url).buttonStyle(Quiet(strong: true)) }
			}
			#if os(iOS)
			SettingRow(symbol: "arrow.clockwise", title: "Background App Refresh", detail: noRefresh ? "Off: messages wait until you open baud" : "On") {
				if noRefresh, let url = URL(string: UIApplication.openSettingsURLString) { Link("Turn on", destination: url).buttonStyle(Quiet(strong: true)) }
			}
			#endif
		}
		.task { await check() }
		.onChange(of: phase) { _, p in if p == .active { Task { await check() } } }
	}
	private func check() async {
		off = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
		#if os(iOS)
		noRefresh = UIApplication.shared.backgroundRefreshStatus != .available
		#endif
	}
}

// MARK: calls

/// The microphone and the camera: whether baud may use them, and the way to the switch when not.
struct CallsCard: View {
	@Environment(\.openURL) private var openURL
	@Environment(\.scenePhase) private var phase
	@State private var tick = 0
	var body: some View {
		let _ = tick
		ListCard(footer: "baud uses them only during a call you place or answer.") {
			row(.audio, symbol: "mic", title: "Microphone")
			row(.video, symbol: "video", title: "Camera")
		}
		.onChange(of: phase) { _, _ in tick &+= 1 }
	}
	private func row(_ media: AVMediaType, symbol: String, title: String) -> some View {
		let status = AVCaptureDevice.authorizationStatus(for: media)
		let words: String = switch status {
		case .authorized: "Allowed"
		case .notDetermined: "Asked on your first call"
		default: "Not allowed"
		}
		return SettingRow(symbol: symbol, title: title, detail: words) {
			if status == .denied || status == .restricted { Button("Open Settings") { open(media) }.buttonStyle(Quiet(strong: true)) }
		}
	}
	private func open(_ media: AVMediaType) {
		#if os(iOS)
		if let u = URL(string: UIApplication.openSettingsURLString) { openURL(u) }
		#else
		if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(media == .audio ? "Privacy_Microphone" : "Privacy_Camera")") { openURL(u) }
		#endif
	}
}

// MARK: updates

/// This version, where the next one stands, and whether baud takes it by itself.
struct UpdatesCard: View {
	@Environment(\.tones) private var tones
	#if os(macOS)
	@Environment(Updates.self) private var updates
	#endif
	var body: some View {
		let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
		VStack(alignment: .leading, spacing: Space.section) {
			ListCard {
				HStack(spacing: Rows.gap) {
					BaudTile(side: Rows.personFace).frame(width: Rows.personFace)
					VStack(alignment: .leading, spacing: 2) {
						Text("baud \(v)").font(Theme.font.weight(.medium))
						#if os(macOS)
						Text(updates.word).font(Theme.smallFont).foregroundStyle(tones.secondary).monospacedDigit()
						#else
						Text("From TestFlight").font(Theme.smallFont).foregroundStyle(tones.secondary)
						#endif
					}
					Spacer(minLength: 8)
					#if os(macOS)
					switch updates.state {
					case .available: Button("Update") { updates.install() }.buttonStyle(Quiet(strong: true))
					case .downloading: Button("Updating…") {}.buttonStyle(Quiet()).disabled(true)
					case .ready: Button("Restart") { updates.restart() }.buttonStyle(Quiet(strong: true))
					default: Button("Check") { updates.check(quiet: false) }.buttonStyle(Quiet()).disabled(updates.state == .checking)
					}
					#endif
				}
				.frame(minHeight: Rows.person)
				.cardRow()
			}
			#if os(macOS)
			ListCard(footer: "When there's a new baud, it's downloaded, checked against baud's signature and put in place by itself. Nothing restarts until you say so.") {
				HStack(spacing: Rows.gap) {
					Image(systemName: "arrow.down.circle").font(Icon.font(Icon.row)).foregroundStyle(tones.secondary).frame(width: Rows.personFace)
					Text("Download and install updates automatically").font(Theme.font.weight(.medium))
					Spacer(minLength: 8)
					Toggle("Download and install updates automatically", isOn: Binding(get: { updates.auto }, set: { updates.auto = $0 })).toggleStyle(.switch).labelsHidden()
				}
				.frame(minHeight: Rows.line)
				.cardRow()
			}
			#endif
		}
	}
}

#if os(macOS)
/// A Mac that's on carries messages for your phone and your friends: open at login.
struct AtLoginCard: View {
	@Environment(\.tones) private var tones
	@State private var atLogin = SMAppService.mainApp.status == .enabled
	var body: some View {
		ListCard(footer: "A Mac that's on carries messages for your phone and your friends while they're away.") {
			HStack(spacing: Rows.gap) {
				Image(systemName: "power").font(Icon.font(Icon.row)).foregroundStyle(tones.secondary).frame(width: Rows.personFace)
				Text("Open at login").font(Theme.font.weight(.medium))
				Spacer(minLength: 8)
				Toggle("Open at login", isOn: $atLogin).toggleStyle(.switch).labelsHidden()
			}
			.frame(minHeight: Rows.line)
			.cardRow()
		}
		.onChange(of: atLogin) { _, on in LoginItem.set(on); atLogin = SMAppService.mainApp.status == .enabled }
	}
}
#endif

// MARK: data

/// What baud keeps on this device, and last, on its own, starting over.
struct DataCard: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	@State private var size: Int64?
	var body: some View {
		VStack(alignment: .leading, spacing: Space.section * 2) {
			ListCard(footer: "Your chats, photos and files, and what this \(AppModel.thisKind) carries for others while they're away.") {
				SettingRow(symbol: "internaldrive", title: "Stored on this \(AppModel.thisKind)") {
					Text(size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…").font(Theme.font).foregroundStyle(tones.secondary).monospacedDigit()
				}
			}
			StartOver()
		}
		.task { size = await model.storeSize() }
	}
}

// MARK: me

/// Me: my face (with its camera), my name (a tap renames), and the colour the whole app wears.
struct MeCard: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	@State private var name = ""
	@State private var picking = false
	@State private var photo: PhotosPickerItem?
	@State private var renaming = false
	/// Any colour: the hue and lightness strips, open under the swatches.
	#if DEBUG
	@State private var custom = ProcessInfo.processInfo.environment["BAUD_COLOUR_OPEN"] == "1"
	#else
	@State private var custom = false
	#endif
	@FocusState private var editing: Bool
	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			HStack(spacing: 16) {
				ZStack(alignment: .bottomTrailing) {
					Avatar(name: model.me.name, hash: model.me.avatar, size: Settings.face)
					PhotoButton(picking: $picking, photo: $photo).offset(x: 4, y: 4)
				}
				// The name is the name until it is tapped; then it's a field (⏎ keeps it).
				Group {
					if renaming {
						TextField("", text: $name, prompt: Text("Your name").foregroundStyle(tones.secondary)).textFieldStyle(.plain).font(Theme.displayFont)
							.focused($editing)
							.onSubmit { if !name.isEmpty { model.setName(name) }; renaming = false }
							.onAppear { editing = true }
					} else {
						Button { name = model.me.name; renaming = true } label: { Text(model.me.name).font(Theme.displayFont).lineLimit(1).minimumScaleFactor(0.6) }
							.buttonStyle(.plain).accessibilityHint("Rename")
					}
				}
			}
			Swatches(custom: $custom)
			if custom { ColourStrips().transition(.opacity) }
		}
		.padding(Space.side)
		.frame(maxWidth: .infinity, alignment: .leading)
		.glass(corner: Radius.card)
		.animation(Motion.standard, value: custom)
		.onChange(of: editing) { _, e in if !e, renaming { if name != model.me.name, !name.isEmpty { model.setName(name) }; renaming = false } }
		.onChange(of: photo) { _, item in Task { await model.setPhoto(item) } }
		.fileImporter(isPresented: $picking, allowedContentTypes: [.image]) { r in if case .success(let url) = r { _ = url.startAccessingSecurityScopedResource(); model.attempt { try model.core.setAvatar(url) }; model.refreshAll() } }
	}
}

/// Photos on the phone, a file on the Mac: a small camera on the face.
struct PhotoButton: View {
	@Environment(\.tones) private var tones
	@Binding var picking: Bool
	@Binding var photo: PhotosPickerItem?
	var body: some View {
		let glyph = Image(systemName: "camera.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(tones.text)
			.frame(width: 26, height: 26).background(Circle().fill(tones.raised)).overlay(Circle().strokeBorder(tones.hairline))
		#if os(iOS)
		PhotosPicker(selection: $photo, matching: .images) { glyph }.accessibilityLabel("Photo")
		#else
		Button { picking = true } label: { glyph }.buttonStyle(.plain).help("Photo").accessibilityLabel("Photo")
		#endif
	}
}

/// The colour: no colour (white, or black), eight swatches, and any colour (the strips, here).
struct Swatches: View {
	@Environment(\.tones) private var tones
	@Environment(AppModel.self) private var model
	@Binding var custom: Bool
	var body: some View {
		#if os(macOS)
		HStack(spacing: 8) { prefix; suffix }
		#else
		LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), alignment: .leading, spacing: 8) { prefix; suffix }
		#endif
	}
	@ViewBuilder private var prefix: some View {
		swatch(nil, fill: AnyShapeStyle(Color.white), name: "White")
		swatch(Accent.black, fill: AnyShapeStyle(Color.black), name: "Black")
		ForEach(Accent.swatches.prefix(4), id: \.hex) { s in swatch(s.hex, fill: AnyShapeStyle(Accent.color(s.hex)!), name: s.name) }
	}
	@ViewBuilder private var suffix: some View {
		ForEach(Accent.swatches.suffix(4), id: \.hex) { s in swatch(s.hex, fill: AnyShapeStyle(Accent.color(s.hex)!), name: s.name) }
		// Any colour: the rainbow opens the strips under the row (no sheet, no panel over the app).
		let mine = model.accentHex != nil && model.accentHex != Accent.black && !Accent.swatches.contains { $0.hex == model.accentHex }
		Button { custom.toggle() } label: {
			Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center)).frame(width: 26, height: 26)
				.overlay(Circle().strokeBorder(tones.hairline))
				.overlay(Circle().stroke(tones.text, lineWidth: mine || custom ? 2 : 0).padding(-4))
				.frame(width: 36, height: 36).contentShape(Circle())
		}
		.buttonStyle(.plain).accessibilityLabel("Any colour").accessibilityAddTraits(custom ? .isSelected : [])
	}
	private func swatch(_ hex: String?, fill: AnyShapeStyle, name: String) -> some View {
		Button { model.accentHex = hex; custom = false } label: {
			Circle().fill(fill).frame(width: 26, height: 26)
				.overlay(Circle().strokeBorder(tones.hairline))
				.overlay(Circle().stroke(tones.text, lineWidth: model.accentHex == hex && !custom ? 2 : 0).padding(-4))
				.frame(width: 36, height: 36).contentShape(Circle())
		}.buttonStyle(.plain).accessibilityLabel(name).accessibilityAddTraits(model.accentHex == hex ? .isSelected : [])
	}
}

/// Any colour, in place: a hue strip and a lightness strip. The app wears the colour as the finger
/// moves; it's kept (and goes to my other devices, and to the icon) when the finger lifts.
struct ColourStrips: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	@State private var hue: Double = 0.6
	@State private var light: Double = 0.62
	@State private var started = false
	static let chroma = 0.17
	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			strip("Hue", value: $hue, colours: (0...12).map { OKLCH.color(l: 0.68, c: Self.chroma, h: Double($0) / 12 * 2 * .pi) })
			strip("Lightness", value: $light, colours: (0...6).map { OKLCH.color(l: 0.3 + Double($0) / 6 * 0.6, c: Self.chroma, h: hue * 2 * .pi) })
		}
		.onAppear {
			guard !started else { return }
			started = true
			if let hex = model.accentHex, let lch = OKLCH.parse(hex), lch.c > 0.03 {
				hue = (lch.h < 0 ? lch.h + 2 * .pi : lch.h) / (2 * .pi)
				light = min(1, max(0, (lch.l - 0.3) / 0.6))
			}
		}
	}
	private var hex: String { Accent.hex(OKLCH.color(l: 0.3 + light * 0.6, c: Self.chroma, h: hue * 2 * .pi)) }

	private func strip(_ title: String, value: Binding<Double>, colours: [Color]) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			Text(title).font(Theme.smallFont.weight(.semibold)).foregroundStyle(tones.secondary)
			GeometryReader { g in
				let w = g.size.width
				ZStack(alignment: .leading) {
					Capsule().fill(LinearGradient(colors: colours, startPoint: .leading, endPoint: .trailing))
						.overlay(Capsule().strokeBorder(tones.hairline))
					Circle().fill(OKLCH.color(l: 0.3 + light * 0.6, c: Self.chroma, h: hue * 2 * .pi))
						.overlay(Circle().strokeBorder(Color.white, lineWidth: 2.5))
						.shadow(color: tones.shade, radius: 3, y: 1)
						.frame(width: 26, height: 26)
						.offset(x: max(0, min(w - 26, value.wrappedValue * w - 13)))
				}
				.contentShape(Rectangle())
				.gesture(DragGesture(minimumDistance: 0)
					.onChanged { d in value.wrappedValue = min(1, max(0, d.location.x / w)); model.previewHex = hex }
					.onEnded { _ in model.accentHex = hex; model.previewHex = nil })
			}
			.frame(height: 28)
			.accessibilityElement()
			.accessibilityLabel(title)
			.accessibilityValue("\(Int(value.wrappedValue * 100)) percent")
			.accessibilityAdjustableAction { dir in
				value.wrappedValue = min(1, max(0, value.wrappedValue + (dir == .increment ? 0.05 : -0.05)))
				model.accentHex = hex
			}
		}
	}
}

// MARK: devices

/// My devices: each a row (a click opens it), and last, on its own, adding one, which asks first:
/// a device added is me, with all my chats, my friends and my identity.
struct DevicesSection: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	@Environment(\.dismiss) private var dismiss
	@State private var open: DeviceId?
	@State private var removing: Device?
	@State private var asking = false
	/// The Add screen in device mode. On the iPhone You is a sheet: it steps aside first.
	private func addDevice() {
		#if os(iOS)
		model.afterYou = .device; dismiss()
		#else
		model.offer = .device
		#endif
	}
	var body: some View {
		ListCard(title: "Your devices", footer: "This \(AppModel.thisKind) is called \(AppModel.deviceName).") {
			ForEach(model.me.devices) { d in
				let this = d.id == model.me.thisDevice
				Button { open = d.id } label: { DeviceRow(d: d, this: this) }
					.buttonStyle(RowStyle())
					.modifier(ThingCard(shown: Binding(get: { open == d.id }, set: { if !$0 { open = nil } })) { DeviceCard(d: d, this: this) })
					.contextMenu {
						Button { open = d.id } label: { Label("Show", systemImage: "info.circle") }
						if !this { Divider(); Button(role: .destructive) { removing = d } label: { Label("Remove…", systemImage: "minus.circle") } }
					}
			}
			Button { asking = true } label: { ActionRow(symbol: "plus", title: "Add a device") }.buttonStyle(RowStyle())
		}
		.confirmationDialog("Add a device that's yours?", isPresented: $asking, titleVisibility: .visible) {
			Button("Add my device") { addDevice() }
			Button("Cancel", role: .cancel) {}
		} message: { Text("It gets all your chats, your friends and your identity. Never add someone else's device.") }
		.confirmationDialog("Remove \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
			Button("Remove", role: .destructive) { if let d = removing { model.attempt { try model.core.revoke(d.id) }; model.refreshAll() }; removing = nil }
			Button("Cancel", role: .cancel) { removing = nil }
		} message: { Text("It stops getting your chats and friends. You can add it again later.") }
	}
}

/// The light and at most two words: "Online", "Away 2 h", "Reaching…".
struct StatusWord: View {
	@Environment(\.tones) private var tones
	let on: Bool
	let word: String
	var body: some View {
		HStack(spacing: 4) {
			Light(on: on, size: 6)
			Text(word).font(Theme.smallFont).foregroundStyle(tones.secondary).lineLimit(1).minimumScaleFactor(0.6)
		}
	}
}

/// A card a thing opens: a popover beside it on the Mac, a sheet on the iPhone.
struct ThingCard<C: View>: ViewModifier {
	@Environment(\.tones) private var tones
	@Binding var shown: Bool
	@ViewBuilder var card: C
	func body(content: Content) -> some View {
		#if os(macOS)
		content.popover(isPresented: $shown, arrowEdge: .bottom) { card.padding(18).frame(width: 300, alignment: .leading).background(tones.surface) }
		#else
		content.sheet(isPresented: $shown) { card.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).presentationDetents([.medium]).presentationBackground(tones.surface).presentationDragIndicator(.visible) }
		#endif
	}
}

/// A device, opened: its tile, its name, how it is reached; remove it, or start over if it is this one.
struct DeviceCard: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	let d: Device
	let this: Bool
	@State private var confirm = false
	var body: some View {
		VStack(spacing: 14) {
			DeviceGlyph(shape: DeviceShape(d), lit: this || d.online, size: 96)
			Text(d.name).font(Theme.titleFont).lineLimit(1)
			StatusWord(on: this || d.online, word: this ? "This one" : d.word.capitalizedFirst)
			HStack(spacing: 5) {
				MarkView(mark: .stable, size: 14, color: model.stable(d.id) ? tones.text : tones.tertiary)
				Text(model.stable(d.id) ? "Reachable" : "Not reachable from outside").font(Theme.smallFont).foregroundStyle(tones.secondary)
			}
			if !this {
				Button("Remove", role: .destructive) { confirm = true }.buttonStyle(Quiet(danger: true))
					.confirmationDialog("Remove \(d.name)?", isPresented: $confirm, titleVisibility: .visible) {
						Button("Remove", role: .destructive) { model.attempt { try model.core.revoke(d.id) }; model.refreshAll() }
						Button("Cancel", role: .cancel) {}
					} message: { Text("It stops getting your chats and friends. You can add it again later.") }
			}
		}
		.frame(maxWidth: .infinity)
	}
}

// MARK: the app

/// baud's icon, small: the family tile, or the whole tile in the chosen colour (as the app icon is).
struct BaudTile: View {
	@Environment(\.tones) private var tones
	var side: CGFloat = 44
	var body: some View {
		let t = tones.iconTile
		RoundedRectangle(cornerRadius: side * 0.23, style: .continuous)
			.fill(LinearGradient(colors: t.fill, startPoint: .top, endPoint: .bottom))
			.overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
			.overlay(MarkView(mark: .direct, size: side * 0.64, color: t.mark))
			.frame(width: side, height: side)
			.accessibilityHidden(true)
	}
}

/// Start over on this device: keys, store, friends here, everything. Last, on its own, in red, its
/// sentence in plain sight, and it asks first.
struct StartOver: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	@Environment(\.restart) private var restart
	@State private var asking = false
	var body: some View {
		VStack(alignment: .leading, spacing: Space.title) {
			SectionTitle("Start over")
			VStack(alignment: .leading, spacing: 12) {
				Text("Erase this \(AppModel.thisKind): its chats, friends and keys go for good. Your other devices keep theirs.")
					.font(Theme.font).foregroundStyle(tones.secondary).fixedSize(horizontal: false, vertical: true)
				Button("Start over…") { asking = true }.buttonStyle(Quiet(danger: true))
			}
			.padding(Space.side)
			.frame(maxWidth: .infinity, alignment: .leading)
			.glass(corner: Radius.card)
		}
		.confirmationDialog("Erase this \(AppModel.thisKind)?", isPresented: $asking, titleVisibility: .visible) {
			Button("Erase", role: .destructive) { Task { await model.wipe(); restart() } }
			Button("Cancel", role: .cancel) {}
		} message: { Text("Its chats, friends and keys go for good. Your other devices keep theirs.") }
	}
}

/// The app makes a fresh model after starting over, as on first run.
private struct RestartKey: EnvironmentKey { static let defaultValue: @MainActor @Sendable () -> Void = {} }
/// This device was removed by another of mine: the picture, two words, Start over.
struct RemovedView: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	@Environment(\.restart) private var restart
	var body: some View {
		VStack(spacing: 16) {
			DeviceGlyph(shape: AppModel.deviceKind == .iphone ? .iphone : .macbook, lit: false, size: 72)
			Text("Removed").font(Theme.titleFont)
			Button("Start over") { Task { await model.wipe(); restart() } }.buttonStyle(Quiet(strong: true)).keyboardShortcut(.defaultAction)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background(tones.surface.ignoresSafeArea())
	}
}

extension EnvironmentValues { var restart: @MainActor @Sendable () -> Void { get { self[RestartKey.self] } set { self[RestartKey.self] = newValue } } }

extension String {
	/// "away 2 h" → "Away 2 h".
	var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
