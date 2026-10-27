import Testing
@testable import AgentSpeedCore

@Suite("Semantic version")
struct SemanticVersionTests {
    static func version(_ text: String) throws -> SemanticVersion {
        try #require(SemanticVersion(text), "\(text) should parse")
    }

    @Test(arguments: [
        ("1.2.3", SemanticVersion(major: 1, minor: 2, patch: 3)),
        ("v1.2.3", SemanticVersion(major: 1, minor: 2, patch: 3)),
        ("0.0.0", SemanticVersion(major: 0, minor: 0, patch: 0)),
        ("v0.10.0", SemanticVersion(major: 0, minor: 10, patch: 0)),
        ("10.20.30", SemanticVersion(major: 10, minor: 20, patch: 30)),
        ("999999999.999999999.999999999", SemanticVersion(major: 999_999_999, minor: 999_999_999, patch: 999_999_999)),
        ("1.0.0-alpha", SemanticVersion(major: 1, minor: 0, patch: 0, prerelease: ["alpha"])),
        ("v2.0.0-rc.1", SemanticVersion(major: 2, minor: 0, patch: 0, prerelease: ["rc", "1"])),
        ("1.0.0-alpha-1", SemanticVersion(major: 1, minor: 0, patch: 0, prerelease: ["alpha-1"])),
        ("1.0.0-0.3.7", SemanticVersion(major: 1, minor: 0, patch: 0, prerelease: ["0", "3", "7"])),
        ("1.0.0-x.7.z.92", SemanticVersion(major: 1, minor: 0, patch: 0, prerelease: ["x", "7", "z", "92"])),
        ("1.0.0-x-y-z.--", SemanticVersion(major: 1, minor: 0, patch: 0, prerelease: ["x-y-z", "--"])),
        ("1.0.0+20130313144700", SemanticVersion(major: 1, minor: 0, patch: 0)),
        ("1.0.0+build-1.001", SemanticVersion(major: 1, minor: 0, patch: 0)),
        ("1.0.0-beta+exp.sha.5114f85", SemanticVersion(major: 1, minor: 0, patch: 0, prerelease: ["beta"])),
        ("v1.2.3-rc.1+build.5", SemanticVersion(major: 1, minor: 2, patch: 3, prerelease: ["rc", "1"])),
    ])
    func parses(text: String, expected: SemanticVersion) throws {
        #expect(try Self.version(text) == expected)
    }

    @Test(arguments: [
        "", "v", "1", "1.2", "1.2.", "1..3", ".1.2.3", "1.2.3.", "1.2.3.4",
        "01.2.3", "1.02.3", "1.2.03", "00.0.0",
        "1234567890.0.0", "1.1234567890.0", "99999999999999999999.0.0",
        "V1.2.3", "vv1.2.3", " 1.2.3", "1.2.3 ", "1.2.3\n", "v 1.2.3",
        "-1.2.3", "1.-2.3", "1.2.-3", "+1.2.3", "1.2.+3",
        "1.2.3-", "1.2.3+", "1.2.3-+build", "1.2.3-alpha..1", "1.2.3-.alpha", "1.2.3-alpha.",
        "1.2.3-al pha", "1.2.3-beta_1", "1.2.3-é", "1.2.3+build+again", "1.2.3+bu ild",
        "1.2.3-" + String(repeating: "a", count: 65),
        "a.b.c", "1.2.x", "１.２.３", "٣.٢.١", "latest", "nightly", "release-1.2.3",
    ])
    func rejects(text: String) {
        #expect(SemanticVersion(text) == nil)
    }

    @Test func acceptsLongestAllowedPrereleaseIdentifier() throws {
        let identifier = String(repeating: "a", count: 64)
        #expect(try Self.version("1.2.3-" + identifier).prerelease == [identifier])
    }

    @Test(arguments: [
        ("1.2.3", "1.2.3"), ("v1.2.3", "1.2.3"), ("v1.2.3-rc.1+build.5", "1.2.3-rc.1"),
        ("1.0.0+meta", "1.0.0"), ("0.0.0-dev.2", "0.0.0-dev.2"),
    ])
    func describesWithoutPrefixOrBuildMetadata(text: String, expected: String) throws {
        #expect(try Self.version(text).description == expected)
    }

    @Test(arguments: [
        ("0.0.0", true), ("v0.0.0", true), ("0.0.0+local", true), ("0.0.0-dev", true),
        ("0.0.1", false), ("0.1.0", false), ("1.0.0", false), ("10.0.0", false),
    ])
    func developmentBuilds(text: String, expected: Bool) throws {
        #expect(try Self.version(text).isDevelopment == expected)
    }

    @Test(arguments: [
        ("1.0.0", false), ("1.0.0+build.1", false), ("1.0.0-rc.1", true), ("v2.0.0-0", true),
    ])
    func prereleaseFlag(text: String, expected: Bool) throws {
        #expect(try Self.version(text).isPrerelease == expected)
    }

    /// The precedence chain from the Semantic Versioning 2.0 specification, extended with the core components.
    static let ascending = [
        "0.0.0", "0.0.1", "0.1.0", "0.9.9", "0.10.0",
        "1.0.0-0", "1.0.0-1", "1.0.0-2", "1.0.0-10", "1.0.0--1", "1.0.0-Alpha", "1.0.0-alpha", "1.0.0-alpha.1",
        "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0",
        "1.0.1-rc.1", "1.0.1", "1.0.9", "1.0.10", "1.9.0", "1.10.0", "2.0.0", "2.1.0", "2.1.1", "10.0.0",
    ]

    @Test func followsSemanticVersioningPrecedence() throws {
        let versions = try Self.ascending.map(Self.version)
        for (lowerIndex, lower) in versions.enumerated() {
            for higher in versions[(lowerIndex + 1)...] {
                #expect(lower < higher, "\(lower) < \(higher)")
                #expect(!(higher < lower), "!(\(higher) < \(lower))")
                #expect(lower != higher)
            }
            #expect(!(lower < lower))
        }
        #expect(versions.reversed().sorted() == versions)
    }

    @Test(arguments: [
        ("1.0.0-alpha.1", "1.0.0-alpha.1.0"),
        ("1.0.0-2", "1.0.0-11"),
        ("1.0.0-99999999999999999999", "1.0.0-100000000000000000000"),
        ("1.0.0-99999999999999999999", "1.0.0-a"),
        ("1.0.0-rc.9", "1.0.0-rc.10"),
        ("1.0.0-rc.1", "1.0.0"),
        ("v1.1.0", "1.2.0-beta"),
    ])
    func orders(lower: String, higher: String) throws {
        let low = try Self.version(lower)
        let high = try Self.version(higher)
        #expect(low < high)
        #expect(!(high < low))
        #expect(high > low)
    }

    @Test(arguments: [
        ("1.0.0", "v1.0.0"), ("1.0.0+a", "1.0.0+b"), ("1.0.0+build.1", "1.0.0"), ("1.0.0-rc.1+x", "1.0.0-rc.1"),
    ])
    func ignoresPrefixAndBuildMetadata(left: String, right: String) throws {
        let a = try Self.version(left)
        let b = try Self.version(right)
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        #expect(!(a < b) && !(b < a))
    }
}
