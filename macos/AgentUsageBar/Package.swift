// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentUsageBar",
    platforms: [.macOS(.v14)],
    products: [
        // The app itself is an Xcode target under macos/ — it needs an Info.plist, an
        // icon, entitlements, and signing settings that a SwiftPM executable cannot
        // express. This package holds the parts worth testing on their own.
        .library(name: "UsageMeterCore", targets: ["UsageMeterCore"]),
    ],
    targets: [
        // Pure logic. No AppKit, no SwiftUI, no network calls performed here.
        .target(name: "UsageMeterCore"),

        .testTarget(
            name: "UsageMeterCoreTests",
            dependencies: ["UsageMeterCore"]
        ),
    ]
)
