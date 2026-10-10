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
    ],
    swiftLanguageModes: [.v6]
)
