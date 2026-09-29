import Foundation
import CryptoKit
import Security

/// Reads the credential for the Codex Home currently selected in app settings.
enum CurrentCodexCredentialReader {
    static func currentCredential(home: URL?) throws -> QuotaAccountCredential {
        let codexHome = (home ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex"))
            .standardizedFileURL.resolvingSymlinksInPath()
        let configURL = codexHome.appendingPathComponent("config.toml")
        let configText = (try? limitedRead(configURL)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let globalConfig = configText.components(separatedBy: .newlines)
            .prefix { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }
            .joined(separator: "\n")
        let storeMode = globalConfig.range(
            of: #"(?m)^\s*cli_auth_credentials_store\s*=\s*["'](keyring|auto)["']"#,
            options: .regularExpression
        )
        if storeMode != nil {
            let digest = SHA256.hash(data: Data(codexHome.path.utf8))
                .map { String(format: "%02x", $0) }.joined()
            if let data = try? keychainSecret(account: "cli|" + digest.prefix(16)) {
                return try QuotaAccountCredential.parse(data)
            }
            if globalConfig.range(
                of: #"(?m)^\s*cli_auth_credentials_store\s*=\s*["']keyring["']"#,
                options: .regularExpression
            ) != nil {
                throw DirectQuotaError.credentials
            }
        }
        return try QuotaAccountCredential.parse(limitedRead(codexHome.appendingPathComponent("auth.json")))
    }

    private static func limitedRead(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576 else { throw DirectQuotaError.credentials }
        return data
    }

    private static func keychainSecret(account: String) throws -> Data {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "Codex Auth",
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationUI: kSecUseAuthenticationUIFail,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw DirectQuotaError.credentials
        }
        return data
    }
}
