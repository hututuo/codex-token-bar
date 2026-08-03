import Darwin
import XCTest
@testable import CodexTokenBar

final class CodexUnreadThreadReaderTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryDirectories {
            CodexUnreadThreadReader.resetSessionVisibilityCacheForTesting(codexHome: url)
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testUnreadReaderKeepsOnlyConfirmedVisibleUserThreads() throws {
        let codexHome = try makeCodexHome()
        let userID = "019edaaa-1111-7222-8333-aaaaaaaaaaaa"
        let subagentID = "019edaaa-2222-7333-8444-bbbbbbbbbbbb"
        let archivedID = "019edaaa-3333-7444-8555-cccccccccccc"
        let unresolvedID = "019edaaa-4444-7555-8666-dddddddddddd"
        let vscodeID = "019edaaa-5555-7666-8777-eeeeeeeeeeee"

        try writeUnreadState([userID, subagentID, archivedID, unresolvedID, vscodeID], to: codexHome)
        try seedStateDatabase(
            at: codexHome,
            userID: userID,
            subagentID: subagentID,
            archivedID: archivedID,
            vscodeID: vscodeID
        )

        let result = CodexUnreadThreadReader.readUnreadThreadIDs(codexHome: codexHome)

        guard case let .available(threadIDs) = result else {
            return XCTFail("Expected unread state to be readable")
        }
        XCTAssertEqual(threadIDs, [userID, vscodeID])
    }

    func testUnreadPollingDoesNotRetainStateDatabaseDescriptors() throws {
        let codexHome = try makeCodexHome()
        let threadID = "019edaaa-1010-7222-8333-aaaaaaaaaaaa"
        try writeUnreadState([threadID], to: codexHome)
        try seedVisibleStateDatabase(at: codexHome, threadIDs: [threadID])
        let databaseURL = codexHome.appendingPathComponent("state_5.sqlite")

        for _ in 0..<10 {
            XCTAssertEqual(
                availableIDs(CodexUnreadThreadReader.readUnreadThreadIDs(codexHome: codexHome)),
                [threadID]
            )
            XCTAssertEqual(
                try openDescriptorCount(for: databaseURL),
                0,
                "unread polling must close state_5 before returning"
            )
        }
    }

    func testUnreadPollingReopensSameSizeSameMtimeReplacement() throws {
        let codexHome = try makeCodexHome()
        let threadID = "019edaaa-2020-7333-8444-bbbbbbbbbbbb"
        let sessions = codexHome.appendingPathComponent("sessions/2026/07/31", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try writeSessionMeta(
            id: threadID,
            threadSource: "user",
            to: sessions.appendingPathComponent("rollout-visible.jsonl")
        )
        try writeUnreadState([threadID], to: codexHome)

        let databaseURL = codexHome.appendingPathComponent("state_5.sqlite")
        try seedVisibilityDatabase(at: databaseURL, threadID: threadID, archived: false)
        let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: databaseURL.path)
        XCTAssertEqual(
            availableIDs(CodexUnreadThreadReader.readUnreadThreadIDs(codexHome: codexHome)),
            [threadID]
        )
        XCTAssertEqual(try openDescriptorCount(for: databaseURL), 0)

        let originalAttributes = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
        let replacementURL = codexHome.appendingPathComponent("state_5.replacement.sqlite")
        try seedVisibilityDatabase(at: replacementURL, threadID: threadID, archived: true)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: replacementURL.path)
        let replacementAttributes = try FileManager.default.attributesOfItem(atPath: replacementURL.path)
        XCTAssertEqual(
            originalAttributes[.size] as? NSNumber,
            replacementAttributes[.size] as? NSNumber,
            "fixture must defeat the former size-only identity check"
        )
        XCTAssertEqual(
            originalAttributes[.modificationDate] as? Date,
            replacementAttributes[.modificationDate] as? Date,
            "fixture must defeat the former mtime-only identity check"
        )

        try FileManager.default.removeItem(at: databaseURL)
        try FileManager.default.moveItem(at: replacementURL, to: databaseURL)

        XCTAssertEqual(
            availableIDs(CodexUnreadThreadReader.readUnreadThreadIDs(codexHome: codexHome)),
            [],
            "the replacement database marks the thread archived; stale handle or fallback data must not win"
        )
        XCTAssertEqual(try openDescriptorCount(for: databaseURL), 0)
    }

    func testInitializedSidebarStateFiltersGhostUnreadThreads() throws {
        let codexHome = try makeCodexHome()
        let orderedID = "019edaaa-6111-7222-8333-aaaaaaaaaaaa"
        let pinnedID = "019edaaa-6222-7333-8444-bbbbbbbbbbbb"
        let projectlessID = "019edaaa-6333-7444-8555-cccccccccccc"
        let ghostID = "019edaaa-6444-7555-8666-dddddddddddd"

        try writeUnreadState(
            [orderedID, pinnedID, projectlessID, ghostID],
            sidebarThreadIDs: [orderedID],
            pinnedThreadIDs: [pinnedID],
            projectlessThreadIDs: [projectlessID],
            initialized: true,
            to: codexHome
        )
        try seedVisibleStateDatabase(
            at: codexHome,
            threadIDs: [orderedID, pinnedID, projectlessID, ghostID]
        )

        XCTAssertEqual(
            availableIDs(CodexUnreadThreadReader.readUnreadThreadIDs(codexHome: codexHome)),
            [orderedID, pinnedID, projectlessID]
        )
    }

    func testInitializedEmptySidebarStateClearsGhostUnreadThreads() throws {
        let codexHome = try makeCodexHome()
        let ghostID = "019edaaa-6555-7666-8777-eeeeeeeeeeee"

        try writeUnreadState(
            [ghostID],
            sidebarThreadIDs: [],
            initialized: true,
            to: codexHome
        )
        try seedVisibleStateDatabase(at: codexHome, threadIDs: [ghostID])

        XCTAssertEqual(
            availableIDs(CodexUnreadThreadReader.readUnreadThreadIDs(codexHome: codexHome)),
            []
        )
    }

    func testUninitializedSidebarStateFailsClosedWithoutHistoricalVisibilityFallback() throws {
        let codexHome = try makeCodexHome()
        let unreadID = "019edaaa-6666-7777-8888-ffffffffffff"

        try writeUnreadState(
            [unreadID],
            sidebarThreadIDs: [],
            initialized: false,
            to: codexHome
        )
        try seedVisibleStateDatabase(at: codexHome, threadIDs: [unreadID])

        guard case .unavailable = CodexUnreadThreadReader.readUnreadThreadIDs(codexHome: codexHome) else {
            return XCTFail("An uninitialized sidebar snapshot must not expose historical IDs")
        }
    }

    func testMalformedSidebarStateFailsClosedWithoutHistoricalVisibilityFallback() throws {
        let codexHome = try makeCodexHome()
        let unreadID = "019edaaa-6777-7888-8999-aaaaaaaaaaaa"
        let object: [String: Any] = [
            "electron-persisted-atom-state": [
                "unread-thread-ids-by-host-v1": ["local": [unreadID]],
                "flat-project-sidebar-preferences-v1": ["initialized": true]
            ],
            "sidebar-project-thread-orders": [:],
            "pinned-thread-ids": "malformed",
            "projectless-thread-ids": []
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: codexHome.appendingPathComponent(".codex-global-state.json"))
        try seedVisibleStateDatabase(at: codexHome, threadIDs: [unreadID])

        guard case .unavailable = CodexUnreadThreadReader.readUnreadThreadIDs(codexHome: codexHome) else {
            return XCTFail("A malformed sidebar snapshot must not expose historical IDs")
        }
    }

    func testSessionVisibilityIndexOnlyParsesNewOrReplacedSessionMetas() throws {
        let codexHome = try makeCodexHome()
        let sessions = codexHome.appendingPathComponent("sessions/2026/07/15", isDirectory: true)
        let archivedSessions = codexHome.appendingPathComponent("archived_sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archivedSessions, withIntermediateDirectories: true)

        let userID = "019f6200-1111-7222-8333-aaaaaaaaaaaa"
        let subagentID = "019f6200-2222-7333-8444-bbbbbbbbbbbb"
        let secondUserID = "019f6200-3333-7444-8555-cccccccccccc"
        let unresolvedID = "019f6200-4444-7555-8666-dddddddddddd"
        let userSession = sessions.appendingPathComponent("rollout-user.jsonl")
        let subagentSession = sessions.appendingPathComponent("rollout-subagent.jsonl")
        let secondUserSession = sessions.appendingPathComponent("rollout-second-user.jsonl")

        try writeSessionMeta(id: userID, threadSource: "user", to: userSession)
        try writeSessionMeta(id: subagentID, threadSource: "subagent", to: subagentSession)
        try writeUnreadState([userID, subagentID, unresolvedID], to: codexHome)
        CodexUnreadThreadReader.resetSessionVisibilityCacheForTesting(codexHome: codexHome)

        XCTAssertEqual(
            availableIDs(CodexUnreadThreadReader.readUnreadThreadIDs(codexHome: codexHome)),
            [userID]
        )
        let initialParseCount = CodexUnreadThreadReader.sessionMetaParseCountForTesting(codexHome: codexHome)
        XCTAssertEqual(initialParseCount, 2)
        XCTAssertEqual(CodexUnreadThreadReader.sessionVisibilityFullScanCountForTesting(codexHome: codexHome), 1)

        XCTAssertEqual(
            availableIDs(CodexUnreadThreadReader.readUnreadThreadIDs(codexHome: codexHome)),
            [userID]
        )
        XCTAssertEqual(
            CodexUnreadThreadReader.sessionMetaParseCountForTesting(codexHome: codexHome),
            initialParseCount,
            "Unchanged session metas should be served from the visibility index"
        )
        XCTAssertEqual(
            CodexUnreadThreadReader.sessionVisibilityFullScanCountForTesting(codexHome: codexHome),
            1,
            "An unchanged official unread set should not rescan the session tree"
        )

        try writeSessionMeta(id: secondUserID, threadSource: "user", to: secondUserSession)
        try writeUnreadState([userID, subagentID, secondUserID, unresolvedID], to: codexHome)
        XCTAssertEqual(
            availableIDs(CodexUnreadThreadReader.readUnreadThreadIDs(codexHome: codexHome)),
            [userID, secondUserID]
        )
        XCTAssertEqual(
            CodexUnreadThreadReader.sessionMetaParseCountForTesting(codexHome: codexHome),
            initialParseCount + 1,
            "Only the newly discovered session should be parsed"
        )
        XCTAssertEqual(CodexUnreadThreadReader.sessionVisibilityFullScanCountForTesting(codexHome: codexHome), 2)

        let archivedUserSession = archivedSessions.appendingPathComponent(userSession.lastPathComponent)
        try FileManager.default.moveItem(at: userSession, to: archivedUserSession)
        XCTAssertEqual(
            availableIDs(CodexUnreadThreadReader.readUnreadThreadIDs(codexHome: codexHome)),
            [secondUserID],
            "Moving a session into the archive must immediately remove it from visible unread threads"
        )
        XCTAssertEqual(
            CodexUnreadThreadReader.sessionMetaParseCountForTesting(codexHome: codexHome),
            initialParseCount + 2
        )
        XCTAssertEqual(CodexUnreadThreadReader.sessionVisibilityFullScanCountForTesting(codexHome: codexHome), 3)
    }

    private func makeCodexHome() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-unread-reader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func writeUnreadState(_ ids: [String], to codexHome: URL) throws {
        let object: [String: Any] = [
            "electron-persisted-atom-state": [
                "unread-thread-ids-by-host-v1": [
                    "local": ids
                ],
                "flat-project-sidebar-preferences-v1": [
                    "initialized": true,
                    "mode": "project"
                ]
            ],
            "sidebar-project-thread-orders": [
                "local-project": [
                    "sortKey": "updated_at",
                    "threadIds": ids
                ]
            ],
            "pinned-thread-ids": [],
            "projectless-thread-ids": []
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: codexHome.appendingPathComponent(".codex-global-state.json"))
    }

    private func writeUnreadState(
        _ ids: [String],
        sidebarThreadIDs: [String],
        pinnedThreadIDs: [String] = [],
        projectlessThreadIDs: [String] = [],
        initialized: Bool,
        to codexHome: URL
    ) throws {
        let object: [String: Any] = [
            "electron-persisted-atom-state": [
                "unread-thread-ids-by-host-v1": [
                    "local": ids
                ],
                "flat-project-sidebar-preferences-v1": [
                    "initialized": initialized,
                    "mode": "project"
                ]
            ],
            "sidebar-project-thread-orders": [
                "local-project": [
                    "sortKey": "updated_at",
                    "threadIds": sidebarThreadIDs
                ]
            ],
            "pinned-thread-ids": pinnedThreadIDs,
            "projectless-thread-ids": projectlessThreadIDs
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: codexHome.appendingPathComponent(".codex-global-state.json"))
    }

    private func writeSessionMeta(id: String, threadSource: String, to url: URL) throws {
        let line = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\",\"thread_source\":\"\(threadSource)\",\"source\":\"desktop\"}}\n"
        try line.write(to: url, atomically: true, encoding: .utf8)
    }

    private func availableIDs(_ result: CodexUnreadThreadReadResult) -> Set<String> {
        guard case let .available(ids) = result else {
            XCTFail("Expected unread state to be readable")
            return []
        }
        return ids
    }

    private func seedStateDatabase(
        at codexHome: URL,
        userID: String,
        subagentID: String,
        archivedID: String,
        vscodeID: String
    ) throws {
        let driver = SQLiteDatabaseDriver(url: codexHome.appendingPathComponent("state_5.sqlite"))
        try driver.execute("""
        CREATE TABLE threads (
            id TEXT PRIMARY KEY,
            archived INTEGER,
            has_user_event INTEGER,
            thread_source TEXT,
            source TEXT,
            preview TEXT
        );
        """)
        try driver.execute(
            """
            INSERT INTO threads (id, archived, has_user_event, thread_source, source, preview)
            VALUES
                (?, 0, 1, 'user', '', 'visible user thread'),
                (?, 0, 0, 'subagent', '{"subagent":true}', 'subagent thread'),
                (?, 1, 1, 'user', '', 'archived thread'),
                (?, 0, 0, 'user', 'vscode', 'vscode unread thread');
            """,
            bindings: [.text(userID), .text(subagentID), .text(archivedID), .text(vscodeID)]
        )
    }

    private func seedVisibleStateDatabase(at codexHome: URL, threadIDs: [String]) throws {
        let driver = SQLiteDatabaseDriver(url: codexHome.appendingPathComponent("state_5.sqlite"))
        try driver.execute("""
        CREATE TABLE threads (
            id TEXT PRIMARY KEY,
            archived INTEGER,
            thread_source TEXT,
            source TEXT,
            preview TEXT
        );
        """)
        for threadID in threadIDs {
            try driver.execute(
                """
                INSERT INTO threads (id, archived, thread_source, source, preview)
                VALUES (?, 0, 'user', 'desktop', 'visible user thread');
                """,
                bindings: [.text(threadID)]
            )
        }
    }

    private func seedVisibilityDatabase(at url: URL, threadID: String, archived: Bool) throws {
        let driver = SQLiteDatabaseDriver(url: url)
        try driver.execute("""
        CREATE TABLE threads (
            id TEXT PRIMARY KEY,
            archived INTEGER,
            thread_source TEXT,
            source TEXT,
            preview TEXT
        );
        """)
        try driver.execute(
            """
            INSERT INTO threads (id, archived, thread_source, source, preview)
            VALUES (?, ?, 'user', 'desktop', 'visible user thread');
            """,
            bindings: [.text(threadID), .int(archived ? 1 : 0)]
        )
    }

    private func openDescriptorCount(for url: URL) throws -> Int {
        var expected = stat()
        let status = url.path.withCString { Darwin.lstat($0, &expected) }
        guard status == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var count = 0
        for descriptor in 0..<getdtablesize() {
            var candidate = stat()
            guard Darwin.fstat(descriptor, &candidate) == 0 else { continue }
            if candidate.st_dev == expected.st_dev, candidate.st_ino == expected.st_ino {
                count += 1
            }
        }
        return count
    }
}
