/// Calls on the iPhone: CallKit shows the ring (and the lock screen's call), baud's own screen
/// covers everything from the moment a call is placed or answered until it's over.
import SwiftUI

struct CallPresenter: ViewModifier {
	@Environment(AppModel.self) private var model
	func body(content: Content) -> some View {
		content.fullScreenCover(item: Binding(get: { shown }, set: { if $0 == nil, let s = model.calls.session, !s.phase.over { model.calls.end() } })) { s in
			CallScreen(session: s).statusBarHidden(s.video && s.phase == .live)
		}
	}
	private var shown: CallCenter.Session? {
		guard let s = model.calls.session else { return nil }
		// The ring is CallKit's (except in a test call, or one the system wouldn't ring).
		if s.phase == .incoming && !CallCenter.test && s.callKit { return nil }
		return s
	}
}
