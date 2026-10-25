import CryptoKit
import Foundation

/// Signs the canonical string of a request (REPORTING 5.1): ES256 over the message bytes, 64-byte `r ‖ s`. The app
/// signs inside the Secure Enclave; tests and Macs without one use a CryptoKit software key.
public protocol ReportSigner: Sendable {
    var publicKey: ReportPublicKey { get }
    func signature(for message: Data) throws -> Data
}

/// A P-256 public key: the 32-byte big-endian affine coordinates (REPORTING 4.1).
public struct ReportPublicKey: Equatable, Hashable, Sendable {
    public let x: Data
    public let y: Data

    /// From CryptoKit's `rawRepresentation` (`x ‖ y`, 64 bytes); nil when the point is not on P-256. The point is
    /// imported in X9.63 form because `init(rawRepresentation:)` does not check that it is on the curve.
    public init?(raw: Data) {
        guard raw.count == 64, Self.cryptoKitKey(raw) != nil else { return nil }
        x = Data(raw.prefix(32))
        y = Data(raw.suffix(32))
    }

    public var raw: Data { x + y }

    /// The JSON Web Key sent in registrations and rotations.
    public var jwk: ReportJSON {
        .object(["kty": .string("EC"), "crv": .string("P-256"), "x": .string(Base64URL.encode(x)),
                 "y": .string(Base64URL.encode(y))])
    }

    /// RFC 7638 thumbprint (base64url of SHA-256 over the required members in lexicographic order).
    public var thumbprint: String {
        let members = "{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"\(Base64URL.encode(x))\",\"y\":\"\(Base64URL.encode(y))\"}"
        return Base64URL.encode(Data(SHA256.hash(data: Data(members.utf8))))
    }

    /// The first 8 characters of the thumbprint (DESIGN 11, `report.device.fingerprint`).
    public var fingerprint: String { String(thumbprint.prefix(8)) }

    /// REPORTING 4.1: kty EC, crv P-256, canonical 43-character coordinates below p, on the curve, no `d`.
    public static func parse(jwk value: JSONValue) -> ReportPublicKey? {
        guard let members = value.object, members["kty"]?.string == "EC", members["crv"]?.string == "P-256",
              members["d"] == nil,
              let xText = members["x"]?.string, let yText = members["y"]?.string,
              xText.utf8.count == 43, yText.utf8.count == 43,
              let x = Base64URL.decode(xText), let y = Base64URL.decode(yText),
              x.count == 32, y.count == 32, isBelowPrime(x), isBelowPrime(y) else { return nil }
        return ReportPublicKey(raw: x + y)
    }

    /// ES256 verification over the message; both forms of `s` verify (REPORTING 5.1).
    public func isValidSignature(_ signature: Data, for message: Data) -> Bool {
        guard signature.count == 64, Self.isInScalarRange(signature.prefix(32)), Self.isInScalarRange(signature.suffix(32)),
              let key = Self.cryptoKitKey(raw),
              let parsed = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else { return false }
        return key.isValidSignature(parsed, for: message)
    }

    private static let prime: [UInt8] = [
        0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    ]
    private static let order: [UInt8] = [
        0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xBC, 0xE6, 0xFA, 0xAD, 0xA7, 0x17, 0x9E, 0x84, 0xF3, 0xB9, 0xCA, 0xC2, 0xFC, 0x63, 0x25, 0x51,
    ]

    private static func cryptoKitKey(_ raw: Data) -> P256.Signing.PublicKey? {
        try? P256.Signing.PublicKey(x963Representation: Data([0x04]) + raw)
    }

    private static func isBelowPrime(_ value: Data) -> Bool {
        Array(value).lexicographicallyPrecedes(prime)
    }

    /// `1 ≤ v ≤ n − 1` for a 32-byte big-endian scalar.
    private static func isInScalarRange<D: DataProtocol>(_ value: D) -> Bool {
        let bytes = Array(value)
        return bytes.contains { $0 != 0 } && bytes.lexicographicallyPrecedes(order)
    }
}

/// A CryptoKit software key: Macs without a Secure Enclave (DESIGN 11, Storage) and tests.
public struct SoftwareReportSigner: ReportSigner {
    public let key: P256.Signing.PrivateKey

    public init(key: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) {
        self.key = key
    }

    public var publicKey: ReportPublicKey {
        ReportPublicKey(raw: key.publicKey.rawRepresentation)!
    }

    public func signature(for message: Data) throws -> Data {
        try key.signature(for: message).rawRepresentation
    }
}
