// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WhisperFlow",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../core"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "WhisperFlow",
            dependencies: [
                .product(name: "WhisperFlowCore", package: "core"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
