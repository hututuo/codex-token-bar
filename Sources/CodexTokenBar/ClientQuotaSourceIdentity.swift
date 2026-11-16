import CryptoKit
import Foundation

/// The existing history source key also separates independently observed
/// organizations. Only a digest is stored; old unscoped rows stay untouched.
enum ClientQuotaSourceIdentity {
    private static let marker = "@scope:"

    static func scoped(_ source: String, organization: String?) -> String {
        guard let raw = organization?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, raw.utf8.count <= 256,
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return source }
        let digest = SHA256.hash(data: Data(("claude-org:v1:" + raw.lowercased()).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return source + marker + digest
    }

    static func base(_ source: String) -> String {
        guard let range = source.range(of: marker),
              source[range.upperBound...].count == 64,
              source[range.upperBound...].allSatisfy({ "0123456789abcdef".contains($0) }) else { return source }
        return String(source[..<range.lowerBound])
    }

    static func historyLabel(_ source: String, ordinal: Int) -> String {
        base(source) == source ? "历史采样 · 身份未验证" : "历史采样 \(ordinal) · 独立组织"
    }
}
