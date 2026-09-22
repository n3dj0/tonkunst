import Foundation
import Security

enum KeychainStore {
    private static let account = "tonkunst.server.profile"
    private static let service = "com.tonkunst.music"
    private static let activeAccountKey = "tonkunst.activeProfileID"

    enum StorageError: LocalizedError {
        case unavailable(OSStatus)
        case invalidData

        var errorDescription: String? {
            switch self {
            case .unavailable(let status):
                "Tonkunst could not access your saved accounts (Keychain error \(status))."
            case .invalidData:
                "Tonkunst could not read your saved accounts from the Keychain."
            }
        }
    }

    private static var itemQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func save(_ profile: ServerProfile) throws -> [ServerProfile] {
        var profiles = try loadProfiles()
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        try write(profiles)
        UserDefaults.standard.set(profile.id, forKey: activeAccountKey)
        return profiles
    }

    static func load() throws -> (profiles: [ServerProfile], active: ServerProfile?) {
        let profiles = try loadProfiles()
        let activeID: String
        if let savedID = UserDefaults.standard.string(forKey: activeAccountKey) {
            activeID = savedID
        } else {
            // Before saved accounts existed, the single Keychain profile was active.
            activeID = profiles.first?.id ?? ""
            UserDefaults.standard.set(activeID, forKey: activeAccountKey)
        }
        return (profiles, profiles.first { $0.id == activeID })
    }

    static func activate(_ profile: ServerProfile) {
        UserDefaults.standard.set(profile.id, forKey: activeAccountKey)
    }

    static func signOut() {
        UserDefaults.standard.set("", forKey: activeAccountKey)
    }

    static func remove(_ profile: ServerProfile) throws -> [ServerProfile] {
        let profiles = try loadProfiles().filter { $0.id != profile.id }
        try write(profiles)
        return profiles
    }

    private static func loadProfiles() throws -> [ServerProfile] {
        var query = itemQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw StorageError.unavailable(status) }
        guard let data = item as? Data else { throw StorageError.invalidData }
        if let profiles = try? JSONDecoder().decode([ServerProfile].self, from: data) {
            return profiles
        }
        // Read profiles saved by previous versions without losing the session.
        if let profile = try? JSONDecoder().decode(ServerProfile.self, from: data) {
            return [profile]
        }
        throw StorageError.invalidData
    }

    private static func write(_ profiles: [ServerProfile]) throws {
        if profiles.isEmpty {
            let status = SecItemDelete(itemQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw StorageError.unavailable(status)
            }
            return
        }

        let data = try JSONEncoder().encode(profiles)
        let status = SecItemUpdate(itemQuery as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = itemQuery
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw StorageError.unavailable(addStatus) }
        } else if status != errSecSuccess {
            throw StorageError.unavailable(status)
        }
    }
}
