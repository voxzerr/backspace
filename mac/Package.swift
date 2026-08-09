// swift-tools-version: 5.9
import PackageDescription

// Backspace for macOS.
//
// The module split is load-bearing, not decoration. BackspaceCore imports
// Foundation and nothing else: it is the correction engine plus the safety
// gates, and it is the only part of the app that can be tested exhaustively
// on a machine with no display, no permissions and no windowserver — which
// is every CI runner we will ever have. Everything that touches AppKit or
// the Accessibility API lives above it and is verified only as far as "it
// compiles and it degrades honestly".
let package = Package(
    name: "Backspace",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BackspaceCore", targets: ["BackspaceCore"]),
        .library(name: "BackspaceAX", targets: ["BackspaceAX"]),
        .library(name: "BackspaceAI", targets: ["BackspaceAI"]),
        .executable(name: "backspace", targets: ["BackspaceApp"]),
    ],
    targets: [
        // Platform-free. Foundation only. Fully tested.
        .target(name: "BackspaceCore"),

        // macOS Accessibility. Compiles everywhere macOS does; its runtime
        // behaviour needs a real session and a granted permission, so CI can
        // only prove it builds and refuses cleanly.
        .target(name: "BackspaceAX", dependencies: ["BackspaceCore"]),

        // Claude API client for the rewrite, completion and ask surfaces.
        .target(name: "BackspaceAI", dependencies: ["BackspaceCore"]),

        // The app: menu bar, overlays, settings, coordinator.
        .executableTarget(
            name: "BackspaceApp",
            dependencies: ["BackspaceCore", "BackspaceAX", "BackspaceAI"]
        ),

        .testTarget(name: "BackspaceCoreTests", dependencies: ["BackspaceCore"]),
        .testTarget(name: "BackspaceAXTests", dependencies: ["BackspaceAX"]),
    ]
)
