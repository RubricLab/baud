/// The composer: multiline, markdown in channels, a reply strip, files and photos (picked, dropped
/// or pasted, shown before they go), drafts per conversation. Enter sends on the Mac (shift-enter
/// for a new line); the button on iPhone.
import BaudCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
	@Environment(AppModel.self) private var model
	@Environment(\.accent) private var accent
	@Environment(\.tones) private var tones
	let conv: ConversationId
	var thread: EventId? = nil
	@Binding var reply: Event?
	@State private var text = ""
	@State private var files: [URL] = []
	@State private var importing = false
	@State private var locating = false
	@State private var choosingPhotos = false
	@State private var photos: [PhotosPickerItem] = []
	@State private var editing: Event?
	@State private var mentionIndex = 0
	@FocusState private var focused: Bool
	#if os(iOS)
	@State private var field = ComposerField()
	#endif
	/// Where this composer's draft is kept: the chat, or a thread in it.
	private var draftKey: String { thread == nil ? conv : conv + "/" + (thread ?? "") }

	private var online: Bool { model.core.members(conv).contains { !$0.me && $0.online } }
	/// People who match the @prefix being typed: members of this conversation first.
	private var mentionMatches: [Member] {
		guard let p = Composing.mentionPrefix(text) else { return [] }
		return model.core.members(conv).filter { !$0.me && (p.isEmpty || $0.name.lowercased().hasPrefix(p.lowercased())) }
	}

	var body: some View {
		VStack(spacing: 0) {
			let matches = mentionMatches
			if !matches.isEmpty {
				VStack(alignment: .leading, spacing: 0) {
					ForEach(Array(matches.prefix(6).enumerated()), id: \.element.id) { i, m in
						HStack(spacing: 8) { Avatar(name: m.name, size: 18, presence: Mark.presence(m.devices)); Text(m.name).font(Theme.font); Spacer(); Text(presenceWord(m.devices)).font(Theme.smallFont).foregroundStyle(tones.secondary) }
							.padding(.horizontal, 8).frame(height: Theme.row - 6)
							.background(i == mentionIndex ? tones.hover : Color.clear, in: RoundedRectangle(cornerRadius: Theme.corner))
							.contentShape(Rectangle()).onTapGesture { text = Composing.complete(text, with: m.name) }
					}
				}.padding(.horizontal, 12).padding(.top, 6)
			}
			if let e = editing {
				HStack(spacing: 6) {
					Text("Editing").font(Theme.smallFont).foregroundStyle(tones.secondary)
					Spacer()
					Button { cancelEdit() } label: { Image(systemName: "xmark").font(.system(size: 10)) }.buttonStyle(.plain).foregroundStyle(tones.secondary)
				}.padding(.horizontal, 16).padding(.top, 6)
				.onAppear { _ = e }
			}
			if let r = reply {
				HStack {
					Quote(name: model.name(of: r.user), text: PlaceText.words(r.text) ?? "attachment")
					Spacer()
					Button { reply = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }.buttonStyle(.plain).foregroundStyle(tones.secondary)
				}.padding(.horizontal, 16).padding(.top, 6)
			}
			if !files.isEmpty {
				ScrollView(.horizontal) {
					HStack(spacing: 6) {
						ForEach(files, id: \.self) { f in StagedFile(url: f) { files.removeAll { $0 == f } } }
					}.padding(.horizontal, 16).padding(.top, 8)
				}.scrollIndicators(.never)
			}
			HStack(alignment: .bottom, spacing: 8) {
				#if os(iOS)
				Menu {
					Button { choosingPhotos = true } label: { Label("Photos", systemImage: "photo.on.rectangle") }
					Button { importing = true } label: { Label("Files", systemImage: "folder") }
					Button { locating = true } label: { Label("Location", systemImage: "location") }
				} label: { Image(systemName: "plus").font(.system(size: 14, weight: .semibold)).frame(width: 24, height: PhoneComposerText.line) }
					.foregroundStyle(tones.secondary).accessibilityLabel("Attach")
				#else
				Menu {
					Button { importing = true } label: { Label("Photos and Files…", systemImage: "paperclip") }
					Button { locating = true } label: { Label("Location…", systemImage: "location") }
				} label: { Image(systemName: "plus").font(.system(size: 14, weight: .semibold)) }
					.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
					.foregroundStyle(tones.secondary).frame(width: 24, height: 24)
					.help("Attach files, photos or where you are (or drop or paste files here)")
				#endif
				#if os(macOS)
				MacComposerText(text: $text, placeholder: placeholder, onSend: send,
					onEscape: { if editing != nil { cancelEdit(); return true }; if reply != nil { reply = nil; return true }; return false },
					onUpEmpty: { beginEditLast() },
					onFiles: { files += $0.filter { $0.startAccessingSecurityScopedResource() || true } },
					onArrow: { d in guard !mentionMatches.isEmpty else { return false }; mentionIndex = max(0, min(mentionMatches.prefix(6).count - 1, mentionIndex + d)); return true },
					onAccept: { guard let m = mentionMatches.prefix(6).dropFirst(mentionIndex).first else { return false }; text = Composing.complete(text, with: m.name); mentionIndex = 0; return true },
					focus: focused)
					.onChange(of: text) { _, new in changed(new) }
				Button { NSApp.orderFrontCharacterPalette(nil) } label: { Image(systemName: "face.smiling").font(.system(size: 13)) }
					.buttonStyle(.plain).foregroundStyle(tones.secondary).frame(width: 24, height: 24).help("Emoji (⌃⌘Space); :tada: works too")
				#else
				// One line sits centred on the buttons' height; more lines grow the field upward.
				PhoneComposerText(text: $text, placeholder: placeholder, field: field)
					.onChange(of: text) { _, new in changed(new) }
				#endif
				#if os(iOS)
				Button { send() } label: { Image(systemName: "arrow.up").font(.system(size: 15, weight: .heavy)) }
					.buttonStyle(.plain).frame(width: 30, height: 30)
					.foregroundStyle(tones.onLoud)
					.background(Circle().fill(tones.loud))
					.scaleEffect(text.isEmpty && files.isEmpty ? 0.6 : 1).opacity(text.isEmpty && files.isEmpty ? 0 : 1)
					.animation(.spring(duration: 0.3, bounce: 0.45), value: text.isEmpty && files.isEmpty)
					.disabled(text.isEmpty && files.isEmpty)
					.accessibilityLabel("Send")
				#endif
			}
			.padding(.horizontal, 10).padding(.vertical, 7)
			.background(RoundedRectangle(cornerRadius: 21, style: .continuous).fill(tones.field).lifted(tones))
			.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 14)
		}
		.onAppear {
			text = model.draft(draftKey); focused = Theme.autofocus; Bench.typeInto = { text += $0 }
			#if DEBUG
			// `BAUD_COMPOSE=words` (Debug): typed into the composer, for pictures of it.
			if text.isEmpty, let t = ProcessInfo.processInfo.environment["BAUD_COMPOSE"] { text = t }
			#endif
		}
		.onChange(of: conv) { _, c in text = model.draft(c); focused = Theme.autofocus }
		// Dropped on the conversation, not on the field: staged here all the same.
		.onChange(of: model.dropped[conv], initial: true) { _, urls in
			guard thread == nil, let urls, !urls.isEmpty else { return }
			files += urls.filter { !files.contains($0) }; model.dropped[conv] = nil
		}
		// The model and the colour handed on by name: a sheet from the composer doesn't inherit them.
		.sheet(isPresented: $locating) { LocationSheet(conv: conv).environment(model).environment(\.tones, tones) }
		#if DEBUG
		// `BAUD_LOCATE=1`: the Location sheet opens on the chat, for a picture.
		.task { if ProcessInfo.processInfo.environment["BAUD_LOCATE"] == "1" { try? await Task.sleep(for: .milliseconds(900)); locating = true } }
		#endif
		.fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in
			// Picked by the person: readable here whether or not the URL is security-scoped.
			if case .success(let urls) = r { files += urls.map { _ = $0.startAccessingSecurityScopedResource(); return $0 } }
		}
		.photosPicker(isPresented: $choosingPhotos, selection: $photos, maxSelectionCount: 20, matching: .any(of: [.images, .videos]))
		.onChange(of: photos) { _, items in
			guard !items.isEmpty else { return }
			photos = []
			Task { for i in items { if let p = try? await i.loadTransferable(type: Picked.self) { files.append(p.url) } } }
		}
	}

	private var placeholder: String {
		if let c = model.conversation(conv) { return thread != nil ? "Reply in thread" : c.kind == .channel ? "Message #\(c.name ?? "")" : "Message \(model.title(c))" }
		return "Message"
	}

	private func changed(_ new: String) {
		Measure.keypress()
		let expanded = Composing.expandShortcodes(new)
		if expanded != new { text = expanded; return }
		mentionIndex = 0
		if editing == nil { model.setDraft(draftKey, new) }
		// One typing frame every two seconds while the text keeps changing, not one per keystroke:
		// the other side keeps "is typing" for five seconds after the last frame it saw.
		if !new.isEmpty, Date().timeIntervalSince(typingSent) > 2 { typingSent = Date(); model.core.typing(conv) }
	}
	@State private var typingSent = Date.distantPast

	/// ↑ on an empty composer: my last message comes back to be changed.
	private func beginEditLast() -> Bool {
		guard let last = model.timeline(conv).events.last(where: { $0.mine && $0.type == .message && $0.text != nil }) else { return false }
		editing = last; text = last.text ?? ""
		return true
	}
	private func cancelEdit() { editing = nil; text = model.draft(conv) }

	private func send() {
		#if os(iOS)
		// The keyboard's word in progress belongs to this message, not the next.
		if let typed = field.commit(), typed != text { text = typed }
		#endif
		let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
		if let e = editing {
			guard !t.isEmpty else { return }
			model.attempt { try model.core.edit(conv, e.id, text: t) }
			editing = nil; text = model.draft(conv); return
		}
		guard !t.isEmpty || !files.isEmpty else { return }
		let draft = Draft(text: t, attachments: files, reply: reply?.id, thread: thread, mentions: mentions(in: t))
		// Emptied before it goes, the draft too: a composer drawn afresh as the message lands (a new
		// view of this chat) loaded the old draft and showed the message still waiting to be sent.
		model.setDraft(draftKey, "")
		text = ""; files = []; reply = nil
		#if os(iOS)
		field.clear(sent: t)
		#endif
		model.send(conv, draft)
		Haptic.send()
	}

	private func mentions(in t: String) -> [UserId] {
		model.core.members(conv).filter { !$0.me && t.contains("@\($0.name)") }.map(\.user)
	}
}

enum Haptic {
	static func send() {
		#if os(iOS)
		UIImpactFeedbackGenerator(style: .light).impactOccurred()
		#endif
	}
}

/// A file waiting in the composer: a photo as a small picture, anything else as its name; × takes it back.
private struct StagedFile: View {
	@Environment(\.tones) private var tones
	let url: URL
	let remove: () -> Void
	@State private var thumb: Image?
	private var isImage: Bool { UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .image) == true }
	var body: some View {
		Group {
			if isImage {
				RoundedRectangle(cornerRadius: 8).fill(tones.quiet).frame(width: 56, height: 56)
					.overlay { if let thumb { thumb.resizable().scaledToFill() } }
					.clipShape(RoundedRectangle(cornerRadius: 8))
					.overlay(RoundedRectangle(cornerRadius: 8).stroke(tones.hairline))
					.task { if let cg = await Task.detached(operation: { downscaled(url, maxPixels: 200) }).value { thumb = Image(decorative: cg, scale: 2) } }
			} else {
				HStack(spacing: 6) {
					Image(systemName: "doc").font(.system(size: Theme.small)).foregroundStyle(tones.secondary)
					Text(url.lastPathComponent).font(Theme.smallFont).lineLimit(1).truncationMode(.middle).frame(maxWidth: 180, alignment: .leading)
				}
				.padding(.horizontal, 10).frame(height: 56)
				.background(RoundedRectangle(cornerRadius: 8).fill(tones.raised))
				.overlay(RoundedRectangle(cornerRadius: 8).stroke(tones.hairline))
			}
		}
		.overlay(alignment: .topTrailing) {
			Button(action: remove) {
				Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(tones.text)
					.frame(width: 18, height: 18).background(Circle().fill(tones.surface)).overlay(Circle().stroke(tones.hairline))
			}
			.buttonStyle(.plain).offset(x: 6, y: -6).accessibilityLabel("Remove \(url.lastPathComponent)")
		}
		.padding(.top, 6).padding(.trailing, 6)
	}
}

/// A photo or video from the library, copied out to a file of its own (its own name and type).
struct Picked: Transferable {
	let url: URL
	static var transferRepresentation: some TransferRepresentation {
		FileRepresentation(importedContentType: .movie) { Picked(url: try copyIn($0.file)) }
		FileRepresentation(importedContentType: .image) { Picked(url: try copyIn($0.file)) }
	}
	static func copyIn(_ file: URL) throws -> URL {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("picked-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		let to = dir.appendingPathComponent(file.lastPathComponent)
		try FileManager.default.copyItem(at: file, to: to)
		return to
	}
}
