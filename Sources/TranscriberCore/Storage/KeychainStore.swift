import Foundation
import LocalAuthentication
import Security

/// Injectable seam for Cloud API key Keychain persistence.
/// Tests supply a fake; production code uses `KeychainStore`.
public protocol KeychainPersisting: Sendable {
    func write(_ value: String) throws
    func read(allowingUserInteraction: Bool) throws -> String?
    func delete(allowingUserInteraction: Bool) throws
}

public extension KeychainPersisting {
    func read() throws -> String? {
        try read(allowingUserInteraction: true)
    }

    func delete() throws {
        try delete(allowingUserInteraction: true)
    }
}

public final class KeychainStore: Sendable, KeychainPersisting {
    public enum KeychainError: Error { case osStatus(OSStatus) }

    private let service: String
    private let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    public func write(_ value: String) throws {
        let data = Data(value.utf8)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // Codex rc1-final P1.9: SECURITY.md documents the
        // `kSecAttrAccessibleAfterFirstUnlock` policy. Set it
        // explicitly so a fresh keychain entry isn't accidentally
        // accessible only when the user is logged in (the default
        // varies across macOS versions). After-first-unlock is the
        // right balance: the entry is unavailable until the user has
        // unlocked the device once after boot, then survives screen
        // locks for the rest of the session.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.osStatus(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.osStatus(updateStatus)
        }
    }

    public func read(allowingUserInteraction: Bool = true) throws -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if allowingUserInteraction == false {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.osStatus(status)
        }
    }

    public func delete(allowingUserInteraction: Bool = true) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if allowingUserInteraction == false {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.osStatus(status)
        }
    }
}
