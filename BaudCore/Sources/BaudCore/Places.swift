/// Where I am, for the people in a chat I chose to share it with, and where they are for me. A
/// share is per chat and has an end (an hour, the end of the day, or when I stop). Each fix goes
/// straight to the chat's online devices, sealed with the chat's key like a message, and is never
/// carried, logged in the chat's history, or sent anywhere else: a place is news now or never, and
/// a device that comes online gets the latest at once. Nobody who isn't in the chat ever has it.
import Foundation

public struct Place: Codable, Hashable, Sendable {
	public var user: UserId
	public var device: DeviceId
	public var lat: Double, lon: Double
	/// Metres either way.
	public var accuracy: Double
	/// When the fix was taken.
	public var at: Double
	/// When the share ends; nil, until it's stopped. A stop is a place whose end has passed.
	public var until: Double?
	public var over: Bool { (until ?? .infinity) <= Date().timeIntervalSince1970 }
	public var date: Date { Date(timeIntervalSince1970: at) }
}

extension LocalCore {
	/// Share my location in this chat until then (nil, until I stop). The last fix goes at once.
	public func share(place conv: ConversationId, until: Date?) {
		lock.withLock { store.run("insert or replace into me(k,v) values(?,?)", ["share:" + conv, until.map { String($0.timeIntervalSince1970) } ?? "always"]) }
		trace("sharing my location in \(conv.prefix(8)) \(until.map { "until \($0)" } ?? "until I stop")")
		emit(.places(conv))
		sendPlace(conv)
	}

	/// Stop sharing in this chat: everyone in it hears so, and my pin goes from their maps.
	public func stopSharing(_ conv: ConversationId) {
		guard sharing()[conv] != nil else { return }
		lock.withLock { store.run("delete from me where k=?", ["share:" + conv]) }
		if let fix = lock.withLock({ lastFix }) {
			let stop = Place(user: user, device: device, lat: fix.lat, lon: fix.lon, accuracy: fix.accuracy, at: Date().timeIntervalSince1970, until: Date().timeIntervalSince1970 - 1)
			post(place: stop, conv: conv, to: nil)
		}
		emit(.places(conv))
	}

	/// The chats I share my location in, and until when (distantFuture: until I stop). A share
	/// whose time is up is gone.
	public func sharing() -> [ConversationId: Date] {
		let rows = lock.withLock { store.query("select k, v from me where k like 'share:%'") }
		var out: [ConversationId: Date] = [:]
		let now = Date()
		for r in rows {
			guard let k = r.string("k"), let v = r.string("v") else { continue }
			let conv = String(k.dropFirst("share:".count))
			let until = v == "always" ? Date.distantFuture : Date(timeIntervalSince1970: Double(v) ?? 0)
			if until > now { out[conv] = until } else { lock.withLock { store.run("delete from me where k=?", [k]) } }
		}
		return out
	}

	/// A new fix from this device's location service: to every chat I share in.
	public func moved(lat: Double, lon: Double, accuracy: Double) {
		lock.withLock { lastFix = (lat, lon, accuracy, Date().timeIntervalSince1970) }
		for conv in sharing().keys { sendPlace(conv) }
	}

	/// Whether any chat wants my location: the app keeps its location service on only then.
	public var wantsPlace: Bool { !sharing().isEmpty }

	/// The people sharing their location with me in this chat, the latest of each; ended ones gone.
	public func places(_ conv: ConversationId) -> [Place] {
		lock.withLock {
			let all = heldPlaces[conv] ?? [:]
			let live = all.filter { !$0.value.over }
			if live.count != all.count { heldPlaces[conv] = live }
			return live.values.sorted { $0.at > $1.at }
		}
	}

	/// The latest fix to this chat's online devices (or just `to`, one that came online).
	func sendPlace(_ conv: ConversationId, to only: DeviceId? = nil) {
		guard let until = sharing()[conv], let fix = lock.withLock({ lastFix }) else { return }
		let p = Place(user: user, device: device, lat: fix.lat, lon: fix.lon, accuracy: fix.accuracy, at: fix.at, until: until == .distantFuture ? nil : until.timeIntervalSince1970)
		post(place: p, conv: conv, to: only)
	}

	private func post(place p: Place, conv: ConversationId, to only: DeviceId?) {
		guard online else { return }
		for d in memberDevices(conv) where d != device && (only == nil || d == only) {
			if let t = transport, t.isOnline(d) { let bytes = seal(.place(conv, p), conv: conv); Task { _ = await t.send(bytes, to: d) } }
			else { mesh?.send(.place(conv, p), from: device, to: d) }
		}
	}

	/// A member's place: kept until their share ends, gone when they stop.
	func keep(place p: Place, conv: ConversationId, from: DeviceId) {
		guard user(of: from) == p.user, p.device == from, isMember(conv),
			  lock.withLock({ store.int("select count(*) as n from members where conv=? and user=?", [conv, p.user]) > 0 }) else { return }
		lock.withLock {
			if p.over { heldPlaces[conv]?.removeValue(forKey: p.user) }
			else if (heldPlaces[conv]?[p.user]?.at ?? 0) <= p.at { heldPlaces[conv, default: [:]][p.user] = p }
		}
		emit(.places(conv))
	}

	/// A device came online: the chats I share in that it's part of get my latest fix now.
	func placesOnConnect(_ d: DeviceId) {
		for conv in sharing().keys where memberDevices(conv).contains(d) { sendPlace(conv, to: d) }
	}
}
