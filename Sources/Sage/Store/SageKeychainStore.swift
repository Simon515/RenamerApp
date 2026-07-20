import Foundation
import Security

/// Keychain 读写错误。
public enum SageKeychainError: LocalizedError, Sendable {
    case missing(account: String)
    case osStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .missing(let account):
            return "Keychain 中未找到 account「\(account)」对应的 API Key。"
        case .osStatus(let status):
            return "Keychain 操作失败，OSStatus = \(status)。"
        }
    }
}

/// API Key 等 secret 的持久化（spec §10）。
public struct SageKeychainStore: Sendable {
    private let service: String

    public init(service: String = "com.jiyuliang.Sage") {
        self.service = service
    }

    public func read(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                return nil
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw SageKeychainError.osStatus(status)
        }
    }

    public func write(account: String, value: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw SageKeychainError.osStatus(addStatus) }
        } else if status != errSecSuccess {
            throw SageKeychainError.osStatus(status)
        }
    }

    public func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw SageKeychainError.osStatus(status)
        }
    }
}