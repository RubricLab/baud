/// Disappearing messages: the choice where a conversation's people and name live, and the small
/// timer beside its name while it's on. The core does the rest (BaudCore's Disappear.swift).
import BaudCore
import SwiftUI

/// Off, or how long a message stays after it's read. Anyone in a chat changes it; in a channel
/// only an admin, and everyone else sees it as it is.
struct DisappearPicker: View {
	@Environment(AppModel.self) private var model
	@Environment(\.tones) private var tones
	let conversation: Conversation
	static let choices = [0, 300, 3600, 28_800, 86_400, 604_800, 2_419_200]

	var body: some View {
		let c = conversation
		let can = c.kind != .channel || c.admins.contains(model.me.user)
		let words = c.disappear == 0 ? "Off" : disappearAfter(c.disappear)
		VStack(alignment: .leading, spacing: 4) {
			Menu {
				Picker("Disappearing messages", selection: Binding(get: { c.disappear }, set: { s in model.attempt { try model.core.setDisappear(c.id, s) } })) {
					ForEach(Self.choices, id: \.self) { s in Text(s == 0 ? "Off" : disappearAfter(s)).tag(s) }
				}
				.pickerStyle(.inline).labelsHidden()
			} label: {
				HStack(spacing: 6) {
					Image(systemName: "timer").font(.system(size: 12, weight: .semibold)).foregroundStyle(tones.secondary)
					Text(words).font(Theme.font).foregroundStyle(can ? tones.text : tones.secondary)
					Spacer(minLength: 4)
					if can { Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(tones.secondary) }
				}
				.padding(.horizontal, 6).frame(minHeight: Rows.compact).contentShape(Rectangle())
			}
			.menuIndicator(.hidden).buttonStyle(.plain).disabled(!can)
			.accessibilityLabel("Disappearing messages: \(words)")
			if c.disappear > 0 || !can {
				Text(!can ? "Only an admin can change this." : "New messages go \(disappearAfter(c.disappear)) after they're read.")
					.font(Theme.smallFont).foregroundStyle(tones.secondary).padding(.horizontal, 6)
			}
		}
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
