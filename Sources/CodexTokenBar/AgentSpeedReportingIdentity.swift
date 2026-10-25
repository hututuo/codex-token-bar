import AgentSpeedCore
import CryptoKit
import Foundation
import Security

/// Separate device identity; never reads Codex authentication or the Agent Speed app's keys.
enum AgentSpeedReportingIdentity {
    enum Failure: Error { case unavailable, unreadable }
    static let service = "local.codex.token-bar.speed-report"

    static func signer(deviceID: String) throws -> any ReportSigner {
        guard ReportCanonical.isDeviceId(deviceID) else { throw Failure.unavailable }
        if SecureEnclave.isAvailable {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("CodexTokenBar/agent-speed-report", isDirectory: true)
            let file = directory.appendingPathComponent(deviceID + ".sekey")
            if FileManager.default.fileExists(atPath: file.path) {
                // Never silently replace a registered device's unreadable key.
                return EnclaveSigner(key: try .init(dataRepresentation: Data(contentsOf: file)))
            }
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                                            [.privateKeyUsage], &error) else { throw Failure.unavailable }
            let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try key.dataRepresentation.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return EnclaveSigner(key: key)
        }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: deviceID]
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess, let raw = result as? Data {
            return SoftwareReportSigner(key: try P256.Signing.PrivateKey(rawRepresentation: raw))
        }
        guard status == errSecItemNotFound else { throw Failure.unreadable }
        let key = P256.Signing.PrivateKey()
        var insert = query
        insert[kSecValueData as String] = key.rawRepresentation
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw Failure.unavailable }
        return SoftwareReportSigner(key: key)
    }

    private struct EnclaveSigner: ReportSigner {
        let key: SecureEnclave.P256.Signing.PrivateKey
        var publicKey: ReportPublicKey { ReportPublicKey(raw: key.publicKey.rawRepresentation)! }
        func signature(for message: Data) throws -> Data { try key.signature(for: message).rawRepresentation }
    }
}
