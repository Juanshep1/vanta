import Foundation
import Security

/// API keys in the macOS Keychain (generic passwords, one per provider), never
/// in UserDefaults. Values are cached in memory after the first read so the
/// Keychain is touched once per provider per launch.
///
/// Under `--snapshot`, `--selftest` or the mock provider the Keychain is never
/// read or written.
final class KeyStore {
    static let shared = KeyStore()
    private let service = "com.juanshep.vantastudio.ai"
    private var cache: [String: String] = [:]

    /// When true (tests / mock mode) nothing touches the real Keychain.
    var sandboxed = false

    func key(for provider: String) -> String {
        if let v = cache[provider] { return v }
        if sandboxed { return "" }
        let v = read(provider) ?? ""
        cache[provider] = v
        return v
    }

    func setKey(_ value: String, for provider: String) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        cache[provider] = v
        guard !sandboxed else { return }
        if v.isEmpty { delete(provider) } else { write(v, for: provider) }
    }

    func hasKey(_ provider: String) -> Bool { !key(for: provider).isEmpty }

    // MARK: Security framework

    private func baseQuery(_ provider: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: provider]
    }

    private func read(_ provider: String) -> String? {
        var q = baseQuery(provider)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private func write(_ value: String, for provider: String) {
        let data = Data(value.utf8)
        let q = baseQuery(provider)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Vanta Studio – \(AIProvider.name(provider)) API key"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private func delete(_ provider: String) {
        SecItemDelete(baseQuery(provider) as CFDictionary)
    }
}
