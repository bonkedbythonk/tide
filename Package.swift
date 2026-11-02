// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MusicSample",
    platforms: [.macOS(.v15)],
    dependencies: [
        // libmpv + FFmpeg as prebuilt xcframeworks, with the moltenvk context that
        // lets mpv draw into our CAMetalLayer. Same fork anicat uses (adds loudnorm).
        .package(url: "https://github.com/bonkedbythonk/MPVKit.git", exact: "1.0.0-anicat.1"),
    ],
    targets: [
        .executableTarget(
            name: "MusicSample",
            dependencies: [.product(name: "MPVKit-GPL", package: "MPVKit"), "TideLink"],
            path: "Sources/MusicSample",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The protocol shared with the iPhone app (iOS/), which compiles these sources directly.
        .target(name: "TideLink", path: "Sources/TideLink", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
