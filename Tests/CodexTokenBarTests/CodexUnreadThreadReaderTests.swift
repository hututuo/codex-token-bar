import XCTest
@testable import CodexTokenBar

final class CodexUnreadThreadReaderTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testUnreadReaderKeepsUnresolvedOfficialUnreadIDsButFiltersKnownSubagents() throws {
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
        XCTAssertEqual(threadIDs, [userID, unresolvedID, vscodeID])
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
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: codexHome.appendingPathComponent(".codex-global-state.json"))
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
}
