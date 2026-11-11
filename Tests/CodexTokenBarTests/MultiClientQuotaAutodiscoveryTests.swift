import XCTest
@testable import CodexTokenBar

private final class QuotaProbeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    func read() -> Int { lock.withLock { value } }
}

private final class LocalQuotaTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    func set(_ value: TimeInterval) { lock.withLock { time = value } }
    func read() -> TimeInterval { lock.withLock { time } }
}

@MainActor
private final class LocalQuotaTestTimer: AccountQuotaTimerToken {
    let interval: TimeInterval
    let handler: @MainActor @Sendable () -> Void
    var invalidated = false
    init(interval: TimeInterval, handler: @escaping @MainActor @Sendable () -> Void) {
        self.interval = interval; self.handler = handler
    }
    func invalidate() { invalidated = true }
    func fire() { if !invalidated { handler() } }
}

@MainActor
private final class LocalQuotaTestScheduler: AccountQuotaTimerScheduling {
    var timers: [LocalQuotaTestTimer] = []
    func scheduleRepeatingTimer(interval: TimeInterval, handler: @escaping @MainActor @Sendable () -> Void) -> any AccountQuotaTimerToken {
        let timer = LocalQuotaTestTimer(interval: interval, handler: handler)
        timers.append(timer); return timer
    }
}

final class MultiClientQuotaAutodiscoveryTests: XCTestCase {
    @MainActor
    func testLocalQuotaFollowsMainPageCadenceReschedulesAndAllowsManualRefresh() async throws {
        let root = try temporaryDirectory()
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("300", forKey: AccountQuotaRefreshCadence.storageKey)
        defaults.set(false, forKey: "liveRateMonitoringEnabled")
        let scheduler = LocalQuotaTestScheduler(), clock = LocalQuotaTestClock(), calls = QuotaProbeCounter()
        let store = MultiClientUsageStore(defaults: defaults, databaseURL: root.appendingPathComponent("usage.sqlite"),
            quotaReader: { calls.increment(); return .init(state: "available", capturedAt: nil, fiveHour: .init(usedPercent: Double(calls.read()), resetsAt: nil), sevenDay: nil) }, desktopQuotaReader: { .missing },
            antigravityQuotaReader: { AntigravityLocalQuota.empty() }, quotaTimerScheduler: scheduler,
            quotaProbeUptime: { clock.read() })
        defer { store.stop() }
        store.start()
        for _ in 0..<200 where store.claudeQuota.fiveHour?.usedPercent != 1 || store.refreshing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(calls.read(), 1)
        XCTAssertEqual(scheduler.timers.map(\.interval), [300])

        defaults.set("30", forKey: AccountQuotaRefreshCadence.storageKey)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        for _ in 0..<100 where scheduler.timers.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(scheduler.timers.map(\.interval), [300, 30])
        XCTAssertTrue(scheduler.timers.first?.invalidated == true)
        clock.set(29); store.refreshLocalQuotaCaches()
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(calls.read(), 1)
        clock.set(29.999); scheduler.timers.last?.fire()
        for _ in 0..<100 where store.claudeQuota.fiveHour?.usedPercent != 2 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(calls.read(), 2, "Neither the old 60-second cache nor timer jitter may swallow the 30-second tick")

        defaults.set("600", forKey: AccountQuotaRefreshCadence.storageKey)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        for _ in 0..<100 where scheduler.timers.count < 3 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(scheduler.timers.last?.interval, 600)
        clock.set(90); store.refreshLocalQuotaCaches()
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(calls.read(), 2, "Usage refreshes must not shorten a selected ten-minute quota interval")
        clock.set(630); scheduler.timers.last?.fire()
        for _ in 0..<100 where store.claudeQuota.fiveHour?.usedPercent != 3 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(calls.read(), 3)
        store.refreshLocalQuotaCaches(force: true)
        for _ in 0..<100 where store.claudeQuota.fiveHour?.usedPercent != 4 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(calls.read(), 4, "Manual refresh only bypasses local cache reuse")
        let timerCount = scheduler.timers.count
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(scheduler.timers.count, timerCount, "Unrelated settings must not restart the quota clock")
        store.stop()
        XCTAssertTrue(scheduler.timers.allSatisfy(\.invalidated))
    }
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
