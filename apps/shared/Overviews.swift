/// What the main pane shows when nothing is open: on the Spaces side, every space as a thing you
/// can hop into; on the Home side, who is around and how to start.
import BaudCore
import SwiftUI

struct SpacesOverview: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	@Binding var sheet: NewSheet.What?
	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 18) {
				VStack(alignment: .leading, spacing: 4) {
					Text("Spaces").font(Theme.displayFont)
					Text("Closed circles. Everyone in a space is friends with everyone in it, every channel has every member, and only its members carry its messages.")
						.font(Theme.font).foregroundStyle(tones.secondary).fixedSize(horizontal: false, vertical: true)
				}
				LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
					ForEach(model.spaces) { s in
						Button { model.selectedSpace = s.id } label: { SpaceCard(s: s) }.buttonStyle(TileStyle())
					}
					Button { sheet = .space } label: {
						HStack(spacing: 12) {
							Image(systemName: "plus").font(.system(size: 14, weight: .semibold)).frame(width: 36, height: 36).overlay(Circle().strokeBorder(tones.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
							VStack(alignment: .leading, spacing: 2) {
								Text("New space").font(Theme.font.weight(.semibold))
								Text("Name it, then add friends").font(Theme.smallFont).foregroundStyle(tones.secondary)
							}
							Spacer(minLength: 0)
						}.padding(14).frame(minHeight: 112)
					}.buttonStyle(TileStyle(empty: true))
				}
			}
			.padding(.horizontal, 28).padding(.top, Theme.band + 18).padding(.bottom, 28)
			.frame(maxWidth: 820, alignment: .leading)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		.background(tones.surface)
	}
}

/// A space as a thing: its tile and name, its people's faces with their lights, its numbers.
struct SpaceCard: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	let s: Conversation
	var body: some View {
		let people = model.people(in: s.id)
		let channels = model.channels(in: s.id)
		let unread = model.unread(space: s.id)
		VStack(alignment: .leading, spacing: 12) {
			HStack(spacing: 10) {
				SpaceTile(name: s.name ?? "", size: 30)
				Text(s.name ?? "space").font(Theme.headingFont).lineLimit(1)
				Spacer(minLength: 4)
				if unread > 0 { UnreadBadge(count: unread) }
			}
			Faces(members: people, size: 26)
			Text("\(model.peopleLine(people)) · \(channels.count) channel\(channels.count == 1 ? "" : "s")").font(Theme.smallFont).foregroundStyle(tones.secondary)
		}
		.padding(14).frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
	}
}

/// A row of overlapping faces, each with its light, and how many more.
struct Faces: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	let members: [Member]
	var size: CGFloat = 24
	var max = 7
	var body: some View {
		HStack(spacing: -size * 0.22) {
			ForEach(members.prefix(max)) { m in
				Avatar(name: m.me ? model.me.name : m.name, hash: m.me ? model.me.avatar : model.contacts.first { $0.user == m.user }?.avatar, size: size, presence: Mark.presence(m.devices))
					.padding(1.5).background(Circle().fill(tones.raised))
			}
			if members.count > max { Text("+\(members.count - max)").font(Theme.smallFont.weight(.semibold)).foregroundStyle(tones.secondary).padding(.leading, size * 0.35) }
		}
	}
}

struct HomeOverview: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	@Binding var sheet: NewSheet.What?
	var body: some View {
		let online = model.contacts.filter(\.online)
		VStack(alignment: .leading, spacing: 18) {
			VStack(alignment: .leading, spacing: 4) {
			}
			HStack(spacing: 12) {
				Button { model.offer = .friend } label: { Start(title: "New friend", detail: "", symbol: "person.badge.plus") }.buttonStyle(TileStyle())
				Button { sheet = .group } label: { Start(title: "New group", detail: "⇧⌘N", symbol: "person.2") }.buttonStyle(TileStyle())
			}
		}
		.padding(.horizontal, 28).padding(.top, Theme.band + 18)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		.background(tones.surface)
	}
	struct Start: View {
		@Environment(\.tones) private var tones
		let title: String, detail: String, symbol: String
		var body: some View {
			VStack(alignment: .leading, spacing: 10) {
				Image(systemName: symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(tones.secondary)
				VStack(alignment: .leading, spacing: 2) {
					Text(title).font(Theme.font.weight(.semibold))
					Text(detail).font(Theme.smallFont).foregroundStyle(tones.secondary)
				}
			}.padding(14).frame(width: 160, height: 88, alignment: .topLeading)
		}
	}
}
