/// Disappearing messages: the choice where a conversation's people and name live, and the small
/// timer beside its name while it's on. The core does the rest (BaudCore's Disappear.swift).
import BaudCore
import SwiftUI

/// Disappearing messages as a section of a chat's details: the choice in a card, and under it what
/// it means, or who may change it.
struct DisappearCard: View {
	@Environment(AppModel.self) private var model
	let conversation: Conversation
	var body: some View {
		let c = conversation
		let can = c.kind != .channel || c.admins.contains(model.me.user)
		ListCard(title: "Disappearing messages", footer: !can ? "Only an admin can change this." : c.disappear > 0 ? "New messages go \(disappearAfter(c.disappear)) after they're read." : nil) {
			DisappearPicker(conversation: c).cardRow()
		}
	}
}

/// Off, or how long a message stays after it's read. Anyone in a chat changes it; in a channel
/// only an admin, and everyone else sees it as it is. A row of a card: its glyph, its words, and the
/// choices on a click.
struct DisappearPicker: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	let conversation: Conversation
	static let choices = [0, 300, 3600, 28_800, 86_400, 604_800, 2_419_200]

	var body: some View {
		let c = conversation
		let can = c.kind != .channel || c.admins.contains(model.me.user)
		let words = c.disappear == 0 ? "Off" : disappearAfter(c.disappear)
		Menu {
			Picker("Disappearing messages", selection: Binding(get: { c.disappear }, set: { s in model.attempt { try model.core.setDisappear(c.id, s) } })) {
				ForEach(Self.choices, id: \.self) { s in Text(s == 0 ? "Off" : disappearAfter(s)).tag(s) }
			}
			.pickerStyle(.inline).labelsHidden()
		} label: {
			HStack(spacing: Rows.gap) {
				Image(systemName: "timer").font(Icon.font(Icon.row)).foregroundStyle(tones.secondary).frame(width: Rows.personFace)
				VStack(alignment: .leading, spacing: 2) {
					Text("Disappearing messages").font(Theme.font.weight(.medium)).foregroundStyle(tones.text)
					Text(!can ? "\(words) · only an admin can change this" : c.disappear == 0 ? "Off" : "New messages go \(disappearAfter(c.disappear)) after they're read").font(Theme.smallFont).foregroundStyle(tones.secondary).fixedSize(horizontal: false, vertical: true)
				}
				Spacer(minLength: 4)
				if can { Image(systemName: "chevron.up.chevron.down").font(Icon.font(Icon.inline)).foregroundStyle(tones.secondary) }
			}
			.frame(minHeight: Rows.person).contentShape(Rectangle())
		}
		.menuIndicator(.hidden).buttonStyle(.plain).disabled(!can)
		.accessibilityLabel("Disappearing messages: \(words)")
	}
}

/// Beside a conversation's name while its messages disappear: a timer and how long, "1d".
struct DisappearMark: View {
	@Environment(\.tones) private var tones
	let seconds: Int
	var body: some View {
		HStack(spacing: 2) {
			Image(systemName: "timer").font(.system(size: 10, weight: .bold))
			Text(disappearShort(seconds)).font(Theme.smallFont.weight(.semibold)).monospacedDigit()
		}
		.foregroundStyle(tones.secondary)
		.help("Messages disappear \(disappearAfter(seconds)) after they're read")
		.accessibilityElement(children: .ignore)
		.accessibilityLabel("Messages disappear \(disappearAfter(seconds)) after they're read")
	}
}
