// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WhisperFlow",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "WhisperFlowCore",
            dependencies: [.product(name: "WhisperKit", package: "WhisperKit")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "WhisperFlow",
            dependencies: [
                "WhisperFlowCore",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "WhisperFlowTests",
            dependencies: ["WhisperFlowCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
