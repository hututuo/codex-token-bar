import Foundation
import XCTest
@testable import CodexTokenBar

final class CodexThreadDeleteBridgeTests: XCTestCase {
    @MainActor
    func testMissingDebugPortOffersLoopbackOnlyCodexRelaunch() {
        XCTAssertTrue(CodexThreadDeleteBridgeStatus.idle.requiresCodexRelaunch)
        XCTAssertEqual(
            CodexThreadDeleteBridgeStatus.idle.connectionActionTitle,
            "重启 Codex 并连接会话增强"
        )
        XCTAssertEqual(CodexThreadDeleteBridgeStatus.idle.dashboardActionTitle, "会话增强")
        XCTAssertEqual(
            CodexThreadDeleteDesktopLauncher.openCommandArguments(
                applicationPath: "/Applications/ChatGPT.app"
            ),
            [
                "-na",
                "/Applications/ChatGPT.app",
                "--args",
                "--remote-debugging-address=127.0.0.1",
                "--remote-debugging-port=9229",
            ]
        )

        let interrupted = CodexThreadDeleteBridgeStatus(
            connected: false,
            debugPort: 9229,
            message: "连接中断"
        )
        XCTAssertFalse(interrupted.requiresCodexRelaunch)
        XCTAssertEqual(interrupted.connectionActionTitle, "重新连接 Codex 会话增强")
        XCTAssertEqual(interrupted.dashboardActionTitle, "会话增强")

        let connected = CodexThreadDeleteBridgeStatus(
            connected: true,
            debugPort: 9229,
            message: "Codex 会话删除按钮已连接"
        )
        XCTAssertEqual(connected.dashboardActionTitle, "会话增强")

        let busy = CodexThreadDeleteBridgeStatus(
            connected: false,
            debugPort: nil,
            message: "正在重启",
            phase: .relaunching
        )
        XCTAssertTrue(busy.isBusy)
        XCTAssertFalse(busy.requiresCodexRelaunch)
        XCTAssertEqual(busy.dashboardActionTitle, "增强连接中")

        let waiting = CodexThreadDeleteInjectionVerification.waitingForRows
            .bridgeStatus(debugPort: 9229)
        XCTAssertFalse(waiting.connected)
        XCTAssertEqual(waiting.phase, .waitingForRows)
        XCTAssertEqual(waiting.dashboardActionTitle, "会话增强")
    }

    func testSharedInjectionTemplateRendersSwiftOwner() throws {
        let script = try CodexThreadDeleteInjectionScript.render(
            owner: "swift",
            bindingName: "codexTokenBarDeleteSwift"
        )

        XCTAssertTrue(script.contains("const owner = \"swift\";"))
        XCTAssertTrue(script.contains("const bindingName = \"codexTokenBarDeleteSwift\";"))
        XCTAssertFalse(script.contains("__CTB_OWNER_JSON__"))
        XCTAssertFalse(script.contains("__CTB_BINDING_JSON__"))
    }

    func testRealBrowserBindingPayloadMapsThreadIdToSwiftProperty() throws {
        let payload = Data(#"{"id":"swift-1","owner":"swift","threadId":"019f5a7c-1234-7abc-8def-0123456789ab","title":"真实会话"}"#.utf8)

        let request = try JSONDecoder().decode(CodexThreadDeleteBindingRequest.self, from: payload)

        XCTAssertEqual(request.id, "swift-1")
        XCTAssertEqual(request.owner, "swift")
        XCTAssertEqual(request.threadID, "019f5a7c-1234-7abc-8def-0123456789ab")
        XCTAssertEqual(request.title, "真实会话")
    }

    func testDeleteCommandUsesOfficialForceArgumentsWithoutShell() throws {
        let threadID = "019f5a7c-1234-7abc-8def-0123456789ab"
        try CodexThreadID.validate(threadID)

        XCTAssertEqual(
            FoundationCodexThreadDeleteExecutor.commandArguments(threadID: threadID),
            ["delete", "--force", threadID]
        )
        XCTAssertThrowsError(try CodexThreadID.validate("\(threadID); rm -rf /"))
    }

    func testResolveExpressionEscapesUntrustedRequestText() throws {
        let expression = try CodexThreadDeleteInjectionScript.resolveExpression(
            owner: "swift",
            requestID: "id\" ); window.bad = true; //",
            result: CodexThreadDeleteBindingResult(
                status: "failed",
                message: "错误 \"quoted\""
            )
        )

        XCTAssertTrue(expression.contains("window.__codexTokenBarThreadDeleteResolve"))
        XCTAssertTrue(expression.contains("\\\""))
        XCTAssertFalse(expression.contains("id\" ); window.bad"))
    }

    func testHealthExpressionEscapesOwnerAndBindingName() throws {
        let expression = try CodexThreadDeleteInjectionScript.healthExpression(
            owner: "swift\" ); window.bad = true; //",
            bindingName: "binding\"name"
        )

        XCTAssertTrue(expression.hasPrefix("window.__codexTokenBarThreadDeleteHealth("))
        XCTAssertTrue(expression.contains("\\\""))
        XCTAssertFalse(expression.contains("swift\" ); window.bad"))
    }

    func testHealthVerificationDistinguishesReadyWaitingAndStructuralFailure() throws {
        XCTAssertEqual(
            try CodexThreadDeleteInjectionVerification.verify(health(
                candidateRows: 3,
                eligibleRows: 3,
                attachedRows: 3,
                buttons: 3,
                readiness: "ready"
            )),
            .ready(buttonCount: 3)
        )
        XCTAssertEqual(
            try CodexThreadDeleteInjectionVerification.verify(health(
                candidateRows: 0,
                eligibleRows: 0,
                attachedRows: 0,
                buttons: 0,
                readiness: "waitingForRows"
            )),
            .waitingForRows
        )

        XCTAssertThrowsError(try CodexThreadDeleteInjectionVerification.verify(health(
            candidateRows: 3,
            eligibleRows: 3,
            attachedRows: 0,
            buttons: 0,
            missingButtons: 3,
            readiness: "failed"
        )))
        XCTAssertThrowsError(try CodexThreadDeleteInjectionVerification.verify(health(
            candidateRows: 1,
            eligibleRows: 0,
            attachedRows: 0,
            buttons: 0,
            readiness: "waitingForRows"
        )))
        XCTAssertThrowsError(try CodexThreadDeleteInjectionVerification.verify(health(
            candidateRows: 2,
            eligibleRows: 1,
            attachedRows: 1,
            buttons: 1,
            readiness: "ready"
        )))
    }

    func testNativeHealthVerificationRejectsContradictoryScriptReadiness() {
        XCTAssertThrowsError(try CodexThreadDeleteInjectionVerification.verify(health(
            candidateRows: 3,
            eligibleRows: 3,
            attachedRows: 2,
            buttons: 2,
            missingButtons: 1,
            readiness: "ready"
        )))
        XCTAssertThrowsError(try CodexThreadDeleteInjectionVerification.verify(health(
            candidateRows: 2,
            eligibleRows: 2,
            attachedRows: 2,
            buttons: 3,
            duplicateButtons: 1,
            readiness: "ready"
        )))
    }

    func testCDPCommandErrorsAndEvaluateExceptionsAreNotReportedAsConnected() throws {
        let commandError = try JSONDecoder().decode(
            CodexThreadDeleteCDPCommandResponse.self,
            from: Data(#"{"id":101,"error":{"code":-32601,"message":"Method not found"}}"#.utf8)
        )
        XCTAssertThrowsError(try commandError.validated(method: "Runtime.addBinding")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Runtime.addBinding"))
            XCTAssertTrue(error.localizedDescription.contains("Method not found"))
        }

        let exception = try JSONDecoder().decode(
            CodexThreadDeleteCDPCommandResponse.self,
            from: Data(#"{"id":102,"result":{"result":{"type":"undefined"},"exceptionDetails":{"text":"Uncaught","exception":{"description":"ReferenceError: bad selector"}}}}"#.utf8)
        )
        XCTAssertThrowsError(try exception.validated(method: "Runtime.evaluate")) { error in
            XCTAssertTrue(error.localizedDescription.contains("ReferenceError: bad selector"))
        }

        let emptyResponse = try JSONDecoder().decode(
            CodexThreadDeleteCDPCommandResponse.self,
            from: Data(#"{"id":103}"#.utf8)
        )
        XCTAssertThrowsError(try emptyResponse.validated(method: "Runtime.enable")) { error in
            XCTAssertTrue(error.localizedDescription.contains("无效回执"))
        }
    }

    func testRealRuntimeEvaluateHealthResponseDecodesAndVerifies() throws {
        let data = Data(#"{"id":104,"result":{"result":{"type":"object","value":{"schemaVersion":2,"owner":"swift","bridgeRegistered":true,"bindingMatches":true,"bindingAvailable":true,"deleteEnabled":true,"sessionEnhancementsInstalled":true,"sessionEnhancementError":null,"candidateRowCount":2,"eligibleRowCount":2,"attachedRowCount":2,"buttonCount":2,"missingButtonCount":0,"duplicateButtonCount":0,"orphanButtonCount":0,"styleInstalled":true,"observerInstalled":true,"scanError":null,"readiness":"ready"}}}}"#.utf8)
        let response = try JSONDecoder().decode(
            CodexThreadDeleteCDPCommandResponse.self,
            from: data
        )

        XCTAssertEqual(
            try CodexThreadDeleteInjectionVerification.verify(
                response.validated(method: "Runtime.evaluate").decodedHealth()
            ),
            .ready(buttonCount: 2)
        )
    }

    @MainActor
    func testCodexPlusPlusProcessesAreReportedAsLaunchConflicts() {
        let snapshots = [
            CodexThreadDeleteRunningApplicationSnapshot(
                bundleIdentifier: "com.bigpizzav3.codexplusplus",
                localizedName: "Codex++",
                processIdentifier: 10,
                bundlePath: "/Applications/Codex++.app",
                terminated: false
            ),
            CodexThreadDeleteRunningApplicationSnapshot(
                bundleIdentifier: "com.bigpizzav3.codexplusplus.manager",
                localizedName: "Codex++ 管理工具",
                processIdentifier: 11,
                bundlePath: "/Applications/Codex++ 管理工具.app",
                terminated: false
            ),
            CodexThreadDeleteRunningApplicationSnapshot(
                bundleIdentifier: "com.bigpizzav3.codexplusplus",
                localizedName: "Codex++",
                processIdentifier: 12,
                bundlePath: "/Applications/Codex++.app",
                terminated: true
            ),
        ]

        XCTAssertEqual(
            CodexThreadDeleteDesktopLauncher.conflictingApplicationNames(in: snapshots),
            ["Codex++", "Codex++ 管理工具"]
        )
    }

    @MainActor
    func testCodexLaunchPathRejectsDifferentRunningCopies() throws {
        let oneCopy = CodexThreadDeleteRunningApplicationSnapshot(
            bundleIdentifier: "com.openai.codex",
            localizedName: "Codex",
            processIdentifier: 20,
            bundlePath: "/Applications/ChatGPT.app",
            terminated: false
        )
        XCTAssertEqual(
            try CodexThreadDeleteDesktopLauncher.selectedApplicationPath(
                running: [oneCopy],
                registeredPath: "/Applications/Other Codex.app"
            ),
            "/Applications/ChatGPT.app"
        )

        let secondCopy = CodexThreadDeleteRunningApplicationSnapshot(
            bundleIdentifier: "com.openai.codex",
            localizedName: "Codex Copy",
            processIdentifier: 21,
            bundlePath: "/Applications/Other Codex.app",
            terminated: false
        )
        XCTAssertThrowsError(try CodexThreadDeleteDesktopLauncher.selectedApplicationPath(
            running: [oneCopy, secondCopy],
            registeredPath: "/Applications/ChatGPT.app"
        ))

        let missingIdentity = CodexThreadDeleteRunningApplicationSnapshot(
            bundleIdentifier: "com.openai.codex",
            localizedName: "Codex",
            processIdentifier: 22,
            bundlePath: nil,
            terminated: false
        )
        XCTAssertThrowsError(try CodexThreadDeleteDesktopLauncher.selectedApplicationPath(
            running: [missingIdentity],
            registeredPath: "/Applications/ChatGPT.app"
        ))
    }

    func testTransportCorrelatesOutOfOrderResponsesAndKeepsBindingEvents() async throws {
        let socket = TestThreadDeleteWebSocket()
        let transport = CodexThreadDeleteCDPTransport(socket: socket)
        await transport.start()

        async let first = transport.request(
            method: "Runtime.first",
            params: TestCDPParameters(value: 1),
            timeout: .seconds(1)
        )
        async let second = transport.request(
            method: "Runtime.second",
            params: TestCDPParameters(value: 2),
            timeout: .seconds(1)
        )
        let requests = try await socket.waitForRequests(count: 2)
        let firstID = try XCTUnwrap(requests.first(where: { $0.method == "Runtime.first" })?.id)
        let secondID = try XCTUnwrap(requests.first(where: { $0.method == "Runtime.second" })?.id)

        await socket.enqueue(#"{"id":\#(secondID),"result":{}}"#)
        let payload = #"{"id":"swift-event","owner":"swift","threadId":"019f5a7c-1234-7abc-8def-0123456789ab","title":"事件"}"#
        let eventData = try JSONSerialization.data(withJSONObject: [
            "method": "Runtime.bindingCalled",
            "params": [
                "name": "codexTokenBarDeleteSwift",
                "payload": payload,
                "executionContextId": 77,
            ],
        ])
        await socket.enqueue(String(decoding: eventData, as: UTF8.self))
        await socket.enqueue(#"{"id":\#(firstID),"result":{}}"#)

        let firstResponse = try await first
        let secondResponse = try await second
        XCTAssertEqual(firstResponse.id, firstID)
        XCTAssertEqual(secondResponse.id, secondID)
        var iterator = await transport.bindingEvents().makeAsyncIterator()
        let event = try await iterator.next()
        XCTAssertEqual(event?.name, "codexTokenBarDeleteSwift")
        XCTAssertEqual(event?.executionContextID, 77)
        XCTAssertEqual(event?.payload, payload)
        await transport.close()
    }

    func testTransportCancellationIgnoresLateResponseAndAllowsNextRequest() async throws {
        let socket = TestThreadDeleteWebSocket()
        let transport = CodexThreadDeleteCDPTransport(socket: socket)
        await transport.start()

        let cancelled = Task {
            try await transport.request(
                method: "Runtime.cancelled",
                params: TestCDPParameters(value: 1),
                timeout: .seconds(1)
            )
        }
        let firstRequest = try await socket.waitForRequests(count: 1)[0]
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("cancelled request unexpectedly succeeded")
        } catch is CancellationError {
            // Expected.
        }
        await socket.enqueue(#"{"id":\#(firstRequest.id),"result":{}}"#)

        let next = Task {
            try await transport.request(
                method: "Runtime.next",
                params: TestCDPParameters(value: 2),
                timeout: .seconds(1)
            )
        }
        let requests = try await socket.waitForRequests(count: 2)
        let nextID = try XCTUnwrap(requests.first(where: { $0.method == "Runtime.next" })?.id)
        await socket.enqueue(#"{"id":\#(nextID),"result":{}}"#)
        let nextResponse = try await next.value
        XCTAssertEqual(nextResponse.id, nextID)
        await transport.close()
    }

    func testTransportTimeoutClosesAndFailsPendingRequests() async throws {
        let socket = TestThreadDeleteWebSocket()
        let transport = CodexThreadDeleteCDPTransport(socket: socket)
        await transport.start()

        let request = Task {
            try await transport.request(
                method: "Runtime.neverReplies",
                params: TestCDPParameters(value: 1),
                timeout: .milliseconds(300)
            )
        }
        let companion = Task {
            try await transport.request(
                method: "Runtime.alsoPending",
                params: TestCDPParameters(value: 2),
                timeout: .seconds(2)
            )
        }
        _ = try await socket.waitForRequests(count: 2)
        do {
            _ = try await request.value
            XCTFail("timed out request unexpectedly succeeded")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("回执超时"))
        }
        do {
            _ = try await companion.value
            XCTFail("companion pending request unexpectedly succeeded")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("回执超时"))
        }

        do {
            _ = try await transport.request(
                method: "Runtime.afterTimeout",
                params: TestCDPParameters(value: 2),
                timeout: .seconds(1)
            )
            XCTFail("closed transport unexpectedly accepted a request")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("已关闭"))
        }
    }

    func testDebugPortProbeOnlyTreatsConnectionRefusedAsUnavailable() {
        XCTAssertTrue(CodexThreadDeleteDebugPortErrorClassifier.meansNoListener(
            URLError(.cannotConnectToHost)
        ))
        XCTAssertFalse(CodexThreadDeleteDebugPortErrorClassifier.meansNoListener(
            URLError(.timedOut)
        ))
        XCTAssertFalse(CodexThreadDeleteDebugPortErrorClassifier.meansNoListener(
            URLError(.badServerResponse)
        ))
        XCTAssertFalse(CodexThreadDeleteDebugPortErrorClassifier.meansNoListener(
            URLError(.networkConnectionLost)
        ))
    }

    func testOnlyLoopbackWebSocketsAreAccepted() {
        XCTAssertTrue(CodexThreadDeleteInjectionScript.isLoopback(URL(string: "ws://127.0.0.1:9229/devtools/page/1")!))
        XCTAssertTrue(CodexThreadDeleteInjectionScript.isLoopback(URL(string: "ws://[::1]:9229/devtools/page/1")!))
        XCTAssertFalse(CodexThreadDeleteInjectionScript.isLoopback(URL(string: "ws://192.168.1.10:9229/devtools/page/1")!))
        XCTAssertFalse(CodexThreadDeleteInjectionScript.isLoopback(URL(string: "wss://example.com/devtools/page/1")!))
    }

    func testWebSocketHandshakeOmitsChromiumRejectedOriginHeader() {
        let target = CodexThreadDeleteTarget(
            port: 9229,
            webSocketURL: URL(string: "ws://127.0.0.1:9229/devtools/page/1")!
        )

        let request = CodexThreadDeleteWebSocketRequest.make(for: target)

        XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
        XCTAssertEqual(request.url, target.webSocketURL)
    }

    private func health(
        candidateRows: Int,
        eligibleRows: Int,
        attachedRows: Int,
        buttons: Int,
        missingButtons: Int = 0,
        duplicateButtons: Int = 0,
        orphanButtons: Int = 0,
        readiness: String,
        bindingAvailable: Bool = true,
        scanError: String? = nil
    ) -> CodexThreadDeleteInjectionHealth {
        CodexThreadDeleteInjectionHealth(
            schemaVersion: 2,
            owner: "swift",
            bridgeRegistered: true,
            bindingMatches: true,
            bindingAvailable: bindingAvailable,
            deleteEnabled: true,
            sessionEnhancementsInstalled: true,
            sessionEnhancementError: nil,
            candidateRowCount: candidateRows,
            eligibleRowCount: eligibleRows,
            attachedRowCount: attachedRows,
            buttonCount: buttons,
            missingButtonCount: missingButtons,
            duplicateButtonCount: duplicateButtons,
            orphanButtonCount: orphanButtons,
            styleInstalled: true,
            observerInstalled: true,
            scanError: scanError,
            readiness: readiness
        )
    }
}

private struct TestCDPParameters: Encodable, Sendable {
    let value: Int
}

private struct TestCDPRequestHeader: Decodable, Equatable, Sendable {
    let id: Int
    let method: String
}

private enum TestThreadDeleteWebSocketError: Error {
    case requestTimeout
}

private actor TestThreadDeleteWebSocketState {
    private var sentTexts: [String] = []
    private var queuedTexts: [String] = []
    private var receivers: [CheckedContinuation<String, Error>] = []
    private var closed = false

    func record(_ text: String) throws {
        guard !closed else { throw CancellationError() }
        sentTexts.append(text)
    }

    func receive() async throws -> String {
        if !queuedTexts.isEmpty {
            return queuedTexts.removeFirst()
        }
        guard !closed else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in
            receivers.append(continuation)
        }
    }

    func enqueue(_ text: String) {
        guard !closed else { return }
        if receivers.isEmpty {
            queuedTexts.append(text)
        } else {
            receivers.removeFirst().resume(returning: text)
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        let pending = receivers
        receivers.removeAll()
        for receiver in pending {
            receiver.resume(throwing: CancellationError())
        }
    }

    func sentRequests() throws -> [TestCDPRequestHeader] {
        try sentTexts.map { text in
            try JSONDecoder().decode(TestCDPRequestHeader.self, from: Data(text.utf8))
        }
    }
}

private final class TestThreadDeleteWebSocket: CodexThreadDeleteWebSocket, @unchecked Sendable {
    private let state = TestThreadDeleteWebSocketState()

    func resume() {}

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        switch message {
        case let .string(text):
            try await state.record(text)
        case let .data(data):
            try await state.record(String(decoding: data, as: UTF8.self))
        @unknown default:
            return
        }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        .string(try await state.receive())
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task {
            await state.close()
        }
    }

    func enqueue(_ text: String) async {
        await state.enqueue(text)
    }

    func waitForRequests(count: Int) async throws -> [TestCDPRequestHeader] {
        for _ in 0..<100 {
            let requests = try await state.sentRequests()
            if requests.count >= count {
                return requests
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for \(count) CDP requests")
        throw TestThreadDeleteWebSocketError.requestTimeout
    }
}
