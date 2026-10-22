import Foundation
import XCTest
@testable import CodexTokenBar

final class PersistentQuotaLiveProbeTests: XCTestCase {
    func testInstalledCodexCanReadQuotaAndCardsTwiceThroughOneOwnedProcess() throws {
        guard ProcessInfo.processInfo.environment["TOKENBAR_LIVE_QUOTA_AUDIT"] == "1" else {
            throw XCTSkip("Opt-in read-only live Codex quota check")
        }
        let transport = CountingLiveQuotaTransport()
        let service = PersistentQuotaService(transport: transport, cacheDuration: 0)
        defer { service.shutdown() }
        let first = try service.read(dataSource: nil).get()
        let second = try service.read(dataSource: nil).get()
        XCTAssertTrue(first.isAvailable)
        XCTAssertTrue(second.isAvailable)
        XCTAssertNotNil(first.resetCreditsAvailableCount)
        XCTAssertNotNil(second.resetCreditsAvailableCount)
        XCTAssertEqual(transport.starts, 1)
    }
}

private final class CountingLiveQuotaTransport: AccountQuotaProcessTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let underlying = FoundationAccountQuotaProcessTransport(launchLeasePool: AccountQuotaProcessLaunchLeasePool())
    var starts: Int { lock.withLock { count } }
    func start(codexPath: String, dataSource: CodexDataSource?) throws -> any AccountQuotaProcessSession {
        lock.withLock { count += 1 }
        return try underlying.start(codexPath: codexPath, dataSource: dataSource)
    }
}
