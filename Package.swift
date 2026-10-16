// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mirage",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "MirageCore", targets: ["MirageCore"]),
        .executable(name: "miraged", targets: ["miraged"]),
        .executable(name: "mirage", targets: ["mirage"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "MirageCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "miraged",
            dependencies: [
                "MirageCore",
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
        .testTarget(
            name: "MirageCoreTests",
            dependencies: ["MirageCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
