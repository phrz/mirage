// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "RevealLab",
    platforms: [.macOS(.v15)],
    targets: [.executableTarget(name: "RevealLab", swiftSettings: [.swiftLanguageMode(.v5)])]
)
