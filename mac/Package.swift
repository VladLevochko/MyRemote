// swift-tools-version: 6.0
import PackageDescription

// MyRemote macOS agent. Zero third-party dependencies:
// Network.framework (WSS + Bonjour), Security (TLS identity), CryptoKit (SHA-256).
//
// MyRemoteCore is pure logic and builds in the Swift 6 language mode.
// The targets that sit on callback-based system frameworks (Network, AppKit,
// CoreGraphics) are confined to one serial queue / the main thread by design and
// are built in the Swift 5 language mode.
let package = Package(
    name: "MyRemote",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MyRemoteCore", targets: ["MyRemoteCore"]),
        .executable(name: "MyRemoteAgent", targets: ["MyRemoteAgent"]),
    ],
    targets: [
        .target(
            name: "MyRemoteCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MyRemoteAgentKit",
            dependencies: ["MyRemoteCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "MyRemoteAgent",
            dependencies: ["MyRemoteAgentKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MyRemoteCoreTests",
            dependencies: ["MyRemoteCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MyRemoteAgentKitTests",
            dependencies: ["MyRemoteAgentKit", "MyRemoteCore", "MyRemoteAgent"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
