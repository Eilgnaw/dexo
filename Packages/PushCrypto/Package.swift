// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "PushCrypto",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
    ],
    products: [
        .library(name: "PushCrypto", targets: ["PushCrypto"]),
    ],
    targets: [
        .target(name: "PushCrypto"),
        .testTarget(name: "PushCryptoTests", dependencies: ["PushCrypto"]),
    ]
)
