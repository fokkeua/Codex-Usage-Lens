// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexUsageMenuBar",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "CodexUsageMenuBar",
            targets: ["CodexUsageMenuBar"]
        )
    ],
    targets: [
        .executableTarget(
            name: "CodexUsageMenuBar",
            path: "Sources/CodexUsageMenuBar",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "CodexUsageMenuBarTests",
            dependencies: ["CodexUsageMenuBar"],
            path: "Tests/CodexUsageMenuBarTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
