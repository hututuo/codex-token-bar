import CryptoKit
import Foundation

/// `SHA256SUMS.txt`: one `<sha256>  <file name>` line per asset (`sha256sum` text or binary mode).
public enum ChecksumList {
    public static let maxBytes = 1 << 20

    /// Lowercase digests by file name. A name listed twice with different digests is dropped as ambiguous.
    public static func parse(_ text: String) -> [String: String] {
        var digests: [String: String] = [:]
        var conflicting: Set<String> = []
        for rawLine in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            guard let (digest, name) = entry(rawLine) else { continue }
            if let existing = digests[name], existing != digest { conflicting.insert(name) }
            digests[name] = digest
        }
        for name in conflicting { digests[name] = nil }
        return digests
    }

    public static func digest(for name: String, in text: String) -> String? {
        parse(text)[name]
    }

    /// Case-insensitive comparison of two hex SHA-256 digests.
    public static func matches(_ expected: String, _ actual: String) -> Bool {
        isDigest(expected) && isDigest(actual) && expected.lowercased() == actual.lowercased()
    }

    private static func entry(_ line: Substring) -> (String, String)? {
        let characters = Array(line)
        guard characters.count > 66, characters[64] == " ", characters[65] == " " || characters[65] == "*" else {
            return nil
        }
        let digest = String(characters[0..<64])
        guard isDigest(digest) else { return nil }
        var name = String(characters[66...])
        while let last = name.last, last.isWhitespace { name.removeLast() }
        guard !name.isEmpty else { return nil }
        return (digest.lowercased(), name)
    }

    private static func isDigest(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
    }
}

public enum FileDigest {
    /// Lowercase hex SHA-256 of a file, read in 1 MiB chunks.
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    public static func sha256(of data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        let alphabet = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(64)
        for byte in digest {
            bytes.append(alphabet[Int(byte >> 4)])
            bytes.append(alphabet[Int(byte & 0x0F)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
