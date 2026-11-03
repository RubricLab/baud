/// The Mac's sidebar, rebuilt for the two modes with a wall between them. At the top, beside the
/// traffic lights, the switch: Home or Spaces. Home is chats (direct and group), friends and my
/// devices. Spaces is the list of spaces; hop into one and the sidebar is that space: its channels
/// and its people, a way back at the top. Never both. At the bottom, me, which opens Settings.
import BaudCore
import SwiftUI

struct Sidebar: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	@Environment(\.openWindow) private var openWindow
	@Binding var sheet: NewSheet.What?
	@FocusState private var focused: Bool
	@State private var query = ""

	var body: some View {
		VStack(spacing: 0) {
			// The band the traffic lights sit in: the switch beside them, the rest drags the window.
			HStack(spacing: 0) {
				Color.clear.frame(width: 78)
				if Features.spaces { ModeSwitch() } else { Spacer() }
			}
			.padding(.trailing, 12)
			.frame(height: Theme.band)
			.background(Color.clear.contentShape(Rectangle()).modifier(DragsWindow()))
			// Signal's top row: my face (Settings), Chats, compose (New group, New friend); search under it.
			HStack {
				Button { openWindow(id: "settings") } label: { Avatar(name: model.me.name, hash: model.me.avatar, size: 26) }.buttonStyle(.plain).help("You (⌘,)")
				Spacer()
				Text("Chats").font(Theme.headingFont)
				Spacer()
				Menu { Button("New group") { sheet = .group }; Button("New friend") { model.offer = .friend } } label: { Image(systemName: "square.and.pencil").font(.system(size: 13, weight: .semibold)) }
					.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 26).help("New")
			}
			.padding(.horizontal, 16).padding(.bottom, 8)
			SidebarSearch(query: $query).padding(.horizontal, Rows.inset).padding(.bottom, 6)
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
				.onChange(of: model.selectedConversation) { _, id in if let id { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) } } }
			}

			// This Mac's status at the foot: the mark and the words; a tap explains.
			Hairline()
			HStack { NetStatusChip(); Spacer() }.padding(.horizontal, 11).padding(.vertical, 8)
		}
		.background(tones.raised)
		// Arrows walk this side of the wall and open as they go, ⏎ hops into a space, ⎋ or ← out of it.
		.focusable()
		.focused($focused)
		.focusEffectDisabled()
		.onKeyPress(.downArrow) { model.step(1); return .handled }
		.onKeyPress(.upArrow) { model.step(-1); return .handled }
		.onKeyPress(.return) { if model.mode == .spaces, model.selectedSpace == nil, let c = model.stepCursor { model.selectedSpace = c; return .handled }; return .ignored }
		.onKeyPress(.escape) { if model.mode == .spaces, model.selectedSpace != nil { model.leaveSpace(); return .handled }; return .ignored }
		.onKeyPress(.leftArrow) { if model.mode == .spaces, model.selectedSpace != nil { model.leaveSpace(); return .handled }; return .ignored }
		.onChange(of: focused) { _, f in model.sidebarFocused = f }
		.onChange(of: model.focusSidebar) { _, _ in focused = true }
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
struct SidebarSearch: View {
	@Environment(\.tones) private var tones
	@Binding var query: String
	var body: some View {
		HStack(spacing: 6) {
			Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(tones.secondary)
			TextField("", text: $query, prompt: Text("Search").foregroundStyle(tones.secondary)).textFieldStyle(.plain).font(Theme.font)
		}
		.padding(.horizontal, 8).frame(height: 28)
		.background(RoundedRectangle(cornerRadius: 7).fill(tones.field))
	}
}

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
				}.frame(height: Rows.compact)
			}
			.buttonStyle(RowStyle()).help("Join #\(c.name ?? "")")
		}
		SectionHeading(title: "People") {
			IconButton(symbol: "plus", help: "Add someone to \(space.name ?? "the space")") { model.addingTo = space.id }
		}
		ForEach(people) { m in
			Button { person = m } label: { PersonRow(m: m, conv: space.id) }
				.buttonStyle(RowStyle())
				.popover(isPresented: Binding(get: { person?.id == m.id }, set: { if !$0 { person = nil } }), arrowEdge: .trailing) { PersonPage(user: m.user, conv: space.id).frame(width: 360, height: 560) }
		}
	}
}

/// Me, at the foot of the sidebar: my face, my name, my devices; Settings is one click.
struct YouRow: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	let action: () -> Void
	var body: some View {
		let others = model.me.otherDevices
		Button(action: action) {
			HStack(spacing: 8) {
				Avatar(name: model.me.name, hash: model.me.avatar, size: 26, presence: .online)
				VStack(alignment: .leading, spacing: 0) {
					Text(model.me.name).font(Theme.font.weight(.semibold)).lineLimit(1)
					Text(others.isEmpty ? "this \(AppModel.thisKind) only" : "\(others.count + 1) devices · \(others.filter(\.online).count + 1) online").font(Theme.smallFont).foregroundStyle(tones.secondary).lineLimit(1)
				}
				Spacer()
				Image(systemName: "gearshape").font(.system(size: 12, weight: .medium)).foregroundStyle(tones.secondary)
			}
			.frame(height: 40)
		}
		.buttonStyle(RowStyle()).padding(.vertical, 6).help("Settings (⌘,)")
	}
}
