import Foundation
import XCTest
@testable import CodexTokenBar

final class CodexAutoResumeAppServerClientTests: XCTestCase {
    func testLiveProgressedThreadIsSkippedWhenExplicitlyEnabled() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CODEX_TOKEN_BAR_RUN_LIVE_AUTO_RESUME_TEST"] == "1" else {
            throw XCTSkip("Set CODEX_TOKEN_BAR_RUN_LIVE_AUTO_RESUME_TEST=1 for the isolated live test")
        }
        let threadID = try XCTUnwrap(environment["CODEX_TOKEN_BAR_LIVE_AUTO_RESUME_THREAD_ID"])
        let source = try XCTUnwrap(CodexDataSourceResolver().resolve())
        let codexPath = try CodexBinaryLocator.findExecutable()
        let client = CodexAppServerClient()
        let threads = try await client.listThreads(codexPath: codexPath, dataSource: source)
        let target = try XCTUnwrap(threads.first { $0.id == threadID })

        do {
            _ = try await client.resumeThread(
                codexPath: codexPath,
                dataSource: source,
                target: target,
                prompt: "继续",
                clientMessageID: "live-progress-skip:\(threadID):\(UUID().uuidString)",
                expectedFreshness: AutoResumeThreadFreshness(
                    updatedAt: .distantPast,
                    lastTurnID: "codex-token-bar-stale-live-baseline"
                )
            )
            XCTFail("Expected the real thread/read preflight to detect newer progress")
        } catch {
            XCTAssertEqual(error as? CodexAutoResumeAppServerError, .threadProgressed)
        }
    }

    func testLiveResumeWhenExplicitlyEnabled() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CODEX_TOKEN_BAR_RUN_LIVE_AUTO_RESUME_TEST"] == "1" else {
            throw XCTSkip("Set CODEX_TOKEN_BAR_RUN_LIVE_AUTO_RESUME_TEST=1 for the isolated live test")
        }
        let threadID = try XCTUnwrap(environment["CODEX_TOKEN_BAR_LIVE_AUTO_RESUME_THREAD_ID"])
        let source = try XCTUnwrap(CodexDataSourceResolver().resolve())
        let codexPath = try CodexBinaryLocator.findExecutable()
        let client = CodexAppServerClient()
        let threads = try await client.listThreads(codexPath: codexPath, dataSource: source)
        let target = try XCTUnwrap(
            threads.first { $0.id == threadID },
            "The isolated live thread must be returned by the explicit top-level sourceKinds filter"
        )

        let result = try await client.resumeThread(
            codexPath: codexPath,
            dataSource: source,
            target: target,
            prompt: "继续",
            clientMessageID: "live-test:\(threadID):\(UUID().uuidString)"
        )

        XCTAssertEqual(result.threadID, threadID)
        XCTAssertFalse(result.turnID.isEmpty)
        XCTAssertEqual(result.status.lowercased().filter(\.isLetter), "completed")
        print(
            "LIVE_AUTO_RESUME_RESULT thread=\(result.threadID) "
                + "turn=\(result.turnID) status=\(result.status)"
        )
    }

    func testListThreadsUsesStableAPIAndKeepsSameCWDThreads() async throws {
        let transport = AutoResumeScriptedTransport(events: [
            rpcResult(id: 1, result: [:]),
            rpcResult(id: 2, result: [
                "data": [
                    ["id": "thread-a", "name": "Alpha", "cwd": "/tmp/shared", "updatedAt": 100],
                    ["id": "thread-b", "name": "Beta", "cwd": "/tmp/shared", "updatedAt": 300],
                ],
                "nextCursor": "page-2",
            ]),
            rpcResult(id: 3, result: [
                "data": [
                    ["id": "thread-c", "preview": "Gamma\nSecond line", "cwd": "/tmp/other", "updatedAt": 200],
                ],
                "nextCursor": NSNull(),
            ]),
        ])
        let client = CodexAppServerClient(transport: transport, requestTimeout: 1, turnTimeout: 1)

        let threads = try await client.listThreads(codexPath: "/fake/codex", dataSource: nil)

        XCTAssertEqual(threads.map(\.id), ["thread-b", "thread-c", "thread-a"])
        XCTAssertEqual(threads.filter { $0.cwd == "/tmp/shared" }.count, 2)
        XCTAssertEqual(threads.first { $0.id == "thread-c" }?.title, "Gamma")

        let writes = transport.writes
        XCTAssertEqual(writes.compactMap(rpcMethod), ["initialize", "initialized", "thread/list", "thread/list"])
        let initialize = try XCTUnwrap(writes.first)
        let capabilities = try XCTUnwrap(
            (initialize["params"] as? [String: Any])?["capabilities"] as? [String: Any]
        )
        XCTAssertEqual(capabilities["experimentalApi"] as? Bool, false)

        let firstList = try XCTUnwrap(writes.first { rpcMethod($0) == "thread/list" })
        let firstParams = try XCTUnwrap(firstList["params"] as? [String: Any])
        XCTAssertEqual(firstParams["archived"] as? Bool, false)
        XCTAssertEqual((firstParams["limit"] as? NSNumber)?.intValue, 100)
        XCTAssertEqual(firstParams["sortKey"] as? String, "updated_at")
        XCTAssertEqual(firstParams["sortDirection"] as? String, "desc")
        XCTAssertEqual(
            firstParams["sourceKinds"] as? [String],
            ["cli", "vscode", "exec", "appServer", "unknown"]
        )
        XCTAssertNil(firstParams["cursor"])

        let listWrites = writes.filter { rpcMethod($0) == "thread/list" }
        let secondParams = try XCTUnwrap(listWrites.last?["params"] as? [String: Any])
        XCTAssertEqual(secondParams["cursor"] as? String, "page-2")
    }

    func testVisibilityRebuildScansActiveAndArchivedWithinPageCap() throws {
        var events = [rpcResult(id: 1, result: [:])]
        for page in 0..<23 {
            events.append(rpcResult(id: page + 2, result: [
                "data": [["id": "active-\(page)"]],
                "nextCursor": page < 22 ? "active-\(page + 1)" : NSNull(),
            ]))
        }
        events.append(rpcResult(id: 25, result: [
            "data": [["id": "archived-1"], ["id": "archived-2"]],
            "nextCursor": NSNull(),
        ]))
        let transport = AutoResumeScriptedTransport(events: events)
        let client = CodexAppServerClient(transport: transport, requestTimeout: 1, turnTimeout: 1)
        var pageChecks = 0

        let result = try client.rebuildConversationVisibilityMetadata(
            codexPath: "/fake/codex",
            dataSource: nil,
            beforePage: { pageChecks += 1 }
        )

        XCTAssertEqual(result.activeThreads, 23)
        XCTAssertEqual(result.archivedThreads, 2)
        XCTAssertEqual(result.pagesScanned, 24)
        XCTAssertEqual(pageChecks, 24)
        let lists = transport.writes.filter { rpcMethod($0) == "thread/list" }
        XCTAssertEqual(lists.count, 24)
        let firstParams = try XCTUnwrap(lists.first?["params"] as? [String: Any])
        XCTAssertEqual(firstParams["archived"] as? Bool, false)
        XCTAssertEqual(firstParams["useStateDbOnly"] as? Bool, false)
        XCTAssertEqual(
            firstParams["sourceKinds"] as? [String],
            ["cli", "vscode", "exec", "appServer", "subAgent", "unknown"]
        )
        let archivedParams = try XCTUnwrap(lists.last?["params"] as? [String: Any])
        XCTAssertEqual(archivedParams["archived"] as? Bool, true)
        XCTAssertNil(archivedParams["cursor"])
    }

    func testVisibilityRebuildRejectsRepeatedCursor() throws {
        let transport = AutoResumeScriptedTransport(events: [
            rpcResult(id: 1, result: [:]),
            rpcResult(id: 2, result: ["data": [], "nextCursor": "repeat"]),
            rpcResult(id: 3, result: ["data": [], "nextCursor": "repeat"]),
        ])
        let client = CodexAppServerClient(transport: transport, requestTimeout: 1, turnTimeout: 1)

        XCTAssertThrowsError(
            try client.rebuildConversationVisibilityMetadata(
                codexPath: "/fake/codex",
                dataSource: nil
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("重复游标"))
        }
    }

    func testVisibilityRebuildStopsAtPageCapOnEndlessUniqueCursors() throws {
        var events = [rpcResult(id: 1, result: [:])]
        for page in 0..<3 {
            events.append(rpcResult(id: page + 2, result: [
                "data": [],
                "nextCursor": "unique-\(page)",
            ]))
        }
        let transport = AutoResumeScriptedTransport(events: events)
        let client = CodexAppServerClient(
            transport: transport,
            requestTimeout: 1,
            turnTimeout: 1,
            visibilityRebuildMaxPages: 3
        )

        XCTAssertThrowsError(
            try client.rebuildConversationVisibilityMetadata(
                codexPath: "/fake/codex",
                dataSource: nil
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("页上限"))
        }
        let lists = transport.writes.filter { rpcMethod($0) == "thread/list" }
        XCTAssertEqual(lists.count, 3, "达到页上限后不得再发起分页请求")
    }

    func testVisibilityRebuildStopsWhenTimeBudgetIsExhausted() throws {
        let transport = AutoResumeScriptedTransport(events: [
            rpcResult(id: 1, result: [:]),
        ])
        let client = CodexAppServerClient(
            transport: transport,
            requestTimeout: 1,
            turnTimeout: 1,
            visibilityRebuildTimeBudget: 0
        )

        XCTAssertThrowsError(
            try client.rebuildConversationVisibilityMetadata(
                codexPath: "/fake/codex",
                dataSource: nil
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("总时限"))
        }
        let lists = transport.writes.filter { rpcMethod($0) == "thread/list" }
        XCTAssertEqual(lists.count, 0, "超时后不得再发起分页请求")
    }

    func testResumeUsesStableSequenceAndDeterministicClientMessageID() async throws {
        let transport = AutoResumeScriptedTransport(events: successfulResumeEvents(
            beforeMatchingCompletion: [
                notification("turn/completed", params: [
                    "threadId": "thread-1",
                    "turn": ["id": "foreign-turn", "status": "completed"],
                ]),
                notification("turn/completed", params: [
                    "threadId": "foreign-thread",
                    "turn": ["id": "turn-1", "status": "completed"],
                ]),
            ]
        ))
        let client = CodexAppServerClient(transport: transport, requestTimeout: 1, turnTimeout: 1)
        let target = thread(id: "thread-1")

        let result = try await client.resumeThread(
            codexPath: "/fake/codex",
            dataSource: nil,
            target: target,
            prompt: "继续",
            clientMessageID: "daily:thread-1:2026-07-16:0900"
        )

        XCTAssertEqual(result.threadID, "thread-1")
        XCTAssertEqual(result.turnID, "turn-1")
        XCTAssertEqual(result.status, "completed")
        XCTAssertEqual(result.message, "done")

        let writes = transport.writes
        XCTAssertEqual(
            writes.compactMap(rpcMethod),
            ["initialize", "initialized", "thread/resume", "thread/read", "turn/start"]
        )
        let resume = try XCTUnwrap(writes.first { rpcMethod($0) == "thread/resume" })
        let resumeParams = try XCTUnwrap(resume["params"] as? [String: Any])
        XCTAssertEqual(Set(resumeParams.keys), ["threadId"])
        XCTAssertEqual(resumeParams["threadId"] as? String, "thread-1")

        let start = try XCTUnwrap(writes.first { rpcMethod($0) == "turn/start" })
        let startParams = try XCTUnwrap(start["params"] as? [String: Any])
        XCTAssertEqual(startParams["clientUserMessageId"] as? String, "daily:thread-1:2026-07-16:0900")
        XCTAssertEqual(startParams["threadId"] as? String, "thread-1")
        let input = try XCTUnwrap(startParams["input"] as? [[String: Any]])
        XCTAssertEqual(input.first?["type"] as? String, "text")
        XCTAssertEqual(input.first?["text"] as? String, "继续")
    }

    func testReadThreadFreshnessUsesThreadReadAndReturnsLastTurn() async throws {
        let transport = AutoResumeScriptedTransport(events: [
            rpcResult(id: 1, result: [:]),
            rpcResult(id: 2, result: [
                "thread": [
                    "id": "thread-1",
                    "updatedAt": 200,
                    "turns": [
                        ["id": "turn-old", "status": "completed"],
                        ["id": "turn-current", "status": "completed"],
                    ],
                ],
            ]),
        ])
        let client = CodexAppServerClient(transport: transport, requestTimeout: 1, turnTimeout: 1)

        let freshness = try await client.readThreadFreshness(
            codexPath: "/fake/codex",
            dataSource: nil,
            threadID: "thread-1"
        )

        XCTAssertEqual(freshness.lastTurnID, "turn-current")
        XCTAssertEqual(freshness.updatedAt, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(
            transport.writes.compactMap(rpcMethod),
            ["initialize", "initialized", "thread/read"]
        )
        let read = try XCTUnwrap(transport.writes.first { rpcMethod($0) == "thread/read" })
        let params = try XCTUnwrap(read["params"] as? [String: Any])
        XCTAssertEqual(params["threadId"] as? String, "thread-1")
        XCTAssertEqual(params["includeTurns"] as? Bool, true)
    }

    func testReadLatestTurnObservationUsesOneTurnSummaryAndStructuredCapacityError() async throws {
        let transport = AutoResumeScriptedTransport(events: [
            rpcResult(id: 1, result: [:]),
            rpcResult(id: 2, result: [
                "data": [[
                    "id": "capacity-turn",
                    "status": "failed",
                    "completedAt": 200,
                    "error": [
                        "message": "Selected model is at capacity. Please try a different model.",
                        "codexErrorInfo": "serverOverloaded",
                    ],
                    "items": [[
                        "type": "userMessage",
                        "clientId": "desktop-user-message",
                    ]],
                ]],
            ]),
        ])
        let client = CodexAppServerClient(transport: transport, requestTimeout: 1, turnTimeout: 1)

        let value = try await client.readLatestTurnObservation(
            codexPath: "/fake/codex",
            dataSource: nil,
            threadID: "thread-1"
        )
        let observation = try XCTUnwrap(value)

        XCTAssertEqual(observation.turnID, "capacity-turn")
        XCTAssertEqual(observation.completedAt, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(observation.codexErrorCode, "serverOverloaded")
        XCTAssertEqual(observation.clientUserMessageID, "desktop-user-message")
        XCTAssertTrue(observation.isRecoverableCapacityFailure)
        XCTAssertEqual(
            transport.writes.compactMap(rpcMethod),
            ["initialize", "initialized", "thread/turns/list"]
        )
        let initialize = try XCTUnwrap(transport.writes.first)
        let capabilities = try XCTUnwrap(
            (initialize["params"] as? [String: Any])?["capabilities"] as? [String: Any]
        )
        XCTAssertEqual(capabilities["experimentalApi"] as? Bool, true)
        let list = try XCTUnwrap(transport.writes.first { rpcMethod($0) == "thread/turns/list" })
        let params = try XCTUnwrap(list["params"] as? [String: Any])
        XCTAssertEqual((params["limit"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual(params["sortDirection"] as? String, "desc")
        XCTAssertEqual(params["itemsView"] as? String, "summary")
    }

    func testReadLatestTurnObservationParsesObjectErrorCodeAndRejectsOwnCapacityTurn() async throws {
        let transport = AutoResumeScriptedTransport(events: [
            rpcResult(id: 1, result: [:]),
            rpcResult(id: 2, result: [
                "data": [[
                    "id": "capacity-retry-turn",
                    "status": "failed",
                    "completedAt": 200,
                    "error": [
                        "message": "overloaded",
                        "codexErrorInfo": [
                            "responseTooManyFailedAttempts": ["httpStatusCode": 429],
                        ],
                    ],
                    "items": [[
                        "type": "userMessage",
                        "clientId": "capacity:thread-1:original-turn",
                    ]],
                ]],
            ]),
        ])
        let client = CodexAppServerClient(transport: transport, requestTimeout: 1, turnTimeout: 1)

        let value = try await client.readLatestTurnObservation(
            codexPath: "/fake/codex",
            dataSource: nil,
            threadID: "thread-1"
        )
        let observation = try XCTUnwrap(value)

        XCTAssertEqual(observation.codexErrorCode, "responseTooManyFailedAttempts")
        XCTAssertTrue(observation.isGeneratedByCapacityRecovery)
        XCTAssertFalse(observation.isRecoverableCapacityFailure)
    }

    func testCapacityObservationFallsBackToFullItemsToVerifyClientIdentity() async throws {
        let capacityTurn: [String: Any] = [
            "id": "capacity-retry-turn",
            "status": "failed",
            "startedAt": 195,
            "completedAt": 200,
            "error": [
                "message": "Selected model is at capacity. Please try a different model.",
                "codexErrorInfo": "serverOverloaded",
            ],
        ]
        var fullTurn = capacityTurn
        fullTurn["items"] = [[
            "type": "userMessage",
            "clientId": "capacity:thread-1:original-turn",
        ]]
        let transport = AutoResumeScriptedTransport(events: [
            rpcResult(id: 1, result: [:]),
            rpcResult(id: 2, result: ["data": [capacityTurn]]),
            rpcResult(id: 3, result: ["data": [fullTurn]]),
        ])
        let client = CodexAppServerClient(transport: transport, requestTimeout: 1, turnTimeout: 1)

        let value = try await client.readLatestTurnObservation(
            codexPath: "/fake/codex",
            dataSource: nil,
            threadID: "thread-1"
        )
        let observation = try XCTUnwrap(value)

        XCTAssertEqual(observation.startedAt, Date(timeIntervalSince1970: 195))
        XCTAssertTrue(observation.isGeneratedByCapacityRecovery)
        XCTAssertFalse(observation.isRecoverableCapacityFailure)
        let listRequests = transport.writes.filter { rpcMethod($0) == "thread/turns/list" }
        XCTAssertEqual(listRequests.count, 2)
        XCTAssertEqual(
            (listRequests.last?["params"] as? [String: Any])?["itemsView"] as? String,
            "full"
        )
    }

    func testAutomaticResumeSkipsBeforeResumeOrTurnStartWhenThreadProgressed() async {
        let transport = AutoResumeScriptedTransport(events: [
            rpcResult(id: 1, result: [:]),
            rpcResult(id: 2, result: [
                "thread": [
                    "id": "thread-1",
                    "updatedAt": 200,
                    "turns": [["id": "manual-turn", "status": "completed"]],
                ],
            ]),
        ])
        let client = CodexAppServerClient(transport: transport, requestTimeout: 1, turnTimeout: 1)
        let baseline = AutoResumeThreadFreshness(
            updatedAt: Date(timeIntervalSince1970: 100),
            lastTurnID: "old-turn"
        )

        do {
            _ = try await client.resumeThread(
                codexPath: "/fake/codex",
                dataSource: nil,
                target: thread(id: "thread-1"),
                prompt: "继续",
                clientMessageID: "daily:thread-1:2026-07-16:0900",
                expectedFreshness: baseline
            )
            XCTFail("Expected progressed thread to satisfy the pending continuation")
        } catch {
            XCTAssertEqual(error as? CodexAutoResumeAppServerError, .threadProgressed)
        }

        XCTAssertEqual(
            transport.writes.compactMap(rpcMethod),
            ["initialize", "initialized", "thread/read"]
        )
        XCTAssertFalse(transport.writes.contains { rpcMethod($0) == "thread/resume" })
        XCTAssertFalse(transport.writes.contains { rpcMethod($0) == "turn/start" })
    }

    func testAutomaticResumeContinuesWhenFreshnessStillMatches() async throws {
        let transport = AutoResumeScriptedTransport(events: [
            rpcResult(id: 1, result: [:]),
            rpcResult(id: 2, result: [
                "thread": [
                    "id": "thread-1",
                    "updatedAt": 100,
                    "turns": [["id": "old-turn", "status": "completed"]],
                ],
            ]),
            rpcResult(id: 3, result: ["thread": ["id": "thread-1"]]),
            rpcResult(id: 4, result: [
                "thread": [
                    "id": "thread-1",
                    "updatedAt": 100,
                    "turns": [["id": "old-turn", "status": "completed"]],
                ],
            ]),
            rpcResult(id: 5, result: ["turn": ["id": "turn-1", "status": "inProgress"]]),
            notification("turn/completed", params: [
                "threadId": "thread-1",
                "turn": ["id": "turn-1", "status": "completed", "result": "done"],
            ]),
        ])
        let client = CodexAppServerClient(transport: transport, requestTimeout: 1, turnTimeout: 1)
        let baseline = AutoResumeThreadFreshness(
            updatedAt: Date(timeIntervalSince1970: 100),
            lastTurnID: "old-turn"
        )

        let result = try await client.resumeThread(
            codexPath: "/fake/codex",
            dataSource: nil,
            target: thread(id: "thread-1"),
            prompt: "继续",
            clientMessageID: "interval:thread-1:15:1",
            expectedFreshness: baseline
        )

        XCTAssertEqual(result.turnID, "turn-1")
        XCTAssertEqual(
            transport.writes.compactMap(rpcMethod),
            [
                "initialize",
                "initialized",
                "thread/read",
                "thread/resume",
                "thread/read",
                "turn/start",
            ]
        )
    }

    func testScheduleGenerationChangeAfterFinalReadPreventsTurnStartWrite() async throws {
        let transport = AutoResumeScriptedTransport(events: [
            rpcResult(id: 1, result: [:]),
            rpcResult(id: 2, result: [
                "thread": [
                    "id": "thread-1",
                    "updatedAt": 100,
                    "turns": [["id": "old-turn", "status": "completed"]],
                ],
            ]),
            rpcResult(id: 3, result: ["thread": ["id": "thread-1"]]),
        ])
        let client = CodexAppServerClient(transport: transport, requestTimeout: 2, turnTimeout: 2)
        var configuration = AutoResumeConfiguration.default
        configuration.enabled = true
        configuration.target = thread(id: "thread-1")
        configuration.scheduleMode = .interval
        let gate = AutoResumeStartGuard(configuration: configuration)
        let authorization = try XCTUnwrap(gate.authorization(
            for: .interval,
            targetID: "thread-1"
        ))
        let baseline = AutoResumeThreadFreshness(
            updatedAt: Date(timeIntervalSince1970: 100),
            lastTurnID: "old-turn"
        )
        let task = Task {
            try await client.resumeThread(
                codexPath: "/fake/codex",
                dataSource: nil,
                target: thread(id: "thread-1"),
                prompt: "继续",
                clientMessageID: "interval:thread-1:15:race",
                expectedFreshness: baseline,
                startAuthorization: authorization
            )
        }
        await waitForAutoResumeCondition("final thread/read request") {
            transport.writes.filter { rpcMethod($0) == "thread/read" }.count == 2
        }

        configuration.scheduleMode = .off
        gate.update(configuration: configuration)
        transport.enqueue(rpcResult(id: 4, result: [
            "thread": [
                "id": "thread-1",
                "updatedAt": 100,
                "turns": [["id": "old-turn", "status": "completed"]],
            ],
        ]))

        do {
            _ = try await task.value
            XCTFail("Expected the old schedule generation to be invalidated")
        } catch {
            XCTAssertEqual(error as? AutoResumeStartGuardError, .invalidated)
        }
        XCTAssertFalse(transport.writes.contains { rpcMethod($0) == "turn/start" })
    }

    func testResumeRejectsAnActiveLastTurnBeforeStartingAnother() async {
        let transport = AutoResumeScriptedTransport(events: [
            rpcResult(id: 1, result: [:]),
            rpcResult(id: 2, result: ["thread": ["id": "thread-1"]]),
            rpcResult(id: 3, result: [
                "thread": [
                    "id": "thread-1",
                    "turns": [["id": "active-turn", "status": "inProgress"]],
                ],
            ]),
        ])
        let client = CodexAppServerClient(transport: transport, requestTimeout: 1, turnTimeout: 1)

        do {
            _ = try await client.resumeThread(
                codexPath: "/fake/codex",
                dataSource: nil,
                target: thread(id: "thread-1"),
                prompt: "继续",
                clientMessageID: "manual-1"
            )
            XCTFail("Expected active turn rejection")
        } catch {
            XCTAssertEqual(error as? CodexAutoResumeAppServerError, .activeTurn("active-turn"))
        }
        XCTAssertFalse(transport.writes.contains { rpcMethod($0) == "turn/start" })
    }

    func testNewCommandApprovalIsDeclinedThenTurnIsInterrupted() async {
        let transport = AutoResumeScriptedTransport(events: successfulResumeEvents(
            replaceCompletionWith: serverRequest(
                id: 91,
                method: "item/commandExecution/requestApproval"
            )
        ))

        await assertRequiresHuman(transport: transport, expectedMethod: "item/commandExecution/requestApproval")

        let response = transport.writes.first { rpcID($0) == 91 }
        let result = response?["result"] as? [String: Any]
        XCTAssertEqual(result?["decision"] as? String, "decline")
        XCTAssertNil(response?["error"])
        assertInterruptAndNoApproval(transport.writes)
    }

    func testLegacyExecApprovalIsDeniedThenTurnIsInterrupted() async {
        let transport = AutoResumeScriptedTransport(events: successfulResumeEvents(
            replaceCompletionWith: serverRequest(id: 92, method: "execCommandApproval")
        ))

        await assertRequiresHuman(transport: transport, expectedMethod: "execCommandApproval")

        let response = transport.writes.first { rpcID($0) == 92 }
        let result = response?["result"] as? [String: Any]
        XCTAssertEqual(result?["decision"] as? String, "denied")
        XCTAssertNil(response?["error"])
        assertInterruptAndNoApproval(transport.writes)
    }

    func testUserInputReturnsJSONRPCErrorWithoutFabricatingAnswersAndInterrupts() async {
        let transport = AutoResumeScriptedTransport(events: successfulResumeEvents(
            replaceCompletionWith: serverRequest(id: 93, method: "item/tool/request_user_input")
        ))

        await assertRequiresHuman(transport: transport, expectedMethod: "item/tool/request_user_input")

        let response = transport.writes.first { rpcID($0) == 93 }
        let error = response?["error"] as? [String: Any]
        XCTAssertEqual((error?["code"] as? NSNumber)?.intValue, -32_000)
        XCTAssertNil(response?["result"])
        XCTAssertNil(response?["answers"])
        let encodedWrites = transport.writes.map(String.init(describing:)).joined(separator: "\n").lowercased()
        XCTAssertFalse(encodedWrites.contains("answers"))
        assertInterruptAndNoApproval(transport.writes)
    }

    func testQuotaLimitFailureIsClassifiedForFreshObservationRecoveryFlow() async {
        let transport = AutoResumeScriptedTransport(events: successfulResumeEvents(
            replaceCompletionWith: notification("turn/completed", params: [
                "threadId": "thread-1",
                "turn": [
                    "id": "turn-1",
                    "status": "failed",
                    "error": ["message": "usage limit reached; try again after reset"],
                ],
            ])
        ))
        let client = CodexAppServerClient(transport: transport, requestTimeout: 1, turnTimeout: 1)

        do {
            _ = try await client.resumeThread(
                codexPath: "/fake/codex",
                dataSource: nil,
                target: thread(id: "thread-1"),
                prompt: "继续",
                clientMessageID: "quota-test"
            )
            XCTFail("Expected quota limit classification")
        } catch {
            XCTAssertEqual(
                error as? CodexAutoResumeAppServerError,
                .quotaLimited("usage limit reached; try again after reset")
            )
        }
    }

    func testStructuredServerOverloadWith429IsNotMisclassifiedAsQuota() async {
        let message = "Selected model is at capacity (429). Please try a different model."
        let transport = AutoResumeScriptedTransport(events: successfulResumeEvents(
            replaceCompletionWith: notification("turn/completed", params: [
                "threadId": "thread-1",
                "turn": [
                    "id": "turn-1",
                    "status": "failed",
                    "error": [
                        "message": message,
                        "codexErrorInfo": "serverOverloaded",
                    ],
                ],
            ])
        ))
        let client = CodexAppServerClient(transport: transport, requestTimeout: 1, turnTimeout: 1)

        do {
            _ = try await client.resumeThread(
                codexPath: "/fake/codex",
                dataSource: nil,
                target: thread(id: "thread-1"),
                prompt: "继续",
                clientMessageID: "capacity-test"
            )
            XCTFail("Expected server failure")
        } catch {
            XCTAssertEqual(error as? CodexAutoResumeAppServerError, .serverError(message))
        }
    }

    func testCancellationBeforeTurnStartResponseWaitsForTurnIDAndInterrupts() async {
        let transport = AutoResumeScriptedTransport(events: [
            rpcResult(id: 1, result: [:]),
            rpcResult(id: 2, result: ["thread": ["id": "thread-1"]]),
            rpcResult(id: 3, result: [
                "thread": [
                    "id": "thread-1",
                    "turns": [["id": "old-turn", "status": "completed"]],
                ],
            ]),
        ])
        let client = CodexAppServerClient(transport: transport, requestTimeout: 2, turnTimeout: 2)
        let task = Task {
            try await client.resumeThread(
                codexPath: "/fake/codex",
                dataSource: nil,
                target: thread(id: "thread-1"),
                prompt: "继续",
                clientMessageID: "cancel-test"
            )
        }
        await waitForAutoResumeCondition("turn/start request") {
            transport.writes.contains { rpcMethod($0) == "turn/start" }
        }

        task.cancel()
        transport.enqueue(notification("turn/started", params: [
            "threadId": "thread-1",
            "turn": ["id": "turn-cancelled", "status": "inProgress"],
        ]))

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "Unexpected cancellation error: \(error)")
        }
        await waitForAutoResumeCondition("turn/interrupt request") {
            transport.writes.contains { rpcMethod($0) == "turn/interrupt" }
        }
        let interrupt = transport.writes.first { rpcMethod($0) == "turn/interrupt" }
        let params = interrupt?["params"] as? [String: Any]
        XCTAssertEqual(params?["threadId"] as? String, "thread-1")
        XCTAssertEqual(params?["turnId"] as? String, "turn-cancelled")
    }

    private func assertRequiresHuman(
        transport: AutoResumeScriptedTransport,
        expectedMethod: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let client = CodexAppServerClient(transport: transport, requestTimeout: 1, turnTimeout: 1)
        do {
            _ = try await client.resumeThread(
                codexPath: "/fake/codex",
                dataSource: nil,
                target: thread(id: "thread-1"),
                prompt: "继续",
                clientMessageID: "trigger-1"
            )
            XCTFail("Expected requiresHuman", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? CodexAutoResumeAppServerError,
                .requiresHuman(expectedMethod),
                file: file,
                line: line
            )
        }
    }

    private func assertInterruptAndNoApproval(
        _ writes: [[String: Any]],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let interrupt = writes.first { rpcMethod($0) == "turn/interrupt" }
        let params = interrupt?["params"] as? [String: Any]
        XCTAssertEqual(params?["threadId"] as? String, "thread-1", file: file, line: line)
        XCTAssertEqual(params?["turnId"] as? String, "turn-1", file: file, line: line)
        let encoded = writes.map(String.init(describing:)).joined(separator: "\n").lowercased()
        XCTAssertFalse(encoded.contains("\"approve\""), file: file, line: line)
        XCTAssertFalse(encoded.contains("\"accept\""), file: file, line: line)
    }
}

private final class AutoResumeScriptedTransport: AccountQuotaProcessTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var session: AutoResumeScriptedSession?
    private let events: [Data]

    init(events: [Data]) {
        self.events = events
    }

    var writes: [[String: Any]] {
        lock.withLock { session?.writes ?? [] }
    }

    func start(codexPath: String, dataSource: CodexDataSource?) throws -> any AccountQuotaProcessSession {
        lock.withLock {
            let created = AutoResumeScriptedSession(events: events)
            session = created
            return created
        }
    }

    func enqueue(_ event: Data) {
        lock.withLock { session?.enqueue(event) }
    }
}

private final class AutoResumeScriptedSession: AccountQuotaProcessSession, @unchecked Sendable {
    private let condition = NSCondition()
    private var events: [Data]
    private var rawWrites: [[String: Any]] = []
    private var terminated = false

    init(events: [Data]) {
        self.events = events
    }

    var writes: [[String: Any]] {
        condition.withLock { rawWrites }
    }

    func writeStdin(_ data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let message = object as? [String: Any] else { return }
        condition.withLock {
            rawWrites.append(message)
            condition.broadcast()
        }
    }

    func nextStdoutEvent(timeout: TimeInterval) throws -> AccountQuotaStdoutEvent {
        condition.withLock {
            if !events.isEmpty {
                return .line(events.removeFirst())
            }
            return terminated ? .endOfFile : .idle
        }
    }

    func stderrTailText() -> String? { nil }

    func requestTermination() {
        condition.withLock { terminated = true }
    }

    func enqueue(_ event: Data) {
        condition.withLock {
            events.append(event)
            condition.broadcast()
        }
    }

    func shutdown() throws -> AccountQuotaProcessExit {
        requestTermination()
        return AccountQuotaProcessExit(status: 0, reason: .exit)
    }
}

private func thread(id: String) -> AutoResumeThreadDescriptor {
    AutoResumeThreadDescriptor(id: id, title: "Target", cwd: "/tmp/project", updatedAt: nil)
}

private func successfulResumeEvents(
    beforeMatchingCompletion: [Data] = [],
    replaceCompletionWith replacement: Data? = nil
) -> [Data] {
    var values = [
        rpcResult(id: 1, result: [:]),
        rpcResult(id: 2, result: ["thread": ["id": "thread-1"]]),
        rpcResult(id: 3, result: [
            "thread": [
                "id": "thread-1",
                "turns": [["id": "old-turn", "status": "completed"]],
            ],
        ]),
        rpcResult(id: 4, result: ["turn": ["id": "turn-1", "status": "inProgress"]]),
    ]
    values.append(contentsOf: beforeMatchingCompletion)
    values.append(replacement ?? notification("turn/completed", params: [
        "threadId": "thread-1",
        "turn": [
            "id": "turn-1",
            "status": "completed",
            "result": "done",
        ],
    ]))
    return values
}

private func rpcResult(id: Int, result: [String: Any]) -> Data {
    jsonLine(["jsonrpc": "2.0", "id": id, "result": result])
}

private func notification(_ method: String, params: [String: Any]) -> Data {
    jsonLine(["jsonrpc": "2.0", "method": method, "params": params])
}

private func serverRequest(id: Int, method: String) -> Data {
    jsonLine(["jsonrpc": "2.0", "id": id, "method": method, "params": [:]])
}

private func jsonLine(_ object: [String: Any]) -> Data {
    var data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    data.append(0x0A)
    return data
}

private func rpcMethod(_ object: [String: Any]) -> String? {
    object["method"] as? String
}

private func rpcID(_ object: [String: Any]) -> Int? {
    (object["id"] as? NSNumber)?.intValue
}

private func waitForAutoResumeCondition(
    _ description: String,
    timeout: TimeInterval = 2,
    condition: @escaping () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Timed out waiting for \(description)")
}
