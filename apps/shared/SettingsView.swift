/// You: me (face, name, colour), my devices, my friends, the network, the app, and starting over.
/// A picture, a name and a button per thing; no sentences. The same page is the Mac's Settings
/// window and the iPhone's You tab.
import BaudCore
import PhotosUI
import SwiftUI
import UserNotifications
#if os(macOS)
import ServiceManagement
#else
import UIKit
#endif

struct SettingsView: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	#if os(macOS)
	@Environment(Updates.self) private var updates
	#endif

	var body: some View {
		ScrollViewReader { proxy in
			ScrollView {
				SettingsPage().onDisappear { model.settleIcon() }
			}
			.onAppear { if let s = model.settingsSection { proxy.scrollTo(s, anchor: .top); model.settingsSection = nil } }
			.onChange(of: model.settingsSection) { _, s in if let s { withAnimation { proxy.scrollTo(s, anchor: .top) }; model.settingsSection = nil } }
		}
		.background(tones.surface.ignoresSafeArea())
		#if os(macOS)
		.background(WindowTint(color: tones.surface, dark: tones.chromeDark))
		.onAppear { updates.check(quiet: true) }
		#endif
	}
}

/// Everything You shows, top to bottom; the window scrolls it, the pictures render it whole.
struct SettingsPage: View {
	var body: some View {
		VStack(alignment: .leading, spacing: Settings.gap) {
			MeCard().id("you")
			NotifyCard()
			DevicesSection().id("devices")
			FriendsSection().id("friends")
			NetworkSection().id("network")
			AppCard().id("app")
			StartOver()
		}
		.padding(.horizontal, Settings.side).padding(.top, Settings.top).padding(.bottom, 40)
		.frame(maxWidth: 720, alignment: .leading)
		.frame(maxWidth: .infinity)
	}
}

enum Settings {
	#if os(macOS)
	static let side: CGFloat = 24, top: CGFloat = 8, gap: CGFloat = 24, hero: CGFloat = 56
	#else
	static let side: CGFloat = 16, top: CGFloat = 8, gap: CGFloat = 24, hero: CGFloat = 52
	#endif
}

/// A titled card: the section's name at the one heading size, its things on a raised card, padded 16.
struct Card<Content: View>: View {
	@Environment(\.tones) private var tones
	let title: String
	@ViewBuilder var content: Content
	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(title).font(Theme.headingFont).foregroundStyle(tones.heading).accessibilityAddTraits(.isHeader)
			VStack(alignment: .leading, spacing: 0) { content }
				.padding(16)
				.frame(maxWidth: .infinity, alignment: .leading)
				.glass(corner: 18)
		}
	}
}

// MARK: notifications

/// What keeps baud from saying a message came: shown only then, a line and a button each.
struct NotifyCard: View {
	@Environment(\.tones) private var tones
	@Environment(\.scenePhase) private var phase
	@State private var off = false
	@State private var noRefresh = false
	var body: some View {
		Group {
			if off || noRefresh {
				Card(title: "Notifications") {
					VStack(alignment: .leading, spacing: 12) {
						if off { row("bell.slash", "Notifications are off", Notifier.settings) }
						#if os(iOS)
						if noRefresh { row("arrow.clockwise", "Background App Refresh is off", URL(string: UIApplication.openSettingsURLString)) }
						#endif
					}
				}
			}
		}
		.task { await check() }
		.onChange(of: phase) { _, p in if p == .active { Task { await check() } } }
	}
	private func row(_ symbol: String, _ text: String, _ url: URL?) -> some View {
		HStack(spacing: 10) {
			Image(systemName: symbol).foregroundStyle(tones.secondary).frame(width: 20)
			Text(text).font(Theme.font)
			Spacer(minLength: 8)
			if let url { Link("Turn on", destination: url).buttonStyle(Quiet(strong: true)) }
		}
	}
	private func check() async {
		off = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
		#if os(iOS)
		noRefresh = UIApplication.shared.backgroundRefreshStatus != .available
		#endif
	}
}

// MARK: me

struct MeCard: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	@State private var name = ""
	@State private var picking = false
	@State private var photo: PhotosPickerItem?
	@State private var renaming = false
	@FocusState private var editing: Bool
	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			HStack(spacing: 14) {
				ZStack(alignment: .bottomTrailing) {
					Avatar(name: model.me.name, hash: model.me.avatar, size: 64)
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
			Swatches()
		}
		.padding(16)
		.frame(maxWidth: .infinity, alignment: .leading)
		.glass(corner: 18)
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

/// The colour: no colour, eight swatches, any colour. The whole app is downstream of it.
struct Swatches: View {
	@Environment(\.rendering) private var rendering
	@Environment(\.tones) private var tones
	@Environment(AppModel.self) private var model
	var body: some View {
		ViewThatFits(in: .horizontal) {
			HStack(spacing: 10) { dots }
			VStack(alignment: .leading, spacing: 10) {
				HStack(spacing: 10) { dots.prefix }
				HStack(spacing: 10) { dots.suffix }
			}
		}
	}
	private var dots: Dots { Dots(model: model, tones: tones, rendering: rendering) }
	struct Dots: View {
		let model: AppModel
		let tones: Tones
		let rendering: Bool
		var body: some View { prefix; suffix }
		@ViewBuilder var prefix: some View {
			// No colour: white (the plain ramp, light or dark as the system is) or black (black in both).
			swatch(nil, fill: AnyShapeStyle(Color.white), name: "White")
			swatch(Accent.black, fill: AnyShapeStyle(Color.black), name: "Black")
			ForEach(Accent.swatches.prefix(4), id: \.hex) { s in swatch(s.hex, fill: AnyShapeStyle(Accent.color(s.hex)!), name: s.name) }
		}
		@ViewBuilder var suffix: some View {
			ForEach(Accent.swatches.suffix(4), id: \.hex) { s in swatch(s.hex, fill: AnyShapeStyle(Accent.color(s.hex)!), name: s.name) }
			// Any colour: a rainbow circle the size of the others. On the iPhone the system picker
			// opens on tap but never draws its own well (it sits, all but invisible, over the
			// circle); on the Mac that well took no clicks (Dexter: "the color picker doesn't
			// click"), so the circle is a button that opens the colour panel.
			let custom = model.accentHex != nil && model.accentHex != Accent.black && !Accent.swatches.contains { $0.hex == model.accentHex }
			let rainbow = Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center)).frame(width: 26, height: 26)
				.overlay(Circle().strokeBorder(tones.hairline))
				.overlay(Circle().stroke(tones.text, lineWidth: custom ? 2 : 0).padding(-4))
			#if os(macOS)
			Button { ColourPanel.shared.open(model.chosen) { model.accentHex = $0 } } label: {
				rainbow.frame(width: 36, height: 36).contentShape(Circle())
			}
			.buttonStyle(.plain).accessibilityLabel("Any colour")
			#else
			ZStack {
				rainbow
				if !rendering {
					ColorPicker("", selection: Binding(get: { model.accent }, set: { model.accentHex = Accent.hex($0) }), supportsOpacity: false).labelsHidden()
						.frame(width: 36, height: 36).opacity(0.02).clipShape(Circle())
				}
			}
			.frame(width: 36, height: 36).accessibilityLabel("Any colour")
			#endif
		}
		private func swatch(_ hex: String?, fill: AnyShapeStyle, name: String) -> some View {
			Button { model.accentHex = hex } label: {
				Circle().fill(fill).frame(width: 26, height: 26)
					.overlay(Circle().strokeBorder(tones.hairline))
					.overlay(Circle().stroke(tones.text, lineWidth: model.accentHex == hex ? 2 : 0).padding(-4))
					.frame(width: 36, height: 36).contentShape(Circle())
			}.buttonStyle(.plain).accessibilityLabel(name).accessibilityAddTraits(model.accentHex == hex ? .isSelected : [])
		}
	}
}

// MARK: devices

struct DevicesSection: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	@Environment(\.dismiss) private var dismiss
	@State private var open: DeviceId?
	/// The Add screen in device mode. On the iPhone You is a sheet: it steps aside first.
	private func addDevice() {
		#if os(iOS)
		model.afterYou = .device; dismiss()
		#else
		model.offer = .device
		#endif
	}
	var body: some View {
		Card(title: "Devices") {
			LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], alignment: .leading, spacing: 8) {
				ForEach(model.me.devices) { d in
					let this = d.id == model.me.thisDevice
					Button { open = d.id } label: { DeviceTile(d: d, this: this) }
						.buttonStyle(TileStyle(on: open == d.id, bare: true))
						.modifier(ThingCard(shown: Binding(get: { open == d.id }, set: { if !$0 { open = nil } })) { DeviceCard(d: d, this: this) })
				}
				Button { addDevice() } label: {
					VStack(spacing: 6) {
						Image(systemName: "plus").font(.system(size: 16, weight: .semibold)).frame(width: Settings.hero, height: Settings.hero)
							.overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tones.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
						Text("Add").font(Theme.smallFont.weight(.semibold))
					}.padding(8).frame(maxWidth: .infinity)
				}.buttonStyle(TileStyle(empty: true, bare: true)).accessibilityLabel("Add a device")
			}
		}
	}
}

/// One of my devices: its tile (with the house when it is reachable from outside), its name, the light and a word.
struct DeviceTile: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	let d: Device
	let this: Bool
	var body: some View {
		VStack(spacing: 6) {
			DeviceGlyph(shape: DeviceShape(d), lit: this || d.online, size: Settings.hero)
				.overlay(alignment: .topTrailing) { if model.stable(d.id) { MarkView(mark: .stable, size: 14, color: tones.strong).background(Circle().fill(tones.raised).padding(-1.5)) } }
			Text(this ? Names.device(AppModel.deviceName) : Names.device(d.name)).font(Theme.smallFont.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.6)
			StatusWord(on: this || d.online, word: this ? "This one" : d.word)
		}
		.padding(8).frame(maxWidth: .infinity)
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
					}
			}
		}
		.frame(maxWidth: .infinity)
	}
}

// MARK: friends

struct FriendsSection: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	@Environment(\.dismiss) private var dismiss
	@State private var open: UserId?
	private func addFriend() {
		#if os(iOS)
		model.afterYou = .friend; dismiss()
		#else
		model.offer = .friend
		#endif
	}
	var body: some View {
		Card(title: "Friends") {
			ForEach(model.contacts) { k in
				Button { open = k.user } label: {
					HStack(spacing: 10) {
						Avatar(name: k.name, hash: k.avatar, size: 32)
						Text(k.name).font(Theme.font.weight(.medium)).lineLimit(1)
						if k.verified { MarkView(mark: .verified, size: 14, color: tones.secondary) }
						Spacer(minLength: 8)
						StatusWord(on: k.online, word: presenceWord(k.devices).capitalizedFirst)
					}.frame(minHeight: 44)
				}
				.buttonStyle(RowStyle()).padding(.horizontal, -Rows.inset - Rows.pad)
				.modifier(ThingCard(shown: Binding(get: { open == k.user }, set: { if !$0 { open = nil } })) { FriendCard(k: k) })
			}
			Button { addFriend() } label: { Label("Add", systemImage: "plus").font(Theme.font.weight(.semibold)).frame(minHeight: 44) }
				.buttonStyle(RowStyle()).padding(.horizontal, -Rows.inset - Rows.pad).accessibilityLabel("Add a friend")
		}
	}
}

/// A friend, opened: face, name, their devices, Message and Verify.
struct FriendCard: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	let k: Contact
	@State private var verifying = false
	@State private var confirm = false
	var body: some View {
		VStack(spacing: 14) {
			Avatar(name: k.name, hash: k.avatar, size: 72)
			HStack(spacing: 6) {
				Text(k.name).font(Theme.titleFont)
				MarkView(mark: k.verified ? .verified : k.vouched ? .vouched : .unverified, size: 16, color: k.verified ? tones.text : tones.secondary)
			}
			HStack(spacing: 14) {
				ForEach(k.devices) { d in
					VStack(spacing: 4) { DeviceGlyph(shape: DeviceShape(d), lit: d.online, size: 40); StatusWord(on: d.online, word: d.word.capitalizedFirst) }
				}
			}
			HStack(spacing: 8) {
				Button("Message") { model.message(k.user) }.buttonStyle(Quiet(strong: true))
				if !k.verified { Button("Verify") { verifying = true }.buttonStyle(Quiet()) }
				Button("Remove friend", role: .destructive) { confirm = true }.buttonStyle(Quiet(danger: true))
					.confirmationDialog("Remove \(k.name)?", isPresented: $confirm, titleVisibility: .visible) {
						Button("Remove", role: .destructive) { model.unfriend(k.user) }
					}
			}
		}
		.frame(maxWidth: .infinity)
		.sheet(isPresented: $verifying) { VerifySheet(contact: k) }
	}
}

// MARK: the network

struct NetworkSection: View {
	var body: some View {
		Card(title: "Network") { NetworkPicture() }
	}
}

// MARK: the app

struct AppCard: View {
	@Environment(\.tones) private var tones
	#if os(macOS)
	@Environment(Updates.self) private var updates
	@State private var atLogin = SMAppService.mainApp.status == .enabled
	#endif
	var body: some View {
		let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
		VStack(alignment: .leading, spacing: 14) {
		HStack(spacing: 12) {
			BaudTile()
			VStack(alignment: .leading, spacing: 2) {
				Text("baud \(v)").font(Theme.font.weight(.semibold))
				#if os(macOS)
				Text(updates.word).font(Theme.smallFont).foregroundStyle(tones.secondary).monospacedDigit()
				#else
				Text("TestFlight").font(Theme.smallFont).foregroundStyle(tones.secondary)
				#endif
			}
			Spacer(minLength: 8)
			#if os(macOS)
			if case .available = updates.state { Button("Download") { updates.download() }.buttonStyle(Quiet(strong: true)) }
			else { Button("Check") { updates.check(quiet: false) }.buttonStyle(Quiet()).disabled(updates.state == .checking) }
			#endif
		}
		#if os(macOS)
		// A Mac that's on carries messages for your phone and your friends: open at login.
		HStack {
			Text("Open at login").font(Theme.font)
			Spacer(minLength: 8)
			Toggle("Open at login", isOn: $atLogin).toggleStyle(.switch).labelsHidden()
		}
		.onChange(of: atLogin) { _, on in LoginItem.set(on); atLogin = SMAppService.mainApp.status == .enabled }
		#endif
		}
		.padding(16)
		.glass(corner: 18)
	}
}

/// baud's icon, small: the family tile, or the whole tile in the chosen colour (as the app icon is).
struct BaudTile: View {
	@Environment(\.tones) private var tones
	var body: some View {
		let t = tones.iconTile
		RoundedRectangle(cornerRadius: 10, style: .continuous)
			.fill(LinearGradient(colors: t.fill, startPoint: .top, endPoint: .bottom))
			.overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
			.overlay(MarkView(mark: .direct, size: 28, color: t.mark))
			.frame(width: 44, height: 44)
			.accessibilityHidden(true)
	}
}

/// Start over on this device: keys, store, friends here, everything; a confirmation says so.
struct StartOver: View {
	@Environment(AppModel.self) private var model
	@Environment(\.restart) private var restart
	@State private var confirm = false
	var body: some View {
		Button("Start over", role: .destructive) { confirm = true }
			.buttonStyle(Quiet(danger: true))
			.frame(maxWidth: .infinity)
			.confirmationDialog("Erase this \(AppModel.thisKind)?", isPresented: $confirm, titleVisibility: .visible) {
				Button("Erase chats, friends and keys", role: .destructive) { Task { await model.wipe(); restart() } }
			}
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

#if os(macOS)
/// The Mac's colour panel for Any colour: a pick lands when the mouse lets go, not on every step
/// of a drag, so a drag across the wheel is one colour for my other devices, not hundreds.
@MainActor final class ColourPanel: NSObject {
	static let shared = ColourPanel()
	private var pick: ((String) -> Void)?
	func open(_ current: Color?, pick: @escaping (String) -> Void) {
		self.pick = pick
		let p = NSColorPanel.shared
		p.showsAlpha = false
		p.isContinuous = false
		if let current { p.color = NSColor(current) }
		p.setTarget(self)
		p.setAction(#selector(changed(_:)))
		p.orderFront(nil)
	}
	@objc private func changed(_ p: NSColorPanel) {
		let c = p.color.usingColorSpace(.sRGB) ?? .black
		pick?(String(format: "%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255)))
	}
}
#endif
