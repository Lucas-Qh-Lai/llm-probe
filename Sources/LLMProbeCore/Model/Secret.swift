import Foundation

/// Resolves `SecretSource` values at request time.
public enum SecretResolver {
    public static func resolve(_ source: SecretSource, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        switch source {
        case .none:
            return nil
        case .inline(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .environment(let name):
            guard let raw = environment[name] else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .file(let path):
            let expanded = PathTools.expand(path)
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: expanded)),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .keychain(let service, let account):
            return KeychainReader.genericPassword(service: service, account: account)
        }
    }
}

#if canImport(Security)
import Security

/// Minimal read-only Keychain access. Writes are intentionally not implemented:
/// the app never stores a credential the user did not type into their own tools.
public enum KeychainReader {
    public static func genericPassword(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
#else
public enum KeychainReader {
    /// Keychain access is macOS-only; other platforms fall back to no credential.
    public static func genericPassword(service: String, account: String) -> String? { nil }
}
#endif
