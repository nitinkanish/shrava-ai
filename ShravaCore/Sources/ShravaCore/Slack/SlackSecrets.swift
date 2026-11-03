import Foundation

/// Slack bot token (`xoxb-…`) stored in Keychain. Never log or commit the value.
public enum SlackSecrets {
    public static let keychainAccount = "slack_bot_token"

    public static func loadToken() -> String? {
        try? KeychainManager.shared.load(key: keychainAccount)
    }

    public static func saveToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("xoxb-") else {
            throw SlackError.invalidToken
        }
        try KeychainManager.shared.save(key: keychainAccount, value: trimmed)
    }

    public static func deleteToken() {
        try? KeychainManager.shared.delete(key: keychainAccount)
    }

    public static func hasToken() -> Bool {
        KeychainManager.shared.exists(key: keychainAccount)
    }
}
