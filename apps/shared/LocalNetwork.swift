/// The local network permission (iOS, and macOS since 15), asked at first launch: a Bonjour
/// service of our own, published and browsed for (the browse raises the prompt). Finding it means
/// granted; a policy refusal means denied. Kept running so a change in Settings shows when the app
/// comes back. Refused, baud reaches no device on the same network by its local address: 0.2.4
/// was refused on Dexter's Mac, Mac mini and iPhone, and none of them met.
import Network
import Foundation
import dnssd
#if os(iOS)
import UIKit
#else
import AppKit
#endif

@MainActor final class LocalNetwork {
	static let shared = LocalNetwork()
	/// true granted, false denied.
	var onChange: ((Bool) -> Void)?
	private var browser: NWBrowser?
	private var listener: NWListener?
	private let name = "baud-" + UUID().uuidString.prefix(8)

	func probe() {
		browser?.cancel(); listener?.cancel()
		let l = try? NWListener(using: .udp)
		l?.service = NWListener.Service(name: name, type: "_baud._udp")
		l?.newConnectionHandler = { $0.cancel() }
		l?.stateUpdateHandler = { _ in }
		l?.start(queue: .main)
		listener = l
		let b = NWBrowser(for: .bonjour(type: "_baud._udp", domain: nil), using: .udp)
		b.stateUpdateHandler = { [weak self] state in
			if case .waiting(let e) = state, case .dns(let code) = e, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
				Task { @MainActor in Measure.log("local network: denied"); self?.onChange?(false) }
			}
		}
		b.browseResultsChangedHandler = { [weak self] results, _ in
			guard let self else { return }
			let me = self.name
			if results.contains(where: { if case .service(let n, _, _, _) = $0.endpoint { return n == me }; return false }) {
				Task { @MainActor in Measure.log("local network: granted"); self.onChange?(true) }
			}
		}
		b.start(queue: .main)
		browser = b
	}

	/// Why baud asks, the reason the issue gives (the system prompt says the same, project.yml).
	/// Devices on one Wi-Fi meet at their local addresses; a router that doesn't loop its public
	/// address back inside (Dexter's refused it over TCP and UDP) leaves no other way there.
	static var why: String {
		#if os(iOS)
		"baud needs it to reach your devices on the same Wi-Fi, like your Mac at home. Away from home it isn't used."
		#else
		"baud needs it to reach your devices on the same network, like your iPhone at home. Away from home it isn't used."
		#endif
	}

	/// Where the switch is, for when the button lands one page short.
	static var path: String {
		#if os(iOS)
		"Settings → baud → Local Network"
		#else
		"System Settings → Privacy & Security → Local Network → baud"
		#endif
	}

	/// Where the permission is changed: baud's page in Settings on the iPhone, Privacy & Security →
	/// Local Network on the Mac.
	static func openSettings() {
		#if os(iOS)
		if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
		#else
		if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") { NSWorkspace.shared.open(u) }
		#endif
	}
}
