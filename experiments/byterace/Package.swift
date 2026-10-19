// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "byterace",
    platforms: [.macOS(.v15)],
    targets: [
        // Symlinks into the main package: libwebp as vendored there, and the host's own TileTracker /
        // ShiftDetector / TileCodec, so the replay classifies, detects copy-rects and encodes tiles
        // with exactly the code the host runs.
        .target(name: "CWebP", path: "Sources/CWebP", exclude: ["COPYING"], sources: ["src", "sharpyuv"],
                publicHeadersPath: "include", cSettings: [.headerSearchPath(".")]),
        .target(name: "MirageTiles", dependencies: ["CWebP"], swiftSettings: [.swiftLanguageMode(.v5)]),
        // Recorder: generates content in its own windows and captures them with ScreenCaptureKit.
        .executableTarget(name: "bytrec", swiftSettings: [.swiftLanguageMode(.v5)],
                          linkerSettings: [.linkedFramework("ScreenCaptureKit"), .linkedFramework("AppKit"), .linkedFramework("AVFoundation")]),
        // Replay: the three strategies over recorded sequences.
        .executableTarget(name: "byterace", dependencies: ["MirageTiles"], swiftSettings: [.swiftLanguageMode(.v5)],
                          linkerSettings: [.linkedFramework("VideoToolbox")]),
    ]
)
