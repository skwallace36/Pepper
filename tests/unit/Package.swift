// swift-tools-version: 5.9
// Unit tests for PepperCommand types and dispatcher routing.
// Runs on macOS — no iOS simulator required.
import PackageDescription

let package = Package(
    name: "PepperUnitTests",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "PepperCore",
            path: "Sources/PepperCore"
        ),
        .testTarget(
            name: "PepperCoreTests",
            dependencies: ["PepperCore"],
            path: "Tests/PepperCoreTests"
        ),
    ]
)
