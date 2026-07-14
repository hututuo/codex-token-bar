import Foundation
import XCTest
@testable import CodexTokenBar

final class CodexThreadDeleteBridgeTests: XCTestCase {
    @MainActor
    func testMissingDebugPortOffersLoopbackOnlyCodexRelaunch() {
        XCTAssertTrue(CodexThreadDeleteBridgeStatus.idle.requiresCodexRelaunch)
        XCTAssertEqual(
            CodexThreadDeleteBridgeStatus.idle.connectionActionTitle,
            "重启 Codex 并启用删除按钮"
        )
        XCTAssertEqual(CodexThreadDeleteBridgeStatus.idle.dashboardActionTitle, "启用会话删除")
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
        XCTAssertEqual(interrupted.connectionActionTitle, "重新连接 Codex 删除按钮")
        XCTAssertEqual(interrupted.dashboardActionTitle, "重连会话删除")

        let connected = CodexThreadDeleteBridgeStatus(
            connected: true,
            debugPort: 9229,
            message: "Codex 会话删除按钮已连接"
        )
        XCTAssertEqual(connected.dashboardActionTitle, "会话删除已启用")
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

    func testOnlyLoopbackWebSocketsAreAccepted() {
        XCTAssertTrue(CodexThreadDeleteInjectionScript.isLoopback(URL(string: "ws://127.0.0.1:9229/devtools/page/1")!))
        XCTAssertTrue(CodexThreadDeleteInjectionScript.isLoopback(URL(string: "ws://[::1]:9229/devtools/page/1")!))
        XCTAssertFalse(CodexThreadDeleteInjectionScript.isLoopback(URL(string: "ws://192.168.1.10:9229/devtools/page/1")!))
        XCTAssertFalse(CodexThreadDeleteInjectionScript.isLoopback(URL(string: "wss://example.com/devtools/page/1")!))
    }
}
