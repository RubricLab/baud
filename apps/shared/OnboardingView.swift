/// First run: a face and a name, then the Add screen. Nothing else.
import BaudCore
import PhotosUI
import SwiftUI

struct OnboardingView: View {
	@Environment(\.tones) private var tones
	@Environment(AppModel.self) private var model
	@State private var name = ""
	/// The photo picked before there is a card to put it on: set with the name.
	@State private var face: URL?
	@FocusState private var focused: Bool

	var body: some View {
		VStack(spacing: 20) {
			if model.join != nil || model.named {
				// A link opened on first run asks for the name itself; once named, the Add screen.
				Spacer(minLength: 0)
				AddView()
				#if DEBUG
				if model.demo == nil { Button("Demo") { model.onboarded = true; model.startDemo() }.buttonStyle(Quiet()) }
				#endif
				Spacer(minLength: 0)
			} else {
				Spacer()
				FaceSlot(name: name, face: $face).padding(.bottom, 12)
				TextField("", text: $name, prompt: Text("Your name").foregroundStyle(tones.secondary))
					.textFieldStyle(.plain).font(.system(size: Theme.title, weight: .semibold)).multilineTextAlignment(.center)
					.padding(14).background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(tones.field).lifted(tones)).frame(maxWidth: 320)
					.focused($focused).onSubmit(go)
				Button("Continue", action: go).buttonStyle(Quiet(strong: true, large: true)).keyboardShortcut(.defaultAction)
					.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
				// baud on another device already: scan its link, no name needed.
				Button { model.join = AppModel.Join(link: nil) } label: { Label("Scan", systemImage: "qrcode.viewfinder") }.buttonStyle(Quiet())
				if let f = model.openFailure { Text(f).font(Theme.smallFont).foregroundStyle(tones.secondary) }
				Spacer()
			}
		}
		.padding(24)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.overlay(alignment: .topTrailing) {
			if model.named { Button("Later") { model.onboarded = true; model.join = nil; model.refreshAll() }.buttonStyle(Quiet()).padding(16) }
		}
		.background(tones.surface.ignoresSafeArea())
		.onAppear { focused = model.join == nil }
		// `BAUD_DOOR=friend|device|paste` opens that side of the Add screen once the name is in, for the smoke.
		.onChange(of: model.named, initial: true) { _, n in if n, model.offer == nil, model.join == nil, let d = ProcessInfo.processInfo.environment["BAUD_DOOR"] { Task { try? await Task.sleep(for: .seconds(2)); model.door(d) } } }
	}
	private func go() {
		model.setName(name.trimmingCharacters(in: .whitespaces))
		if model.named, let face { model.attempt { try model.core.setAvatar(face) } }
	}
}

/// Your face on first run: your initials as you type, your photo once you pick one (a tap).
private struct FaceSlot: View {
	@Environment(\.tones) private var tones
	let name: String
	@Binding var face: URL?
	@State private var picking = false
	@State private var photo: PhotosPickerItem?
	@State private var shown: Image?
	private let size: CGFloat = 104

	var body: some View {
		let slot = ZStack(alignment: .bottomTrailing) {
			Group {
				if let shown { shown.resizable().scaledToFill() }
				else {
					Circle().fill(tones.face).overlay {
						if initials.isEmpty { Image(systemName: "person.fill").font(.system(size: size * 0.4)).foregroundStyle(tones.onFace) }
						else { Text(initials).font(.system(size: size * 0.4, weight: .heavy, design: .rounded)).foregroundStyle(tones.onFace) }
					}
				}
			}
			.frame(width: size, height: size).clipShape(Circle())
			Image(systemName: "camera.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(tones.onLoud)
				.frame(width: 34, height: 34).background(Circle().fill(tones.loud)).overlay(Circle().strokeBorder(tones.surface, lineWidth: 3))
		}
		// The whole face is the button: Photos on the phone, a file on the Mac.
		Group {
			#if os(iOS)
			PhotosPicker(selection: $photo, matching: .images) { slot }
			#else
			Button { picking = true } label: { slot }.buttonStyle(.plain)
			#endif
		}
		.accessibilityLabel(shown == nil ? "Add a photo" : "Change photo")
		.onChange(of: photo) { _, item in Task { await take(item) } }
		.fileImporter(isPresented: $picking, allowedContentTypes: [.image]) { r in
			guard case .success(let url) = r, url.startAccessingSecurityScopedResource() else { return }
			defer { url.stopAccessingSecurityScopedResource() }
			keep(try? Data(contentsOf: url))
		}
	}

	private var initials: String { name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased() }

	private func take(_ item: PhotosPickerItem?) async { keep(try? await item?.loadTransferable(type: Data.self)) }
	/// A copy of its own, so the picker's file can go: shown now, set with the name.
	private func keep(_ data: Data?) {
		guard let data else { return }
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("face-\(UUID().uuidString).jpg")
		guard (try? data.write(to: url)) != nil, let cg = downscaled(url, maxPixels: 400) else { return }
		face = url
		shown = Image(decorative: cg, scale: 2)
	}
}
