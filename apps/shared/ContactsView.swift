/// Verifying a friend: compare safety numbers in the room. Friends themselves live in Settings and
/// in Home; this is the one sheet both open.
import BaudCore
import SwiftUI

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
