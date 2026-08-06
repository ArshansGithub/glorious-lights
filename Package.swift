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
        .library(name: "GloriousSync", targets: ["GloriousSync"]),
        .library(name: "GloriousVisualizer", targets: ["GloriousVisualizer"]),
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
        // The one place the two protocols meet: a pure translation layer that
        // maps a device-neutral look onto each device's own vocabulary.
        .target(name: "GloriousSync",
                dependencies: ["GMMKProtocol", "GloriousMouseProtocol"]),
        // Audio analysis and the bar-graph render, kept out of the app target so
        // the mapping and the colour ramp are unit-testable without a device.
        .target(name: "GloriousVisualizer", dependencies: ["GMMKProtocol"]),
        .executableTarget(name: "gmmk-cli",
                          dependencies: ["GMMKProtocol", "GMMKHID",
                                         "GloriousMouseProtocol", "GloriousMouseHID"]),
        .executableTarget(name: "GMMKLightsApp",
                          dependencies: ["GMMKProtocol", "GMMKHID",
                                         "GloriousMouseProtocol", "GloriousMouseHID",
                                         "GloriousSync", "GloriousVisualizer"]),
        .testTarget(name: "GMMKProtocolTests", dependencies: ["GMMKProtocol"]),
        .testTarget(name: "GMMKHIDTests", dependencies: ["GMMKHID"]),
        .testTarget(name: "GloriousMouseProtocolTests", dependencies: ["GloriousMouseProtocol"]),
        .testTarget(name: "GloriousSyncTests", dependencies: ["GloriousSync"]),
        .testTarget(name: "GloriousVisualizerTests", dependencies: ["GloriousVisualizer"]),
    ]
)
