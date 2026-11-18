import Foundation
import Security

/// Speichert Passwörter ausschließlich im macOS-Schlüsselbund (Generic Password,
/// Service „de.reichi.sync“, Account = Verbindungs-ID).
struct KeychainStore: Sendable {
    enum KeychainError: Error, LocalizedError {
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "Status \(status)"
                return "Schlüsselbund-Fehler: \(message)"
            }
        }
    }

    static let service = "de.reichi.sync"

    private func baseQuery(accountID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: accountID,
        ]
    }

    func savePassword(_ password: String, accountID: String, label: String) throws {
        let data = Data(password.utf8)
        var query = baseQuery(accountID: accountID)
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrLabel as String: label]
            let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard update == errSecSuccess else { throw KeychainError.unexpectedStatus(update) }
        } else if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrLabel as String] = label
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let add = SecItemAdd(query as CFDictionary, nil)
            guard add == errSecSuccess else { throw KeychainError.unexpectedStatus(add) }
        } else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func password(accountID: String) throws -> String? {
        var query = baseQuery(accountID: accountID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError.unexpectedStatus(status) }
        return String(data: data, encoding: .utf8)
    }

    func deletePassword(accountID: String) throws {
        let status = SecItemDelete(baseQuery(accountID: accountID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.unexpectedStatus(status) }
    }
}
