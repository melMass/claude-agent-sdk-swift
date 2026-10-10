// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeAgentSDK",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ClaudeAgentSDK", targets: ["ClaudeAgentSDK"]),
    ],
    targets: [
        .target(name: "ClaudeAgentSDK"),
        // A stand-in for the `claude` CLI that replays a scripted NDJSON conversation; used by the tests.
        .executableTarget(name: "FakeClaude", dependencies: ["ClaudeAgentSDK"], path: "Sources/FakeClaude"),
        .testTarget(name: "ClaudeAgentSDKTests", dependencies: ["ClaudeAgentSDK", "FakeClaude"]),
    ],
    swiftLanguageModes: [.v6]
)
