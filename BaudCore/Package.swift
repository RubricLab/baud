// swift-tools-version:6.0
import PackageDescription

let package = Package(
	name: "BaudCore",
	platforms: [.iOS(.v17), .macOS(.v14)],
	products: [.library(name: "BaudCore", targets: ["BaudCore"])],
	targets: [
		.target(name: "BaudCore", path: "Sources/BaudCore"),
		.testTarget(name: "BaudCoreTests", dependencies: ["BaudCore"], path: "Tests/BaudCoreTests"),
	],
	swiftLanguageModes: [.v5]
)
