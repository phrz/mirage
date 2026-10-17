// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "boxcache",
    platforms: [.macOS(.v15)],
    targets: [.executableTarget(name: "boxcache", swiftSettings: [.swiftLanguageMode(.v5)],
                                linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("WebKit")])]
)
