// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "seqbench",
    platforms: [.macOS(.v15)],
    targets: [.executableTarget(name: "seqbench", swiftSettings: [.swiftLanguageMode(.v5)])]
)
