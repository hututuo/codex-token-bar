import Foundation
import Security

/// One signed API request (REPORTING 2.3, 5). Headers keep their order; the body is sent exactly as signed.
public struct ReportRequest: Sendable {
    public struct Header: Equatable, Sendable {
        public var name: String
        public var value: String
    }

    public var method: String
    public var url: URL
    public var headers: [Header]
    public var body: Data

    public func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// The canonical string of REPORTING 5.3 and the header rules of 5.2.
public enum ReportCanonical {
    public static let label = "AGENTSPEED-V1"
    public static let deviceHeader = "X-AgentSpeed-Device"
    public static let timestampHeader = "X-AgentSpeed-Timestamp"
    public static let nonceHeader = "X-AgentSpeed-Nonce"
    public static let signatureHeader = "X-AgentSpeed-Signature"
    public static let newKeySignatureHeader = "X-AgentSpeed-New-Key-Signature"

    /// Eight lines joined by a line feed, no final line feed.
    public static func string(
        method: String, authority: String, path: String, timestamp: String, nonce: String, deviceId: String, body: Data
    ) -> String {
        [label, method, authority, path, timestamp, nonce, deviceId, ReportHash.sha256Hex(body)].joined(separator: "\n")
    }

    /// The first missing or malformed signature header (header names in any case), or nil (REPORTING 5.2).
    public static func malformedHeader(in headers: [String: String]) -> String? {
        let lower = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { $1 })
        if !isDeviceId(lower[deviceHeader.lowercased()] ?? "") { return deviceHeader }
        if !isTimestamp(lower[timestampHeader.lowercased()] ?? "") { return timestampHeader }
        if Base64URL.decode(lower[nonceHeader.lowercased()] ?? "")?.count != 16 { return nonceHeader }
        if !isSignature(lower[signatureHeader.lowercased()] ?? "") { return signatureHeader }
        return nil
    }

    /// 86 canonical base64url characters that decode to 64 bytes.
    public static func isSignature(_ text: String) -> Bool {
        text.utf8.count == 86 && Base64URL.decode(text)?.count == 64
    }

    /// A lower-case version-4 UUID.
    public static func isDeviceId(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard bytes.count == 36 else { return false }
        for (index, byte) in bytes.enumerated() {
            switch index {
            case 8, 13, 18, 23: guard byte == UInt8(ascii: "-") else { return false }
            case 14: guard byte == UInt8(ascii: "4") else { return false }
            case 19: guard "89ab".utf8.contains(byte) else { return false }
            default: guard "0123456789abcdef".utf8.contains(byte) else { return false }
            }
        }
        return true
    }

    private static func isTimestamp(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return bytes.count == 10 && bytes[0] != UInt8(ascii: "0") && bytes.allSatisfy { (48...57).contains($0) }
    }

    /// A fresh lower-case version-4 UUID (device ids, run ids).
    public static func newUUID() -> String {
        UUID().uuidString.lowercased()
    }

    /// 16 bytes from the system's cryptographic generator (REPORTING 5.2).
    public static func newNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max, using: &generator) }
        }
        return Base64URL.encode(bytes)
    }
}

/// Builds the requests of one device (REPORTING 2.3, 5.2): the fixed headers, the four signature headers and, when
/// the user entered one, the API key.
public struct ReportRequestBuilder: Sendable {
    public var userAgent: String
    public var deviceId: String
    public var apiKey: String?

    public init(userAgent: String, deviceId: String, apiKey: String?) {
        self.userAgent = userAgent
        self.deviceId = deviceId
        self.apiKey = apiKey
    }

    /// `timestamp` is Unix seconds (the session's clock correction applied); `newKey` adds the rotation header.
    public func make(
        method: String, url: URL, body: Data, signer: any ReportSigner, timestamp: Int64,
        nonce: String = ReportCanonical.newNonce(), newKey: (any ReportSigner)? = nil
    ) throws -> ReportRequest {
        let stamp = String(timestamp)
        let canonical = Data(ReportCanonical.string(
            method: method, authority: ReportURLs.authority(of: url), path: ReportURLs.requestPath(of: url),
            timestamp: stamp, nonce: nonce, deviceId: deviceId, body: body
        ).utf8)
        var headers = [
            ReportRequest.Header(name: "User-Agent", value: userAgent),
            ReportRequest.Header(name: "Accept", value: "application/json"),
        ]
        if !body.isEmpty { headers.append(.init(name: "Content-Type", value: "application/json")) }
        headers += [
            .init(name: ReportCanonical.deviceHeader, value: deviceId),
            .init(name: ReportCanonical.timestampHeader, value: stamp),
            .init(name: ReportCanonical.nonceHeader, value: nonce),
            .init(name: ReportCanonical.signatureHeader, value: Base64URL.encode(try signer.signature(for: canonical))),
        ]
        if let newKey {
            headers.append(.init(name: ReportCanonical.newKeySignatureHeader,
                                 value: Base64URL.encode(try newKey.signature(for: canonical))))
        }
        if let apiKey { headers.append(.init(name: "Authorization", value: "Bearer \(apiKey)")) }
        return ReportRequest(method: method, url: url, headers: headers, body: body)
    }
}
