/// The Mac's sidebar. In the band with the traffic lights, compose (and the Home or Spaces switch
/// when spaces are on); under it, search (⌘F); then the list: chats (direct and group) and friends
/// not written to yet, or the spaces. At the foot, me: my face and name open Settings, and this
/// Mac's status opens its sheet.
import BaudCore
import SwiftUI

struct Sidebar: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	@Environment(\.openWindow) private var openWindow
	@Binding var sheet: NewSheet.What?
	@FocusState private var focused: Bool
	@FocusState private var searching: Bool
	@State private var query = ""
	@Environment(Updates.self) private var updates

	var body: some View {
		VStack(spacing: 0) {
			// The band the traffic lights sit in: compose at its end, the rest drags the window.
			HStack(spacing: 8) {
				Color.clear.frame(width: 70)
				if Features.spaces { ModeSwitch() } else { Spacer() }
				Compose(sheet: $sheet)
			}
			.padding(.trailing, Rows.inset)
			.frame(height: Theme.band + 4)
			.background(Color.clear.contentShape(Rectangle()).modifier(DragsWindow()))
			SearchBox(text: $query, keys: query.isEmpty && !searching ? "⌘F" : nil, fill: tones.hover, focus: $searching)
				.onKeyPress(.escape) { if !query.isEmpty { query = "" } else { searching = false; focused = true }; return .handled }
				.padding(.horizontal, Rows.inset).padding(.top, 4).padding(.bottom, 8)
			ScrollViewReader { proxy in
				ScrollView {
					VStack(alignment: .leading, spacing: 0) {
						switch model.mode {
						case .home: if query.trimmingCharacters(in: .whitespaces).count >= 2 { SearchList(query: query) } else { HomeList(sheet: $sheet, focused: focused) }
						case .spaces:
							if let s = model.selectedSpace, let space = model.conversation(s) { SpaceList(space: space, sheet: $sheet, focused: focused) }
							else { SpacesList(sheet: $sheet, focused: focused) }
						}
					}
					.padding(.bottom, 16)
					// A new side of the wall starts at its top.
					.id(model.mode == .home ? "home" : model.selectedSpace ?? "spaces")
				}
				.scrollIndicators(.never)
				.onChange(of: model.selectedConversation) { _, id in if let id { withAnimation(Motion.quick) { proxy.scrollTo(id) } } }
			}

			// A newer baud, where it's seen: one press updates, another restarts into it.
			if updates.offering { UpdateBar().padding(.horizontal, Rows.inset).padding(.bottom, 8).transition(.move(edge: .bottom).combined(with: .opacity)) }
			Hairline()
			YouRow()
		}
		.background(tones.raised)
		// Arrows walk this side of the wall and open as they go; ⏎ hands the keyboard to the chat's
		// composer, or hops into a space; ⎋ or ← out of it.
		.focusable()
		.focused($focused)
		.focusEffectDisabled()
		.onKeyPress(.downArrow) { model.step(1); return .handled }
		.onKeyPress(.upArrow) { model.step(-1); return .handled }
		.onKeyPress(.return) {
			if model.mode == .spaces, model.selectedSpace == nil, let c = model.stepCursor { model.selectedSpace = c; return .handled }
			if model.selectedConversation != nil { focused = false; model.focusComposer &+= 1; return .handled }
			return .ignored
		}
		.onKeyPress(.escape) { if model.mode == .spaces, model.selectedSpace != nil { model.leaveSpace(); return .handled }; return .ignored }
		.onKeyPress(.leftArrow) { if model.mode == .spaces, model.selectedSpace != nil { model.leaveSpace(); return .handled }; return .ignored }
		.onChange(of: focused) { _, f in model.sidebarFocused = f }
		.onChange(of: model.focusSidebar) { _, _ in focused = true }
		.onChange(of: model.focusSearch) { _, _ in searching = true }
	}
}

/// Compose, by the traffic lights: a new chat, a new group, a new friend.
struct Compose: View {
	@Environment(AppModel.self) private var model
	@Binding var sheet: NewSheet.What?
	var body: some View {
		Menu {
			Button { sheet = .chat } label: { Label("New chat", systemImage: "bubble.left") }
			Button { sheet = .group } label: { Label("New group", systemImage: "person.2") }
			Button { model.offer = .friend } label: { Label("New friend", systemImage: "person.badge.plus") }
		} label: {
			Image(systemName: "square.and.pencil").font(Icon.font(Icon.bar))
		}
		.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
		.frame(width: 24, height: 24)
		.help("New chat, group or friend (⌘N, ⇧⌘N, ⌥⌘N)")
		.accessibilityLabel("New")
	}
}

/// Home or Spaces: one control, the side I'm on filled, a dot on the other when something there is unread.
struct ModeSwitch: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	var body: some View {
		HStack(spacing: 2) {
			segment(.home, "Home", dot: model.unreadHome)
			segment(.spaces, "Spaces", dot: model.unreadSpaces)
		}
		.padding(2)
		.background(Capsule().fill(tones.pressed))
		.accessibilityElement(children: .contain).accessibilityLabel("Home or Spaces")
	}
	private func segment(_ m: AppModel.Mode, _ title: String, dot: Bool) -> some View {
		let on = model.mode == m
		return Button { model.show(m) } label: {
			HStack(spacing: 5) {
				Text(title).font(.system(size: Theme.body, weight: .semibold))
				if dot && !on { Circle().fill(tones.strong).frame(width: 6, height: 6) }
			}
			.frame(maxWidth: .infinity).frame(height: 24)
		}
		.buttonStyle(Segment(on: on))
		.help(m == .home ? "Home: chats, friends, devices (⌘1)" : "Spaces (⌘2)")
		.accessibilityAddTraits(on ? .isSelected : [])
	}
	struct Segment: ButtonStyle {
		let on: Bool
		func makeBody(configuration: Configuration) -> some View { Look(configuration: configuration, on: on) }
		struct Look: View {
			@Environment(\.tones) private var tones
			@State private var hover = false
			let configuration: Configuration
			let on: Bool
			var body: some View {
				configuration.label
					.foregroundStyle(on ? tones.onLoud : tones.secondary)
					.background(Capsule().fill(configuration.isPressed ? tones.pressed : on ? tones.loud : hover ? tones.hover : .clear))
					.contentShape(Capsule())
					.onHover { hover = $0 }
			}
		}
	}
}

/// Home: chats, friends, my devices.
struct HomeList: View {
	@Environment(AppModel.self) private var model
	@Environment(\.openWindow) private var openWindow
	@Binding var sheet: NewSheet.What?
	let focused: Bool
	var body: some View {
		ForEach(model.chats) { c in
			let on = model.selectedConversation == c.id
			Button { model.open(c.id) } label: { ChatRow(c: c, selected: on) }
				.buttonStyle(RowStyle(selected: on, focused: focused)).id(c.id)
				.contextMenu { ChatMenu(c: c) }
		}
		ForEach(model.quiet) { f in
			Button { if let id = model.startChat(with: f.user) { model.open(id) } } label: { NewChatRow(friend: f) }
				.buttonStyle(RowStyle(focused: focused)).id(f.user)
		}

	}
}

/// Search, in the sidebar: every message that matches.
struct SearchList: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	let query: String
	var body: some View {
		ForEach(model.core.search(query, scope: nil).prefix(40)) { h in
			Button { model.open(h.conversation.id); if let t = h.event.thread { model.openThread = t } } label: {
				VStack(alignment: .leading, spacing: 2) {
					Text("\(model.name(of: h.event.user)): \(h.snippet)").font(Theme.font).lineLimit(2)
					Text(model.title(h.conversation) + " · " + whenShort(h.event.at)).font(Theme.smallFont).foregroundStyle(tones.secondary)
				}.padding(.vertical, 5)
			}.buttonStyle(RowStyle())
		}
	}
}

/// Spaces, from outside: every space I am in. Hop into one.
struct SpacesList: View {
	@Environment(AppModel.self) private var model
	@Binding var sheet: NewSheet.What?
	let focused: Bool
	var body: some View {
		SectionHeading(title: "Spaces", first: true) {
			IconButton(symbol: "plus", help: "New space (⌥⌘N)") { sheet = .space }
		}
		ForEach(model.spaces) { s in
			let cursor = model.stepCursor == s.id
			Button { model.selectedSpace = s.id } label: { SpaceRow(s: s, selected: cursor) }
				.buttonStyle(RowStyle(selected: cursor, focused: focused)).id(s.id)
		}
		if model.spaces.isEmpty { EmptyLine(text: "No spaces yet.") }
	}
}

/// Inside a space: the way back, its name, its channels, its people.
struct SpaceList: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	let space: Conversation
	@Binding var sheet: NewSheet.What?
	let focused: Bool
	@State private var person: Member?
	var body: some View {
		let people = model.people(in: space.id)
		Button { model.leaveSpace() } label: {
			HStack(spacing: 4) { Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold)); Text("Spaces").font(Theme.smallFont.weight(.medium)) }
				.foregroundStyle(tones.secondary).frame(height: 22)
		}
		.buttonStyle(RowStyle()).fixedSize().help("Back to all spaces (⌘[)").padding(.top, 2)
		HStack(spacing: 10) {
			SpaceTile(name: space.name ?? "", size: 32)
			VStack(alignment: .leading, spacing: 1) {
				Text(space.name ?? "space").font(Theme.titleFont).foregroundStyle(tones.heading).lineLimit(1)
				Text(model.peopleLine(people)).font(Theme.smallFont).foregroundStyle(tones.secondary)
			}
		}
		.padding(.horizontal, Rows.inset + Rows.pad).padding(.top, 8)
		SectionHeading(title: "Channels") {
			IconButton(symbol: "plus", help: "New channel (⌃⌘N)") { sheet = .channel }
		}
		ForEach(model.channels(in: space.id)) { c in
			let on = model.selectedConversation == c.id
			Button { model.open(c.id) } label: { ChannelRow(c: c, selected: on) }
				.buttonStyle(RowStyle(selected: on, focused: focused)).id(c.id)
		}
		ForEach(model.browsable(in: space.id)) { c in
			Button { model.attempt { try model.core.join(space: space.id, channel: c.id); model.refreshAll(); model.open(c.id) } } label: {
				HStack(spacing: 6) {
					Text("#").font(Theme.font.weight(.medium)).foregroundStyle(tones.secondary).frame(width: Rows.smallFace - 4)
					Text(c.name ?? "").font(Theme.font).foregroundStyle(tones.secondary)
					Spacer()
					Text("Join").font(Theme.smallFont.weight(.semibold)).padding(.horizontal, 7).frame(height: 18).background(Capsule().strokeBorder(tones.hairline))
				}.frame(minHeight: Rows.compact)
			}
			.buttonStyle(RowStyle()).help("Join #\(c.name ?? "")")
		}
		SectionHeading(title: "People") {
			IconButton(symbol: "plus", help: "Add someone to \(space.name ?? "the space")") { model.addingTo = space.id }
		}
		ForEach(people) { m in
			Button { person = m } label: { SpacePersonRow(m: m, conv: space.id) }
				.buttonStyle(RowStyle())
				.popover(isPresented: Binding(get: { person?.id == m.id }, set: { if !$0 { person = nil } }), arrowEdge: .trailing) { PersonPage(user: m.user, conv: space.id).frame(width: 360, height: 560) }
		}
	}
}

/// Me, at the foot of the sidebar: my face and name (Settings), and this Mac's status (its sheet),
/// far enough apart that neither is hit for the other.
struct YouRow: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	@Environment(\.openWindow) private var openWindow
	var body: some View {
		HStack(spacing: 8) {
			Button { openWindow(id: "settings") } label: {
				HStack(spacing: 8) {
					Avatar(name: model.me.name, hash: model.me.avatar, size: 22)
					Text(model.me.name).font(Theme.font.weight(.semibold)).foregroundStyle(tones.text).lineLimit(1)
				}
				.padding(.leading, 3).padding(.trailing, 8).frame(height: 28)
			}
			.buttonStyle(Pill()).help("Settings (⌘,)").accessibilityLabel("Settings")
			Spacer(minLength: 24)
			NetStatusChip().fixedSize()
		}
		.padding(.horizontal, Rows.inset).frame(height: 44)
	}
}
