import Foundation
import Security

/// Speichert Passwörter ausschließlich im macOS-Schlüsselbund (Generic Password,
/// Service „de.reichi.sync“, Account = Verbindungs-ID).
struct KeychainStore: Sendable {
    enum KeychainError: Error, LocalizedError {
        case unexpectedStatus(OSStatus)
        case invalidData

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "Status \(status)"
                return "Schlüsselbund-Fehler: \(message)"
            case .invalidData:
                return "Der Schlüsselbund-Eintrag enthält keine gültigen Textdaten."
            }
        }
    }

    static let service = "de.reichi.sync"

    private func baseQuery(accountID: String, dataProtection: Bool = false) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: accountID,
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    func savePassword(_ password: String, accountID: String, label: String) throws {
        let data = Data(password.utf8)
        var query = baseQuery(accountID: accountID)
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrLabel as String: label,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard update == errSecSuccess else { throw KeychainError.unexpectedStatus(update) }
        } else if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrLabel as String] = label
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let add = SecItemAdd(query as CFDictionary, nil)
            guard add == errSecSuccess else { throw KeychainError.unexpectedStatus(add) }
        } else {
            throw KeychainError.unexpectedStatus(status)
        }
        // Frühere Builds konnten bei einer profilierten Xcode-Signatur den
        // Data-Protection-Keychain verwenden. Profilfreie ad-hoc- und
        // Developer-ID-Builds besitzen dessen Access-Group-Entitlement nicht;
        // nach erfolgreicher Migration wird der alte Eintrag daher nur
        // best-effort entfernt.
        _ = SecItemDelete(baseQuery(accountID: accountID, dataProtection: true) as CFDictionary)
    }

    func password(accountID: String) throws -> String? {
        var query = baseQuery(accountID: accountID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            // Einmalige Migration aus einem DPK-Eintrag, sofern die aktuelle
            // Signatur darauf zugreifen darf.
            var protected = baseQuery(accountID: accountID, dataProtection: true)
            protected[kSecReturnData as String] = true
            protected[kSecMatchLimit as String] = kSecMatchLimitOne
            var protectedItem: CFTypeRef?
            let protectedStatus = SecItemCopyMatching(protected as CFDictionary, &protectedItem)
            if protectedStatus == errSecItemNotFound || protectedStatus == errSecMissingEntitlement { return nil }
            guard protectedStatus == errSecSuccess, let protectedData = protectedItem as? Data else {
                throw KeychainError.unexpectedStatus(protectedStatus)
            }
            guard let password = String(data: protectedData, encoding: .utf8) else { throw KeychainError.invalidData }
            try savePassword(password, accountID: accountID, label: "reichi Sync")
            return password
        }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError.unexpectedStatus(status) }
        guard let password = String(data: data, encoding: .utf8) else { throw KeychainError.invalidData }
        return password
    }

    func deletePassword(accountID: String) throws {
        let status = SecItemDelete(baseQuery(accountID: accountID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.unexpectedStatus(status) }
        let protectedStatus = SecItemDelete(baseQuery(accountID: accountID, dataProtection: true) as CFDictionary)
        guard protectedStatus == errSecSuccess || protectedStatus == errSecItemNotFound
                || protectedStatus == errSecMissingEntitlement else {
            throw KeychainError.unexpectedStatus(protectedStatus)
        }
    }
}
