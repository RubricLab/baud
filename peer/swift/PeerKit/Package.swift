// swift-tools-version:5.9
// The Swift package `PeerKit` (module `PeerKit`, class `Peer`, so apps write `PeerKit.Peer`): UniFFI bindings over the peer crate, with the static library as an
// XCFramework (aarch64 iOS, iOS simulator, macOS). Build it with `scripts/build-swift.sh`.
import PackageDescription

let package = Package(
    name: "PeerKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "PeerKit", targets: ["PeerKit"])],
    targets: [
        .binaryTarget(name: "peerFFI", path: "peerFFI.xcframework"),
        .target(
            name: "PeerKit",
            dependencies: ["peerFFI"],
            path: "Sources/PeerKit",
            linkerSettings: [
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("Network"),
                .linkedFramework("Security"),
                .linkedFramework("CoreFoundation"),
                .linkedLibrary("resolv"),
            ]
        ),
        .testTarget(name: "PeerKitTests", dependencies: ["PeerKit"], path: "Tests/PeerKitTests"),
    ]
)
