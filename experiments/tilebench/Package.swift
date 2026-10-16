// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "tilebench",
    platforms: [.macOS(.v15)],
    targets: [.executableTarget(name: "tilebench", swiftSettings: [.swiftLanguageMode(.v5)])]
)
