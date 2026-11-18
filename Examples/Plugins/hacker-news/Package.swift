// swift-tools-version:6.2
// Build with Scripts/build-plugin.sh Examples/Plugins/hacker-news <Plugins folder>/hacker-news
import PackageDescription

let package = Package(
    name: "HackerNews",
    dependencies: [.package(path: "../../../PluginKit")],
    targets: [
        .executableTarget(
            name: "HackerNews",
            dependencies: [.product(name: "TinycastKit", package: "PluginKit")],
            swiftSettings: [.defaultIsolation(MainActor.self)])
    ]
)
