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
        .executable(name: "mirage-release", targets: ["mirage-release"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        // libwebp 1.6.0 (encoder, decoder, dsp, utils, sharpyuv), vendored as-is; lossless tiles.
        .target(
            name: "CWebP",
            path: "Sources/CWebP",
            exclude: ["COPYING"],
            sources: ["src", "sharpyuv"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath(".")]
        ),
        // Shared by host and every client; no AppKit/ScreenCaptureKit so it compiles for iOS.
        .target(
            name: "MirageCore",
            dependencies: ["CWebP"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            // MetalFX autolinks from `import MetalFX` (absent from the iOS Simulator SDK, so it cannot be linked unconditionally).
            linkerSettings: [.linkedFramework("Metal"), .linkedFramework("VideoToolbox")]
        ),
        // macOS-only host side: ScreenCaptureKit capture, VideoToolbox encode, CGEvent input, cursor.
        .target(
            name: "MirageHost",
            dependencies: ["MirageCore"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("ScreenCaptureKit"), .linkedFramework("VideoToolbox"), .linkedFramework("AppKit")]
        ),
        // Host updates (DESIGN §3.10): feed, signed manifests, verification, the atomic swap, health commit and rollback.
        // macOS only (Security's code-signing and Gatekeeper APIs); the iOS viewer never reads the feed.
        .target(
            name: "MirageUpdater",
            dependencies: ["MirageCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The release script's helper (scripts/release.sh): manifest keys, writing and signing manifests, verifying them
        // with the same code the host runs.
        .executableTarget(
            name: "mirage-release",
            dependencies: [
                "MirageCore", "MirageUpdater",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "miraged",
            dependencies: [
                "MirageCore", "MirageHost", "MirageUpdater",
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
            // Session/ (platform-neutral) + macOS/ (AppKit shell). iOS/ is the UIKit shell, built only by the universal
            // app (App/Mirage.xcodeproj), which compiles Session/ with it.
            exclude: ["iOS"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SwiftUI"), .linkedFramework("AVFoundation"), .linkedFramework("VideoToolbox")]
        ),
        // The Mac viewer's own logic (settings migration, the toolbar's state): the executable target, tested in place.
        .testTarget(
            name: "MirageViewerTests",
            dependencies: ["mirage-viewer", "MirageCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MirageUpdaterTests",
            dependencies: ["MirageUpdater", "MirageCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MirageCoreTests",
            dependencies: ["MirageCore", "MirageHost"],   // MirageHost: the local control server
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
