/// Friends, a page of their own (not in Settings, nowhere near adding a device): adding one, a map
/// of everyone sharing where they are with me, and each friend, who opens to their page. And
/// verifying a friend: compare safety numbers in the room.
import BaudCore
import SwiftUI

struct FriendsPage: View {
	@Environment(\.tones) private var tones
	@Environment(AppModel.self) private var model
	@State private var open: UserId?
	@State private var removing: Contact?
	var body: some View {
		VStack(spacing: 0) {
			#if os(macOS)
			SheetHeader(title: "Friends", close: { model.pane = nil }, help: "Back")
			#endif
			ScrollView {
				VStack(alignment: .leading, spacing: Space.section) {
					ListCard {
						Button { model.offer = .friend } label: { ActionRow(symbol: "person.badge.plus", title: "Add a friend") }.buttonStyle(RowStyle())
					}
					let places = model.livePlaces
					if !places.isEmpty {
						VStack(alignment: .leading, spacing: Space.title) {
							SectionTitle(places.count == 1 ? "Sharing where they are" : "\(places.count) sharing where they are")
							PlacesMap(places: places)
								.frame(height: 300)
								.clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
						}
					}
					ListCard(title: model.contacts.count == 1 ? "1 friend" : "\(model.contacts.count) friends", footer: model.contacts.isEmpty ? "Friends are people you've met: one scans the other's code, or opens their link." : nil) {
						ForEach(model.contacts.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { k in row(k) }
					}
				}
				.padding(.horizontal, Space.side).padding(.vertical, Space.section)
				.frame(maxWidth: 720).frame(maxWidth: .infinity)
			}
		}
		.background(tones.surface.ignoresSafeArea())
		.modifier(RemoveFriendQuestion(removing: $removing))
		#if os(iOS)
		.navigationTitle("Friends").navigationBarTitleDisplayMode(.inline)
		.modifier(Bars())
		#endif
	}

	@ViewBuilder private func row(_ k: Contact) -> some View {
		let r = PersonRow(name: k.name, hash: k.avatar, presence: Mark.presence(k.devices), detail: presenceWord(k.devices).capitalizedFirst, verified: k.verified) {
			#if os(iOS)
			Image(systemName: "chevron.right").font(Icon.font(Icon.inline)).foregroundStyle(tones.tertiary)
			#endif
		}
		#if os(iOS)
		NavigationLink(value: PersonLink(user: k.user)) { r }.buttonStyle(RowStyle())
			.contextMenu { FriendMenu(friend: k, removing: $removing) }
		#else
		Button { open = k.user } label: { r }
			.buttonStyle(RowStyle())
			.popover(isPresented: Binding(get: { open == k.user }, set: { if !$0 { open = nil } }), arrowEdge: .trailing) { PersonPage(user: k.user).frame(width: 360, height: 600) }
			.contextMenu { FriendMenu(friend: k, removing: $removing) }
		#endif
	}
}

/// Compare safety numbers in the room. A match pins the key; a later change is shown as a break.
struct VerifySheet: View {
	@Environment(\.tones) private var tones
	@Environment(AppModel.self) private var model
	@Environment(\.dismiss) private var dismiss
	let contact: Contact
	@State private var result: String?
	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Verify \(contact.name)").font(Theme.font.weight(.semibold))
			Text(contact.fingerprint).font(Theme.mono).textSelection(.enabled)
			QRCode(text: contact.fingerprint).frame(width: 160, height: 160)
			Text("Yours: \(model.me.fingerprint)").font(Theme.mono).foregroundStyle(tones.secondary)
			if let result { Text(result).font(Theme.smallFont) }
			HStack {
				Button("They match") { model.attempt { result = try model.core.verify(contact.user, fingerprint: contact.fingerprint) ? "Verified." : "They don't match." } }
				Spacer()
				Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
				Button("") { dismiss() }.keyboardShortcut(.cancelAction).hidden()
			}
		}
		.padding(20).frame(width: 360)
	}
}
