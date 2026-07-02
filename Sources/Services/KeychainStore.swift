import Foundation
import Security

/// Keychain 操作错误，携带底层 OSStatus 以便诊断。
struct KeychainError: LocalizedError, Sendable {
    let status: OSStatus
    let operation: String

    var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "未知错误"
        return "Keychain \(operation) 失败（\(status)）：\(message)"
    }
}

/// 基于 Security 框架 `kSecClassGenericPassword` 的最小封装，用于安全存储凭据。
struct KeychainStore: Sendable {
    let service: String

    /// 读取指定 account 的值；不存在时返回 nil。
    func read(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainError(status: status, operation: "读取")
        }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    /// 写入 account 的值；已存在则更新。
    func write(account: String, value: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let existing = SecItemCopyMatching(query as CFDictionary, nil)
        if existing == errSecSuccess {
            let attributes: [String: Any] = [kSecValueData as String: data]
            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard status == errSecSuccess else {
                throw KeychainError(status: status, operation: "更新")
            }
        } else if existing == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let status = SecItemAdd(addQuery as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw KeychainError(status: status, operation: "写入")
            }
        } else {
            throw KeychainError(status: existing, operation: "查询")
        }
    }

    /// 删除 account 的条目；不存在时不视为错误。
    func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status, operation: "删除")
        }
    }
}
