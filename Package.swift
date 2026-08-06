// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "glorious-lights",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GMMKProtocol", targets: ["GMMKProtocol"]),
        .library(name: "GMMKHID", targets: ["GMMKHID"]),
        .library(name: "GloriousMouseProtocol", targets: ["GloriousMouseProtocol"]),
        .library(name: "GloriousMouseHID", targets: ["GloriousMouseHID"]),
        .executable(name: "gmmk-cli", targets: ["gmmk-cli"]),
        .executable(name: "GMMKLightsApp", targets: ["GMMKLightsApp"]),
    ],
    targets: [
        .target(name: "GMMKProtocol"),
        .target(name: "GMMKHID", dependencies: ["GMMKProtocol"]),
        // The mouse is a different device with a different protocol; its
        // targets deliberately share nothing with the keyboard's.
        .target(name: "GloriousMouseProtocol"),
        .target(name: "GloriousMouseHID", dependencies: ["GloriousMouseProtocol"]),
        .executableTarget(name: "gmmk-cli",
                          dependencies: ["GMMKProtocol", "GMMKHID",
                                         "GloriousMouseProtocol", "GloriousMouseHID"]),
        .executableTarget(name: "GMMKLightsApp",
                          dependencies: ["GMMKProtocol", "GMMKHID",
                                         "GloriousMouseProtocol", "GloriousMouseHID"]),
        .testTarget(name: "GMMKProtocolTests", dependencies: ["GMMKProtocol"]),
        .testTarget(name: "GMMKHIDTests", dependencies: ["GMMKHID"]),
        .testTarget(name: "GloriousMouseProtocolTests", dependencies: ["GloriousMouseProtocol"]),
    ]
)
