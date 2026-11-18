import Foundation

enum ExtensionHostError: LocalizedError {
    case noActiveExtension
    case unknown(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .noActiveExtension: return "No extension command is running."
        case .unknown(let what): return "Unknown host call '\(what)'."
        case .unsupported(let what): return "\(what) is not supported in Tinycast extensions."
        }
    }
}
