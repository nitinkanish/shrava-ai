import Foundation

public protocol CloudSyncDelegate: AnyObject, Sendable {
    func cloudSyncDidUpdateDictionary(_ entries: [DictionaryEntry])
    func cloudSyncDidUpdateHistory(_ entries: [HistoryEntry])
}

public final class CloudSyncManager: @unchecked Sendable {
    public static let shared = CloudSyncManager()
    
    private let kvStore: NSUbiquitousKeyValueStore
    private let dictionaryKey = "com.murmurapp.dictionary"
    private let historyKey = "com.murmurapp.history"
    
    public weak var delegate: CloudSyncDelegate?
    
    private var isEnabled: Bool = false
    
    public init(kvStore: NSUbiquitousKeyValueStore = .default) {
        self.kvStore = kvStore
        setupNotifications()
    }
    
    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled {
            kvStore.synchronize()
        }
    }
    
    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvStore,
            queue: .main
        ) { [weak self] notification in
            self?.handleExternalChange(notification)
        }
    }
    
    private func handleExternalChange(_ notification: Notification) {
        guard isEnabled else { return }
        
        guard let userInfo = notification.userInfo,
              let reason = userInfo[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int else {
            return
        }
        
        if reason == NSUbiquitousKeyValueStoreServerChange ||
           reason == NSUbiquitousKeyValueStoreInitialSyncChange {
            
            if let changedKeys = userInfo[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] {
                for key in changedKeys {
                    if key == dictionaryKey {
                        if let data = kvStore.data(forKey: dictionaryKey),
                           let entries = try? JSONDecoder().decode([DictionaryEntry].self, from: data) {
                            delegate?.cloudSyncDidUpdateDictionary(entries)
                        }
                    } else if key == historyKey {
                        if let data = kvStore.data(forKey: historyKey),
                           let entries = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
                            delegate?.cloudSyncDidUpdateHistory(entries)
                        }
                    }
                }
            }
        }
    }
    
    public func syncDictionary(_ entries: [DictionaryEntry]) {
        guard isEnabled else { return }
        
        if let data = try? JSONEncoder().encode(entries) {
            kvStore.set(data, forKey: dictionaryKey)
            kvStore.synchronize()
        }
    }
    
    public func syncHistory(_ entries: [HistoryEntry]) {
        guard isEnabled else { return }
        
        let limitedEntries = Array(entries.prefix(100))
        
        if let data = try? JSONEncoder().encode(limitedEntries) {
            kvStore.set(data, forKey: historyKey)
            kvStore.synchronize()
        }
    }
    
    public func fetchDictionary() -> [DictionaryEntry]? {
        guard isEnabled else { return nil }
        
        if let data = kvStore.data(forKey: dictionaryKey),
           let entries = try? JSONDecoder().decode([DictionaryEntry].self, from: data) {
            return entries
        }
        return nil
    }
    
    public func fetchHistory() -> [HistoryEntry]? {
        guard isEnabled else { return nil }
        
        if let data = kvStore.data(forKey: historyKey),
           let entries = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            return entries
        }
        return nil
    }
}
