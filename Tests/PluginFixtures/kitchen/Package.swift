// swift-tools-version:6.2
// The plugin Tests/WasmPluginTests.swift drives: one command per path through the host.
import PackageDescription

let package = Package(
    name: "Kitchen",
    dependencies: [.package(path: "../../../PluginKit")],
    targets: [
        .executableTarget(
            name: "Kitchen",
            dependencies: [.product(name: "TinycastKit", package: "PluginKit")],
            swiftSettings: [.defaultIsolation(MainActor.self)])
    ]
)
