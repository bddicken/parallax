import Foundation
import Security

/// Stores the server token and platform settings outside the JSON profile, in
/// a file only you can read (like the built-in server's sign-ins).
///
/// Not the Keychain: Parallax is signed without a team ID, so macOS ties
/// Keychain access to the exact binary and asks for your password again after
/// every rebuild.
public struct SecretStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func read(_ account: String) -> String? {
        load()[account]
    }

    public func write(_ value: String?, for account: String) {
        var secrets = load()
        secrets[account] = value?.isEmpty == false ? value : nil
        save(secrets)
    }

    /// Copies `accounts` from where older builds kept them, the first time
    /// only. macOS asks for your password once more to allow it.
    public func importFromKeychain(_ accounts: [String]) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        save(Dictionary(uniqueKeysWithValues: accounts.compactMap { account in
            Self.keychainValue(account).map { (account, $0) }
        }))
    }

    private func load() -> [String: String] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func save(_ secrets: [String: String]) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(secrets) else { return }
        // Created owner-only, then moved into place, so it's never readable by others.
        let temp = dir.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if rename(temp.path, url.path) != 0 {
            try? FileManager.default.removeItem(at: temp)
        }
    }

    private static func keychainValue(_ account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: "com.bddicken.parallax", kSecAttrAccount: account,
            kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
