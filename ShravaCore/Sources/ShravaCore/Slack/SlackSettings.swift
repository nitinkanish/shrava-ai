import Foundation

public struct SlackIntegrationSettings: Codable, Equatable, Sendable {
    public var defaultChannelID: String?
    public var defaultChannelName: String?
    public var autoSendAfterAnalyze: Bool
    public var includeTranscript: Bool

    public static let `default` = SlackIntegrationSettings(
        defaultChannelID: nil,
        defaultChannelName: nil,
        autoSendAfterAnalyze: false,
        includeTranscript: false
    )

    public init(
        defaultChannelID: String? = nil,
        defaultChannelName: String? = nil,
        autoSendAfterAnalyze: Bool = false,
        includeTranscript: Bool = false
    ) {
        self.defaultChannelID = defaultChannelID
        self.defaultChannelName = defaultChannelName
        self.autoSendAfterAnalyze = autoSendAfterAnalyze
        self.includeTranscript = includeTranscript
    }
}

public enum SlackSettingsStore {
    private static let key = "shrava.slackSettings"

    public static func load() -> SlackIntegrationSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(SlackIntegrationSettings.self, from: data) else {
            return .default
        }
        return s
    }

    public static func save(_ settings: SlackIntegrationSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
