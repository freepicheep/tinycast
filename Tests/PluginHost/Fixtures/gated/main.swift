import Foundation
import Tinycast

Plugin.action("fetch") {
    _ = try await URLSession.shared.data(from: URL(string: "https://example.com")!)
}
