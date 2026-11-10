import XCTest
@testable import CodexTokenBar

private final class QuotaProbeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    func read() -> Int { lock.withLock { value } }
}

final class MultiClientQuotaAutodiscoveryTests: XCTestCase {
    @MainActor
    func testCLIAPIModeRemainsVisibleBesideIndependentDesktopQuotaWithoutTranscriptOptIn() async throws {
        let root = try temporaryDirectory()
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = MultiClientUsageStore(defaults: defaults, databaseURL: root.appendingPathComponent("usage.sqlite"),
            quotaReader: { .init(state: "api", capturedAt: nil, fiveHour: nil, sevenDay: nil) },
            desktopQuotaReader: { .init(state: "available", capturedAt: Date(), fiveHour: .init(usedPercent: 13, resetsAt: nil), sevenDay: nil) },
            antigravityQuotaReader: { AntigravityLocalQuota.empty() })
        store.refreshLocalQuotaCaches()
        for _ in 0..<100 where store.claudeDesktopQuota.state != "available" { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(Set(store.displayClientIDs).isSuperset(of: ["claudeCode", "claudeDesktop"]))
        XCTAssertFalse(store.preferences.contains { $0.enabled })
        let readings = store.localQuotaReadings
        XCTAssertEqual(readings.first { $0.client == "claudeCode" }?.state, "api")
        XCTAssertTrue(readings.first { $0.client == "claudeCode" }?.windows.isEmpty == true)
        XCTAssertEqual(readings.first { $0.client == "claudeDesktop" }?.windows.first?.usedPercent, 13)
    }
    @MainActor
    func testDesktopQuotaRemainsIndependentFromCLIAndTranscriptOptIn() async throws {
        let root = try temporaryDirectory()
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let available = ClaudeLocalQuota(state: "available", capturedAt: Date(), fiveHour: .init(usedPercent: 13, resetsAt: nil), sevenDay: .init(usedPercent: 29, resetsAt: nil))
        let calls = QuotaProbeCounter()
        let databaseURL = root.appendingPathComponent("unopenable.sqlite")
        try FileManager.default.createDirectory(at: databaseURL, withIntermediateDirectories: true)
        let store = MultiClientUsageStore(defaults: defaults, databaseURL: databaseURL, quotaReader: { .missing }, desktopQuotaReader: {
            calls.increment(); return available
        })
        store.refreshLocalQuotaCaches(); store.refreshLocalQuotaCaches(); store.refresh()
        for _ in 0..<100 where store.claudeDesktopQuota.state != "available" || store.refreshing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.claudeQuota.state, "missing")
        XCTAssertEqual(store.quotaReading(.claudeDesktop).windows.first?.usedPercent, 13)
        XCTAssertTrue(store.quotaReading(.claudeCode).windows.isEmpty)
        XCTAssertTrue(store.displayClientIDs.contains("claudeDesktop")); XCTAssertFalse(store.displayClientIDs.contains("claudeCode"))
        XCTAssertFalse(store.preferences.contains { $0.enabled }); XCTAssertEqual(calls.read(), 1)
        XCTAssertFalse(store.diagnostics.isEmpty)
    }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("multi-client-quota-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func isolatedDefaults() -> (UserDefaults, String) {
        let name = "multi-client-quota-" + UUID().uuidString
        return (UserDefaults(suiteName: name)!, name)
    }

    @MainActor
    func testQuotaProbeRunsWithTranscriptOptInOffEvenWhenUsageStoreFails() async throws {
        let root = try temporaryDirectory()
        let (defaults, defaultsName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let databaseURL = root.appendingPathComponent("unopenable.sqlite")
        try FileManager.default.createDirectory(at: databaseURL, withIntermediateDirectories: true)
        let available = ClaudeLocalQuota(state: "available", capturedAt: Date(),
            fiveHour: .init(usedPercent: 25, resetsAt: Date().addingTimeInterval(3600)), sevenDay: nil)
        let calls = QuotaProbeCounter()
        let store = MultiClientUsageStore(defaults: defaults, databaseURL: databaseURL, quotaReader: {
            calls.increment()
            return available
        }, desktopQuotaReader: { .missing })

        XCTAssertFalse(store.preferences.contains { $0.enabled })
        XCTAssertFalse(store.displayClientIDs.contains(UsageClient.claudeCode.rawValue))
        XCTAssertFalse(store.availablePreferences.contains { $0.client == .claudeCode })
        store.refreshLocalQuotaCaches()
        store.refreshLocalQuotaCaches()
        store.refresh()
        for _ in 0..<100 where store.claudeQuota.state != "available" || store.refreshing {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(store.claudeQuota, available)
        XCTAssertFalse(store.preferences.contains { $0.enabled }, "quota probing must not opt into transcript collection")
        XCTAssertTrue(store.displayClientIDs.contains(UsageClient.claudeCode.rawValue))
        XCTAssertTrue(store.availablePreferences.contains { $0.client == .claudeCode })
        XCTAssertFalse(store.diagnostics.isEmpty, "fixture should exercise the failing usage-store path")
        XCTAssertEqual(calls.read(), 1, "rapid requests share one bounded cache probe")
    }

    @MainActor
    func testTranscriptIngestionContinuesWhenQuotaCacheHasNoUsableReading() async throws {
        let root = try temporaryDirectory()
        let (defaults, defaultsName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let transcript = root.appendingPathComponent("session.jsonl")
        let line = #"{"type":"assistant","sessionId":"s","timestamp":"2026-10-25T03:00:00Z","message":{"id":"m1","role":"assistant","model":"claude-test","usage":{"input_tokens":100,"output_tokens":20}}}"#
        try Data((line + "\n").utf8).write(to: transcript)
        var preference = MultiClientUsagePreference.defaults[0]
        preference.enabled = true
        preference.path = transcript.path
        defaults.set(try JSONEncoder().encode([preference]), forKey: MultiClientUsageStore.preferencesKey)
        let store = MultiClientUsageStore(defaults: defaults, databaseURL: root.appendingPathComponent("usage.sqlite"), quotaReader: { .missing }, desktopQuotaReader: { .missing })

        store.refreshLocalQuotaCaches()
        store.refresh()
        for _ in 0..<100 where store.total(.claudeCode) == 0 || store.refreshing {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(store.claudeQuota.state, "missing")
        XCTAssertEqual(store.total(.claudeCode), 120)
        XCTAssertEqual(store.summaries.first?.requests, 1)
    }
}
