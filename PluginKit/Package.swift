// swift-tools-version:6.2
// The kit a Tinycast plugin imports. A plugin is a WebAssembly reactor module built from Swift
// with the Swift SDK for WebAssembly; docs/features/plugins.md describes the module ABI.
import PackageDescription

let package = Package(
    name: "TinycastKit",
    products: [.library(name: "TinycastKit", targets: ["TinycastKit"])],
    targets: [
        .target(name: "CTinycastKit"),
        .target(
            name: "TinycastKit", dependencies: ["CTinycastKit"],
            // One thread, and views as SwiftUI has them: everything is the main actor's.
            swiftSettings: [.defaultIsolation(MainActor.self)],
            // A reactor: the host calls the kit's exports, never a `_start` that would run once and exit.
            linkerSettings: [.unsafeFlags(["-Xclang-linker", "-mexec-model=reactor"])])
    ]
)
