import Foundation
import Testing
@testable import AgentSpeedCore

@Suite("Update schedule")
struct UpdateScheduleTests {
    static let launch = Date(timeIntervalSince1970: 1_800_000_000)
    static let hour: TimeInterval = 60 * 60

    static func next(lastSuccess: Date? = nil, lastAttempt: Date? = nil, now: Date = launch) -> Date {
        UpdateSchedule.nextCheck(launchedAt: launch, lastSuccess: lastSuccess, lastAttempt: lastAttempt, now: now)
    }

    @Test func constantsFollowTheSpec() {
        #expect(UpdateSchedule.launchDelay == 30)
        #expect(UpdateSchedule.interval == 6 * Self.hour)
    }

    @Test func firstLaunchChecksAfterThirtySeconds() {
        let due = Self.next()
        #expect(due == Self.launch.addingTimeInterval(30))
        #expect(UpdateSchedule.delay(until: due, now: Self.launch) == 30)
    }

    @Test func recentSuccessWaitsForTheRestOfTheInterval() {
        let success = Self.launch.addingTimeInterval(-1 * Self.hour)
        let due = Self.next(lastSuccess: success)
        #expect(due == Self.launch.addingTimeInterval(5 * Self.hour))
        #expect(UpdateSchedule.delay(until: due, now: Self.launch) == 5 * Self.hour)
    }

    @Test(arguments: [6 * hour, 6 * hour + 1, 7 * hour, 30 * 24 * hour])
    func oldSuccessChecksSoonAfterLaunch(age: TimeInterval) {
        #expect(Self.next(lastSuccess: Self.launch.addingTimeInterval(-age)) == Self.launch.addingTimeInterval(30))
    }

    @Test func successJustUnderSixHoursAgoNeverChecksBeforeTheLaunchDelay() {
        let almost = Self.launch.addingTimeInterval(-6 * Self.hour + 10)
        #expect(Self.next(lastSuccess: almost) == Self.launch.addingTimeInterval(30))
        let closer = Self.launch.addingTimeInterval(-6 * Self.hour + 60)
        #expect(Self.next(lastSuccess: closer) == Self.launch.addingTimeInterval(60))
    }

    @Test func failedAttemptThisRunRetriesAfterTheInterval() {
        let attempt = Self.launch.addingTimeInterval(30)
        let now = attempt.addingTimeInterval(2)
        let due = Self.next(lastSuccess: nil, lastAttempt: attempt, now: now)
        #expect(due == attempt.addingTimeInterval(6 * Self.hour))
        #expect(UpdateSchedule.delay(until: due, now: now) == 6 * Self.hour - 2)
    }

    @Test func laterOfSuccessAndAttemptWins() {
        let success = Self.launch.addingTimeInterval(30)
        let attempt = success.addingTimeInterval(6 * Self.hour)
        let now = attempt.addingTimeInterval(1)
        #expect(Self.next(lastSuccess: success, lastAttempt: attempt, now: now) == attempt.addingTimeInterval(6 * Self.hour))
        #expect(Self.next(lastSuccess: attempt, lastAttempt: success, now: now) == attempt.addingTimeInterval(6 * Self.hour))
    }

    @Test func periodicChecksEverySixHoursWhileRunning() {
        var now = Self.launch
        var lastSuccess: Date?
        var checks: [Date] = []
        for _ in 0..<4 {
            let due = Self.next(lastSuccess: lastSuccess, now: now)
            now = now.addingTimeInterval(UpdateSchedule.delay(until: due, now: now))
            checks.append(now)
            lastSuccess = now
        }
        #expect(checks == [0, 1, 2, 3].map { Self.launch.addingTimeInterval(30 + TimeInterval($0) * 6 * Self.hour) })
    }

    @Test func overdueCheckRunsImmediately() {
        let now = Self.launch.addingTimeInterval(2 * 24 * Self.hour)
        let success = now.addingTimeInterval(-6 * Self.hour - 60)
        let due = Self.next(lastSuccess: success, now: now)
        #expect(due < now)
        #expect(UpdateSchedule.delay(until: due, now: now) == 0)
    }

    @Test func futureTimestampsCountAsNow() {
        let now = Self.launch.addingTimeInterval(10)
        let future = now.addingTimeInterval(3 * 24 * Self.hour)
        #expect(Self.next(lastSuccess: future, now: now) == now.addingTimeInterval(6 * Self.hour))
        #expect(Self.next(lastAttempt: future, now: now) == now.addingTimeInterval(6 * Self.hour))
        #expect(Self.next(lastSuccess: future, lastAttempt: future, now: now) == now.addingTimeInterval(6 * Self.hour))
        let due = Self.next(lastSuccess: .distantFuture, now: now)
        #expect(UpdateSchedule.delay(until: due, now: now) == 6 * Self.hour)
    }

    @Test(arguments: [-1_000_000.0, -1, -0.001, 0, 0.5, 30, 21_600])
    func delayIsNeverNegative(offset: TimeInterval) {
        let now = Self.launch
        let delay = UpdateSchedule.delay(until: now.addingTimeInterval(offset), now: now)
        #expect(delay >= 0)
        #expect(delay == max(0, offset))
    }

    @Test func delayUntilDistantPastIsZero() {
        #expect(UpdateSchedule.delay(until: .distantPast, now: Self.launch) == 0)
    }

    @Test(arguments: [
        ("1.2.0", true), ("v1.2.0", true), ("0.0.1", true), ("0.1.0", true), ("1.2.0-rc.1", true), ("1.2.0+42", true),
        ("0.0.0", false), ("v0.0.0", false), ("0.0.0-dev", false), ("0.0.0+local", false),
        ("", false), ("dev", false), ("1.2", false), ("1.2.0.0", false), ("unknown", false),
    ])
    func automaticChecksSkipDevelopmentAndUnparseableBuilds(version: String, expected: Bool) {
        #expect(UpdateSchedule.checksAutomatically(currentVersion: version) == expected)
    }
}

@Suite("Update decision")
struct UpdateDecisionTests {
    static func release(_ tag: String) throws -> Release {
        Release(tag: tag, version: try #require(SemanticVersion(tag)))
    }

    @Test(arguments: [
        ("1.0.0", "v1.1.0", UpdateOffer.available),
        ("1.0.9", "v1.0.10", UpdateOffer.available),
        ("v1.1.0-rc.1", "v1.1.0", UpdateOffer.available),
        ("0.0.0", "v0.1.0", UpdateOffer.available),
        ("1.1.0", "v1.1.0", UpdateOffer.upToDate),
        ("v1.1.0", "1.1.0", UpdateOffer.upToDate),
        ("1.1.0+5", "v1.1.0", UpdateOffer.upToDate),
        ("1.2.0", "v1.1.0", UpdateOffer.upToDate),
        ("2.0.0", "v1.9.9", UpdateOffer.upToDate),
        ("garbage", "v9.0.0", UpdateOffer.upToDate),
        ("", "v9.0.0", UpdateOffer.upToDate),
        ("1.0", "v9.0.0", UpdateOffer.upToDate),
    ])
    func comparesVersions(current: String, latest: String, expected: UpdateOffer) throws {
        let release = try Self.release(latest)
        for manual in [false, true] {
            #expect(UpdateDecision.evaluate(currentVersion: current, latest: release, skippedTag: nil, manual: manual) == expected)
        }
    }

    @Test func skippedVersionIsHiddenOnlyFromAutomaticChecks() throws {
        let release = try Self.release("v1.2.0")
        #expect(UpdateDecision.evaluate(currentVersion: "1.1.0", latest: release, skippedTag: "v1.2.0", manual: false) == .skipped)
        #expect(UpdateDecision.evaluate(currentVersion: "1.1.0", latest: release, skippedTag: "v1.2.0", manual: true) == .available)
    }

    @Test(arguments: ["v1.1.5", "v1.3.0", "1.2.0", "V1.2.0", ""])
    func otherSkippedTagsDoNotHideTheRelease(skipped: String) throws {
        let release = try Self.release("v1.2.0")
        #expect(UpdateDecision.evaluate(currentVersion: "1.1.0", latest: release, skippedTag: skipped, manual: false) == .available)
    }

    @Test func skippingDoesNotMatterWhenAlreadyUpToDate() throws {
        let release = try Self.release("v1.2.0")
        for manual in [false, true] {
            #expect(UpdateDecision.evaluate(currentVersion: "1.2.0", latest: release, skippedTag: "v1.2.0", manual: manual) == .upToDate)
            #expect(UpdateDecision.evaluate(currentVersion: "1.3.0", latest: release, skippedTag: "v1.2.0", manual: manual) == .upToDate)
        }
    }

    @Test func newerReleaseAfterASkippedOneIsOfferedAgain() throws {
        let release = try Self.release("v1.3.0")
        #expect(UpdateDecision.evaluate(currentVersion: "1.1.0", latest: release, skippedTag: "v1.2.0", manual: false) == .available)
    }
}
