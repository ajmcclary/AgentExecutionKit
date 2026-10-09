// swift-tools-version: 6.0
import PackageDescription

let settings: [SwiftSetting] = [.swiftLanguageMode(.v6), .enableExperimentalFeature("StrictConcurrency")]
let package = Package(
    name: "AgentExecutionKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "AgentExecutionKit", targets: ["AgentExecutionKit"]),
        .library(name: "AgentProcessSupport", targets: ["AgentProcessSupport"])
    ],
    dependencies: [
        .package(url: "https://github.com/ajmcclary/ProcessKit.git", .upToNextMinor(from: "0.1.0-beta.5"))
    ],
    targets: [
        .target(name: "AgentProcessSupport", dependencies: [.product(name: "ProcessKit", package: "ProcessKit")], swiftSettings: settings),
        .target(name: "AgentExecutionKit", dependencies: ["AgentProcessSupport"], swiftSettings: settings),
        .testTarget(name: "AgentProcessSupportTests", dependencies: ["AgentProcessSupport"], swiftSettings: settings)
    ]
)
