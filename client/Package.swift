// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Parallax",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Parallax", targets: ["ParallaxApp"]),
    ],
    targets: [
        // Pure models and DSP. No AVFoundation, so it's fast to test.
        .target(name: "ParallaxCore"),
        // Capture, compositing, audio mixing, recording.
        .target(name: "ParallaxMedia", dependencies: ["ParallaxCore"]),
        // Client for the relay server (broadcast control + chat).
        .target(name: "ParallaxRemote"),
        .executableTarget(
            name: "ParallaxApp",
            dependencies: ["ParallaxCore", "ParallaxMedia", "ParallaxRemote"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "ParallaxCoreTests", dependencies: ["ParallaxCore"]),
        .testTarget(name: "ParallaxMediaTests", dependencies: ["ParallaxMedia", "ParallaxCore"]),
    ]
)
