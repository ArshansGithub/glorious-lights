// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "gmmk-lights",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GMMKProtocol", targets: ["GMMKProtocol"]),
        .library(name: "GMMKHID", targets: ["GMMKHID"]),
        .executable(name: "gmmk-cli", targets: ["gmmk-cli"]),
    ],
    targets: [
        .target(name: "GMMKProtocol"),
        .target(name: "GMMKHID", dependencies: ["GMMKProtocol"]),
        .executableTarget(name: "gmmk-cli", dependencies: ["GMMKProtocol", "GMMKHID"]),
        .testTarget(name: "GMMKProtocolTests", dependencies: ["GMMKProtocol"]),
    ]
)
