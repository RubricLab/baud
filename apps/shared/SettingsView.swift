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

/// Everything You shows, top to bottom, as titled cards of rows; the window scrolls it, the pictures
/// render it whole.
struct SettingsPage: View {
	var body: some View {
		VStack(alignment: .leading, spacing: Space.section) {
			MeCard().id("you")
			NotifyCard()
			DevicesSection().id("devices")
			FriendsSection().id("friends")
			NetworkSection().id("network")
			AppCard().id("app")
			StartOver()
		}
		.padding(.horizontal, Settings.side).padding(.top, Settings.top).padding(.bottom, 32)
		.frame(maxWidth: 720, alignment: .leading)
		.frame(maxWidth: .infinity)
	}
}

enum Settings {
	#if os(macOS)
	static let side: CGFloat = 24, top: CGFloat = 16, face: CGFloat = 64
	#else
	static let side: CGFloat = 16, top: CGFloat = 16, face: CGFloat = 72
	#endif
}

/// A titled card that holds a picture rather than rows (the network): padded all round.
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
				ListCard(title: "Notifications") {
					VStack(alignment: .leading, spacing: 0) {
						if off { row("bell.slash", "Notifications are off", Notifier.settings) }
						#if os(iOS)
						if noRefresh { row("arrow.clockwise", "Background App Refresh is off", URL(string: UIApplication.openSettingsURLString)) }
						#endif
					}
					.cardRow()
				}
			}
		}
		.task { await check() }
		.onChange(of: phase) { _, p in if p == .active { Task { await check() } } }
	}
	private func row(_ symbol: String, _ text: String, _ url: URL?) -> some View {
		HStack(spacing: Rows.gap) {
			Image(systemName: symbol).font(Icon.font(Icon.row)).foregroundStyle(tones.secondary).frame(width: Rows.personFace)
			Text(text).font(Theme.font.weight(.medium))
			Spacer(minLength: 8)
			if let url { Link("Turn on", destination: url).buttonStyle(Quiet(strong: true)) }
		}
		.frame(minHeight: Rows.line)
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
			Swatches()
		}
		.padding(Space.side)
		.frame(maxWidth: .infinity, alignment: .leading)
		.glass(corner: Radius.card)
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
	/// Here, not in Dots: on a narrow screen Dots is read for its two rows, never put on screen
	/// itself, and state of its own would go nowhere.
	@State private var picking = false
	var body: some View {
		#if os(macOS)
		HStack(spacing: 8) { dots }
		#else
		LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), alignment: .leading, spacing: 8) { dots.prefix; dots.suffix }
		#endif
	}
	private var dots: Dots { Dots(model: model, tones: tones, rendering: rendering, picking: $picking) }
	struct Dots: View {
		let model: AppModel
		let tones: Tones
		let rendering: Bool
		@Binding var picking: Bool
		var body: some View { prefix; suffix }
		@ViewBuilder var prefix: some View {
			// No colour: white (the plain ramp, light or dark as the system is) or black (black in both).
			swatch(nil, fill: AnyShapeStyle(Color.white), name: "White")
			swatch(Accent.black, fill: AnyShapeStyle(Color.black), name: "Black")
			ForEach(Accent.swatches.prefix(4), id: \.hex) { s in swatch(s.hex, fill: AnyShapeStyle(Accent.color(s.hex)!), name: s.name) }
		}
		@ViewBuilder var suffix: some View {
			ForEach(Accent.swatches.suffix(4), id: \.hex) { s in swatch(s.hex, fill: AnyShapeStyle(Accent.color(s.hex)!), name: s.name) }
			// Any colour: a rainbow circle the size of the others, a button that opens the system's
			// colour picker (a sheet on the iPhone, the colour panel on the Mac). The picker's own
			// well, hidden over the circle, took no clicks on the Mac and did nothing on the iPhone.
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
			Button { picking = true } label: { rainbow.frame(width: 36, height: 36).contentShape(Circle()) }
				.buttonStyle(.plain).accessibilityLabel("Any colour")
				.sheet(isPresented: $picking) {
					ColourSheet(start: model.chosen) { model.accentHex = $0 }
						.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
				}
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
	@State private var removing: Device?
	/// The Add screen in device mode. On the iPhone You is a sheet: it steps aside first.
	private func addDevice() {
		#if os(iOS)
		model.afterYou = .device; dismiss()
		#else
		model.offer = .device
		#endif
	}
	var body: some View {
		ListCard(title: "Devices") {
			Button { addDevice() } label: { ActionRow(symbol: "plus", title: "Add a device") }.buttonStyle(RowStyle())
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
		}
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

// MARK: friends

struct FriendsSection: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	@Environment(\.dismiss) private var dismiss
	@State private var open: UserId?
	@State private var removing: Contact?
	private func addFriend() {
		#if os(iOS)
		model.afterYou = .friend; dismiss()
		#else
		model.offer = .friend
		#endif
	}
	var body: some View {
		ListCard(title: "Friends") {
			Button { addFriend() } label: { ActionRow(symbol: "plus", title: "Add a friend") }.buttonStyle(RowStyle())
			ForEach(model.contacts) { k in
				let row = PersonRow(name: k.name, hash: k.avatar, presence: Mark.presence(k.devices), detail: presenceWord(k.devices).capitalizedFirst, verified: k.verified) {
					#if os(iOS)
					Image(systemName: "chevron.right").font(Icon.font(Icon.inline)).foregroundStyle(tones.tertiary)
					#endif
				}
				#if os(iOS)
				NavigationLink(value: PersonLink(user: k.user)) { row }.buttonStyle(RowStyle())
					.contextMenu { FriendMenu(friend: k, removing: $removing) }
				#else
				Button { open = k.user } label: { row }
					.buttonStyle(RowStyle())
					.popover(isPresented: Binding(get: { open == k.user }, set: { if !$0 { open = nil } }), arrowEdge: .trailing) { PersonPage(user: k.user).frame(width: 360, height: 560) }
					.contextMenu { FriendMenu(friend: k, removing: $removing) }
				#endif
			}
		}
		.modifier(RemoveFriendQuestion(removing: $removing))
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
		ListCard(title: "App") {
			HStack(spacing: Rows.gap) {
				BaudTile(side: Rows.personFace).frame(width: Rows.personFace)
				VStack(alignment: .leading, spacing: 2) {
					Text("baud \(v)").font(Theme.font.weight(.medium))
					#if os(macOS)
					Text(updates.word).font(Theme.smallFont).foregroundStyle(tones.secondary).monospacedDigit()
					#else
					Text("TestFlight").font(Theme.smallFont).foregroundStyle(tones.secondary)
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
			#if os(macOS)
			// A Mac that's on carries messages for your phone and your friends: open at login.
			HStack(spacing: Rows.gap) {
				Image(systemName: "power").font(Icon.font(Icon.row)).foregroundStyle(tones.secondary).frame(width: Rows.personFace)
				Text("Open at login").font(Theme.font.weight(.medium))
				Spacer(minLength: 8)
				Toggle("Open at login", isOn: $atLogin).toggleStyle(.switch).labelsHidden()
			}
			.frame(minHeight: Rows.line)
			.cardRow()
			.onChange(of: atLogin) { _, on in LoginItem.set(on); atLogin = SMAppService.mainApp.status == .enabled }
			#endif
		}
	}
}

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

/// Start over on this device: keys, store, friends here, everything. Last on the page, red, and
/// it asks first.
struct StartOver: View {
	@Environment(AppModel.self) private var model
	@Environment(\.restart) private var restart
	var body: some View {
		DangerCard(symbol: "arrow.counterclockwise", title: "Start over", question: "Erase this \(AppModel.thisKind)?",
			detail: "Its chats, friends and keys go for good. Your other devices keep theirs.", answer: "Erase") {
			Task { await model.wipe(); restart() }
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

#if os(iOS)
/// The iPhone's colour picker for Any colour: a pick lands when a finger lets go (a tap on the
/// grid, the end of a drag on the spectrum), not on every step, so the app re-colours once.
struct ColourSheet: UIViewControllerRepresentable {
	let start: Color?
	let pick: (String) -> Void
	func makeUIViewController(context: Context) -> UIColorPickerViewController {
		let c = UIColorPickerViewController()
		c.supportsAlpha = false
		c.title = "Any colour"
		if let start { c.selectedColor = UIColor(start) }
		c.delegate = context.coordinator
		return c
	}
	func updateUIViewController(_ c: UIColorPickerViewController, context: Context) {}
	func makeCoordinator() -> Coordinator { Coordinator(pick) }
	final class Coordinator: NSObject, UIColorPickerViewControllerDelegate {
		let pick: (String) -> Void
		init(_ pick: @escaping (String) -> Void) { self.pick = pick }
		func colorPickerViewController(_ c: UIColorPickerViewController, didSelect color: UIColor, continuously: Bool) {
			if !continuously { pick(Accent.hex(Color(uiColor: color))) }
		}
		func colorPickerViewControllerDidFinish(_ c: UIColorPickerViewController) { pick(Accent.hex(Color(uiColor: c.selectedColor))) }
	}
}
#endif

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
