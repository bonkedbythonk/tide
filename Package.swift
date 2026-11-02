// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MusicSample",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "MusicSample",
            path: "Sources/MusicSample",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
