import Foundation
import Security

/// Secrets live in the macOS Keychain, never in a file, the repo or the app bundle. Items are generic passwords that stay
/// on this Mac (not synced to iCloud) and are readable only while it's unlocked.
enum Keychain {
    private static let service = "com.jaiamin.bignums"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func read(_ account: String) -> Data? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    /// Replaces any existing item rather than updating it, so the item is always created by, and trusted for, the app that
    /// wrote it. (An updated item keeps the access list of whichever build created it, which would ask for permission again
    /// after every rebuild.)
    @discardableResult
    static func write(_ data: Data, account: String) -> Bool {
        remove(account)
        var attributes = query(account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecAttrSynchronizable as String] = false
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func remove(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}

enum PlaidEnvironment: String, Codable, CaseIterable, Identifiable {
    case production, sandbox

    var id: Self { self }

    var title: String {
        switch self {
        case .production: "Production (real banks)"
        case .sandbox: "Sandbox (test data)"
        }
    }
}

/// The user's own Plaid credentials. BigNums has no server and no shared account: each person brings their own keys, so
/// their bank data only ever travels between their Mac and their own Plaid account.
struct PlaidKeys: Codable, Equatable {
    var clientID: String
    var secret: String
    var environment: PlaidEnvironment

    private static let account = "plaid-api-keys"

    var config: PlaidConfig {
        PlaidConfig(clientID: clientID, secret: secret, baseURL: "https://\(environment.rawValue).plaid.com")
    }

    static var stored: PlaidKeys? {
        Keychain.read(account).flatMap { try? JSONDecoder().decode(PlaidKeys.self, from: $0) }
    }

    @discardableResult
    func save() -> Bool {
        guard let data = try? JSONEncoder().encode(self) else { return false }
        return Keychain.write(data, account: Self.account)
    }

    static func remove() { Keychain.remove(account) }
}
