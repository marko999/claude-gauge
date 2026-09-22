// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeGauge",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "ClaudeGauge", targets: ["ClaudeGauge"]),
        .executable(name: "ClaudeGaugeCoreTests", targets: ["ClaudeGaugeCoreTests"]),
        .library(name: "ClaudeGaugeCore", targets: ["ClaudeGaugeCore"]),
    ],
    targets: [
        .target(
            name: "ClaudeGaugeCore",
            path: "Sources/ClaudeGaugeCore"
        ),
        .executableTarget(
            name: "ClaudeGauge",
            dependencies: ["ClaudeGaugeCore"],
            path: "Sources/ClaudeGauge",
            linkerSettings: [
                .linkedFramework("Carbon"),
            ]
        ),
        // CLT-only environments lack XCTest; use a small assert runner instead.
        .executableTarget(
            name: "ClaudeGaugeCoreTests",
            dependencies: ["ClaudeGaugeCore"],
            path: "Tests/ClaudeGaugeCoreTests"
        ),
    ]
)
