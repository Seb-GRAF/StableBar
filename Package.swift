// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StableBar",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "StableBar", targets: ["StableBar"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0")],
    targets: [
        .target(name: "NativeWidgetPluginABI", path: "Sources/NativeWidgetPluginABI", publicHeadersPath: "include"),
        .executableTarget(name: "StableBar", dependencies: [.product(name: "Sparkle", package: "Sparkle"), "NativeWidgetPluginABI"]),
        .testTarget(name: "StableBarTests", dependencies: ["StableBar", "NativeWidgetPluginABI"])
    ]
)
