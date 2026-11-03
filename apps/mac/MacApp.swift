/// The Mac: three panes. Left, the sidebar, Home or Spaces with a wall between them; middle, the
/// conversation (or, with nothing open, the side's overview); right, the people on ⌘I. ⌘K jumps
/// anywhere. Network and Settings are windows of their own, so the main window never changes shape.
import BaudCore
import SwiftUI

@main
struct BaudMacApp: App {
	@State private var model = AppModel()
	@State private var updates = Updates()
	@State private var palette = false
	@State private var sheet: NewSheet.What?
	@Environment(\.openWindow) private var openWindow

	/// baud carries and relays messages for the people it knows, and its window is often closed:
	/// App Nap would slow its timers and its reading of the network to a crawl. Idle sleep stays
	/// allowed; only the napping goes.
	private static let awake = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Carrying messages for your people")
	init() { _ = Self.awake; LoginItem.firstRun() }

	var body: some Scene {
		WindowGroup("baud") {
			let _ = Measure.log("window content")
			// The hue is applied above the root, so the root's own reads of the palette are the hue's.
			Root(palette: $palette, sheet: $sheet)
				.modifier(Tinted(hex: model.accentHex))
				.environment(model).environment(updates)
				.environment(\.restart, { model = AppModel() })
				.onOpenURL { model.open(url: $0) }
				.onAppear { model.scene(active: true); model.front = NSApp.isActive }
		}
		.defaultSize(width: 1080, height: 700)
		// No toolbar, no title bar: ⌘K lives in the Go menu, the content runs to the top edge and
		// the traffic lights sit over the sidebar's colour.
		.windowStyle(.hiddenTitleBar)
		// The main window always opens at launch: macOS restores the Settings window of a quit
		// session on its own and, left to itself, opened nothing else (seen on the real build).
		.commands {
			CommandGroup(after: .appInfo) { Button("Check for Updates…") { model.settingsSection = "app"; openWindow(id: "settings"); updates.check() } }
			CommandGroup(replacing: .newItem) {
				Button("New Chat") { sheet = .chat }.keyboardShortcut("n")
				Button("New Group") { sheet = .group }.keyboardShortcut("n", modifiers: [.command, .shift])
				Button("New Friend") { model.offer = .friend }.keyboardShortcut("n", modifiers: [.command, .option])
				if Features.spaces {
					Button("New Space") { sheet = .space }.keyboardShortcut("n", modifiers: [.command, .option, .control])
					Button("New Channel") { sheet = .channel }.keyboardShortcut("n", modifiers: [.command, .control]).disabled(model.selectedSpace == nil)
				}
			}
			CommandMenu("Go") {
				Button("Jump to…") { palette = true }.keyboardShortcut("k")
				Button("Search Messages") { model.focusSearch &+= 1 }.keyboardShortcut("f")
				if Features.spaces {
					Button("Home") { model.show(.home) }.keyboardShortcut("1")
					Button("Spaces") { model.show(.spaces) }.keyboardShortcut("2")
					Button("Back to All Spaces") { model.leaveSpace() }.keyboardShortcut("[").disabled(model.mode != .spaces || model.selectedSpace == nil)
				} else {
					// The first nine chats in the list, by their place in it, as Slack and Linear do.
					Menu("Chats") {
						ForEach(Array(model.chats.prefix(9).enumerated()), id: \.element.id) { i, c in
							Button(model.title(c)) { model.show(.home); model.open(c.id) }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
						}
					}
				}
				Button("Next Chat") { model.step(1) }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
				Button("Previous Chat") { model.step(-1) }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
				Button("Sidebar") { model.focusSidebar &+= 1 }.keyboardShortcut("0")
				Divider()
				Button("Friends") { model.settingsSection = "friends"; openWindow(id: "settings") }.keyboardShortcut("1", modifiers: [.command, .shift])
				Button("Network") { model.settingsSection = "network"; openWindow(id: "settings") }.keyboardShortcut("2", modifiers: [.command, .shift])
			}
			// What can be done with the open chat. Calls have no keys: a stray chord shouldn't ring anyone.
			CommandMenu("Chat") {
				let c = model.selectedConversation.flatMap(model.conversation)
				let callable = c.map { model.calls.callable($0.id) && model.calls.session == nil } ?? false
				Button(c.map { "Call \(model.title($0))" } ?? "Call") { if let c { model.calls.start(c.id, video: false) } }.disabled(!callable)
				Button(c.map { "Video Call \(model.title($0))" } ?? "Video Call") { if let c { model.calls.start(c.id, video: true) } }.disabled(!callable)
				Divider()
				Button(model.details ? "Hide Details" : "Show Details") { model.details.toggle() }.keyboardShortcut("i").disabled(c == nil)
				Button("Mark as Read") { if let c { model.markRead(c) } }.keyboardShortcut("u", modifiers: [.command, .shift]).disabled((c?.unread ?? 0) == 0)
				Divider()
				Button(c.map { $0.kind == .home ? "Clear Chat…" : $0.isDirect ? "Delete Chat…" : "Leave and Delete…" } ?? "Delete Chat…") { model.deleting = c }.keyboardShortcut(.delete, modifiers: .command).disabled(c == nil)
			}
		}
		Window("Settings", id: "settings") { SettingsView().toolbarBackground(.hidden, for: .windowToolbar).modifier(NotRestored()).modifier(Tinted(hex: model.accentHex)).environment(model).environment(updates).environment(\.restart, { model = AppModel() }).frame(minWidth: 520, minHeight: 520) }
			.defaultSize(width: 640, height: 800)
			.commands { CommandGroup(replacing: .appSettings) { Button("Settings…") { openWindow(id: "settings") }.keyboardShortcut(",") } }
		// Linking lives in windows of its own, so it survives whatever the main window does
		// (first run turning into the chat list) and can sit next to Settings.
		// Never restored at launch: a linking window left open at quit must not come back empty
		// in place of the main window (it did: SwiftUI restored it and opened nothing else).
		// One Add window for a friend, my own device, and any link I'm given.
		Window("Add", id: "add") { AddView().toolbarBackground(.hidden, for: .windowToolbar).modifier(NotRestored()).modifier(Tinted(hex: model.accentHex)).environment(model) }
			.windowResizability(.contentSize)
	}
}

/// Three panes drawn by hand: no split-view material, hairlines between them. Every pane runs to
/// the top edge; the traffic lights sit in the sidebar's band.
struct Panes: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	@Binding var sheet: NewSheet.What?
	@Binding var palette: Bool
	var body: some View {
		@SwiftUI.Bindable var m = model
		HStack(spacing: 0) {
			Sidebar(sheet: $sheet).frame(width: 264)
			Rectangle().fill(tones.hairline).frame(width: 1)
			if let id = model.selectedConversation, model.conversation(id) != nil {
				ConversationView(conv: id, showMembers: $m.details)
				if model.details {
					Rectangle().fill(tones.hairline).frame(width: 1)
					MembersView(conv: id, close: { model.details = false }).frame(width: 300).background(tones.raised)
				}
			} else if model.mode == .spaces, model.selectedSpace == nil {
				SpacesOverview(sheet: $sheet)
			} else {
				HomeOverview(sheet: $sheet, jump: { palette = true })
			}
		}
		.ignoresSafeArea(.container, edges: .top)
	}
}

struct Root: View {
	@Environment(AppModel.self) private var model
	@Environment(Updates.self) private var updates
	@Environment(\.tones) private var tones
	@Binding var palette: Bool
	@Binding var sheet: NewSheet.What?
	@Environment(\.openWindow) private var openWindow

	var body: some View {
		@SwiftUI.Bindable var m = model
		let _ = Measure.log("root body named=\(model.named) onboarded=\(model.onboarded) convs=\(model.conversations.count)")
		Group {
			if !model.named || (!model.onboarded && model.conversations.isEmpty) {
				OnboardingView()
			} else {
				Panes(sheet: $sheet, palette: $palette)
				.background(Ground())
				.overlay(alignment: .bottomTrailing) { WindowTint(color: tones.surface, dark: tones.chromeDark).frame(width: 1, height: 1).allowsHitTesting(false) }
				// Belt and braces: the moment any window (a sheet, a side window) becomes key, every window takes the surface.
				.onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in dressAll() }
				// Back from System Settings: Local Network may have been turned on (or off).
				.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in LocalNetwork.shared.probe(); model.front = true }
				.onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in model.front = false }
				.onChange(of: tones.surface) { _, _ in dressAll() }
				.onChange(of: tones.chromeDark) { _, _ in dressAll() }
				.onAppear { dressAll() }
				.frame(minWidth: 900, minHeight: 620)
			}
		}
		.overlay { if model.removedHere { RemovedView() } }
		.modifier(CallPresenter())
		.font(Theme.font)
		.modifier(DeleteChatQuestion())
		.onChange(of: model.unread, initial: true) { _, n in NSApp.dockTile.badgeLabel = n > 0 ? "\(n)" : nil }
		.sheet(isPresented: $palette) { Palette(shown: $palette, run: run) }
		.sheet(item: $sheet) { NewSheet(what: $0, space: model.selectedSpace) }
		.sheet(item: Binding(get: { model.addingTo.map(Adding.init) }, set: { if $0 == nil { model.addingTo = nil } })) { AddPeopleSheet(conv: $0.id) }
		.alert("baud", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") {} } message: { Text(model.error ?? "") }
		// A device asking to join shows inside the device window when one is up, else on its own.
		.sheet(item: Binding(get: { model.adding ? nil : model.linkAsk }, set: { if $0 == nil { model.linkAsk = nil } })) { AskBody(ask: $0).padding(24).frame(width: 400).background(tones.surface) }
		.onChange(of: model.adding, initial: true) { _, a in if a && model.named && model.onboarded { openWindow(id: "add") } }
		.onChange(of: model.reveal) { _, id in if let id { model.open(id); model.reveal = nil } }
		.task {
			Measure.opened()
			updates.check(quiet: true)
			// `BAUD_WINDOW=settings` opens that window on launch, for the smoke.
			if let w = ProcessInfo.processInfo.environment["BAUD_WINDOW"] { openWindow(id: w) }
			await Bench.runIfAsked(model)
			await Shots.runIfAsked(model) { what in
				switch what {
				case "members": model.details.toggle()
				case "palette": palette.toggle()
				case let w where w.hasPrefix("sheet:"): sheet = NewSheet.What(rawValue: String(w.dropFirst(6)))
				case let w where w.hasPrefix("marks:"):
					Shots.render(MarksSheet().modifier(Tinted(hex: model.accentHex)).environment(model).font(Theme.font), width: 760, background: tones.surface, to: String(w.dropFirst(6)))
				case let w where w.hasPrefix("page:"):
					Shots.render(SettingsPage().modifier(Tinted(hex: model.accentHex)).environment(model).environment(updates).font(Theme.font), width: 640, background: tones.surface, to: String(w.dropFirst(5)))
				default: openWindow(id: what)
				}
			}
		}
	}

	private func dressAll() { for w in NSApp.windows { WindowTint.dress(w, NSColor(tones.surface), dark: tones.chromeDark) } }

	private func run(_ c: Palette.Command) {
		switch c {
		case .open(let id): model.open(id)
		case .person(let u): model.message(u)
		case .hit(let h): model.open(h.conversation.id); if let t = h.event.thread { model.openThread = t }
		case .newChat: sheet = .chat
		case .newGroup: sheet = .group
		case .newFriend: model.offer = .friend
		case .newSpace: sheet = .space
		case .network: model.settingsSection = "network"; openWindow(id: "settings")
		case .friends: model.settingsSection = "friends"; openWindow(id: "settings")
		case .settings: openWindow(id: "settings")
		case .call(let id, let video): model.calls.start(id, video: video)
		case .details: model.details.toggle()
		case .markRead(let id): if let c = model.conversation(id) { model.markRead(c) }
		}
	}
}

/// Paints the window itself in the palette's surface, so the title bar and any platform view that
/// draws nothing (the timeline's table, a List) sit on the hue, not on white.
struct WindowTint: NSViewRepresentable {
	let color: Color
	func makeNSView(context: Context) -> Tinter { Tinter() }
	var dark: Bool
	func updateNSView(_ v: Tinter, context: Context) { v.color = NSColor(color); v.dark = dark; v.apply() }
	final class Tinter: NSView {
		var color: NSColor = .windowBackgroundColor
		var dark = false
		override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
		func apply() { if let w = window { WindowTint.dress(w, color, dark: dark) } }
	}
	/// The surface colour on every window, its title bar transparent over it, and the window's
	/// appearance the hue's own (dark under white text), so title text, traffic lights, sheets,
	/// menus and fields match the hue instead of sitting in a white or grey band.
	static func dress(_ w: NSWindow, _ color: NSColor, dark: Bool) {
		if w.backgroundColor != color { w.backgroundColor = color }
		if !w.titlebarAppearsTransparent { w.titlebarAppearsTransparent = true }
		#if DEBUG
		// `BAUD_HIDDEN=1` (the lab): a run that draws nothing anyone sees, takes no clicks and no
		// focus, and has no Dock icon, so tests can run beside a person using the Mac.
		if ProcessInfo.processInfo.environment["BAUD_HIDDEN"] == "1" {
			if NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory); Lab.awake = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "lab run") }
			w.alphaValue = 0; w.ignoresMouseEvents = true; w.level = .init(rawValue: -1000)
		}
		#endif
	}
}

#if DEBUG
/// A hidden lab run keeps its timers: nobody sees its window, so macOS would nap it otherwise.
enum Lab { nonisolated(unsafe) static var awake: NSObjectProtocol? }
#endif

/// Side windows are never restored at launch (a restored linking or Settings window must not come
/// back in place of the main one). Done on the NSWindow so it holds on macOS 14, the floor.
struct NotRestored: ViewModifier {
	func body(content: Content) -> some View { content.background(NotRestoredWindow()) }
}
private struct NotRestoredWindow: NSViewRepresentable {
	func makeNSView(context: Context) -> NSView {
		let v = NSView()
		DispatchQueue.main.async { v.window?.isRestorable = false }
		return v
	}
	func updateNSView(_ v: NSView, context: Context) { v.window?.isRestorable = false }
}
