/// Status is a sentence (design.md). Every word the apps show about reachability, delivery and
/// devices is made here, once, so the Mac and the iPhone say the same thing.
import Foundation

public extension Path {
	var sentence: String {
		switch self {
		case .direct(let ms): return ms.map { "Direct, \($0) ms" } ?? "Direct"
		case .relay(_, let name): return "Relayed by \(name)"
		case .nearby: return "Nearby"
		case .waiting: return "Waiting"
		case .unreachable: return "Unreachable"
		case .none: return "Not connected"
		}
	}
	var isLive: Bool { if case .direct = self { return true }; if case .relay = self { return true }; if case .nearby = self { return true }; return false }
}

public extension Device {
	/// "online, direct" · "last online 2 h ago" · "never online"
	var sentence: String {
		if online { return path.isLive ? "online, \(path.sentence.lowercased())" : "online" }
		if let lastOnline { return "last online \(ago(lastOnline))" }
		return "never online"
	}
	/// The word after a name: "Ana's iPhone", "Ben's phone", "Jo's Mac".
	var possessive: String {
		switch kind {
		case .mac: "Mac"
		case .iphone: "iPhone"
		case .android: "phone"
		case .node: "device"
		}
	}
}

public extension Contact {
	/// The row's second line: who is reachable and how.
	var sentence: String {
		let on = devices.filter(\.online)
		if let d = on.first { return on.count > 1 ? "online on \(on.count) devices" : "online on their \(d.possessive)" }
		if let last = lastOnline { return "last online \(ago(last))" }
		return "never online"
	}
}

public extension Delivery {
	/// Under my last message: "read" · "delivered to Ana's iPhone" · "carried by Jo's Mac, waiting for Ana's iPhone" · "sent, nobody online to carry it".
	var sentence: String {
		if devices.isEmpty { return "only you" }
		var read: [String] = [], delivered: [String] = [], carried: [String] = [], waiting: [String] = []
		var readUsers = Set<String>(), carriers = Set<String>()
		for d in devices {
			let who = "\(d.personName)'s \(d.device.possessive)"
			switch d.state {
			case .read: if !readUsers.contains(d.personName) { readUsers.insert(d.personName); read.append(d.personName) }
			case .delivered: delivered.append(who)
			case .carried: for c in d.carriers where !carriers.contains(c) { carriers.insert(c); carried.append(c) }; waiting.append(who)
			case .sent: waiting.append(who)
			}
		}
		let people = Set(devices.map(\.personName)).count
		var parts: [String] = []
		if !read.isEmpty { parts.append(people == 1 ? "read" : "read by \(list(read))") }
		// A device that is read doesn't need to be listed as delivered or waiting.
		let unread = devices.filter { !readUsers.contains($0.personName) }
		if !unread.isEmpty {
			let del = unread.filter { $0.state == .delivered }.map { "\($0.personName)'s \($0.device.possessive)" }
			if !del.isEmpty { parts.append("delivered to \(list(del))") }
			if !carried.isEmpty { parts.append("carried by \(list(carried))") }
			let wait = unread.filter { if case .delivered = $0.state { return false }; return true }.map { "\($0.personName)'s \($0.device.possessive)" }
			if !wait.isEmpty { parts.append("waiting for \(list(wait))") }
		}
		if parts.isEmpty { return "sent" }
		if read.isEmpty, delivered.isEmpty, carried.isEmpty { return "sent, nobody online to carry it" }
		return parts.joined(separator: " · ")
	}
	/// One word for the row: read > delivered > carried > sent.
	var best: DeliveryState {
		if devices.contains(where: { $0.state == .read }) { return .read }
		if devices.contains(where: { $0.state == .delivered }) { return .delivered }
		if let c = devices.first(where: { if case .carried = $0.state { return true }; return false }) { return c.state }
		return .sent
	}
}

public extension Peer {
	/// The Network screen's row: "Ana's Mac · online, direct, 14 ms · record 3 s old via invite · holding 2 for you".
	var sentence: String {
		var parts = [device.sentence]
		if let recordAge { parts.append("record \(recordAge < 1 ? "fresh" : ago(Date().addingTimeInterval(-recordAge)))" + (foundBy.map { " via \($0.rawValue)" } ?? "")) }
		if relaying { parts.append("relaying") }
		if holdingForMe > 0 { parts.append("holding \(holdingForMe) for you") }
		if iHoldForIt > 0 { parts.append("you hold \(iHoldForIt) for it") }
		return parts.joined(separator: " · ")
	}
}

public extension Carrying {
	var sentence: String {
		if envelopes == 0 { return "Holding nothing for anyone right now." }
		let who = held.map { "\($0.count) for \($0.name)" }
		return "Holding \(envelopes) \(envelopes == 1 ? "envelope" : "envelopes") (\(bytesText(bytes)) of \(bytesText(budgetBytes))): \(list(who))."
	}
}

/// "a, b and c"
public func list(_ items: [String]) -> String {
	switch items.count {
	case 0: return ""
	case 1: return items[0]
	case 2: return "\(items[0]) and \(items[1])"
	default: return items.dropLast().joined(separator: ", ") + " and \(items.last!)"
	}
}

public func ago(_ date: Date) -> String {
	let s = Date().timeIntervalSince(date)
	if s < 45 { return "just now" }
	if s < 5400 { return "\(max(1, Int(s / 60))) min ago" }
	if s < 86_400 { return "\(Int(s / 3600)) h ago" }
	return "\(Int(s / 86_400)) d ago"
}

public func bytesText(_ n: Int) -> String {
	if n < 1000 { return "\(n) B" }
	if n < 1_000_000 { return String(format: "%.0f KB", Double(n) / 1000) }
	if n < 1_000_000_000 { return String(format: "%.1f MB", Double(n) / 1_000_000) }
	return String(format: "%.2f GB", Double(n) / 1_000_000_000)
}
