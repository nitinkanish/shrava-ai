// ShravaCore - Shared logic for Shrava voice dictation app
// Copyright 2024 Shrava. All rights reserved.

@_exported import Foundation

public enum ShravaCore {
    public static let version = "1.0.0"
    public static let bundleIdentifier = "com.shrava"
    public static let appGroupIdentifier = "group.com.shrava"
    public static let iCloudContainerIdentifier = "iCloud.com.shrava"
    
    public static func appGroupURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }
    
    public static func sharedTranscriptionURL() -> URL? {
        appGroupURL()?.appendingPathComponent("shared_transcription.txt")
    }
    
    public static func dictionaryStorageURL() -> URL? {
        let url = storageDirectory()?.appendingPathComponent("dictionary.json")
        return url
    }
    
    public static func historyStorageURL() -> URL? {
        let url = storageDirectory()?.appendingPathComponent("history.json")
        return url
    }
    
    public static func snippetsStorageURL() -> URL? {
        let url = storageDirectory()?.appendingPathComponent("snippets.json")
        return url
    }
    
    private static func storageDirectory() -> URL? {
        LegacyMigration.migrateApplicationSupportIfNeeded()

        #if os(iOS)
        if let groupURL = appGroupURL() {
            let dir = groupURL.appendingPathComponent("ShravaData", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        #endif
        
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let dir = appSupport.appendingPathComponent("Shrava", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        
        return nil
    }
}
