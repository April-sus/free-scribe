// swift-tools-version: 6.0
import PackageDescription

/// The logic both Apple platforms share: the scribe rules, filler cleanup,
/// history, search, statistics and model selection.
///
/// Its own package rather than a target inside the macOS app, because iOS has to
/// depend on it without dragging AppKit along.
let package = Package(
    name: "WhisperFlowCore",
    platforms: [.macOS(.v14), .iOS(.v16)],
    products: [
        .library(name: "WhisperFlowCore", targets: ["WhisperFlowCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
    ],
    targets: [
        .target(
            name: "WhisperFlowCore",
            dependencies: [.product(name: "WhisperKit", package: "WhisperKit")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "WhisperFlowCoreTests",
            dependencies: ["WhisperFlowCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
