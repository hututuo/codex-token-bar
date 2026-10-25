import Foundation

/// `[v]MAJOR.MINOR.PATCH[-PRERELEASE][+BUILD]` (UPDATES section 2). Build metadata is accepted and ignored.
public struct SemanticVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// Dot-separated pre-release identifiers; empty for a release.
    public let prerelease: [String]

    public init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    public init?(_ text: String) {
        var body = Substring(text)
        if body.first == "v" { body = body.dropFirst() }
        if let plus = body.firstIndex(of: "+") {
            guard Self.identifiers(body[body.index(after: plus)...]) != nil else { return nil }
            body = body[..<plus]
        }
        var prerelease: [String] = []
        if let dash = body.firstIndex(of: "-") {
            guard let identifiers = Self.identifiers(body[body.index(after: dash)...]) else { return nil }
            prerelease = identifiers
            body = body[..<dash]
        }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Self.number(parts[0]),
              let minor = Self.number(parts[1]),
              let patch = Self.number(parts[2]) else { return nil }
        self.init(major: major, minor: minor, patch: patch, prerelease: prerelease)
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    /// `0.0.0` marks a local development build, which only checks for updates on request.
    public var isDevelopment: Bool { major == 0 && minor == 0 && patch == 0 }

    public var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : core + "-" + prerelease.joined(separator: ".")
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, _): return false
        case (false, true): return true
        case (false, false): return precedes(lhs.prerelease, rhs.prerelease)
        }
    }

    /// Semantic Versioning 2.0 pre-release precedence: numeric identifiers compare numerically and sort before
    /// alphanumeric ones; a shorter list sorts first when all shared identifiers are equal.
    private static func precedes(_ lhs: [String], _ rhs: [String]) -> Bool {
        for (left, right) in zip(lhs, rhs) where left != right {
            switch (left.allSatisfy(\.isASCIIDigit), right.allSatisfy(\.isASCIIDigit)) {
            case (true, true): return (left.count, left) < (right.count, right)
            case (true, false): return true
            case (false, true): return false
            case (false, false): return left < right
            }
        }
        return lhs.count < rhs.count
    }

    /// A non-negative decimal without leading zeros, small enough to never overflow.
    private static func number(_ text: Substring) -> Int? {
        guard (1...9).contains(text.count), text.allSatisfy(\.isASCIIDigit) else { return nil }
        guard text.count == 1 || text.first != "0" else { return nil }
        return Int(text)
    }

    private static func identifiers(_ text: Substring) -> [String]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        for part in parts {
            guard !part.isEmpty, part.count <= 64,
                  part.allSatisfy({ $0.isASCIIDigit || $0.isASCIILetter || $0 == "-" }) else { return nil }
        }
        return parts.map(String.init)
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
    fileprivate var isASCIILetter: Bool { isASCII && isLetter }
}
