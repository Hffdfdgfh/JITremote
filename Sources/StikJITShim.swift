import Foundation

/// Minimal stand-in for the StikJIT framework namespace, so the reused
/// StikJIT sources (ScriptRunner, BundledScript) compile unchanged.
enum StikJIT {
    enum Script {
        case universal
        case legacy
        case custom(URL)
        case customBase64(String)

        var name: String {
            switch self {
            case .universal: return "universal"
            case .legacy: return "legacy"
            case .custom(let url): return url.lastPathComponent
            case .customBase64: return "custom"
            }
        }
    }
}
