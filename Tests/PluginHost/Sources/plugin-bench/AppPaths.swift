import Foundation

/// The app's own `AppPaths`, which reaches the whole app's settings; the catalog only needs this.
enum AppPaths {
    static func applicationSupport() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "PluginHostTests", directoryHint: .isDirectory)
    }
}
