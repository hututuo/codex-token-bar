import Testing
@testable import AgentSpeedCore

@Suite("Dashboard source listing")
struct SourceListingTests {
    static func source(enabled: Bool = true, available: Bool = true, requests: Int = 0, output: Int = 0,
                       live: Double = 0) -> SourceStatus {
        SourceStatus(kind: .codex, enabled: enabled, rootPath: "/codex", available: available, sessionCount: 3,
                     live: Rate(output: live, total: live * 2),
                     today: TokenTotals(requests: requests, input: output * 4, output: output), activeAgents: 0)
    }

    @Test("A detected source without output today is not listed")
    func idleSourcesAreHidden() {
        #expect(!Self.source().producedToday)
        #expect(!Self.source(requests: 2).producedToday)
    }

    @Test("Output today lists the source, enabled or not")
    func outputTodayIsListed() {
        #expect(Self.source(requests: 1, output: 120).producedToday)
        #expect(Self.source(enabled: false, requests: 1, output: 120).producedToday)
        #expect(Self.source(available: false, requests: 1, output: 120).producedToday)
    }

    @Test("A first response still in flight lists the source")
    func liveOutputIsListed() {
        #expect(Self.source(live: 42).producedToday)
    }
}
