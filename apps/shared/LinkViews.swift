/// Linking, the existing device's side: a device asking to become mine, its six digits, Add or not.
/// The rest of linking is the Add screen (`AddView.swift`).
import BaudCore
import SwiftUI

/// The digits an existing device compares before taking a new one as its own.
struct AskBody: View {
	@Environment(\.tones) private var tones
	@Environment(AppModel.self) private var model
	let ask: AppModel.LinkAsk
	var body: some View {
		VStack(spacing: 16) {
			DeviceGlyph(shape: ask.kind == "iphone" ? .iphone : ask.kind == "ipad" ? .ipad : .macbook, size: 64)
			Text(ask.name.isEmpty ? ask.what : ask.name).font(Theme.titleFont)
			Text(ask.spaced).font(.system(size: 40, weight: .bold, design: .monospaced))
			HStack(spacing: 10) {
				Button("Not mine") { model.answerLink(ask, accept: false) }.keyboardShortcut(.cancelAction).buttonStyle(Quiet(large: true))
				Button("Add") { model.answerLink(ask, accept: true) }.keyboardShortcut(.defaultAction).buttonStyle(Quiet(strong: true, large: true))
			}
		}
		.frame(maxWidth: .infinity)
		.onAppear { if ProcessInfo.processInfo.environment["BAUD_AUTO_ACCEPT"] != nil { Task { try? await Task.sleep(for: .seconds(4)); model.answerLink(ask, accept: true) } } }
	}
}
