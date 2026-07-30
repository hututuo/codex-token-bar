import Foundation
import XCTest
@testable import CodexTokenBar

final class AutoResumeAutoApprovalPolicyTests: XCTestCase {
    func testSafeCurrentTurnCommandIsApprovedOnce() {
        let result = AutoResumeAutoApprovalPolicy.evaluate(
            method: "item/commandExecution/requestApproval",
            params: [
                "threadId": "thread-a",
                "turnId": "turn-a",
                "itemId": "item-a",
                "command": "npm run build",
                "availableDecisions": ["accept", "decline"],
            ],
            targetThreadID: "thread-a",
            boundTurnID: "turn-a",
            turnStartPending: true
        )

        XCTAssertEqual(
            result,
            .approve(decision: "accept", requestedTurnID: "turn-a")
        )
    }

    func testApprovalCanBindTheTurnAfterStartWasSent() {
        let result = AutoResumeAutoApprovalPolicy.evaluate(
            method: "item/fileChange/requestApproval",
            params: [
                "threadId": "thread-a",
                "turnId": "turn-from-request",
                "itemId": "item-file-a",
            ],
            targetThreadID: "thread-a",
            boundTurnID: nil,
            turnStartPending: true
        )

        XCTAssertEqual(
            result,
            .approve(decision: "accept", requestedTurnID: "turn-from-request")
        )
    }

    func testWrongThreadOrTurnFailsClosed() {
        let wrongThread = AutoResumeAutoApprovalPolicy.evaluate(
            method: "item/commandExecution/requestApproval",
            params: [
                "threadId": "thread-b",
                "turnId": "turn-a",
                "itemId": "item-wrong-thread",
                "command": "swift test",
            ],
            targetThreadID: "thread-a",
            boundTurnID: "turn-a",
            turnStartPending: true
        )
        let wrongTurn = AutoResumeAutoApprovalPolicy.evaluate(
            method: "item/fileChange/requestApproval",
            params: [
                "threadId": "thread-a",
                "turnId": "turn-b",
                "itemId": "item-wrong-turn",
            ],
            targetThreadID: "thread-a",
            boundTurnID: "turn-a",
            turnStartPending: true
        )

        assertRejected(wrongThread, decision: "decline")
        assertRejected(wrongTurn, decision: "decline")
    }

    func testDestructiveAndPermissionExpandingCommandsAreRejected() {
        let destructive = AutoResumeAutoApprovalPolicy.evaluate(
            method: "item/commandExecution/requestApproval",
            params: [
                "threadId": "thread-a",
                "turnId": "turn-a",
                "itemId": "item-destructive",
                "command": "sudo /bin/rm -rf /tmp/project",
            ],
            targetThreadID: "thread-a",
            boundTurnID: "turn-a",
            turnStartPending: true
        )
        let expanded = AutoResumeAutoApprovalPolicy.evaluate(
            method: "item/commandExecution/requestApproval",
            params: [
                "threadId": "thread-a",
                "turnId": "turn-a",
                "itemId": "item-expanded",
                "command": "cargo test",
                "additionalPermissions": ["filesystem": ["read": ["/"]]],
            ],
            targetThreadID: "thread-a",
            boundTurnID: "turn-a",
            turnStartPending: true
        )

        assertRejected(destructive, decision: "decline")
        assertRejected(expanded, decision: "decline")
    }

    func testLegacyRequestsUseLegacyDecisionsAndExactConversation() {
        let safe = AutoResumeAutoApprovalPolicy.evaluate(
            method: "execCommandApproval",
            params: [
                "conversationId": "thread-a",
                "callId": "call-safe",
                "command": ["git", "status", "--short"],
                "parsedCmd": [["type": "unknown", "cmd": "git status --short"]],
            ],
            targetThreadID: "thread-a",
            boundTurnID: nil,
            turnStartPending: true
        )
        let destructive = AutoResumeAutoApprovalPolicy.evaluate(
            method: "execCommandApproval",
            params: [
                "conversationId": "thread-a",
                "callId": "call-destructive",
                "command": ["git", "reset", "--hard"],
            ],
            targetThreadID: "thread-a",
            boundTurnID: "turn-a",
            turnStartPending: true
        )

        XCTAssertEqual(safe, .approve(decision: "approved", requestedTurnID: nil))
        assertRejected(destructive, decision: "denied")
    }

    func testPersistentPermissionAmendmentsAndMissingRequestIdentityFailClosed() {
        let grantRoot = AutoResumeAutoApprovalPolicy.evaluate(
            method: "item/fileChange/requestApproval",
            params: [
                "threadId": "thread-a",
                "turnId": "turn-a",
                "itemId": "item-file-grant",
                "grantRoot": "/private/tmp/shared",
            ],
            targetThreadID: "thread-a",
            boundTurnID: "turn-a",
            turnStartPending: true
        )
        let policyAmendment = AutoResumeAutoApprovalPolicy.evaluate(
            method: "item/commandExecution/requestApproval",
            params: [
                "threadId": "thread-a",
                "turnId": "turn-a",
                "itemId": "item-policy",
                "command": "npm test",
                "proposedExecpolicyAmendment": ["prefix:npm"],
            ],
            targetThreadID: "thread-a",
            boundTurnID: "turn-a",
            turnStartPending: true
        )
        let missingIdentity = AutoResumeAutoApprovalPolicy.evaluate(
            method: "item/commandExecution/requestApproval",
            params: [
                "threadId": "thread-a",
                "turnId": "turn-a",
                "command": "npm test",
            ],
            targetThreadID: "thread-a",
            boundTurnID: "turn-a",
            turnStartPending: true
        )

        assertRejected(grantRoot, decision: "decline")
        assertRejected(policyAmendment, decision: "decline")
        assertRejected(missingIdentity, decision: "decline")
    }

    func testDestructiveClassifierCoversCrossPlatformHighRiskCommands() {
        let blocked = [
            "rm --recursive --force ./build",
            "powershell Remove-Item C:\\work -Recurse -Force",
            "cmd /c rd /s /q C:\\work",
            "diskutil eraseDisk APFS Empty disk4",
            "dd if=/dev/zero of=/dev/disk4",
            "powershell Clear-Disk -Number 3 -RemoveData",
            "format C:\\",
            "git clean -fdx",
            "git push --force origin main",
            "psql -c 'DROP DATABASE production'",
            "find . -delete",
        ]
        for command in blocked {
            XCTAssertNotNil(
                AutoResumeAutoApprovalPolicy.destructiveReason(in: command),
                command
            )
        }
        XCTAssertNil(
            AutoResumeAutoApprovalPolicy.destructiveReason(
                in: "rm -f .build/debug.log && git push --force-with-lease"
            )
        )
    }

    func testConfigurationDefaultsAutoApprovalOffAndRoundTripsExplicitOptIn() throws {
        let legacy = try JSONDecoder().decode(
            AutoResumeConfiguration.self,
            from: Data("{}".utf8)
        )
        XCTAssertFalse(legacy.autoApprovalEnabled)

        var enabled = AutoResumeConfiguration.default
        enabled.autoApprovalEnabled = true
        let roundTrip = try JSONDecoder().decode(
            AutoResumeConfiguration.self,
            from: JSONEncoder().encode(enabled)
        )
        XCTAssertTrue(roundTrip.autoApprovalEnabled)
    }

    private func assertRejected(
        _ evaluation: AutoResumeApprovalEvaluation,
        decision: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .reject(let actualDecision, let reason) = evaluation else {
            return XCTFail("Expected rejection, got \(evaluation)", file: file, line: line)
        }
        XCTAssertEqual(actualDecision, decision, file: file, line: line)
        XCTAssertFalse(reason.isEmpty, file: file, line: line)
    }
}
