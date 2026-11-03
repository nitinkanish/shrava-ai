import Foundation
import Security

public enum KeychainError: Error, Sendable {
    case itemNotFound
    case duplicateItem
    case unexpectedStatus(OSStatus)
    case encodingFailed
    case decodingFailed
}

public final class KeychainManager: Sendable {
    public static let shared = KeychainManager()
    
    private let service: String
    private let accessGroup: String?
    
    public init(service: String = "com.murmurapp", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }
    
    public func save(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        
        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        
        #if os(macOS)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        #else
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        
        var status = SecItemAdd(query as CFDictionary, nil)
        
        if status == errSecDuplicateItem {
            let updateQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key
            ]
            
            let attributes: [String: Any] = [
                kSecValueData as String: data
            ]
            
            status = SecItemUpdate(updateQuery as CFDictionary, attributes as CFDictionary)
        }
        
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
    
    public func load(key: String) throws -> String {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw KeychainError.itemNotFound
            }
            throw KeychainError.unexpectedStatus(status)
        }
        
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.decodingFailed
        }
        
        return value
    }
    
    public func delete(key: String) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        
        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        
        let status = SecItemDelete(query as CFDictionary)
        
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
    
    public func exists(key: String) -> Bool {
        do {
            _ = try load(key: key)
            return true
        } catch {
            return false
        }
    }
}
