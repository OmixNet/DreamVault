import Foundation
import Security

/// P4-T3: 简易 Keychain 包装（macOS Generic Password 项）。
///
/// 用法：
///   try Keychain.save("sk-...", itemName: "com.OmixNet.dreamvault.openai-key")
///   let key = try Keychain.load(itemName: "com.OmixNet.dreamvault.openai-key")
///   try Keychain.delete(itemName: "...")
///
/// 错误不抛到 GUI 顶层——Keychain 拒访常见（用户在系统设置改了权限），GUI 应
/// 退回"未设置"状态并提示去 System Settings → Privacy → Keychain 授权。
public enum Keychain {

    public enum KeychainError: Error, LocalizedError {
        case unhandled(OSStatus)
        case notFound
        case unexpectedData
        public var errorDescription: String? {
            switch self {
            case .unhandled(let s):
                return "Keychain error (OSStatus \(s)): \(SecCopyErrorMessageString(s, nil) as String? ?? "unknown")"
            case .notFound: return "Keychain item not found"
            case .unexpectedData: return "Keychain data in unexpected format"
            }
        }
    }

    /// 保存（或覆盖）一个 keychain item。service 用 bundle id。
    public static func save(_ secret: String, itemName: String,
                            service: String = defaultService) throws {
        let data = Data(secret.utf8)
        // 先删再存（add 会冲突）
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: itemName,
        ]
        let deleteStatus = SecItemDelete(query as CFDictionary)
        // errSecItemNotFound (-25300) 在 delete 时是 OK 的（说明没旧条目）
        if deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound {
            throw KeychainError.unhandled(deleteStatus)
        }
        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unhandled(addStatus)
        }
    }

    /// 读取 keychain item；不存在抛 .notFound
    public static func load(itemName: String,
                            service: String = defaultService) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: itemName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else { throw KeychainError.notFound }
        guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
        guard let data = item as? Data,
              let str = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedData
        }
        return str
    }

    /// 软读：不存在返回 nil（不抛）
    public static func loadIfPresent(itemName: String,
                                     service: String = defaultService) -> String? {
        do { return try load(itemName: itemName, service: service) }
        catch { return nil }
    }

    public static func delete(itemName: String,
                              service: String = defaultService) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: itemName,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.unhandled(status)
        }
    }

    public static let defaultService = "com.OmixNet.dreamvault"
}
