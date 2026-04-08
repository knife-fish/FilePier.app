import Foundation
import Security

protocol ServerCredentialStore {
    func password(for serverID: UUID) throws -> String?
    func setPassword(_ password: String, for serverID: UUID) throws
    func removePassword(for serverID: UUID) throws
}

enum ServerCredentialStoreError: LocalizedError {
    case unexpectedData
    case keychainFailure(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .unexpectedData:
            return "Saved credentials were unreadable."
        case .keychainFailure(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return message
            }
            return "Keychain error \(status)."
        }
    }
}

struct KeychainServerCredentialStore: ServerCredentialStore {
    let service: String

    init(service: String = AppConfiguration.keychainService) {
        self.service = service
    }

    func password(for serverID: UUID) throws -> String? {
        var query = baseQuery(for: serverID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw ServerCredentialStoreError.keychainFailure(status: status)
        }
        guard
            let data = item as? Data,
            let password = String(data: data, encoding: .utf8)
        else {
            throw ServerCredentialStoreError.unexpectedData
        }
        return password
    }

    func setPassword(_ password: String, for serverID: UUID) throws {
        let passwordData = Data(password.utf8)
        let query = baseQuery(for: serverID)
        let attributes = [kSecValueData as String: passwordData]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw ServerCredentialStoreError.keychainFailure(status: updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = passwordData
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw ServerCredentialStoreError.keychainFailure(status: addStatus)
        }
    }

    func removePassword(for serverID: UUID) throws {
        let status = SecItemDelete(baseQuery(for: serverID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ServerCredentialStoreError.keychainFailure(status: status)
        }
    }

    private func baseQuery(for serverID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverID.uuidString
        ]
    }
}

final class InMemoryServerCredentialStore: ServerCredentialStore {
    private var passwords: [UUID: String]

    init(passwords: [UUID: String] = [:]) {
        self.passwords = passwords
    }

    func password(for serverID: UUID) throws -> String? {
        passwords[serverID]
    }

    func setPassword(_ password: String, for serverID: UUID) throws {
        passwords[serverID] = password
    }

    func removePassword(for serverID: UUID) throws {
        passwords.removeValue(forKey: serverID)
    }
}
