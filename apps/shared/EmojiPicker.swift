/// Every emoji, for a reaction: the ones I used last on top, then Unicode's groups, and a search
/// over their names. A popover on the Mac, a sheet on the iPhone.
import SwiftUI

struct EmojiPicker: View {
	@Environment(\.tones) private var tones
	@Environment(\.dismiss) private var dismiss
	let pick: (String) -> Void
	@State private var query = ""
	@FocusState private var searching: Bool

	struct Item: Hashable { let emoji: String; let name: String }
	static let groups: [(name: String, items: [Item])] = EmojiData.groups.map { g in
		(g.name, g.lines.split(separator: "\n").compactMap { l in
			guard let sp = l.firstIndex(of: " ") else { return nil }
			return Item(emoji: String(l[..<sp]), name: String(l[l.index(after: sp)...]))
		})
	}
	/// The last reactions I picked here, newest first; a per-device convenience.
	static var recent: [String] {
		get { UserDefaults.standard.stringArray(forKey: "recentEmoji") ?? ["👍", "❤️", "😂", "🔥", "👀", "✅", "🙏", "🎉"] }
		set { UserDefaults.standard.set(Array(newValue.prefix(16)), forKey: "recentEmoji") }
	}
	static func used(_ e: String) { recent = [e] + recent.filter { $0 != e } }

	#if os(macOS)
	private let cell: CGFloat = 32, glyph: CGFloat = 22
	#else
	private let cell: CGFloat = 44, glyph: CGFloat = 30
	#endif

	var body: some View {
		VStack(spacing: 0) {
			HStack(spacing: 6) {
				Image(systemName: "magnifyingglass").font(.system(size: Theme.small)).foregroundStyle(tones.secondary)
				TextField("Search emoji", text: $query).textFieldStyle(.plain).font(Theme.font).focused($searching)
					.onSubmit { if let first = matches.first { choose(first.emoji) } }
				if !query.isEmpty {
					Button { query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: Theme.small)) }
						.buttonStyle(.plain).foregroundStyle(tones.secondary).accessibilityLabel("Clear")
				}
			}
			.padding(.horizontal, 8).frame(height: 30)
			.background(RoundedRectangle(cornerRadius: 7).fill(tones.field))
			.padding(12)
			Hairline()
			ScrollView {
				LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
					if query.trimmingCharacters(in: .whitespaces).isEmpty {
						section("Recent", Self.recent.map { Item(emoji: $0, name: $0) })
						ForEach(Self.groups, id: \.name) { g in section(g.name, g.items) }
					} else if matches.isEmpty {
						Text("No emoji for “\(query)”").font(Theme.smallFont).foregroundStyle(tones.secondary).padding(16)
					} else {
						grid(matches)
					}
				}
				.padding(.horizontal, 8).padding(.bottom, 8)
			}
		}
		.background(tones.surface)
		#if os(macOS)
		.frame(width: cell * 9 + 16, height: 360)
		.onAppear { searching = true }
		#endif
	}

	private var matches: [Item] {
		let words = query.lowercased().split(separator: " ")
		guard !words.isEmpty else { return [] }
		return Self.groups.flatMap(\.items).filter { i in words.allSatisfy { i.name.contains($0) } }
	}

	private func section(_ title: String, _ items: [Item]) -> some View {
		Section {
			grid(items)
		} header: {
			Text(title).font(Theme.smallFont.weight(.semibold)).foregroundStyle(tones.secondary)
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(.horizontal, 4).padding(.top, 10).padding(.bottom, 4)
				.background(tones.surface)
		}
	}

	private func grid(_ items: [Item]) -> some View {
		LazyVGrid(columns: [GridItem(.adaptive(minimum: cell, maximum: cell), spacing: 0)], spacing: 0) {
			ForEach(items, id: \.self) { i in
				Button { choose(i.emoji) } label: {
					Text(i.emoji).font(.system(size: glyph)).frame(width: cell, height: cell)
				}
				.buttonStyle(Cell())
				.help(i.name)
				.accessibilityLabel(i.name)
			}
		}
	}

	private func choose(_ e: String) {
		Self.used(e)
		pick(e)
		dismiss()
	}

	struct Cell: ButtonStyle {
		func makeBody(configuration: Configuration) -> some View { Look(configuration: configuration) }
		struct Look: View {
			@Environment(\.tones) private var tones
			@State private var hover = false
			let configuration: Configuration
			var body: some View {
				configuration.label
					.background(RoundedRectangle(cornerRadius: 7).fill(configuration.isPressed ? tones.pressed : hover ? tones.hover : .clear))
					.contentShape(Rectangle())
					.onHover { hover = $0 }
			}
		}
	}
}
