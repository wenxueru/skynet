// swift-tools-version:5.9
import PackageDescription

/// SkynetCore — shared core for the Skynet macOS and iOS apps.
///
/// The package is intentionally dependency-free: everything it needs comes from
/// Foundation. It builds for macOS 13+ and iOS 16+ so a single code base can be
/// linked into both apps (see docs/ARCHITECTURE.md for the process boundaries
/// that separate the two platforms).
let package = Package(
    name: "SkynetCore",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "SkynetCore", targets: ["SkynetCore"]),
        // Doubles are shipped as their own product so app-level unit tests can
        // drive the same fakes the core package tests use.
        .library(name: "SkynetCoreDoubles", targets: ["SkynetCoreDoubles"]),
    ],
    targets: [
        .target(name: "SkynetCore"),
        .target(
            name: "SkynetCoreDoubles",
            dependencies: ["SkynetCore"]
        ),
        .testTarget(
            name: "SkynetCoreTests",
            dependencies: ["SkynetCore", "SkynetCoreDoubles"]
        ),
    ]
)
