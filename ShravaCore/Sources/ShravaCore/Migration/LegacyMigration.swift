import Foundation

/// One-time Murmur → Shrava data migration. Mentions the old "Murmur" name only here.
public enum LegacyMigration {
    private static let defaultsMigratedKey = "com.shrava.didMigrateMurmurDefaults"
    private static let filesMigratedKey = "com.shrava.didMigrateMurmurFiles"

    /// Move ~/Library/Application Support/Murmur → Shrava (and iOS MurmurData → ShravaData) if needed.
    @discardableResult
    public static func migrateApplicationSupportIfNeeded() -> Bool {
        if UserDefaults.standard.bool(forKey: filesMigratedKey) {
            // Still attempt folder move if old exists and new missing (other machines / partial runs).
        }

        var didMigrate = false
        let fm = FileManager.default

        #if os(iOS)
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ShravaCore.appGroupIdentifier) {
            let old = group.appendingPathComponent("MurmurData", isDirectory: true)
            let new = group.appendingPathComponent("ShravaData", isDirectory: true)
            didMigrate = moveIfNeeded(from: old, to: new, fm: fm) || didMigrate
        }
        #endif

        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let old = appSupport.appendingPathComponent("Murmur", isDirectory: true)
            let new = appSupport.appendingPathComponent("Shrava", isDirectory: true)
            didMigrate = moveIfNeeded(from: old, to: new, fm: fm) || didMigrate
        }

        UserDefaults.standard.set(true, forKey: filesMigratedKey)
        return didMigrate
    }

    /// Copy UserDefaults from old bundle id domain com.murmurapp.mac into the current standard defaults.
    @discardableResult
    public static func migrateUserDefaultsIfNeeded() -> Bool {
        let ud = UserDefaults.standard
        if ud.bool(forKey: defaultsMigratedKey) {
            return false
        }

        var migrated = false

        // Old Mac app domain
        if let legacy = UserDefaults(suiteName: "com.murmurapp.mac") {
            for (key, value) in legacy.dictionaryRepresentation() {
                // Skip Apple private keys
                if key.hasPrefix("NS") || key.hasPrefix("Apple") || key.hasPrefix("com.apple.") { continue }
                if ud.object(forKey: key) == nil {
                    ud.set(value, forKey: key)
                    migrated = true
                }
                // Remap settings blob key
                if key == "com.murmurapp.settings", ud.object(forKey: "com.shrava.settings") == nil {
                    ud.set(value, forKey: "com.shrava.settings")
                    migrated = true
                }
            }
        }

        // Also remap settings key if still present under old name in current domain
        if let data = ud.data(forKey: "com.murmurapp.settings"), ud.data(forKey: "com.shrava.settings") == nil {
            ud.set(data, forKey: "com.shrava.settings")
            migrated = true
        }

        // Old app group suite if any
        if let group = UserDefaults(suiteName: "group.com.murmurapp") {
            for (key, value) in group.dictionaryRepresentation() {
                if key.hasPrefix("NS") || key.hasPrefix("Apple") || key.hasPrefix("com.apple.") { continue }
                if let shared = UserDefaults(suiteName: ShravaCore.appGroupIdentifier), shared.object(forKey: key) == nil {
                    shared.set(value, forKey: key)
                    migrated = true
                }
            }
        }

        ud.set(true, forKey: defaultsMigratedKey)
        return migrated
    }

    public static func runAll() {
        _ = migrateApplicationSupportIfNeeded()
        _ = migrateUserDefaultsIfNeeded()
    }

    private static func moveIfNeeded(from old: URL, to new: URL, fm: FileManager) -> Bool {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: old.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        if fm.fileExists(atPath: new.path) {
            return false
        }
        do {
            try fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: old, to: new)
            NSLog("Shrava: migrated \(old.lastPathComponent) → \(new.lastPathComponent)")
            return true
        } catch {
            NSLog("Shrava: migration failed \(error.localizedDescription)")
            return false
        }
    }
}
