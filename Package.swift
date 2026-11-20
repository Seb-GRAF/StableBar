// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StableBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "StableBar", targets: ["StableBar"]),
        // Loaded into /usr/bin/perl, never into StableBar: see Resources/now-playing.pl.
        .library(name: "StableBarNowPlaying", type: .dynamic, targets: ["NowPlayingAdapter"])
    ],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0")],
    targets: [
        .executableTarget(name: "StableBar", dependencies: [.product(name: "Sparkle", package: "Sparkle")]),
        .target(name: "NowPlayingAdapter"),
        .testTarget(name: "StableBarTests", dependencies: ["StableBar"])
    ]
)
