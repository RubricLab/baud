/// The iPhone: the same two modes as the Mac, as tabs. Home is chats (direct and group), friends and
/// my devices; Spaces is the list of spaces, and tapping one is stepping inside it. You is Settings.
/// The same conversation view, rows and marks as the Mac.
import BaudCore
import SwiftUI

@main
struct BaudApp: App {
	@UIApplicationDelegateAdaptor(PushDelegate.self) private var push
	@State private var model = AppModel()
	@Environment(\.scenePhase) private var phase
	init() {
		Refresh.register()
		// Before the first tab bar exists: its badges in the hue's strongest step, not the system's red.
		let hex = ProcessInfo.processInfo.environment["BAUD_ACCENT"].map { $0 == "none" ? nil : $0 } ?? UserDefaults.standard.string(forKey: "accent")
		TabBadges.apply(Tones.make(hex: hex, dark: Appearance.read()))
	}
	var body: some Scene {
		WindowGroup {
			// The hue is applied above the root, so every sheet the root presents wears it too.
			Group {
				if model.waiting { LaunchView(locked: true) } else { IOSRoot() }
			}
				.modifier(Tinted(hex: model.accentHex)).environment(model)
				.environment(\.restart, { model = AppModel() })
				// Unlocked at last: everything can be read now, so baud opens for real.
				.onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
					guard model.waiting else { return }
					model = AppModel(); Refresh.model = model; model.scene(active: phase == .active)
				}
				.onOpenURL { model.open(url: $0) }
				.onChange(of: phase) { _, p in
					// Waiting on a lock that has lifted: open for real.
					if p == .active, model.waiting, !AppModel.locked, ProcessInfo.processInfo.environment["BAUD_LOCKED"] == nil { model = AppModel(); Refresh.model = model }
					// In front: online. A glance away (inactive): still online. Leaving: online a
					// little longer to finish what's under way, then the background wakes.
					switch p {
					case .active: model.scene(active: true); Appearance.shared.refresh(); LocalNetwork.shared.probe()
					case .background: model.front = false; Refresh.linger(); Refresh.schedule(); Refresh.scheduleCatchup()
					default: model.front = false
					}
				}
				.onAppear { Refresh.model = model; model.scene(active: true); Refresh.stubIfAsked() }
		}
	}
}

/// The tab bar's badges wear the hue (the appearance proxy, set before the bar is made).
enum TabBadges {
	static func apply(_ tones: Tones) {
		let a = UITabBarAppearance(); a.configureWithTransparentBackground()
		for item in [a.stackedLayoutAppearance, a.inlineLayoutAppearance, a.compactInlineLayoutAppearance] {
			for state in [item.normal, item.selected] { state.badgeBackgroundColor = UIColor(tones.strong); state.badgeTextAttributes = [.foregroundColor: UIColor(tones.onStrong)] }
		}
		UITabBar.appearance().standardAppearance = a; UITabBar.appearance().scrollEdgeAppearance = a
	}
}

/// Where a stack can go: a conversation, or inside a space.
enum Route: Hashable { case conv(ConversationId), space(ConversationId) }

struct IOSRoot: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	/// The type scale is read from the text size; a change redraws everything.
	@Environment(\.dynamicTypeSize) private var textSize
	@State private var tab = ProcessInfo.processInfo.environment["BAUD_TAB"].map { $0 == "chats" ? "home" : $0 } ?? "home"
	@State private var addHeight: PresentationDetent = .medium
	var body: some View {
		@SwiftUI.Bindable var m = model
		// The tab badges in the strongest step, not the system's red.
		let _ = TabBadges.apply(tones)
		Group {
			if !model.named || (!model.onboarded && model.conversations.isEmpty) {
				OnboardingView()
			} else {
				// One scroll of chats, Signal's way: my face (You) at the left, Chats, compose at the right.
				HomeTab()
			}
		}
		.overlay { if model.removedHere { RemovedView() } }
		.modifier(CallPresenter())
		.id(textSize)
		.font(Theme.font)
		.background(Ground())
		.alert("baud", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") {} } message: { Text(model.error ?? "") }
		// One Add screen for a friend, my own device, and any link I'm given; a medium sheet, full
		// height while my answer to a link (its code and why) is up.
		.sheet(isPresented: Binding(get: { model.adding && model.named && model.onboarded }, set: { if !$0 { model.offer = nil; model.join = nil; model.settleIcon(); addHeight = .medium } })) {
			AddView().frame(maxHeight: .infinity, alignment: .top).presentationDetents([.medium, .large], selection: $addHeight).presentationBackground { Ground() }.presentationDragIndicator(.visible)
		}
		.onChange(of: model.join?.reply != nil) { _, answering in if answering { addHeight = .large } }
		// A device asking to join shows inside the Add screen when it is up, else on its own.
		.sheet(item: Binding(get: { model.adding ? nil : model.linkAsk }, set: { if $0 == nil { model.linkAsk = nil } })) {
			AskBody(ask: $0).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(Ground())
				.presentationDetents([.medium]).presentationBackground { Ground() }.presentationDragIndicator(.visible)
		}
		.sheet(item: Binding(get: { model.addingTo.map(Adding.init) }, set: { if $0 == nil { model.addingTo = nil } })) { AddPeopleSheet(conv: $0.id).presentationBackground { Ground() } }
		.onChange(of: model.reveal) { _, id in if id != nil { tab = "home" } }
		.onChange(of: model.mode) { _, m in if tab == "home" || tab == "spaces" { tab = m == .home ? "home" : "spaces" } }
		.onChange(of: tab) { _, t in if t == "home" { model.mode = .home } else if t == "spaces" { model.mode = .spaces } }
		.task { Measure.opened(); await Bench.runIfAsked(model) }
	}
}

/// A screen's own title: the display size, its actions at the end. The system's large titles
/// vanished on a hued bar, so every root screen draws this instead.
struct ScreenTitle<Trailing: View>: View {
	@Environment(\.tones) private var tones
	let title: String
	var detail: String? = nil
	@ViewBuilder var trailing: Trailing
	var body: some View {
		HStack(alignment: .center, spacing: 4) {
			VStack(alignment: .leading, spacing: 2) {
				Text(title).font(Theme.displayFont).foregroundStyle(tones.heading).lineLimit(1)
				if let detail { Text(detail).font(Theme.smallFont).foregroundStyle(tones.secondary) }
			}
			Spacer()
			trailing
		}
		.padding(.leading, Rows.inset + Rows.pad).padding(.trailing, Rows.inset).padding(.top, 8).padding(.bottom, 2)
	}
}

/// Chats: every chat, direct and group; the search field finds any message in them.
struct HomeTab: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	@State private var sheet: NewSheet.What?
	@State private var path: [Route] = []
	@State private var query = ""
	@State private var you = false
	var body: some View {
		NavigationStack(path: $path) {
			// A List, for swipe to delete; the top row and search ride as its first rows.
			List {
				Group {
					HStack {
						Button { you = true } label: { Avatar(name: model.me.name, hash: model.me.avatar, size: 34) }.buttonStyle(.plain).accessibilityLabel("You")
						// Up to the centred title, with a gap: the face (34) and its spacing take the rest.
						NetStatusChip(room: UIScreen.main.bounds.width / 2 - 26 - (Rows.inset + Rows.pad) - 34 - 8 - 4)
						Spacer()
						Menu { Button("New group") { sheet = .group }; Button("New friend") { model.offer = .friend } } label: { Image(systemName: "square.and.pencil").font(.system(size: 18, weight: .semibold)).frame(width: 44, height: 44) }
							.accessibilityLabel("New")
					}
					.overlay { Text("Chats").font(Theme.headingFont).allowsHitTesting(false) }
					.padding(.horizontal, Rows.inset + Rows.pad).padding(.top, 4)
					SearchField(text: $query).padding(.horizontal, Rows.inset + Rows.pad).padding(.vertical, 8)
					if query.trimmingCharacters(in: .whitespaces).count >= 2 {
						ForEach(model.core.search(query, scope: nil)) { h in
							Button { path.append(.conv(h.conversation.id)) } label: {
								VStack(alignment: .leading, spacing: 2) {
									Text("\(model.name(of: h.event.user)): \(h.snippet)").font(Theme.font).lineLimit(2)
									Text(model.title(h.conversation) + " · " + whenShort(h.event.at)).font(Theme.smallFont).foregroundStyle(tones.secondary)
								}.padding(.vertical, 6)
							}.buttonStyle(RowStyle())
						}
					} else {
						ForEach(model.chats) { c in
							Button { path.append(.conv(c.id)) } label: { ChatRow(c: c) }.buttonStyle(RowStyle())
								.contextMenu { ChatMenu(c: c) }
								.swipeActions(edge: .trailing, allowsFullSwipe: false) {
									Button(c.kind == .home ? "Clear" : "Delete", role: .destructive) { model.deleting = c }
								}
						}
						ForEach(model.quiet) { f in
							Button { if let id = model.startChat(with: f.user) { path.append(.conv(id)) } } label: { NewChatRow(friend: f) }.buttonStyle(RowStyle())
						}
						if model.chats.count <= 1 && model.quiet.isEmpty {
							Button { model.offer = .friend } label: { Label("New friend", systemImage: "plus") }.buttonStyle(Quiet(strong: true)).frame(maxWidth: .infinity).padding(.top, 40)
						}
					}
				}
				.listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
			}
			.listStyle(.plain).scrollContentBackground(.hidden)
			// A scroll through the chats puts the search's keyboard away.
			.scrollDismissesKeyboard(.immediately)
			.modifier(DeleteChatQuestion())
			.background(Ground())
			.toolbar(.hidden, for: .navigationBar)
			.navigationDestination(for: Route.self) { r in RouteView(route: r) }
		}
		.onAppear {
			Staged.push(model, kind: .chat) { path = $0 }
			// `BAUD_TAB=you` opens You on launch, for the pictures.
			if ProcessInfo.processInfo.environment["BAUD_TAB"] == "you" { Task { try? await Task.sleep(for: .milliseconds(600)); you = true } }
		}
		.onChange(of: model.reveal) { _, id in if let id, model.conversation(id)?.kind == .chat { you = false; path = [.conv(id)]; model.reveal = nil } }
		.sheet(item: $sheet) { NewSheet(what: $0).presentationBackground { Ground() } }
		// You: devices, friends, network, colour, the app; from the face.
		.sheet(isPresented: $you, onDismiss: { if let o = model.afterYou { model.afterYou = nil; model.offer = o } }) {
			// A stack of its own: a friend opens full height, with the way back.
			NavigationStack {
				SettingsView().toolbar(.hidden, for: .navigationBar)
					.navigationDestination(for: PersonLink.self) { PersonPage(user: $0.user, conv: $0.conv) }
			}
			.presentationDetents([.large]).presentationBackground { Ground() }.presentationDragIndicator(.visible)
		}
	}
}

/// The search field, drawn in the palette.
struct SearchField: View {
	@Environment(\.tones) private var tones
	@Binding var text: String
	var body: some View {
		HStack(spacing: 8) {
			Image(systemName: "magnifyingglass").foregroundStyle(tones.secondary)
			TextField("", text: $text, prompt: Text("Search").foregroundStyle(tones.secondary)).textFieldStyle(.plain).font(Theme.font)
			if !text.isEmpty { Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(tones.secondary) }.buttonStyle(.plain).accessibilityLabel("Clear") }
		}
		.padding(.horizontal, 12).frame(minHeight: 40)
		.glass(corner: 12, lifted: false)
	}
}

/// Spaces: the list of spaces. Tap one to step inside.
struct SpacesTab: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	@State private var sheet: NewSheet.What?
	@State private var path: [Route] = []
	var body: some View {
		NavigationStack(path: $path) {
			ScrollView {
				LazyVStack(alignment: .leading, spacing: 0) {
					ScreenTitle(title: "Spaces") { IconButton(symbol: "plus", help: "New space", size: 17) { sheet = .space } }
					ForEach(model.spaces) { s in NavigationLink(value: Route.space(s.id)) { SpaceRow(s: s) }.buttonStyle(RowStyle()) }
					if model.spaces.isEmpty {
						EmptyLine(text: "A space is a closed circle: everyone in it is friends with everyone, every channel has every member, and only its members carry its messages.").padding(.top, 8)
						Button("New space") { sheet = .space }.buttonStyle(Quiet(strong: true)).padding(.horizontal, Rows.inset + Rows.pad).padding(.top, 8)
					}
				}
				.padding(.bottom, 24)
			}
			.background(Ground())
			.toolbar(.hidden, for: .navigationBar)
			.navigationDestination(for: Route.self) { r in RouteView(route: r) }
		}
		.onAppear { Staged.push(model, kind: .channel) { path = $0 } }
		.sheet(item: $sheet) { NewSheet(what: $0).presentationBackground { Ground() } }
	}
}

struct RouteView: View {
	let route: Route
	var body: some View {
		switch route {
		case .conv(let id): ConversationScreen(conv: id)
		case .space(let id): SpaceScreen(space: id)
		}
	}
}

/// Inside a space: back to Spaces, its name, its channels, its people.
struct SpaceScreen: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	@Environment(\.dismiss) private var dismiss
	let space: ConversationId
	@State private var sheet: NewSheet.What?
	@State private var person: Member?
	var body: some View {
		let s = model.conversation(space)
		let people = model.people(in: space)
		ScrollView {
			LazyVStack(alignment: .leading, spacing: 0) {
				HStack {
					Button { dismiss() } label: { HStack(spacing: 4) { Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold)); Text("Spaces").font(Theme.font) }.frame(height: 40) }
						.buttonStyle(RowStyle()).fixedSize()
					Spacer()
					Menu { Button("New channel") { sheet = .channel }; Button("Add someone") { model.addingTo = space } } label: { Image(systemName: "plus").font(.system(size: 17, weight: .semibold)).frame(width: 40, height: 40) }
						.padding(.trailing, Rows.inset)
				}
				HStack(spacing: 12) {
					SpaceTile(name: s?.name ?? "", size: 44)
					VStack(alignment: .leading, spacing: 2) {
						Text(s?.name ?? "space").font(Theme.displayFont).foregroundStyle(tones.heading).lineLimit(1)
						Text(model.peopleLine(people)).font(Theme.smallFont).foregroundStyle(tones.secondary)
					}
				}
				.padding(.horizontal, Rows.inset + Rows.pad).padding(.top, 4)
				SectionHeading(title: "Channels")
				ForEach(model.channels(in: space)) { c in NavigationLink(value: Route.conv(c.id)) { ChannelRow(c: c) }.buttonStyle(RowStyle()) }
				ForEach(model.browsable(in: space)) { c in
					Button { model.attempt { try model.core.join(space: space, channel: c.id); model.refreshAll() } } label: {
						HStack { Text("#").foregroundStyle(tones.secondary).frame(width: Rows.smallFace - 4); Text(c.name ?? "").foregroundStyle(tones.secondary); Spacer(); Text("Join").font(Theme.smallFont.weight(.semibold)) }.frame(height: Rows.compact)
					}.buttonStyle(RowStyle())
				}
				SectionHeading(title: "People")
				ForEach(people) { m in Button { person = m } label: { PersonRow(m: m, conv: space) }.buttonStyle(RowStyle()) }
			}
			.padding(.bottom, 24)
		}
		.background(Ground())
		.toolbar(.hidden, for: .navigationBar)
		.sheet(item: $sheet) { NewSheet(what: $0, space: space).presentationBackground { Ground() } }
		.sheet(item: $person) { m in NavigationStack { PersonPage(user: m.user, conv: space) }.presentationDetents([.large]).presentationDragIndicator(.visible) }
		.onAppear { model.selectedSpace = space }
	}
}

struct ConversationScreen: View {
	@Environment(\.tones) private var tones
	@Environment(AppModel.self) private var model
	let conv: ConversationId
	@State private var members = false
	@State private var detail = NavigationPath()
	var body: some View {
		ConversationView(conv: conv, showMembers: $members)
			.background(Ground())
			// Its details, a stack of their own: a person and Add people push in, full height, and back.
			.sheet(isPresented: $members) {
				NavigationStack(path: $detail) {
					MembersView(conv: conv, close: { members = false })
						.toolbar(.hidden, for: .navigationBar)
						.navigationDestination(for: PersonLink.self) { PersonPage(user: $0.user, conv: $0.conv) }
						.navigationDestination(for: AddPeopleLink.self) { AddPeopleSheet(conv: $0.conv, pushed: true) }
				}
				.presentationBackground(tones.surface)
			}
			// `BAUD_INFO=1`: its details open once it's on screen, for the pictures.
			// `BAUD_INFO=person:Ana` or `add` goes one step further in, for the pictures.
			.task {
				guard let info = ProcessInfo.processInfo.environment["BAUD_INFO"] else { return }
				try? await Task.sleep(for: .milliseconds(700)); members = true
				try? await Task.sleep(for: .milliseconds(600))
				if info == "add" { detail.append(AddPeopleLink(conv: conv)) }
				else if info.hasPrefix("person:"), let m = model.core.members(conv).first(where: { model.name(of: $0.user).hasPrefix(info.dropFirst(7)) }) { detail.append(PersonLink(user: m.user, conv: conv)) }
			}
	}
}

/// You is Settings: name, photo, colour, devices, network, notifications, about. Contacts live
/// under it too, one row.
struct YouTab: View {
	@Environment(AppModel.self) private var model
	var body: some View { SettingsView().toolbar(.hidden, for: .navigationBar) }
}

struct SearchTab: View {
	@Environment(\.tones) private var tones
	@Environment(AppModel.self) private var model
	@State private var query = ""
	var body: some View {
		List {
			ForEach(model.core.search(query, scope: nil)) { h in
				NavigationLink(value: h.conversation.id) {
					VStack(alignment: .leading, spacing: 1) {
						Text("\(model.name(of: h.event.user)): \(h.snippet)").font(Theme.font).lineLimit(2)
						Text(model.title(h.conversation) + " · " + whenShort(h.event.at)).font(Theme.smallFont).foregroundStyle(tones.secondary)
					}
				}
			}
		}
		.listStyle(.plain).scrollContentBackground(.hidden).background(Ground())
		.searchable(text: $query, prompt: "Search every message")
		.navigationTitle("Search")
		.navigationDestination(for: ConversationId.self) { ConversationScreen(conv: $0) }
	}
}

/// `BAUD_OPEN=<title>` opens a conversation on launch, for the screenshots; a space's name steps inside it.
enum Staged {
	@MainActor static func open(_ model: AppModel, kind: Kind) -> [Route] {
		guard let want = ProcessInfo.processInfo.environment["BAUD_OPEN"] else { return [] }
		if kind == .channel, let s = model.spaces.first(where: { $0.name == want }) { return [.space(s.id)] }
		guard let c = model.conversations.first(where: { $0.kind == kind && model.title($0).trimmingCharacters(in: CharacterSet(charactersIn: "#")) == want }) else { return [] }
		return kind == .channel ? (c.space.map { [Route.space($0)] } ?? []) + [.conv(c.id)] : [.conv(c.id)]
	}
	/// The conversations can land after the stack appears (the crate adopts the identity, the demo
	/// people arrive), so it waits for the one asked for, up to eight seconds.
	@MainActor static func push(_ model: AppModel, kind: Kind, _ set: @escaping ([Route]) -> Void) {
		guard ProcessInfo.processInfo.environment["BAUD_OPEN"] != nil else { return }
		Task {
			for _ in 0..<40 {
				try? await Task.sleep(for: .milliseconds(200))
				let r = open(model, kind: kind)
				if !r.isEmpty { try? await Task.sleep(for: .milliseconds(200)); set(r); return }
			}
		}
	}
}

/// The edge swipe back works with our own headers too. Hiding the system's bar (every screen draws
/// its own) switched it off, so the back button was the only way back, and an easy one to miss.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
	override open func viewDidLoad() {
		super.viewDidLoad()
		interactivePopGestureRecognizer?.delegate = self
	}
	public func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool { viewControllers.count > 1 }
}
