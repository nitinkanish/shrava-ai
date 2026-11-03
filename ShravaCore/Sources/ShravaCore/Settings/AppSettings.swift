import Foundation

public enum SupportedLanguage: String, CaseIterable, Codable, Sendable {
    case auto = "auto"
    case english = "en"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case italian = "it"
    case portuguese = "pt"
    case dutch = "nl"
    case polish = "pl"
    case russian = "ru"
    case japanese = "ja"
    case korean = "ko"
    case chinese = "zh"
    case arabic = "ar"
    case hindi = "hi"
    case turkish = "tr"
    case vietnamese = "vi"
    case thai = "th"
    case indonesian = "id"
    case swedish = "sv"
    case norwegian = "no"
    case danish = "da"
    case finnish = "fi"
    case czech = "cs"
    case romanian = "ro"
    case hungarian = "hu"
    case greek = "el"
    case hebrew = "he"
    case ukrainian = "uk"
    
    public static var popular: [SupportedLanguage] { [.auto, .english, .hindi] }
    public static var others: [SupportedLanguage] { allCases.filter { !popular.contains($0) }.sorted { $0.displayName < $1.displayName } }

    public var displayName: String {
        switch self {
        case .auto: return "Auto-detect"
        case .english: return "English"
        case .spanish: return "Spanish"
        case .french: return "French"
        case .german: return "German"
        case .italian: return "Italian"
        case .portuguese: return "Portuguese"
        case .dutch: return "Dutch"
        case .polish: return "Polish"
        case .russian: return "Russian"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .chinese: return "Chinese"
        case .arabic: return "Arabic"
        case .hindi: return "Hindi"
        case .turkish: return "Turkish"
        case .vietnamese: return "Vietnamese"
        case .thai: return "Thai"
        case .indonesian: return "Indonesian"
        case .swedish: return "Swedish"
        case .norwegian: return "Norwegian"
        case .danish: return "Danish"
        case .finnish: return "Finnish"
        case .czech: return "Czech"
        case .romanian: return "Romanian"
        case .hungarian: return "Hungarian"
        case .greek: return "Greek"
        case .hebrew: return "Hebrew"
        case .ukrainian: return "Ukrainian"
        }
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var language: SupportedLanguage
    public var iCloudSyncEnabled: Bool
    public var autoCleanup: Bool
    public var showOriginalText: Bool
    public var hapticFeedback: Bool
    public var soundFeedback: Bool
    
    #if os(macOS)
    public var hotkeyModifiers: UInt
    public var hotkeyKeyCode: UInt16
    public var handsFreeEnabled: Bool
    public var useAccessibilityInsertion: Bool
    #endif
    
    public static var `default`: AppSettings {
        #if os(macOS)
        return AppSettings(
            language: .english,
            iCloudSyncEnabled: false,
            autoCleanup: true,
            showOriginalText: false,
            hapticFeedback: true,
            soundFeedback: true,
            hotkeyModifiers: 0,
            hotkeyKeyCode: 63, // Fn key
            handsFreeEnabled: true,
            useAccessibilityInsertion: true
        )
        #else
        return AppSettings(
            language: .english,
            iCloudSyncEnabled: false,
            autoCleanup: true,
            showOriginalText: false,
            hapticFeedback: true,
            soundFeedback: true
        )
        #endif
    }
    
    public init(
        language: SupportedLanguage = .english,
        iCloudSyncEnabled: Bool = false,
        autoCleanup: Bool = true,
        showOriginalText: Bool = false,
        hapticFeedback: Bool = true,
        soundFeedback: Bool = true,
        hotkeyModifiers: UInt = 0,
        hotkeyKeyCode: UInt16 = 63,
        handsFreeEnabled: Bool = true,
        useAccessibilityInsertion: Bool = true
    ) {
        self.language = language
        self.iCloudSyncEnabled = iCloudSyncEnabled
        self.autoCleanup = autoCleanup
        self.showOriginalText = showOriginalText
        self.hapticFeedback = hapticFeedback
        self.soundFeedback = soundFeedback
        #if os(macOS)
        self.hotkeyModifiers = hotkeyModifiers
        self.hotkeyKeyCode = hotkeyKeyCode
        self.handsFreeEnabled = handsFreeEnabled
        self.useAccessibilityInsertion = useAccessibilityInsertion
        #endif
    }
}

public final class SettingsManager: @unchecked Sendable {
    public static let shared = SettingsManager()
    
    private let userDefaults: UserDefaults
    private let settingsKey = "com.shrava.settings"
    
    public var settings: AppSettings {
        didSet {
            save()
        }
    }
    
    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        LegacyMigration.migrateUserDefaultsIfNeeded()

        if let data = userDefaults.data(forKey: settingsKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.settings = decoded
        } else if let data = userDefaults.data(forKey: "com.murmurapp.settings"),
                  let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.settings = decoded
            // Persist under the new key
            if let encoded = try? JSONEncoder().encode(decoded) {
                userDefaults.set(encoded, forKey: settingsKey)
            }
        } else {
            self.settings = .default
        }
    }
    
    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            userDefaults.set(data, forKey: settingsKey)
        }
    }
}


#if os(macOS)
extension AppSettings {
    enum CodingKeys: String, CodingKey {
        case language, iCloudSyncEnabled, autoCleanup, showOriginalText, hapticFeedback, soundFeedback
        case hotkeyModifiers, hotkeyKeyCode, handsFreeEnabled, useAccessibilityInsertion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        language = try c.decodeIfPresent(SupportedLanguage.self, forKey: .language) ?? .english
        iCloudSyncEnabled = try c.decodeIfPresent(Bool.self, forKey: .iCloudSyncEnabled) ?? false
        autoCleanup = try c.decodeIfPresent(Bool.self, forKey: .autoCleanup) ?? true
        showOriginalText = try c.decodeIfPresent(Bool.self, forKey: .showOriginalText) ?? false
        hapticFeedback = try c.decodeIfPresent(Bool.self, forKey: .hapticFeedback) ?? true
        soundFeedback = try c.decodeIfPresent(Bool.self, forKey: .soundFeedback) ?? true
        hotkeyModifiers = try c.decodeIfPresent(UInt.self, forKey: .hotkeyModifiers) ?? 0
        hotkeyKeyCode = try c.decodeIfPresent(UInt16.self, forKey: .hotkeyKeyCode) ?? 63
        handsFreeEnabled = try c.decodeIfPresent(Bool.self, forKey: .handsFreeEnabled) ?? true
        useAccessibilityInsertion = try c.decodeIfPresent(Bool.self, forKey: .useAccessibilityInsertion) ?? true
    }
}
#endif
