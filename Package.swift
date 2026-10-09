// swift-tools-version: 6.0
import PackageDescription

let settings: [SwiftSetting] = [.swiftLanguageMode(.v6), .enableExperimentalFeature("StrictConcurrency")]
let package = Package(
    name: "AgentExecutionKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "AgentExecutionKit", targets: ["AgentExecutionKit"]),
        .library(name: "AgentProcessSupport", targets: ["AgentProcessSupport"]),
        .library(name: "AgentCodexClient", targets: ["AgentCodexClient"]),
        .library(name: "AgentClaudeProtocol", targets: ["AgentClaudeProtocol"]),
        .library(name: "AgentCLIExecution", targets: ["AgentCLIExecution"]),
        .library(name: "AgentHeadlessContracts", targets: ["AgentHeadlessContracts"]),
        .library(name: "AgentCodexExec", targets: ["AgentCodexExec"]),
        .library(name: "AgentClaudeHeadless", targets: ["AgentClaudeHeadless"]),
        .library(name: "AgentGeminiHeadless", targets: ["AgentGeminiHeadless"]),
        .library(name: "AgentACPHeadless", targets: ["AgentACPHeadless"]),
        .library(name: "AgentNativeProcessTransport", targets: ["AgentNativeProcessTransport"])
    ],
    dependencies: [
        .package(url: "https://github.com/ajmcclary/ProcessKit.git", .upToNextMinor(from: "0.1.0-beta.5")),
        .package(url: "https://github.com/ajmcclary/AgentRuntimeKit.git", .upToNextMinor(from: "0.1.0-beta.2")),
        .package(url: "https://github.com/ajmcclary/CodexRuntimeKit.git", .upToNextMinor(from: "0.1.0-beta.4")),
        .package(url: "https://github.com/ajmcclary/CodexAppServerKit.git", .upToNextMinor(from: "0.1.0-beta.4")),
        .package(url: "https://github.com/ajmcclary/ClaudeRuntimeKit.git", .upToNextMinor(from: "0.1.0-beta.3")),
        .package(url: "https://github.com/ajmcclary/AIClientKit.git", .upToNextMinor(from: "0.1.0-beta.9"))
    ],
    targets: [
        .target(name: "AgentProcessSupport", dependencies: [.product(name: "ProcessKit", package: "ProcessKit")], swiftSettings: settings),
        .target(name: "AgentCodexClient", dependencies: [
            .product(name: "AgentRuntimeKit", package: "AgentRuntimeKit"),
            .product(name: "CodexRuntimeKit", package: "CodexRuntimeKit"),
            .product(name: "CodexAppServerKit", package: "CodexAppServerKit"),
            .product(name: "ProcessKit", package: "ProcessKit")
        ], swiftSettings: settings),
        .testTarget(name: "AgentCodexClientTests", dependencies: [
            "AgentCodexClient",
            .product(name: "CodexRuntimeKit", package: "CodexRuntimeKit"),
            .product(name: "CodexAppServerKit", package: "CodexAppServerKit"),
            .product(name: "ProcessKit", package: "ProcessKit")
        ], swiftSettings: settings),
        .target(name: "AgentClaudeProtocol", dependencies: [
            .product(name: "AgentRuntimeKit", package: "AgentRuntimeKit"),
            .product(name: "ClaudeRuntimeKit", package: "ClaudeRuntimeKit"),
            .product(name: "AIClientKit", package: "AIClientKit"),
            .product(name: "ProcessStreamFraming", package: "ProcessKit")
        ], swiftSettings: settings),
        .testTarget(name: "AgentClaudeProtocolTests", dependencies: [
            "AgentClaudeProtocol",
            .product(name: "ClaudeRuntimeKit", package: "ClaudeRuntimeKit"),
            .product(name: "AIClientKit", package: "AIClientKit")
        ], swiftSettings: settings),
        .target(name: "AgentCLIExecution", dependencies: [
            .product(name: "ProcessKit", package: "ProcessKit"),
            .product(name: "ProcessStreamFraming", package: "ProcessKit")
        ], swiftSettings: settings),
        .testTarget(name: "AgentCLIExecutionTests", dependencies: ["AgentCLIExecution", .product(name: "ProcessKit", package: "ProcessKit")], swiftSettings: settings),
        .target(name: "AgentHeadlessContracts", dependencies: [.product(name: "AIClientKit", package: "AIClientKit")], swiftSettings: settings),
        .target(name: "AgentCodexExec", dependencies: ["AgentHeadlessContracts", "AgentCLIExecution", .product(name: "AIClientKit", package: "AIClientKit"), .product(name: "ProcessStreamFraming", package: "ProcessKit")], swiftSettings: settings),
        .testTarget(name: "AgentCodexExecTests", dependencies: ["AgentCodexExec", "AgentHeadlessContracts", "AgentCLIExecution", .product(name: "AIClientKit", package: "AIClientKit")], swiftSettings: settings),
        .target(name: "AgentClaudeHeadless", dependencies: ["AgentHeadlessContracts", "AgentCLIExecution", .product(name: "AIClientKit", package: "AIClientKit"), .product(name: "ProcessStreamFraming", package: "ProcessKit")], swiftSettings: settings),
        .testTarget(name: "AgentClaudeHeadlessTests", dependencies: ["AgentClaudeHeadless", "AgentHeadlessContracts", "AgentCLIExecution", "AgentClaudeProtocol", .product(name: "AIClientKit", package: "AIClientKit")], swiftSettings: settings),
        .target(name: "AgentGeminiHeadless", dependencies: ["AgentHeadlessContracts", "AgentCLIExecution", .product(name: "AIClientKit", package: "AIClientKit"), .product(name: "ProcessStreamFraming", package: "ProcessKit")], swiftSettings: settings),
        .testTarget(name: "AgentGeminiHeadlessTests", dependencies: ["AgentGeminiHeadless", "AgentHeadlessContracts", "AgentCLIExecution", .product(name: "AIClientKit", package: "AIClientKit")], swiftSettings: settings),
        .target(name: "AgentACPHeadless", dependencies: ["AgentHeadlessContracts", .product(name: "AIClientKit", package: "AIClientKit"), .product(name: "AgentRuntimeKit", package: "AgentRuntimeKit")], swiftSettings: settings),
        .testTarget(name: "AgentACPHeadlessTests", dependencies: ["AgentACPHeadless", "AgentHeadlessContracts", .product(name: "AIClientKit", package: "AIClientKit"), .product(name: "AgentRuntimeKit", package: "AgentRuntimeKit")], swiftSettings: settings),
        .target(name: "AgentNativeProcessTransport", dependencies: [.product(name: "ProcessKit", package: "ProcessKit")], swiftSettings: settings),
        .testTarget(name: "AgentNativeProcessTransportTests", dependencies: ["AgentNativeProcessTransport", .product(name: "ProcessKit", package: "ProcessKit")], swiftSettings: settings),
        .target(name: "AgentExecutionKit", dependencies: ["AgentProcessSupport"], swiftSettings: settings),
        .testTarget(name: "AgentProcessSupportTests", dependencies: ["AgentProcessSupport"], swiftSettings: settings)
    ]
)
