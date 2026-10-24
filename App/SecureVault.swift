import Foundation
import Security

actor SecureVault {
    private let service = "com.wujie.moxu.credentials"
    func value(_ id: UUID) throws -> String {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString, kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8)
        else { throw VaultError(status) }
        return value
    }
    func save(_ value: String, id: UUID) throws {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        if value.isEmpty {
            let status = SecItemDelete(q as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError(status) }
            return
        }
        let attrs: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var insert = q
            for (k, v) in attrs { insert[k] = v }
            let add = SecItemAdd(insert as CFDictionary, nil)
            guard add == errSecSuccess else { throw VaultError(add) }
        } else if status != errSecSuccess {
            throw VaultError(status)
        }
    }
}
private struct VaultError: Error, LocalizedError {
    let status: OSStatus
    init(_ status: OSStatus) { self.status = status }
    var errorDescription: String? { "钥匙串读写失败（\(status)）。" }
}
