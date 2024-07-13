// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "swift-nostr-relay",
    platforms: [.macOS(.v10_15), .iOS(.v13), .tvOS(.v13), .watchOS(.v6), .macCatalyst(.v13)],
    products: [
        .library(
            name: "swift-nostr-relay",
            targets: ["swift-nostr-relay"]),
    ],
    dependencies: [
        .package(url: "git@github.com:SparrowTek/CoreNostr.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "swift-nostr-relay",
            dependencies: [
                "CoreNostr"
            ]),
        .testTarget(
            name: "swift-nostr-relayTests",
            dependencies: ["swift-nostr-relay"]
        ),
    ]
)
