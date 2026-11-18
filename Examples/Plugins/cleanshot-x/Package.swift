// swift-tools-version:6.2
// Build with Scripts/build-plugin.sh Examples/Plugins/cleanshot-x <Plugins folder>/cleanshot-x
import PackageDescription

let package = Package(
    name: "CleanShotX",
    dependencies: [.package(path: "../../../PluginKit")],
    targets: [
        .executableTarget(
            name: "CleanShotX",
            dependencies: [.product(name: "TinycastKit", package: "PluginKit")],
            swiftSettings: [.defaultIsolation(MainActor.self)])
    ]
)
