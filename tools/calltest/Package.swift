// swift-tools-version:6.0
// A call between two real peer nodes in one process, with synthetic voice and video: no camera,
// no microphone, no window, no router mapping, nobody's data. `swift run calltest [seconds] [drop]`.
// `Lab` is the path shaper and the latency barcode; `Legacy` is the media of baud 0.2.15, for the
// "before" and for proving a new client still talks to an old one.
import PackageDescription

let package = Package(
	name: "calltest",
	platforms: [.macOS(.v14)],
	dependencies: [.package(path: "../../BaudCore"), .package(path: "../../peer/swift/PeerKit")],
	targets: [
		.target(name: "Lab", path: "Sources/Lab"),
		.target(name: "Legacy", dependencies: ["Lab", "PeerKit"], path: "Sources/Legacy",
			swiftSettings: [.swiftLanguageMode(.v5)]),
		.executableTarget(name: "calltest", dependencies: ["BaudCore", "PeerKit", "Lab", "Legacy"], path: "Sources/calltest",
			swiftSettings: [.swiftLanguageMode(.v5)]),
	]
)
