import Foundation

/// Parsed deep-link / URL-scheme intents for Shrava (`shrava://…`).
public enum URLIntent: Equatable, Sendable {
    case record
    case liveActivity
    case history(UUID?)
    case dictionary
    case settings
    case tab(String)
    case debug(String)
    case unknown(host: String?)
}

public enum URLIntentRouter {
    public static func parse(_ url: URL) -> URLIntent? {
        guard url.scheme?.lowercased() == "shrava" else { return nil }
        switch url.host?.lowercased() {
        case "record":
            return .record
        case "live", "recording":
            return .liveActivity
        case "history":
            let idStr = url.pathComponents.dropFirst().first
            return .history(idStr.flatMap(UUID.init(uuidString:)))
        case "dictionary":
            return .dictionary
        case "settings":
            return .settings
        case "tab":
            let name = url.pathComponents.dropFirst().first?.lowercased() ?? ""
            return .tab(name)
        case "debug":
            let path = url.pathComponents.dropFirst().first?.lowercased() ?? "long"
            return .debug(path)
        default:
            return .unknown(host: url.host)
        }
    }
}
