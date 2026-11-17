// swift-tools-version: 6.2
// The plugin host against real Stir, which a lone swiftc harness can't link. Scripts/test-plugins.sh
import PackageDescription

let package = Package(
    name: "PluginHostTests",
    platforms: [.macOS(.v26)],
    dependencies: [.package(url: "https://github.com/freepicheep/Stir.git", branch: "tinycast-plugins")],
    targets: [
        .executableTarget(
            name: "PluginHostTests",
            dependencies: [
                .product(name: "Stir", package: "Stir"),
                .product(name: "StirFoundation", package: "Stir")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)])
    ]
)
