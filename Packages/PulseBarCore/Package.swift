// swift-tools-version:6.2
// PulseBarCore: models, storage, metrics, Google client and BLE parsing.
// No UI code lives here, so both the menu-bar app and the `pulsebar-mcp`
// executable can share it, and it can be tested with plain `swift test`.

import PackageDescription

let package = Package(
    name: "PulseBarCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PulseBarCore", targets: ["PulseBarCore"]),
    ],
    dependencies: [
        // SQLite toolkit. MIT. Requires Swift 6.1+ / Xcode 16.3+.
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.12.0"),
    ],
    targets: [
        .target(
            name: "PulseBarCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "PulseBarCoreTests",
            dependencies: ["PulseBarCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
