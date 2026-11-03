/// What shows while baud can't show itself yet: its mark on the colour, coming up gently (a quick
/// open never sees it flash), and, on an iPhone not unlocked since it restarted, the one thing to do.
import SwiftUI

struct LaunchView: View {
	@Environment(\.tones) private var tones
	var locked = false
	@State private var shown = false
	var body: some View {
		ZStack {
			Ground()
			VStack(spacing: 22) {
				BaudTile().scaleEffect(1.8).frame(width: 80, height: 80)
				if locked {
					Text("Unlock your iPhone to open baud").font(Theme.font).foregroundStyle(tones.secondary)
				}
			}
			.opacity(shown ? 1 : 0)
			.scaleEffect(shown ? 1 : 0.96)
		}
		.task {
			try? await Task.sleep(for: .milliseconds(200))
			withAnimation(.easeOut(duration: 0.35)) { shown = true }
		}
		.accessibilityElement(children: .combine)
		.accessibilityLabel(locked ? "baud. Unlock your iPhone to open baud." : "baud is opening")
	}
}
