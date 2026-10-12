// swift-tools-version:5.9
import Foundation
import PackageDescription

guard let core = ProcessInfo.processInfo.environment["SKYNET_CORE_PACKAGE"] else {
    fatalError("Run Apps/macOS/Tests/run-ios-model-regression.sh from the repository.")
}

// The runner copies the actual app models and existing XCTest suites into an
// isolated directory. It does not substitute model behavior or access user data.
let package = Package(
    name: "SkynetMobileModelRegression",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: core)],
    targets: [
        .target(name: "Skynet", dependencies: [
            .product(name: "SkynetMobile", package: "SkynetCore"),
        ]),
        .testTarget(name: "SkynetTests", dependencies: ["Skynet", .product(name: "SkynetMobile", package: "SkynetCore")]),
    ]
)
