// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeAgentSDK",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ClaudeAgentSDK", targets: ["ClaudeAgentSDK"]),
        .executable(name: "quick-start", targets: ["QuickStart"]),
        .executable(name: "tool-server", targets: ["ToolServer"]),
    ],
    targets: [
        .target(name: "ClaudeAgentSDK"),
        .executableTarget(name: "QuickStart", dependencies: ["ClaudeAgentSDK"], path: "Examples/QuickStart"),
        .executableTarget(name: "ToolServer", dependencies: ["ClaudeAgentSDK"], path: "Examples/ToolServer"),
        // A stand-in for the `claude` CLI that replays a scripted NDJSON conversation; used by the tests.
        .executableTarget(name: "FakeClaude", dependencies: ["ClaudeAgentSDK"], path: "Sources/FakeClaude"),
        .testTarget(name: "ClaudeAgentSDKTests", dependencies: ["ClaudeAgentSDK", "FakeClaude"]),
    ],
    swiftLanguageModes: [.v6]
)
