// swift-tools-version: 6.0
// The Linux host (`mirage-host`): GNOME on Wayland, captured and driven through Mutter's remote-desktop D-Bus API and
// PipeWire, encoded with x265, served over msquic. Shares MirageCore with the Mac host (Sources/MirageCore, symlinked);
// the Apple-only parts of it are excluded here. Built on Linux only: see linux/build.sh.
import PackageDescription

let systemIncludes: [String] = [
    "-I/usr/include/pipewire-0.3", "-I/usr/include/spa-0.2",
    "-I/usr/include/glib-2.0", "-I/usr/lib/x86_64-linux-gnu/glib-2.0/include", "-I/usr/lib/aarch64-linux-gnu/glib-2.0/include",
    "-I/usr/local/include", "-I/usr/include/libdrm",
]

let package = Package(
    name: "mirage-linux",
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
    ],
    targets: [
        .target(
            name: "CWebP",
            path: "Sources/CWebP",
            exclude: ["COPYING"],
            sources: ["src", "sharpyuv"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath(".")]
        ),
        // msquic (built static into /usr/local by build.sh) behind a small C layer.
        .target(
            name: "CMirageQuic",
            path: "Sources/CMirageQuic",
            cSettings: [.unsafeFlags(["-I/usr/local/include"])],
            linkerSettings: [.unsafeFlags(["-L/usr/local/lib"]), .linkedLibrary("msquic"), .unsafeFlags(["-Xlinker", "-l:libnuma.a"])]
        ),
        .target(
            name: "MirageCore",
            dependencies: ["CWebP", "CMirageQuic", .product(name: "Crypto", package: "swift-crypto")],
            path: "Sources/MirageCore",
            exclude: [
                // Apple-only: Network.framework transport, VideoToolbox decode, Metal compositing, code signing.
                "Transport/QUIC.swift", "Transport/MessageStream.swift", "Transport/TLSIdentity.swift",
                "Video/HEVCDecoder.swift", "Render/Compositor.swift", "Render/LayerScenePlan.swift", "Session/HostAgent.swift",
                // Viewer side, the Mac's local control socket and updater feed: not part of the Linux host.
                "Session/ClientSession.swift", "Session/HostUpdateTrigger.swift", "Session/LocalControl.swift", "Update/Feed.swift", "Tiles/AlphaPlane.swift",
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Mutter remote desktop + PipeWire capture, KMS capture + uinput, x265, in C.
        .target(
            name: "CMirageDesktop",
            path: "Sources/CMirageDesktop",
            cSettings: [.unsafeFlags(systemIncludes + ["-O3"])],
            linkerSettings: [
                .unsafeFlags(["-L/usr/local/lib"]),
                .linkedLibrary("pipewire-0.3"), .linkedLibrary("drm"), .linkedLibrary("gio-2.0"), .linkedLibrary("gobject-2.0"), .linkedLibrary("glib-2.0"),
                // x265 static (a desktop rarely has libx265); its C++ runtime is on every desktop.
                .unsafeFlags(["-Xlinker", "-l:libx265.a", "-Xlinker", "-l:libnuma.a"]), .linkedLibrary("stdc++"), .linkedLibrary("mvec"), .linkedLibrary("m"), .linkedLibrary("dl"),
            ]
        ),
        .executableTarget(
            name: "mirage-host",
            dependencies: [
                "MirageCore", "CMirageDesktop",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/mirage-host",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
