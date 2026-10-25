import Foundation
import Testing
@testable import AgentSpeedCore

@Suite("Zip directory")
struct ZipDirectoryTests {
    static let root = "Agent Speed.app"

    /// A miniature app bundle, packed the way `macos/scripts/build-app.sh` packs the release.
    static func makeBundleArchive(in directory: TempDirectory, blobSize: Int = 0, keepParent: Bool = true) throws -> URL {
        let app = directory.file("src/\(root)")
        try directory.write("src/\(root)/Contents/Info.plist", "<plist/>\n")
        try directory.write("src/\(root)/Contents/PkgInfo", "APPL????")
        try directory.write("src/\(root)/Contents/MacOS/AgentSpeed", "binary")
        try directory.write("src/\(root)/Contents/_CodeSignature/CodeResources", "<plist/>")
        try directory.write("src/\(root)/Contents/Resources/AgentSpeed.icns", "icns")
        if blobSize > 0 {
            try pseudoRandomData(count: blobSize).write(to: app.appendingPathComponent("Contents/Resources/blob.bin"))
        }
        let manager = FileManager.default
        try manager.createSymbolicLink(
            atPath: app.appendingPathComponent("Contents/MacOS/Alias").path, withDestinationPath: "AgentSpeed"
        )
        try manager.createSymbolicLink(
            atPath: app.appendingPathComponent("Contents/Resources/Current").path, withDestinationPath: "../MacOS"
        )
        let zip = directory.file("AgentSpeed-macOS.zip")
        var arguments = ["-c", "-k", "--norsrc", "--noextattr", "--noacl"]
        if keepParent { arguments.append("--keepParent") }
        try runTool("/usr/bin/ditto", arguments + [app.path, zip.path])
        return zip
    }

    static let bundleEntries = [
        ZipEntry(path: "Agent Speed.app/"),
        ZipEntry(path: "Agent Speed.app/Contents/"),
        ZipEntry(path: "Agent Speed.app/Contents/Info.plist", uncompressedSize: 9),
        ZipEntry(path: "Agent Speed.app/Contents/MacOS/"),
        ZipEntry(path: "Agent Speed.app/Contents/MacOS/AgentSpeed", uncompressedSize: 6),
        ZipEntry(path: "Agent Speed.app/Contents/MacOS/Alias", uncompressedSize: 10, isSymbolicLink: true),
        ZipEntry(path: "Agent Speed.app/Contents/PkgInfo", uncompressedSize: 8),
        ZipEntry(path: "Agent Speed.app/Contents/Resources/"),
        ZipEntry(path: "Agent Speed.app/Contents/Resources/AgentSpeed.icns", uncompressedSize: 4),
        ZipEntry(path: "Agent Speed.app/Contents/Resources/Current", uncompressedSize: 8, isSymbolicLink: true),
        ZipEntry(path: "Agent Speed.app/Contents/_CodeSignature/"),
        ZipEntry(path: "Agent Speed.app/Contents/_CodeSignature/CodeResources", uncompressedSize: 8),
    ]

    static func sorted(_ entries: [ZipEntry]) -> [ZipEntry] {
        entries.sorted { $0.path < $1.path }
    }

    // MARK: Archives made by ditto

    @Test func readsDittoBundleArchive() throws {
        let directory = try TempDirectory()
        let zip = try Self.makeBundleArchive(in: directory)
        let entries = try ZipDirectory.entries(of: zip)
        #expect(Self.sorted(entries) == Self.bundleEntries)
        #expect(try ZipDirectory.entries(in: Data(contentsOf: zip)) == entries)
        #expect(Set(entries.filter(\.isSymbolicLink).map(\.path)) == [
            "Agent Speed.app/Contents/MacOS/Alias", "Agent Speed.app/Contents/Resources/Current",
        ])
        #expect(entries.filter(\.isDirectory).count == 5)
        try ArchiveLayout.validate(entries, root: Self.root)
    }

    @Test func readsArchiveLargerThanTheEndRecordSearchWindow() throws {
        let directory = try TempDirectory()
        let zip = try Self.makeBundleArchive(in: directory, blobSize: 300_000)
        let size = try #require(try FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int)
        #expect(size > 22 + 0xFFFF)
        let entries = try ZipDirectory.entries(of: zip)
        #expect(try ZipDirectory.entries(in: Data(contentsOf: zip)) == entries)
        #expect(entries.count == Self.bundleEntries.count + 1)
        #expect(entries.first { $0.path == "Agent Speed.app/Contents/Resources/blob.bin" }?.uncompressedSize == 300_000)
        try ArchiveLayout.validate(entries, root: Self.root)
    }

    @Test(arguments: ["Agent Speed", "Other.app", "agent speed.app", "Agent Speed.app/Contents"])
    func dittoBundleIsOutsideAnyOtherRoot(root: String) throws {
        let directory = try TempDirectory()
        let entries = try ZipDirectory.entries(of: try Self.makeBundleArchive(in: directory))
        let outside = try #require(entries.first { !$0.path.hasPrefix(root + "/") })
        #expect(throws: ArchiveLayoutError.outsideRoot(outside.path)) {
            try ArchiveLayout.validate(entries, root: root)
        }
    }

    @Test func archiveWithoutParentFolderIsRejected() throws {
        let directory = try TempDirectory()
        let entries = try ZipDirectory.entries(of: try Self.makeBundleArchive(in: directory, keepParent: false))
        #expect(entries.allSatisfy { $0.path.hasPrefix("Contents/") })
        #expect(throws: ArchiveLayoutError.outsideRoot(entries[0].path)) {
            try ArchiveLayout.validate(entries, root: Self.root)
        }
    }

    // MARK: Hand-built archives

    /// Parses `archive` from memory and from disk, requiring both readers to agree.
    static func entries(of archive: Data) throws -> [ZipEntry] {
        let directory = try TempDirectory()
        let url = directory.file("archive.zip")
        try archive.write(to: url)
        let fromFile = try ZipDirectory.entries(of: url)
        #expect(try ZipDirectory.entries(in: archive) == fromFile)
        return fromFile
    }

    static func expectFailure(_ error: ZipDirectoryError, _ archive: Data) throws {
        let directory = try TempDirectory()
        let url = directory.file("archive.zip")
        try archive.write(to: url)
        #expect(throws: error) { try ZipDirectory.entries(in: archive) }
        #expect(throws: error) { try ZipDirectory.entries(of: url) }
    }

    static func sampleBuilder() -> ZipBuilder {
        var builder = ZipBuilder()
        builder.directory("Agent Speed.app/")
        builder.file("Agent Speed.app/Contents/Info.plist", "<plist/>")
        builder.symlink("Agent Speed.app/Contents/Current", to: "MacOS")
        builder.file("Agent Speed.app/Contents/MacOS/AgentSpeed", "binary")
        return builder
    }

    static let sampleEntries = [
        ZipEntry(path: "Agent Speed.app/"),
        ZipEntry(path: "Agent Speed.app/Contents/Info.plist", uncompressedSize: 8),
        ZipEntry(path: "Agent Speed.app/Contents/Current", uncompressedSize: 5, isSymbolicLink: true),
        ZipEntry(path: "Agent Speed.app/Contents/MacOS/AgentSpeed", uncompressedSize: 6),
    ]

    @Test func readsHandBuiltArchiveInOrder() throws {
        #expect(try Self.entries(of: Self.sampleBuilder().build().data) == Self.sampleEntries)
    }

    @Test func readsArchiveWithComment() throws {
        var builder = Self.sampleBuilder()
        builder.comment = Array("Agent Speed release".utf8)
        #expect(try Self.entries(of: builder.build().data) == Self.sampleEntries)
    }

    @Test func ignoresFakeEndRecordInsideTheComment() throws {
        var builder = Self.sampleBuilder()
        builder.comment = [0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 30)
        #expect(try Self.entries(of: builder.build().data) == Self.sampleEntries)
    }

    @Test func readsArchiveWithLongestCommentAndLargeEntry() throws {
        var builder = ZipBuilder()
        builder.directory("Agent Speed.app/")
        builder.add("Agent Speed.app/blob.bin", data: [UInt8](pseudoRandomData(count: 100_000)), mode: 0o100644)
        builder.comment = [UInt8](repeating: 0x41, count: 0xFFFF)
        let entries = try Self.entries(of: builder.build().data)
        #expect(entries == [
            ZipEntry(path: "Agent Speed.app/"), ZipEntry(path: "Agent Speed.app/blob.bin", uncompressedSize: 100_000),
        ])
    }

    @Test func emptyArchiveHasNoEntries() throws {
        let entries = try Self.entries(of: ZipBuilder().build().data)
        #expect(entries.isEmpty)
        #expect(throws: ArchiveLayoutError.empty) { try ArchiveLayout.validate(entries, root: Self.root) }
    }

    @Test func decodesFlaggedUTF8Names() throws {
        var builder = ZipBuilder()
        builder.file("Agent Speed.app/Contents/Resources/zh-Hant.lproj/說明 é.txt")
        #expect(try Self.entries(of: builder.build().data).map(\.path) == [
            "Agent Speed.app/Contents/Resources/zh-Hant.lproj/說明 é.txt",
        ])
    }

    @Test func readsUTF8NamesWithoutUTF8Flag() throws {
        var builder = ZipBuilder()
        builder.add(raw: Array("Agent Speed.app/é".utf8), data: [], mode: 0o100644, flags: 0)
        #expect(try Self.entries(of: builder.build().data).map(\.path) == ["Agent Speed.app/é"])
    }

    @Test func rejectsInvalidUTF8Names() throws {
        var builder = ZipBuilder()
        builder.add(raw: Array("Agent Speed.app/".utf8) + [0xFF, 0xFE], data: [], mode: 0o100644, flags: 0x0800)
        try Self.expectFailure(.malformed, builder.build().data)
    }

    @Test func rejectsEmptyNames() throws {
        var builder = ZipBuilder()
        builder.add(raw: [], data: [], mode: 0o100644)
        try Self.expectFailure(.malformed, builder.build().data)
    }

    @Test(arguments: [
        (ZipBuilder.unixMadeBy, UInt32(0o120755), true),
        (ZipBuilder.unixMadeBy, UInt32(0o120777), true),
        (0x031E, UInt32(0o120755), true),
        (ZipBuilder.unixMadeBy, UInt32(0o100644), false),
        (ZipBuilder.unixMadeBy, UInt32(0o040755), false),
        (ZipBuilder.unixMadeBy, UInt32(0o140755), false),
        (ZipBuilder.unixMadeBy, UInt32(0o160755), false),
        (ZipBuilder.dosMadeBy, UInt32(0o120755), false),
        (0x0A14, UInt32(0o120755), false),
    ] as [(UInt16, UInt32, Bool)])
    func detectsUnixSymlinksOnly(madeBy: UInt16, mode: UInt32, isLink: Bool) throws {
        var builder = ZipBuilder()
        builder.add("Agent Speed.app/entry", data: Array("target".utf8), mode: mode, madeBy: madeBy)
        #expect(try Self.entries(of: builder.build().data).map(\.isSymbolicLink) == [isLink])
    }

    // MARK: Damaged and unsupported archives

    @Test(arguments: [
        Data(), Data("PK".utf8), Data("PK\u{5}\u{6}".utf8), Data(repeating: 0, count: 22), Data(repeating: 0xFF, count: 4096),
        pseudoRandomData(count: 100), pseudoRandomData(count: 70_000, seed: 7), Data("not a zip file at all".utf8),
        Data(#"{"tag_name": "v1.0.0"}"#.utf8),
    ])
    func junkIsMalformed(data: Data) throws {
        try Self.expectFailure(.malformed, data)
    }

    enum Damage: String, CaseIterable, Sendable {
        case truncatedEnd, trailingBytes, directoryPastEnd, directoryOverlapsEnd, directoryOverMaximum
        case tooManyEntries, badEntrySignature, nameOverrun
        case otherDisk, directoryOnOtherDisk, entryCountMismatch, zip64EntryCount, zip64DirectorySize
        case zip64DirectoryOffset, zip64EntrySize, zip64LocalOffset, entryOnOtherDisk

        var expected: ZipDirectoryError {
            switch self {
            case .truncatedEnd, .trailingBytes, .directoryPastEnd, .directoryOverlapsEnd, .directoryOverMaximum,
                 .tooManyEntries, .badEntrySignature, .nameOverrun:
                .malformed
            case .otherDisk, .directoryOnOtherDisk, .entryCountMismatch, .zip64EntryCount, .zip64DirectorySize,
                 .zip64DirectoryOffset, .zip64EntrySize, .zip64LocalOffset, .entryOnOtherDisk:
                .unsupported
            }
        }

        func apply(to archive: inout ZipBuilder.Archive, entryCount: UInt32) {
            switch self {
            case .truncatedEnd: archive.data.removeLast()
            case .trailingBytes: archive.data.append(contentsOf: [0, 0, 0, 0])
            case .directoryPastEnd: archive.patch(.directoryOffset, UInt32(archive.endOffset + 1))
            case .directoryOverlapsEnd: archive.patch(.directorySize, UInt32(archive.endOffset - archive.directoryOffset + 1))
            case .directoryOverMaximum: archive.patch(.directorySize, (64 << 20) + 1)
            case .tooManyEntries:
                archive.patch(.entries, entryCount + 1)
                archive.patch(.entriesOnDisk, entryCount + 1)
            case .badEntrySignature: archive.patch(.signature, 0x0403_4B50)
            case .nameOverrun: archive.patch(.nameLength, 0xFFFF)
            case .otherDisk: archive.patch(.disk, 1)
            case .directoryOnOtherDisk: archive.patch(.directoryDisk, 1)
            case .entryCountMismatch: archive.patch(.entriesOnDisk, entryCount - 1)
            case .zip64EntryCount:
                archive.patch(.entries, 0xFFFF)
                archive.patch(.entriesOnDisk, 0xFFFF)
            case .zip64DirectorySize: archive.patch(.directorySize, 0xFFFF_FFFF)
            case .zip64DirectoryOffset: archive.patch(.directoryOffset, 0xFFFF_FFFF)
            case .zip64EntrySize: archive.patch(.uncompressedSize, 0xFFFF_FFFF)
            case .zip64LocalOffset: archive.patch(.localOffset, 0xFFFF_FFFF)
            case .entryOnOtherDisk: archive.patch(.diskStart, 1)
            }
        }
    }

    @Test(arguments: Damage.allCases)
    func damagedArchivesFail(damage: Damage) throws {
        let builder = Self.sampleBuilder()
        var archive = builder.build()
        damage.apply(to: &archive, entryCount: UInt32(builder.entries.count))
        try Self.expectFailure(damage.expected, archive.data)
    }

    @Test func missingOrTinyFilesFail() throws {
        let directory = try TempDirectory()
        #expect(throws: (any Error).self) { try ZipDirectory.entries(of: directory.file("missing.zip")) }
        let tiny = try directory.write("tiny.zip", "PK\u{5}\u{6}")
        #expect(throws: ZipDirectoryError.malformed) { try ZipDirectory.entries(of: tiny) }
        let empty = try directory.write("empty.zip", "")
        #expect(throws: ZipDirectoryError.malformed) { try ZipDirectory.entries(of: empty) }
    }

    // MARK: Malicious layouts

    enum Kind: Sendable {
        case file, directory, link(String)
    }

    struct Layout: Sendable, CustomTestStringConvertible {
        let label: String
        let entries: [(path: String, kind: Kind)]
        let error: ArchiveLayoutError?

        var testDescription: String { label }

        func archive() -> Data {
            var builder = ZipBuilder()
            for entry in entries {
                switch entry.kind {
                case .file: builder.file(entry.path)
                case .directory: builder.directory(entry.path)
                case .link(let target): builder.symlink(entry.path, to: target)
                }
            }
            return builder.build().data
        }
    }

    static let layouts: [Layout] = [
        Layout(label: "parent traversal", entries: [
            ("Agent Speed.app/", .directory), ("../evil", .file),
        ], error: .unsafePath("../evil")),
        Layout(label: "traversal inside root", entries: [
            ("Agent Speed.app/", .directory), ("Agent Speed.app/Contents/../../evil", .file),
        ], error: .unsafePath("Agent Speed.app/Contents/../../evil")),
        Layout(label: "absolute path", entries: [
            ("Agent Speed.app/", .directory), ("/tmp/evil", .file),
        ], error: .unsafePath("/tmp/evil")),
        Layout(label: "home path", entries: [("~/Library/LaunchAgents/evil.plist", .file)],
               error: .unsafePath("~/Library/LaunchAgents/evil.plist")),
        Layout(label: "backslash traversal", entries: [("Agent Speed.app\\..\\evil", .file)],
               error: .unsafePath("Agent Speed.app\\..\\evil")),
        Layout(label: "control character", entries: [("Agent Speed.app/evil\n", .file)],
               error: .unsafePath("Agent Speed.app/evil\n")),
        Layout(label: "outside root", entries: [
            ("Agent Speed.app/", .directory), ("Agent Speed.app/Contents/Info.plist", .file), ("Other.app/evil", .file),
        ], error: .outsideRoot("Other.app/evil")),
        Layout(label: "root look-alike", entries: [
            ("Agent Speed.app/", .directory), ("Agent Speed.appx/evil", .file),
        ], error: .outsideRoot("Agent Speed.appx/evil")),
        Layout(label: "root as file", entries: [("Agent Speed.app", .file)], error: .outsideRoot("Agent Speed.app")),
        Layout(label: "root as symlink", entries: [("Agent Speed.app", .link("/Applications"))],
               error: .outsideRoot("Agent Speed.app")),
        Layout(label: "file through symlink", entries: [
            ("Agent Speed.app/", .directory),
            ("Agent Speed.app/Contents/Frameworks", .link("/Users/Shared")),
            ("Agent Speed.app/Contents/Frameworks/payload", .file),
        ], error: .throughSymbolicLink("Agent Speed.app/Contents/Frameworks/payload")),
        Layout(label: "file through symlink listed first", entries: [
            ("Agent Speed.app/Contents/Frameworks/payload", .file),
            ("Agent Speed.app/Contents/Frameworks", .link("/Users/Shared")),
        ], error: .throughSymbolicLink("Agent Speed.app/Contents/Frameworks/payload")),
        Layout(label: "symlink with differing case", entries: [
            ("Agent Speed.app/Link", .link("/tmp")), ("Agent Speed.app/link/payload", .file),
        ], error: .throughSymbolicLink("Agent Speed.app/link/payload")),
        Layout(label: "symlink with differing normalization", entries: [
            ("Agent Speed.app/caf\u{E9}", .link("/tmp")), ("Agent Speed.app/cafe\u{301}/payload", .file),
        ], error: .throughSymbolicLink("Agent Speed.app/cafe\u{301}/payload")),
        Layout(label: "directory over symlink", entries: [
            ("Agent Speed.app/l", .link("/tmp")), ("Agent Speed.app/l/", .directory),
        ], error: .throughSymbolicLink("Agent Speed.app/l/")),
        Layout(label: "symlink through symlink", entries: [
            ("Agent Speed.app/a", .link("/tmp")), ("Agent Speed.app/a/b", .link("/etc")),
        ], error: .throughSymbolicLink("Agent Speed.app/a/b")),
        Layout(label: "symlink entry with trailing slash", entries: [
            ("Agent Speed.app/Frameworks/", .link("/tmp")), ("Agent Speed.app/Frameworks/payload", .file),
        ], error: .unsafePath("Agent Speed.app/Frameworks/")),
        Layout(label: "symlinks without nested entries", entries: [
            ("Agent Speed.app/", .directory),
            ("Agent Speed.app/lib", .link("library")),
            ("Agent Speed.app/library/", .directory),
            ("Agent Speed.app/library/x", .file),
            ("Agent Speed.app/Contents/Current", .link("../Resources")),
        ], error: nil),
    ]

    @Test(arguments: layouts)
    func validatesLayout(layout: Layout) throws {
        let entries = try Self.entries(of: layout.archive())
        #expect(entries.map(\.path) == layout.entries.map(\.path))
        if let error = layout.error {
            #expect(throws: error) { try ArchiveLayout.validate(entries, root: Self.root) }
        } else {
            try ArchiveLayout.validate(entries, root: Self.root)
        }
    }

    @Test func nonUnixSymlinkBitsDoNotCount() throws {
        var builder = ZipBuilder()
        builder.add("Agent Speed.app/link", data: Array("/tmp".utf8), mode: 0o120755, madeBy: ZipBuilder.dosMadeBy)
        builder.file("Agent Speed.app/link/x")
        let entries = try Self.entries(of: builder.build().data)
        #expect(entries.allSatisfy { !$0.isSymbolicLink })
        try ArchiveLayout.validate(entries, root: Self.root)
    }

    @Test func nulInNameIsUnsafe() throws {
        var builder = ZipBuilder()
        builder.add(raw: Array("Agent Speed.app/evil".utf8) + [0] + Array("/../x".utf8), data: [], mode: 0o100644)
        let entries = try Self.entries(of: builder.build().data)
        let path = try #require(entries.first?.path)
        #expect(path.unicodeScalars.contains("\u{0}"))
        #expect(throws: ArchiveLayoutError.unsafePath(path)) { try ArchiveLayout.validate(entries, root: Self.root) }
    }
}

@Suite("Archive layout")
struct ArchiveLayoutTests {
    static let root = "Agent Speed.app"

    @Test(arguments: [
        "a", "a/", "a/b", "a/b/", "Agent Speed.app/Contents/MacOS/AgentSpeed", "a/.hidden", "a/..b", "a/b..", "a/...",
        "a/~b", "a/…", "é/說明.txt", "a b/c d", "a:b", "a/-",
    ])
    func safePaths(path: String) {
        #expect(ArchiveLayout.isSafe(path))
    }

    @Test(arguments: [
        "", "/", "//", "/abs", "/Agent Speed.app/x", "~", "~/x", "~root/x",
        ".", "..", "./a", "../a", "a/..", "a/../b", "a/./b", "a/.", "a/../", "a//b", "a/b//", "//a",
        "a\\b", "..\\a", "a\u{0}b", "a\nb", "a\rb", "a\tb", "a\u{7F}b", "a\u{1B}[31m",
    ])
    func unsafePaths(path: String) {
        #expect(!ArchiveLayout.isSafe(path))
    }

    @Test func emptyArchiveIsRejected() {
        #expect(throws: ArchiveLayoutError.empty) { try ArchiveLayout.validate([], root: Self.root) }
    }

    @Test func rootFolderAloneIsValid() throws {
        try ArchiveLayout.validate([ZipEntry(path: "Agent Speed.app/")], root: Self.root)
    }

    @Test func reportsTheFirstOffendingEntry() {
        let entries = [
            ZipEntry(path: "Agent Speed.app/"), ZipEntry(path: "Other/x"), ZipEntry(path: "../a"), ZipEntry(path: "/b"),
        ]
        #expect(throws: ArchiveLayoutError.outsideRoot("Other/x")) { try ArchiveLayout.validate(entries, root: Self.root) }
        #expect(throws: ArchiveLayoutError.unsafePath("Other/../x")) {
            try ArchiveLayout.validate([ZipEntry(path: "Other/../x")], root: Self.root)
        }
    }

    @Test func entryCountLimit() throws {
        let limit = (0..<ArchiveLayout.maxEntries).map { ZipEntry(path: "Agent Speed.app/f\($0)") }
        try ArchiveLayout.validate(limit, root: Self.root)
        #expect(throws: ArchiveLayoutError.tooLarge) {
            try ArchiveLayout.validate(limit + [ZipEntry(path: "Agent Speed.app/one-more")], root: Self.root)
        }
    }

    @Test func expandedSizeLimit() throws {
        let half = ArchiveLayout.maxExpandedSize / 2
        let exact = [
            ZipEntry(path: "Agent Speed.app/a", uncompressedSize: half),
            ZipEntry(path: "Agent Speed.app/b", uncompressedSize: half),
        ]
        try ArchiveLayout.validate(exact, root: Self.root)
        #expect(throws: ArchiveLayoutError.tooLarge) {
            try ArchiveLayout.validate(exact + [ZipEntry(path: "Agent Speed.app/c", uncompressedSize: 1)], root: Self.root)
        }
        #expect(throws: ArchiveLayoutError.tooLarge) {
            try ArchiveLayout.validate([
                ZipEntry(path: "Agent Speed.app/a", uncompressedSize: UInt64.max),
                ZipEntry(path: "Agent Speed.app/b", uncompressedSize: 2),
            ], root: Self.root)
        }
    }

    @Test func directoryFlagFollowsTrailingSlash() {
        #expect(ZipEntry(path: "Agent Speed.app/").isDirectory)
        #expect(!ZipEntry(path: "Agent Speed.app").isDirectory)
        #expect(!ZipEntry(path: "Agent Speed.app/link", isSymbolicLink: true).isDirectory)
    }
}
