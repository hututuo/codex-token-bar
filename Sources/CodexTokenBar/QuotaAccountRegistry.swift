import Foundation
import CryptoKit
import Security
import Darwin

struct QuotaAccountEntry: Codable, Identifiable, Sendable {
    var id: String
    var label: String
    var sourcePath: String?
}

struct QuotaAccountRegistryState: Codable, Sendable {
    var version = 1
    var revision = 0
    var selectedID: String?
    var accounts: [QuotaAccountEntry] = []
}

/// The manifest contains metadata only. OAuth access tokens stay in Keychain.
/// Refresh tokens remain owned by the original client; we never copy or rotate them.
enum QuotaAccountRegistry {
    static let service = "com.codextokenbar.quota-accounts"
    static let changed = Notification.Name("CodexTokenBar.quotaAccountsChanged")
    private static let lock = NSRecursiveLock()
    nonisolated(unsafe) static var lastObservedHome: URL?
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexTokenBar")
    }
    private static var manifest: URL { root.appendingPathComponent("quota-accounts.json") }

    static func state() throws -> QuotaAccountRegistryState {
        guard FileManager.default.fileExists(atPath: manifest.path) else { return .init() }
        let data = try limitedRead(manifest)
        guard data.count <= 1_048_576 else { throw DirectQuotaError.response }
        let state = try JSONDecoder().decode(QuotaAccountRegistryState.self, from: data)
        guard state.version == 1, state.selectedID == nil || state.accounts.contains(where: { $0.id == state.selectedID }) else { throw DirectQuotaError.response }
        return state
    }

    static func currentCredential(home: URL?) throws -> QuotaAccountCredential {
        let home = (home ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex"))
            .standardizedFileURL.resolvingSymlinksInPath()
        let configText = (try? limitedRead(home.appendingPathComponent("config.toml"))).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let config = configText.components(separatedBy: .newlines).prefix { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }.joined(separator: "\n")
        let keyring = config.range(of: #"(?m)^\s*cli_auth_credentials_store\s*=\s*["'](keyring|auto)["']"#, options: .regularExpression) != nil
        if keyring {
            let digest = SHA256.hash(data: Data(home.path.utf8)).map { String(format: "%02x", $0) }.joined()
            if let data = try? secret(service: "Codex Auth", id: "cli|" + digest.prefix(16)) {
                return try QuotaAccountCredential.parse(data)
            }
            if config.range(of: #"(?m)^\s*cli_auth_credentials_store\s*=\s*["']keyring["']"#, options: .regularExpression) != nil {
                throw DirectQuotaError.credentials
            }
        }
        guard let data = try? limitedRead(home.appendingPathComponent("auth.json")) else {
            throw DirectQuotaError.credentials
        }
        return try QuotaAccountCredential.parse(data)
    }

    static func credential(home: URL?, currentOnly: Bool = false) throws -> QuotaAccountCredential {
        lock.lock(); lastObservedHome = home; lock.unlock()
        let registry = try state()
        guard !currentOnly, let selected = registry.selectedID else {
            return try currentCredential(home: home)
        }
        guard let entry = registry.accounts.first(where: { $0.id == selected }) else { throw DirectQuotaError.credentials }
        // Choose the freshest matching token, never a different account from a rewritten file.
        var candidates: [QuotaAccountCredential] = []
        if let current = try? currentCredential(home: home) { candidates.append(current) }
        if let path = entry.sourcePath, let data = try? limitedRead(URL(fileURLWithPath: path)),
           let linked = try? QuotaAccountCredential.parse(data) { candidates.append(linked) }
        if let data = try? secret(service: service, id: selected),
           let saved = try? JSONDecoder().decode(QuotaAccountCredential.self, from: data) { candidates.append(saved) }
        guard let fresh = QuotaAccountCredential.freshest(candidates, accountID: selected) else { throw DirectQuotaError.credentials }
        try? updateSecretIfChanged(fresh)
        return fresh
    }

    static func selectionKey(home: URL?) -> String {
        guard let state = try? state() else { return "invalid-registry" }
        let account = try? credential(home: home)
        return "\(state.revision):\(state.selectedID ?? "local"):\(account?.id ?? "unavailable")"
    }

    static func saveCurrent() throws {
        lock.lock(); let home = lastObservedHome; lock.unlock()
        let credential = try currentCredential(home: home)
        let path = (home ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex"))
            .appendingPathComponent("auth.json").path
        try save(credential, sourcePath: path)
    }

    static func importFile(_ url: URL) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 1_048_576 else { throw DirectQuotaError.credentials }
        try save(QuotaAccountCredential.parse(limitedRead(url)), sourcePath: url.path)
    }

    static func save(_ credential: QuotaAccountCredential, sourcePath: String?) throws {
        try mutate { state in
            try writeSecret(id: credential.id, data: JSONEncoder().encode(credential))
            let entry = QuotaAccountEntry(id: credential.id, label: credential.label, sourcePath: sourcePath)
            if let index = state.accounts.firstIndex(where: { $0.id == credential.id }) { state.accounts[index] = entry }
            else { state.accounts.append(entry) }
            state.selectedID = credential.id
        }
    }

    static func select(_ id: String?) throws {
        try mutate { state in
            guard id == nil || state.accounts.contains(where: { $0.id == id }) else { throw DirectQuotaError.credentials }
            state.selectedID = id
        }
    }

    static func remove(_ id: String) throws {
        try mutate { state in
            state.accounts.removeAll { $0.id == id }
            if state.selectedID == id { state.selectedID = nil }
            SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id] as CFDictionary)
        }
    }

    private static func mutate(_ body: (inout QuotaAccountRegistryState) throws -> Void) throws {
        try withRegistryLock {
            var state = try state()
            try body(&state)
            state.revision += 1
            try JSONEncoder().encode(state).write(to: manifest, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    private static func withRegistryLock<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let descriptor = open(root.appendingPathComponent("quota-accounts.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw DirectQuotaError.vault }
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw DirectQuotaError.vault }
        return try body()
    }

    private static func limitedRead(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576 else { throw DirectQuotaError.credentials }
        return data
    }

    private static func updateSecretIfChanged(_ credential: QuotaAccountCredential) throws {
        let data = try JSONEncoder().encode(credential)
        if let existing = try? secret(service: service, id: credential.id),
           let saved = try? JSONDecoder().decode(QuotaAccountCredential.self, from: existing),
           saved.accessToken == credential.accessToken { return }
        try withRegistryLock {
            guard try state().accounts.contains(where: { $0.id == credential.id }) else { return }
            // Another process may have refreshed the account while this reader waited.
            if let existing = try? secret(service: service, id: credential.id),
               let saved = try? JSONDecoder().decode(QuotaAccountCredential.self, from: existing),
               saved.id == credential.id,
               saved.accessToken == credential.accessToken || saved.expiresAt > credential.expiresAt { return }
            try writeSecret(id: credential.id, data: data)
        }
    }

    private static func secret(service: String, id: String) throws -> Data {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecAttrAccount: id, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationUI: kSecUseAuthenticationUIFail]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data else { throw DirectQuotaError.vault }
        return data
    }

    private static func writeSecret(id: String, data: Data) throws {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query; insert[kSecValueData] = data
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw DirectQuotaError.vault }
        } else if status != errSecSuccess { throw DirectQuotaError.vault }
    }
}
