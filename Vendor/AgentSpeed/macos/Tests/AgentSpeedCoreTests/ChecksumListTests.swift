import Foundation
import Testing
@testable import AgentSpeedCore

@Suite("Checksum list")
struct ChecksumListTests {
    static let abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    static let empty = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    static let fox = "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592"

    /// What `sha256sum AgentSpeed-* > SHA256SUMS.txt` writes in the release workflow.
    static let releaseFile = """
    \(abc)  AgentSpeed-Windows-arm64.zip
    \(empty)  AgentSpeed-Windows-x64.zip
    \(fox)  AgentSpeed-macOS.zip

    """

    @Test func parsesReleaseWorkflowOutput() {
        #expect(ChecksumList.parse(Self.releaseFile) == [
            "AgentSpeed-Windows-arm64.zip": Self.abc,
            "AgentSpeed-Windows-x64.zip": Self.empty,
            "AgentSpeed-macOS.zip": Self.fox,
        ])
        #expect(ChecksumList.digest(for: "AgentSpeed-macOS.zip", in: Self.releaseFile) == Self.fox)
        #expect(ChecksumList.digest(for: "AgentSpeed-Linux.zip", in: Self.releaseFile) == nil)
        #expect(ChecksumList.digest(for: "agentspeed-macos.zip", in: Self.releaseFile) == nil)
        #expect(ChecksumList.digest(for: "AgentSpeed-macOS", in: Self.releaseFile) == nil)
    }

    @Test func parsesRealShasumOutputInTextAndBinaryMode() throws {
        let directory = try TempDirectory()
        let files = [
            "AgentSpeed-macOS.zip": pseudoRandomData(count: 70_001, seed: 1),
            "AgentSpeed-Windows-x64.zip": pseudoRandomData(count: 3, seed: 2),
            "Agent Speed notes 1.2.txt": Data("The quick brown fox jumps over the lazy dog".utf8),
            "empty.txt": Data(),
        ]
        for (name, data) in files { try data.write(to: directory.file(name)) }
        let names = files.keys.sorted()
        for flags in [["-a", "256"], ["-a", "256", "-b"]] {
            let output = try runTool("/usr/bin/shasum", flags + names, in: directory.url)
            let digests = ChecksumList.parse(output)
            #expect(digests.count == files.count, "\(output)")
            for (name, data) in files {
                let fileDigest = try FileDigest.sha256(of: directory.file(name))
                #expect(digests[name] == FileDigest.sha256(of: data), "\(name) in \(flags)")
                #expect(digests[name] == fileDigest)
            }
            #expect(ChecksumList.digest(for: "Agent Speed notes 1.2.txt", in: output) == Self.fox)
        }
    }

    @Test func binaryModeMarkerIsNotPartOfTheName() {
        let text = "\(Self.abc) *AgentSpeed-macOS.zip\n\(Self.fox) **star.zip\n"
        #expect(ChecksumList.parse(text) == ["AgentSpeed-macOS.zip": Self.abc, "*star.zip": Self.fox])
    }

    @Test func uppercaseDigestsAreLowercased() {
        let text = "\(Self.abc.uppercased())  AgentSpeed-macOS.zip\nBa7816Bf8F01cfea414140de5dae2223b00361a396177a9cb410ff61f20015AD  mixed.zip"
        #expect(ChecksumList.parse(text) == ["AgentSpeed-macOS.zip": Self.abc, "mixed.zip": Self.abc])
    }

    @Test func handlesWindowsAndOldMacLineEndings() {
        let crlf = "\(Self.abc)  AgentSpeed-macOS.zip\r\n\(Self.fox)  AgentSpeed-Windows-x64.zip\r\n\r\n"
        #expect(ChecksumList.parse(crlf) == ["AgentSpeed-macOS.zip": Self.abc, "AgentSpeed-Windows-x64.zip": Self.fox])
        let cr = "\(Self.abc)  a.zip\r\(Self.fox)  b.zip"
        #expect(ChecksumList.parse(cr) == ["a.zip": Self.abc, "b.zip": Self.fox])
    }

    @Test func trailingWhitespaceIsTrimmedButInnerSpacesKept() {
        let text = "\(Self.abc)  Agent Speed macOS.zip \t\n\(Self.fox)  two  spaces.zip\n"
        #expect(ChecksumList.parse(text) == ["Agent Speed macOS.zip": Self.abc, "two  spaces.zip": Self.fox])
        #expect(ChecksumList.digest(for: "Agent Speed macOS.zip", in: text) == Self.abc)
    }

    @Test func keepsUnicodeNames() {
        let text = "\(Self.abc)  速度-é.zip\n"
        #expect(ChecksumList.parse(text) == ["速度-é.zip": Self.abc])
    }

    @Test(arguments: [
        "",
        "\n\n\r\n",
        "# SHA256 checksums",
        "SHA256 (AgentSpeed-macOS.zip) = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015a  short-by-one.zip",
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad0  long-by-one.zip",
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ag  not-hex.zip",
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015a\u{E9}  non-ascii.zip",
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad single-space.zip",
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\ttab.zip",
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\t\ttabs.zip",
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  ",
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad   ",
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad *",
        "  ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  indented.zip",
        "0x7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  prefixed.zip",
    ])
    func ignoresBadLines(text: String) {
        #expect(ChecksumList.parse(text).isEmpty)
    }

    @Test func badLinesDoNotHideGoodOnes() {
        let text = """
        garbage
        \(Self.abc)  AgentSpeed-macOS.zip
        \(Self.fox.dropLast())  broken.zip
        \(Self.empty)  AgentSpeed-Windows-x64.zip
        """
        #expect(ChecksumList.parse(text) == ["AgentSpeed-macOS.zip": Self.abc, "AgentSpeed-Windows-x64.zip": Self.empty])
    }

    @Test func identicalDuplicatesAreKept() {
        let text = "\(Self.abc)  a.zip\n\(Self.abc.uppercased()) *a.zip\n\(Self.fox)  b.zip\n"
        #expect(ChecksumList.parse(text) == ["a.zip": Self.abc, "b.zip": Self.fox])
    }

    @Test func conflictingDuplicatesAreDropped() {
        let text = "\(Self.abc)  a.zip\n\(Self.fox)  b.zip\n\(Self.empty)  a.zip\n\(Self.abc)  a.zip\n"
        #expect(ChecksumList.parse(text) == ["b.zip": Self.fox])
        #expect(ChecksumList.digest(for: "a.zip", in: text) == nil)
    }

    @Test func namesAreCaseSensitive() {
        let text = "\(Self.abc)  A.zip\n\(Self.fox)  a.zip\n"
        #expect(ChecksumList.parse(text) == ["A.zip": Self.abc, "a.zip": Self.fox])
    }

    static let matchCases: [(String, String, Bool)] = [
        (abc, abc, true),
        (abc.uppercased(), abc, true),
        (abc, abc.uppercased(), true),
        ("Ba7816Bf8F01cfea414140de5dae2223b00361a396177a9cb410ff61f20015AD", abc, true),
        (abc, fox, false),
        (abc, String(abc.dropLast()) + "e", false),
        (String(abc.dropLast()), String(abc.dropLast()), false),
        (abc + "0", abc + "0", false),
        ("", "", false),
        (" " + abc, abc, false),
        (abc + "\n", abc, false),
        (String(repeating: "g", count: 64), String(repeating: "g", count: 64), false),
        (String(repeating: "G", count: 64), String(repeating: "g", count: 64), false),
    ]

    @Test(arguments: matchCases)
    func matchesIsCaseInsensitiveAndStrict(expected: String, actual: String, result: Bool) {
        #expect(ChecksumList.matches(expected, actual) == result)
    }
}

@Suite("File digest")
struct FileDigestTests {
    @Test(arguments: [
        ("abc", ChecksumListTests.abc),
        ("", ChecksumListTests.empty),
        ("The quick brown fox jumps over the lazy dog", ChecksumListTests.fox),
    ])
    func knownDigests(text: String, expected: String) throws {
        #expect(FileDigest.sha256(of: Data(text.utf8)) == expected)
        let directory = try TempDirectory()
        let url = try directory.write("input.bin", text)
        #expect(try FileDigest.sha256(of: url) == expected)
    }

    @Test(arguments: [1, (1 << 20) - 1, 1 << 20, (1 << 20) + 1, 2 << 20, 3 * (1 << 20) + 12_345])
    func fileDigestMatchesDataDigestAcrossChunkBoundaries(size: Int) throws {
        let data = pseudoRandomData(count: size, seed: UInt64(size))
        let directory = try TempDirectory()
        let url = directory.file("asset.zip")
        try data.write(to: url)
        let digest = try FileDigest.sha256(of: url)
        #expect(digest == FileDigest.sha256(of: data))
        #expect(digest.count == 64)
        #expect(digest.allSatisfy { "0123456789abcdef".contains($0) })
    }

    @Test func largeFileMatchesShasum() throws {
        let directory = try TempDirectory()
        let url = directory.file("AgentSpeed-macOS.zip")
        try pseudoRandomData(count: 5 * (1 << 20) + 7, seed: 42).write(to: url)
        let output = try runTool("/usr/bin/shasum", ["-a", "256", "AgentSpeed-macOS.zip"], in: directory.url)
        let expected = try #require(ChecksumList.digest(for: "AgentSpeed-macOS.zip", in: output))
        let actual = try FileDigest.sha256(of: url)
        #expect(ChecksumList.matches(expected, actual))
        #expect(expected == actual)
    }

    @Test func missingFileThrows() throws {
        let directory = try TempDirectory()
        #expect(throws: (any Error).self) {
            try FileDigest.sha256(of: directory.file("missing.zip"))
        }
    }

    @Test func directoryThrows() throws {
        let directory = try TempDirectory()
        #expect(throws: (any Error).self) {
            try FileDigest.sha256(of: directory.url)
        }
    }
}
