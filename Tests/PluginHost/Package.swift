// swift-tools-version: 6.2
// The plugin host against real Scrift, which a lone swiftc harness can't link. Scripts/test-plugins.sh
// runs its checks; Scripts/plugin-dump.sh runs `tinycast-plugin dump`, which prints a plugin's manifest.
import PackageDescription

let package = Package(
    name: "PluginHostTests",
    platforms: [.macOS(.v26)],
    dependencies: [.package(url: "https://github.com/freepicheep/Scrift.git", branch: "main")],
    targets: [
        .executableTarget(
            name: "PluginHostTests",
            dependencies: [
                .product(name: "Scrift", package: "Scrift"),
                .product(name: "ScriftFoundation", package: "Scrift")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]),
        // Scripts/bench-plugins.sh: one command under either engine, for time, CPU and memory.
        .executableTarget(
            name: "plugin-bench",
            dependencies: [
                .product(name: "Scrift", package: "Scrift"),
                .product(name: "ScriftFoundation", package: "Scrift")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(
            name: "tinycast-plugin",
            dependencies: [
                .product(name: "Scrift", package: "Scrift"),
                .product(name: "ScriftFoundation", package: "Scrift")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)])
    ]
)
