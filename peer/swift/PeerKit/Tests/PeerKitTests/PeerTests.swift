import XCTest
@testable import PeerKit

/// Two nodes in one process: ana invites, sam adds, both receive events. The same journey the
/// Rust and Bun tests run, through the Swift package.
final class PeerTests: XCTestCase {
    final class Log: Listener {
        var events: [PeerEvent] = []
        let lock = NSLock()
        func on(event: PeerEvent) { lock.lock(); events.append(event); lock.unlock() }
        func has(_ f: (PeerEvent) -> Bool) -> Bool { lock.lock(); defer { lock.unlock() }; return events.contains(where: f) }
    }

    func testInviteAddAndEvents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("peer-swift-\(UUID().uuidString)")
        func config(_ name: String) -> Config {
            Config(app: "swift", name: name, deviceName: "\(name)-dev", linkScheme: "swift://add", nearby: false, alpns: [], deviceKind: "", vpn: true, portmap: false)
        }
        let ana = try await Peer.open(dir: root.appendingPathComponent("ana").path, keychain: MemoryKeychain(), config: config("ana"))
        let sam = try await Peer.open(dir: root.appendingPathComponent("sam").path, keychain: MemoryKeychain(), config: config("sam"))
        let anaLog = Log(), samLog = Log()
        ana.subscribe(listener: anaLog)
        sam.subscribe(listener: samLog)
        ana.setOnline(online: true)
        sam.setOnline(online: true)

        XCTAssertEqual(ana.inviteMeeting().kind, MeetingKind.none, "no reachable device yet: raw addresses")
        XCTAssertTrue(ana.redirects().isEmpty, "no identity merged yet")
        let link = try ana.invite()
        XCTAssertTrue(link.hasPrefix("swift://add#peer1.f."), link)
        let contact = try await sam.add(link: link)
        XCTAssertEqual(contact.name, "ana")
        try await until("ana sees sam") { ana.contacts().contains { $0.name == "sam" } }
        try await until("online both ways") { ana.contacts().first?.devices.contains { $0.online } == true && sam.contacts().first?.devices.contains { $0.online } == true }
        try await until("events") { anaLog.has { if case .online = $0 { return true }; return false } && samLog.has { if case .contactsChanged = $0 { return true }; return false } }
        if case .direct(let vpn) = sam.contacts().first!.devices.first!.path { XCTAssertFalse(vpn) } else { XCTFail("expected a direct path") }
        XCTAssertEqual(ana.sign(bytes: Data("hi".utf8)).count, 64)
        // A path monitor's change with nothing changed: the connection is checked and kept.
        sam.networkChanged()
        try await Task.sleep(nanoseconds: 300_000_000)
        try await until("still online after a network change") { sam.contacts().first?.devices.contains { $0.online } == true }
        await ana.close()
        await sam.close()
        try? FileManager.default.removeItem(at: root)
    }

    private func until(_ what: String, _ f: () -> Bool) async throws {
        for _ in 0..<100 { if f() { return }; try await Task.sleep(nanoseconds: 50_000_000) }
        XCTFail("timed out waiting for \(what)")
    }
}
