// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mirage",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "MirageCore", targets: ["MirageCore"]),
        .executable(name: "miraged", targets: ["miraged"]),
        .executable(name: "mirage", targets: ["mirage"]),
        .executable(name: "mirage-viewer", targets: ["mirage-viewer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        // Shared by host and every client; no AppKit/ScreenCaptureKit so it compiles for iOS.
        .target(
            name: "MirageCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // macOS-only host side: ScreenCaptureKit capture, VideoToolbox encode, CGEvent input, cursor.
        .target(
            name: "MirageHost",
            dependencies: ["MirageCore"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("ScreenCaptureKit"), .linkedFramework("VideoToolbox"), .linkedFramework("AppKit")]
        ),
        .executableTarget(
            name: "miraged",
            dependencies: [
                "MirageCore", "MirageHost",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "mirage",
            dependencies: [
                "MirageCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "mirage-viewer",
            dependencies: ["MirageCore"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SwiftUI"), .linkedFramework("AVFoundation"), .linkedFramework("VideoToolbox")]
        ),
        .testTarget(
            name: "MirageCoreTests",
            dependencies: ["MirageCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
