// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "swift-nostr-relay",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(
            name: "NostrRelayServer",
            targets: ["NostrRelayServer"]
        ),
    ],
    dependencies: [
        .package(path: "../CoreNostr"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-metrics.git", from: "2.4.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.0.0"),
        .package(url: "https://github.com/vapor/postgres-nio.git", exact: "1.24.0"),
    ],
    targets: [
        .executableTarget(
            name: "NostrRelayServer",
            dependencies: [
                "CoreNostr",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                .product(name: "HummingbirdWSCompression", package: "hummingbird-websocket"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Metrics", package: "swift-metrics"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
            ]
        ),
        .testTarget(
            name: "NostrRelayServerTests",
            dependencies: [
                "NostrRelayServer",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
        ),
    ]
)
