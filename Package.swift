// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Snifix",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Snifix", targets: ["Snifix"]),
        .executable(name: "snifix-selftest", targets: ["SnifixSelfTest"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.30.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.10.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"6.0.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "SnifixCore",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .executableTarget(name: "Snifix", dependencies: ["SnifixCore"]),
        .executableTarget(name: "SnifixSelfTest", dependencies: ["SnifixCore"]),
    ],
    swiftLanguageModes: [.v5]
)
