import Darwin
import Foundation
import XCTest
@testable import CodexTokenBar

final class SessionManagementPresentationTests: XCTestCase {
    func testOnlyNotLoadedStatusPermitsOfficialMutation() {
        XCTAssertTrue(SessionManagementThreadStatus.notLoaded.permitsMutation)
        for status in SessionManagementThreadStatus.allCases where status != .notLoaded {
            XCTAssertFalse(status.permitsMutation, "\(status) must remain fail-closed")
        }
    }

    func testProgressiveDisclosureHasNoTotalCapAndKeepsSelectionVisible() {
        let threads = (0..<250).map {
            makeSessionManagementThread(
                id: String(format: "thread-%03d", $0),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(1_000 - $0))
            )
        }

        let first = SessionManagementPresentation.visibleThreads(
            threads,
            limit: 100,
            selectedThreadID: "thread-249"
        )
        XCTAssertEqual(first.count, 100)
        XCTAssertTrue(first.contains { $0.id == "thread-249" })
        XCTAssertEqual(Set(first.map(\.id)).count, first.count)

        let second = SessionManagementPresentation.visibleThreads(
            threads,
            limit: 200,
            selectedThreadID: nil
        )
        XCTAssertEqual(second.count, 200)

        let all = SessionManagementPresentation.visibleThreads(
            threads,
            limit: 300,
            selectedThreadID: nil
        )
        XCTAssertEqual(all.count, 250)
    }

    func testUnknownByteCountsRemainUnknownInsteadOfBecomingZero() {
        XCTAssertNil(SessionManagementCatalog.empty().totalBytes)

        let known = makeSessionManagementThread(
            id: "known",
            cwd: "/tmp/project",
            fileBytes: 512
        )
        let unknown = makeSessionManagementThread(
            id: "unknown",
            cwd: "/tmp/project",
            fileBytes: nil
        )
        let project = SessionManagementPresentation.projects(from: [known, unknown]).first

        XCTAssertNil(project?.totalBytes)

        let catalog = SessionManagementCatalog(
            threads: [known, unknown],
            generatedAt: Date(),
            codexHome: "/tmp/codex",
            totalBytes: nil,
            warnings: [],
            capabilities: .readOnly
        )
        let sorted = SessionManagementPresentation.filteredThreads(
            in: catalog,
            collection: .all,
            projectID: nil,
            query: "",
            sort: .size
        )
        XCTAssertEqual(sorted.map(\.id), ["known", "unknown"])
        XCTAssertNil(sorted.last?.fileBytes)
    }

    func testDeletionImpactUsesMinimalSpawnRootsAndKeepsForksExternal() {
        let child = makeSessionManagementThread(
            id: "child",
            fileBytes: nil,
            parentThreadID: "root",
            isSubagent: true
        )
        let root = makeSessionManagementThread(id: "root", fileBytes: 10)
        let grandchild = makeSessionManagementThread(
            id: "grandchild",
            fileBytes: 30,
            parentThreadID: "child",
            isSubagent: true
        )
        let externalFork = makeSessionManagementThread(
            id: "external-fork",
            fileBytes: 40,
            forkedFromID: "child"
        )

        // Put the redundant child before its selected ancestor to verify that
        // root minimization is independent of catalog order.
        let impact = SessionManagementPresentation.deletionImpact(
            threads: [child, root, grandchild, externalFork],
            selectedThreadIDs: ["root", "child"]
        )

        XCTAssertEqual(impact.requested.map(\.id), ["child", "root"])
        XCTAssertEqual(impact.effectiveRoots.map(\.id), ["root"])
        XCTAssertEqual(impact.affected.map(\.id), ["root", "child", "grandchild"])
        XCTAssertEqual(impact.indirectDescendants.map(\.id), ["grandchild"])
        XCTAssertEqual(impact.externalForkReferences.map(\.id), ["external-fork"])
        XCTAssertNil(impact.totalBytes)
        XCTAssertEqual(
            impact.coveringRootIDByThreadID,
            [
                "root": "root",
                "child": "root",
                "grandchild": "root",
            ]
        )
    }

    func testAllIncludesArchivedMainAndRecentUsesSevenDayBoundary() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let active = makeSessionManagementThread(
            id: "active",
            updatedAt: now.addingTimeInterval(-8 * 24 * 60 * 60)
        )
        var archived = makeSessionManagementThread(
            id: "archived",
            updatedAt: now.addingTimeInterval(-24 * 60 * 60)
        )
        archived.archived = true
        let unknown = makeSessionManagementThread(id: "unknown", updatedAt: nil)
        let catalog = SessionManagementCatalog(
            threads: [active, archived, unknown],
            generatedAt: now,
            codexHome: "/tmp/codex",
            totalBytes: nil,
            warnings: [],
            capabilities: .readOnly
        )

        XCTAssertEqual(
            Set(SessionManagementPresentation.filteredThreads(
                in: catalog,
                collection: .all,
                projectID: nil,
                query: "",
                sort: .recent,
                now: now
            ).map(\.id)),
            ["active", "archived", "unknown"]
        )
        XCTAssertEqual(
            SessionManagementPresentation.filteredThreads(
                in: catalog,
                collection: .recent,
                projectID: nil,
                query: "",
                sort: .recent,
                now: now
            ).map(\.id),
            ["archived"]
        )
    }

    func testForksAndSubagentsRemainSeparateCollections() {
        var source = makeSessionManagementThread(id: "root", fileBytes: 10)
        source.forkChildCount = 1
        let fork = makeSessionManagementThread(
            id: "fork",
            forkedFromID: "root"
        )
        let subagent = makeSessionManagementThread(
            id: "subagent",
            parentThreadID: "root",
            isSubagent: true
        )
        let catalog = SessionManagementCatalog(
            threads: [source, fork, subagent],
            generatedAt: Date(),
            codexHome: "/tmp/codex",
            totalBytes: nil,
            warnings: [],
            capabilities: .readOnly
        )

        XCTAssertEqual(
            SessionManagementPresentation.filteredThreads(
                in: catalog,
                collection: .forks,
                projectID: nil,
                query: "",
                sort: .recent
            ).map(\.id),
            ["fork"]
        )
        XCTAssertEqual(
            SessionManagementPresentation.filteredThreads(
                in: catalog,
                collection: .subagents,
                projectID: nil,
                query: "",
                sort: .recent
            ).map(\.id),
            ["subagent"]
        )
    }

    func testLayoutSwitchesBeforeThreePaneMinimumWouldClip() {
        XCTAssertTrue(SessionManagementLayout.usesCompactLayout(width: 919))
        XCTAssertFalse(SessionManagementLayout.usesCompactLayout(width: 920))
    }

    func testCatalogLoadingBlocksContentButKeepsCloseAvailable() {
        XCTAssertTrue(
            SessionManagementInteractionPolicy.blocksContent(
                isLoadingCatalog: true
            )
        )
        XCTAssertFalse(
            SessionManagementInteractionPolicy.blocksContent(
                isLoadingCatalog: false
            )
        )
        XCTAssertTrue(
            SessionManagementInteractionPolicy.closeIsEnabled(
                isLoadingCatalog: true,
                isPerformingMutation: false
            )
        )
        XCTAssertFalse(
            SessionManagementInteractionPolicy.closeIsEnabled(
                isLoadingCatalog: false,
                isPerformingMutation: true
            )
        )
    }

    func testInactivityFilterSupportsDayMonthAndCustomThresholds() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 3,
                    day: 31,
                    hour: 12
                )
            )
        )
        func date(year: Int, month: Int, day: Int) throws -> Date {
            try XCTUnwrap(
                calendar.date(
                    from: DateComponents(
                        year: year,
                        month: month,
                        day: day,
                        hour: 12
                    )
                )
            )
        }
        let catalog = SessionManagementCatalog(
            threads: [
                makeSessionManagementThread(
                    id: "four-days",
                    updatedAt: try date(year: 2026, month: 3, day: 27)
                ),
                makeSessionManagementThread(
                    id: "six-days",
                    updatedAt: try date(year: 2026, month: 3, day: 25)
                ),
                makeSessionManagementThread(
                    id: "thirty-days",
                    updatedAt: try date(year: 2026, month: 3, day: 1)
                ),
                makeSessionManagementThread(
                    id: "one-month",
                    updatedAt: try date(year: 2026, month: 2, day: 28)
                ),
                makeSessionManagementThread(
                    id: "three-months",
                    updatedAt: try date(year: 2025, month: 12, day: 31)
                ),
                makeSessionManagementThread(id: "unknown", updatedAt: nil),
            ],
            generatedAt: now,
            codexHome: "/tmp/codex",
            totalBytes: nil,
            warnings: [],
            capabilities: .readOnly
        )
        func ids(
            _ filter: SessionManagementInactivityFilter,
            customDays: Int? = nil
        ) -> Set<String> {
            Set(
                SessionManagementPresentation.filteredThreads(
                    in: catalog,
                    collection: .all,
                    projectID: nil,
                    query: "",
                    sort: .recent,
                    inactivityFilter: filter,
                    customInactiveDays: customDays,
                    calendar: calendar,
                    now: now
                ).map(\.id)
            )
        }

        XCTAssertEqual(
            ids(.fiveDays),
            ["six-days", "thirty-days", "one-month", "three-months"]
        )
        XCTAssertEqual(
            ids(.tenDays),
            ["thirty-days", "one-month", "three-months"]
        )
        XCTAssertEqual(
            ids(.thirtyDays),
            ["thirty-days", "one-month", "three-months"]
        )
        XCTAssertEqual(ids(.oneMonth), ["one-month", "three-months"])
        XCTAssertEqual(ids(.threeMonths), ["three-months"])
        XCTAssertEqual(
            ids(.custom, customDays: 10),
            ["thirty-days", "one-month", "three-months"]
        )
        XCTAssertTrue(ids(.custom, customDays: nil).isEmpty)
        XCTAssertTrue(ids(.custom, customDays: 0).isEmpty)
        XCTAssertTrue(ids(.any).contains("unknown"))
    }

    func testInactivityFilterComposesWithEverySmartCollection() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let recent = now.addingTimeInterval(-2 * 24 * 60 * 60)
        let inactive = now.addingTimeInterval(-40 * 24 * 60 * 60)

        let archivedRecent = makeSessionManagementThread(
            id: "archived-recent",
            updatedAt: recent,
            archived: true
        )
        let archivedInactive = makeSessionManagementThread(
            id: "archived-inactive",
            updatedAt: inactive,
            archived: true
        )
        var similarRecent = makeSessionManagementThread(
            id: "similar-recent",
            updatedAt: recent
        )
        similarRecent.similarityGroupID = "recent-group"
        var similarInactive = makeSessionManagementThread(
            id: "similar-inactive",
            updatedAt: inactive
        )
        similarInactive.similarityGroupID = "inactive-group"

        let catalog = SessionManagementCatalog(
            threads: [
                makeSessionManagementThread(id: "normal-recent", updatedAt: recent),
                makeSessionManagementThread(id: "normal-inactive", updatedAt: inactive),
                archivedRecent,
                archivedInactive,
                makeSessionManagementThread(
                    id: "large-recent",
                    updatedAt: recent,
                    fileBytes: SessionManagementPresentation.largeThreadThreshold
                ),
                makeSessionManagementThread(
                    id: "large-inactive",
                    updatedAt: inactive,
                    fileBytes: SessionManagementPresentation.largeThreadThreshold
                ),
                makeSessionManagementThread(
                    id: "fork-recent",
                    updatedAt: recent,
                    forkedFromID: "root"
                ),
                makeSessionManagementThread(
                    id: "fork-inactive",
                    updatedAt: inactive,
                    forkedFromID: "root"
                ),
                similarRecent,
                similarInactive,
                makeSessionManagementThread(
                    id: "subagent-recent",
                    updatedAt: recent,
                    parentThreadID: "root",
                    isSubagent: true
                ),
                makeSessionManagementThread(
                    id: "subagent-inactive",
                    updatedAt: inactive,
                    parentThreadID: "root",
                    isSubagent: true
                ),
            ],
            generatedAt: now,
            codexHome: "/tmp/codex",
            totalBytes: nil,
            warnings: [],
            capabilities: .readOnly
        )
        func ids(_ collection: SessionManagementCollection) -> Set<String> {
            Set(
                SessionManagementPresentation.filteredThreads(
                    in: catalog,
                    collection: collection,
                    projectID: nil,
                    query: "",
                    sort: .recent,
                    inactivityFilter: .thirtyDays,
                    now: now
                ).map(\.id)
            )
        }

        XCTAssertEqual(
            ids(.all),
            [
                "normal-inactive",
                "archived-inactive",
                "large-inactive",
                "fork-inactive",
                "similar-inactive",
            ]
        )
        XCTAssertTrue(ids(.recent).isEmpty)
        XCTAssertEqual(ids(.officialArchive), ["archived-inactive"])
        XCTAssertEqual(ids(.large), ["large-inactive"])
        XCTAssertEqual(ids(.forks), ["fork-inactive"])
        XCTAssertEqual(ids(.similar), ["similar-inactive"])
        XCTAssertEqual(ids(.subagents), ["subagent-inactive"])
    }

    func testSessionManagementNavigationIsAForwardAndBackDrillDown() {
        XCTAssertNil(SessionManagementNavigationStage.projects.previous)
        XCTAssertEqual(SessionManagementNavigationStage.sessions.previous, .projects)
        XCTAssertEqual(SessionManagementNavigationStage.details.previous, .sessions)
        XCTAssertEqual(
            SessionManagementNavigationStage.allCases,
            [.projects, .sessions, .details]
        )
    }

    func testSelectionDoesNotDependOnDangerousMutationEligibility() {
        var protected = makeSessionManagementThread(id: "protected")
        protected.status = .active
        protected.protectionReasons = ["自动续跑保护"]
        protected.canArchive = false
        protected.canUnarchive = false
        protected.canDelete = false

        XCTAssertTrue(SessionManagementSelectionPolicy.canSelect(protected))

        let malformed = makeSessionManagementThread(id: "  ")
        XCTAssertFalse(SessionManagementSelectionPolicy.canSelect(malformed))
    }
}

@MainActor
final class SessionManagementStoreLoadingTests: XCTestCase {
    func testCustomInactiveDayInputAcceptsOnlyPositiveIntegers() {
        let store = SessionManagementStore(dataSource: nil)

        store.customInactiveDaysText = " 12 "
        XCTAssertEqual(store.customInactiveDays, 12)
        XCTAssertTrue(store.isCustomInactiveDaysValid)

        store.inactivityFilter = .custom
        store.customInactiveDaysText = "0"
        XCTAssertNil(store.customInactiveDays)
        XCTAssertFalse(store.isCustomInactiveDaysValid)

        store.customInactiveDaysText = "not-a-number"
        XCTAssertNil(store.customInactiveDays)
        XCTAssertFalse(store.isCustomInactiveDaysValid)
    }

    func testSupersededRefreshCannotUnlockNewCatalogLoad() async {
        let service = GatedSessionManagementService()
        let dataSource = makeBatchDeletionDataSource("refresh-generation")
        let store = SessionManagementStore(
            dataSource: dataSource,
            service: service
        )

        let firstRefresh = store.refresh()
        let firstLoadStarted = await service.waitForLoadCount(1)
        guard firstLoadStarted else {
            XCTFail("The first catalog load never started")
            return
        }
        XCTAssertTrue(store.isLoadingCatalog)

        let secondRefresh = store.refresh()
        let secondLoadStarted = await service.waitForLoadCount(2)
        guard secondLoadStarted else {
            XCTFail("The replacement catalog load never started")
            return
        }
        XCTAssertTrue(store.isLoadingCatalog)

        await service.completeLoad(
            at: 0,
            with: .empty(codexHome: dataSource.displayPath)
        )
        await firstRefresh?.value
        XCTAssertTrue(
            store.isLoadingCatalog,
            "A cancelled older refresh must not unlock a newer load"
        )

        let now = Date()
        let newest = SessionManagementCatalog(
            threads: [
                makeSessionManagementThread(
                    id: "recent",
                    updatedAt: now.addingTimeInterval(-24 * 60 * 60)
                ),
                makeSessionManagementThread(
                    id: "inactive",
                    updatedAt: now.addingTimeInterval(-40 * 24 * 60 * 60)
                ),
            ],
            generatedAt: now,
            codexHome: dataSource.displayPath,
            totalBytes: 2,
            warnings: [],
            capabilities: .readOnly
        )
        await service.completeLoad(at: 1, with: newest)
        await secondRefresh?.value

        XCTAssertFalse(store.isLoadingCatalog)
        XCTAssertEqual(store.catalog.threads.map(\.id), ["recent", "inactive"])
        XCTAssertEqual(store.selectedThreadID, "recent")

        store.inactivityFilter = .thirtyDays
        XCTAssertEqual(store.matchingThreads.map(\.id), ["inactive"])
        XCTAssertEqual(
            store.selectedThreadID,
            "inactive",
            "Changing the inactivity filter must not leave excluded details selected"
        )

        store.inactivityFilter = .custom
        store.customInactiveDaysText = "invalid"
        XCTAssertTrue(store.matchingThreads.isEmpty)
        XCTAssertNil(store.selectedThreadID)
        XCTAssertTrue(store.contextMessages.isEmpty)

        let loadCount = await service.loadCount()
        XCTAssertEqual(
            loadCount,
            2,
            "Changing local filters must not rescan the session catalog"
        )
    }

    func testRefreshReconcilesSelectionAgainstActiveInactivityFilter() async {
        let service = GatedSessionManagementService()
        let dataSource = makeBatchDeletionDataSource("refresh-filter-selection")
        let store = SessionManagementStore(dataSource: dataSource, service: service)
        let now = Date()

        let initialRefresh = store.refresh()
        guard await service.waitForLoadCount(1) else {
            XCTFail("The initial catalog load never started")
            return
        }
        await service.completeLoad(
            at: 0,
            with: SessionManagementCatalog(
                threads: [
                    makeSessionManagementThread(
                        id: "selected",
                        updatedAt: now.addingTimeInterval(-35 * 24 * 60 * 60)
                    ),
                    makeSessionManagementThread(
                        id: "fallback",
                        updatedAt: now.addingTimeInterval(-40 * 24 * 60 * 60)
                    ),
                ],
                generatedAt: now,
                codexHome: dataSource.displayPath,
                totalBytes: 2,
                warnings: [],
                capabilities: .readOnly
            )
        )
        await initialRefresh?.value
        store.inactivityFilter = .thirtyDays
        XCTAssertEqual(store.selectedThreadID, "selected")

        let replacementRefresh = store.refresh()
        guard await service.waitForLoadCount(2) else {
            XCTFail("The replacement catalog load never started")
            return
        }
        await service.completeLoad(
            at: 1,
            with: SessionManagementCatalog(
                threads: [
                    makeSessionManagementThread(
                        id: "selected",
                        updatedAt: now.addingTimeInterval(-24 * 60 * 60)
                    ),
                    makeSessionManagementThread(
                        id: "fallback",
                        updatedAt: now.addingTimeInterval(-40 * 24 * 60 * 60)
                    ),
                ],
                generatedAt: now,
                codexHome: dataSource.displayPath,
                totalBytes: 2,
                warnings: [],
                capabilities: .readOnly
            )
        )
        await replacementRefresh?.value

        XCTAssertEqual(store.matchingThreads.map(\.id), ["fallback"])
        XCTAssertEqual(
            store.selectedThreadID,
            "fallback",
            "Refreshing must not leave details selected for a row excluded by the active filter"
        )
    }

    func testSupersededContextLoadCannotUnlockOrReplaceNewSelection() async {
        let service = GatedSessionManagementService()
        let dataSource = makeBatchDeletionDataSource("context-generation")
        let store = SessionManagementStore(dataSource: dataSource, service: service)
        let catalogRefresh = store.refresh()
        guard await service.waitForLoadCount(1) else {
            XCTFail("The catalog load never started")
            return
        }
        let catalog = SessionManagementCatalog(
            threads: [
                makeSessionManagementThread(id: "first"),
                makeSessionManagementThread(id: "second"),
            ],
            generatedAt: Date(),
            codexHome: dataSource.displayPath,
            totalBytes: 2,
            warnings: [],
            capabilities: .readOnly
        )
        await service.completeLoad(at: 0, with: catalog)
        await catalogRefresh?.value
        guard await service.waitForContextLoadCount(1) else {
            XCTFail("The automatically selected context load never started")
            return
        }

        let baselineTask = store.loadInitialContext()
        guard await service.waitForContextLoadCount(2) else {
            XCTFail("The baseline context load never started")
            return
        }
        await service.completeContextLoad(
            at: 1,
            with: makeContextPage(threadID: "first", text: "baseline")
        )
        await baselineTask?.value
        XCTAssertFalse(store.isLoadingContext)
        XCTAssertEqual(store.contextMessages.map(\.text), ["baseline"])

        let supersededTask = store.loadInitialContext()
        guard await service.waitForContextLoadCount(3) else {
            XCTFail("The superseded context load never started")
            return
        }
        let currentTask = store.selectThread("second")
        guard await service.waitForContextLoadCount(4) else {
            XCTFail("The replacement context load never started")
            return
        }
        XCTAssertTrue(store.isLoadingContext)

        await service.completeContextLoad(
            at: 2,
            with: makeContextPage(threadID: "first", text: "stale")
        )
        await supersededTask?.value
        XCTAssertTrue(
            store.isLoadingContext,
            "A cancelled older context load must not hide the replacement spinner"
        )
        XCTAssertTrue(store.contextMessages.isEmpty)

        await service.completeContextLoad(
            at: 3,
            with: makeContextPage(threadID: "second", text: "current")
        )
        await currentTask?.value
        XCTAssertFalse(store.isLoadingContext)
        XCTAssertEqual(store.selectedThreadID, "second")
        XCTAssertEqual(store.contextMessages.map(\.text), ["current"])

        await service.completeContextLoad(
            at: 0,
            with: makeContextPage(threadID: "first", text: "obsolete-auto-load")
        )
    }

}

final class SessionManagementBatchDeletionTests: XCTestCase {
    func testBatchDeletionStopsAfterFirstFailureAndReportsOnlyStrictlyProvenPartialSuccess() async {
        let threads = ["thread-a", "thread-b", "thread-c"].map {
            makeSessionManagementThread(id: $0)
        }
        let service = SessionManagementBatchDeletionServiceMock(
            threads: threads,
            failingThreadIDs: ["thread-b"]
        )
        let dataSource = makeBatchDeletionDataSource("batch-fixture")
        let confirmation = makeBatchDeletionConfirmation(
            threads: threads,
            selectedThreadIDs: Set(threads.map(\.id)),
            dataSource: dataSource
        )

        let result = await SessionManagementBatchDeletion.run(
            confirmation: confirmation,
            service: service,
            dataSource: dataSource
        )

        XCTAssertEqual(result.succeededThreadIDs, ["thread-a"])
        XCTAssertEqual(
            Set(result.failures.map(\.threadID)),
            ["thread-b", "thread-c"]
        )
        let deletedThreadIDs = await service.deletedThreadIDs()
        XCTAssertEqual(
            deletedThreadIDs,
            ["thread-a", "thread-b"]
        )
        let events = await service.events()
        XCTAssertEqual(
            events,
            [
                "package:thread-a",
                "package:thread-b",
                "package:thread-c",
                "delete:thread-a",
                "delete:thread-b",
            ]
        )
    }

    func testRecoveryFailureForImplicitDescendantPreventsEveryDelete() async {
        let root = makeSessionManagementThread(id: "root", archived: true)
        let child = makeSessionManagementThread(
            id: "child",
            archived: true,
            parentThreadID: "root",
            isSubagent: true
        )
        let service = SessionManagementBatchDeletionServiceMock(
            threads: [root, child],
            failingRecoveryThreadIDs: ["child"]
        )
        let dataSource = makeBatchDeletionDataSource("recovery-failure")
        let confirmation = makeBatchDeletionConfirmation(
            threads: [root, child],
            selectedThreadIDs: [root.id],
            dataSource: dataSource
        )

        let result = await SessionManagementBatchDeletion.run(
            confirmation: confirmation,
            service: service,
            dataSource: dataSource
        )

        XCTAssertTrue(result.succeededThreadIDs.isEmpty)
        XCTAssertEqual(result.failures.map(\.threadID), ["root"])
        let recoveryThreadIDs = await service.recoveryThreadIDs()
        let deletedThreadIDs = await service.deletedThreadIDs()
        XCTAssertEqual(recoveryThreadIDs, ["root", "child"])
        XCTAssertTrue(deletedThreadIDs.isEmpty)
        XCTAssertEqual(result.affectedCount, 2)
        XCTAssertEqual(result.indirectDescendantCount, 1)
    }

    func testAllAffectedPackagesCompleteBeforeDeletingOnlyMinimalRoot() async {
        let root = makeSessionManagementThread(id: "root", archived: true)
        let child = makeSessionManagementThread(
            id: "child",
            archived: true,
            parentThreadID: "root",
            isSubagent: true
        )
        let grandchild = makeSessionManagementThread(
            id: "grandchild",
            archived: true,
            parentThreadID: "child",
            isSubagent: true
        )
        let service = SessionManagementBatchDeletionServiceMock(
            threads: [root, child, grandchild]
        )
        let dataSource = makeBatchDeletionDataSource("recovery-order")
        let confirmation = makeBatchDeletionConfirmation(
            threads: [root, child, grandchild],
            selectedThreadIDs: [root.id, child.id],
            dataSource: dataSource
        )

        let result = await SessionManagementBatchDeletion.run(
            confirmation: confirmation,
            service: service,
            dataSource: dataSource
        )

        let events = await service.events()
        let deletedThreadIDs = await service.deletedThreadIDs()
        XCTAssertEqual(
            events,
            [
                "package:root",
                "package:child",
                "package:grandchild",
                "delete:root",
            ]
        )
        XCTAssertEqual(deletedThreadIDs, ["root"])
        XCTAssertEqual(
            Set(result.recoveryPackageURLs.keys),
            ["root", "child", "grandchild"]
        )
        XCTAssertEqual(result.succeededThreadIDs, ["root", "child"])
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.affectedCount, 3)
        XCTAssertEqual(result.indirectDescendantCount, 1)
    }

    func testIncompleteInitialCatalogStopsBeforeRecoveryPackaging() async {
        let thread = makeSessionManagementThread(id: "thread-a")
        let service = SessionManagementBatchDeletionServiceMock(
            threads: [thread],
            incompleteCatalogLoadNumbers: [1]
        )
        let dataSource = makeBatchDeletionDataSource("incomplete-initial")
        let confirmation = makeBatchDeletionConfirmation(
            threads: [thread],
            selectedThreadIDs: [thread.id],
            dataSource: dataSource
        )

        let result = await SessionManagementBatchDeletion.run(
            confirmation: confirmation,
            service: service,
            dataSource: dataSource
        )

        XCTAssertTrue(result.succeededThreadIDs.isEmpty)
        XCTAssertEqual(result.failures.map(\.threadID), [thread.id])
        let recoveryThreadIDs = await service.recoveryThreadIDs()
        let deletedThreadIDs = await service.deletedThreadIDs()
        XCTAssertTrue(recoveryThreadIDs.isEmpty)
        XCTAssertTrue(deletedThreadIDs.isEmpty)
    }

    func testIncompleteRefreshedCatalogStopsAfterRecoveryButBeforeDelete() async {
        let thread = makeSessionManagementThread(id: "thread-a")
        let service = SessionManagementBatchDeletionServiceMock(
            threads: [thread],
            incompleteCatalogLoadNumbers: [2]
        )
        let dataSource = makeBatchDeletionDataSource("incomplete-refresh")
        let confirmation = makeBatchDeletionConfirmation(
            threads: [thread],
            selectedThreadIDs: [thread.id],
            dataSource: dataSource
        )

        let result = await SessionManagementBatchDeletion.run(
            confirmation: confirmation,
            service: service,
            dataSource: dataSource
        )

        XCTAssertTrue(result.succeededThreadIDs.isEmpty)
        let recoveryThreadIDs = await service.recoveryThreadIDs()
        let deletedThreadIDs = await service.deletedThreadIDs()
        XCTAssertEqual(recoveryThreadIDs, [thread.id])
        XCTAssertTrue(deletedThreadIDs.isEmpty)
    }

    func testIncompleteFinalCatalogCannotClaimPartialSuccess() async {
        let threads = ["thread-a", "thread-b"].map {
            makeSessionManagementThread(id: $0)
        }
        let service = SessionManagementBatchDeletionServiceMock(
            threads: threads,
            failingThreadIDs: ["thread-b"],
            incompleteCatalogLoadNumbers: [3]
        )
        let dataSource = makeBatchDeletionDataSource("incomplete-final")
        let confirmation = makeBatchDeletionConfirmation(
            threads: threads,
            selectedThreadIDs: Set(threads.map(\.id)),
            dataSource: dataSource
        )

        let result = await SessionManagementBatchDeletion.run(
            confirmation: confirmation,
            service: service,
            dataSource: dataSource
        )

        XCTAssertTrue(result.succeededThreadIDs.isEmpty)
        XCTAssertEqual(
            Set(result.failures.map(\.threadID)),
            Set(threads.map(\.id))
        )
    }

    func testSuccessfulDeleteReplyWithoutClosureDisappearanceIsNotSuccess() async {
        let thread = makeSessionManagementThread(id: "thread-a")
        let service = SessionManagementBatchDeletionServiceMock(
            threads: [thread],
            retainedSuccessfulDeleteRootIDs: [thread.id]
        )
        let dataSource = makeBatchDeletionDataSource("retained-root")
        let confirmation = makeBatchDeletionConfirmation(
            threads: [thread],
            selectedThreadIDs: [thread.id],
            dataSource: dataSource
        )

        let result = await SessionManagementBatchDeletion.run(
            confirmation: confirmation,
            service: service,
            dataSource: dataSource
        )

        XCTAssertTrue(result.succeededThreadIDs.isEmpty)
        XCTAssertEqual(result.failures.map(\.threadID), [thread.id])
        XCTAssertTrue(
            result.failures.first?.reason.contains("仍发现冻结闭包会话") == true
        )
    }
}

final class FoundationSessionManagementBackendTests: XCTestCase {
    func testCatalogMergesOfficialStateAndPreservesUnknownTokenCount() async throws {
        let fixture = try makeFixture(messageCount: 2)
        let appServer = SessionManagementAppServerMock(
            threads: [fixture.appServerThread(status: .notLoaded)]
        )
        let backend = makeBackend(appServer: appServer)

        let catalog = try await backend.loadCatalog(dataSource: fixture.dataSource)
        let thread = try XCTUnwrap(catalog.threads.first)

        XCTAssertEqual(catalog.threads.count, 1)
        XCTAssertTrue(catalog.capabilities.canOfficialMutate)
        XCTAssertEqual(thread.status, .notLoaded)
        XCTAssertTrue(thread.canArchive)
        XCTAssertFalse(thread.canUnarchive)
        XCTAssertTrue(thread.canDelete)
        XCTAssertTrue(thread.rolloutIdentityVerified)
        XCTAssertNil(thread.tokensUsed)
        XCTAssertEqual(thread.fileBytes, Int64(fixture.sourceData.count))
        XCTAssertEqual(catalog.totalBytes, Int64(fixture.sourceData.count))
    }

    func testCatalogSupplementsMissingDatabaseRowFromReadOnlyRolloutScan() async throws {
        let fixture = try makeFixture(messageCount: 1)
        let scannedID = UUID().uuidString.lowercased()
        let historyBaseID = UUID().uuidString.lowercased()
        let scannedURL = fixture.rolloutURL
            .deletingLastPathComponent()
            .appendingPathComponent("rollout-\(scannedID).jsonl")
        let scannedData = try sessionManagementJSONLine([
            "timestamp": "2026-07-30T00:00:00.000Z",
            "type": "session_meta",
            "payload": [
                "id": scannedID,
                "cwd": fixture.project.path,
                "session_id": "session-\(scannedID)",
                "history_base": ["thread_id": historyBaseID],
                "source": "cli",
            ],
        ])
        try scannedData.write(to: scannedURL, options: .atomic)
        let appServer = SessionManagementAppServerMock(
            threads: [fixture.appServerThread(status: .notLoaded)]
        )
        let backend = makeBackend(appServer: appServer)

        let catalog = try await backend.loadCatalog(dataSource: fixture.dataSource)
        let scanned = try XCTUnwrap(
            catalog.threads.first { $0.id == scannedID }
        )

        XCTAssertEqual(scanned.rolloutPath, scannedURL.path)
        XCTAssertEqual(scanned.cwd, fixture.project.path)
        XCTAssertEqual(scanned.forkedFromID, historyBaseID)
        XCTAssertEqual(scanned.status, .unknown)
        XCTAssertTrue(scanned.rolloutIdentityVerified)
        XCTAssertFalse(scanned.canDelete)
        let database = SQLiteDatabaseDriver(
            url: fixture.dataSource.stateDatabase,
            readOnly: true,
            createsFileIfMissing: false
        )
        let matchingRows = try database.readRows(
            "SELECT id FROM threads WHERE id = ?",
            bindings: [.text(scannedID)]
        ) {
            $0.text(0) ?? ""
        }
        XCTAssertTrue(matchingRows.isEmpty, "read-only supplement must not repair SQLite")
    }

    func testContextPagesBackwardWithoutDroppingZeroUsagePeriodMessages() async throws {
        let fixture = try makeFixture(messageCount: 65, appendIncompleteTail: true)
        let appServer = SessionManagementAppServerMock(
            threads: [fixture.appServerThread(status: .notLoaded)]
        )
        let backend = makeBackend(appServer: appServer)
        let catalog = try await backend.loadCatalog(dataSource: fixture.dataSource)
        let thread = try XCTUnwrap(catalog.threads.first)

        var page = try await backend.loadContextPage(
            thread: thread,
            dataSource: fixture.dataSource,
            beforeOffset: nil,
            pageSize: 30
        )
        XCTAssertEqual(page.messages.count, 30)
        XCTAssertTrue(page.hasMoreBefore)
        XCTAssertTrue(page.warnings.contains { $0.contains("尾部") })

        var allMessages = page.messages
        while page.hasMoreBefore {
            page = try await backend.loadContextPage(
                thread: thread,
                dataSource: fixture.dataSource,
                beforeOffset: try XCTUnwrap(page.nextBeforeOffset),
                pageSize: 30
            )
            allMessages = page.messages + allMessages
        }

        XCTAssertEqual(allMessages.count, 65)
        XCTAssertEqual(allMessages.first?.text, "message-0")
        XCTAssertEqual(allMessages.last?.text, "message-64")
        XCTAssertEqual(allMessages.first?.timestamp, "2026-07-30T00:00:00.000Z")
    }

    func testDeleteRequiresFreshNotLoadedStatus() async throws {
        let fixture = try makeFixture(messageCount: 1)
        let appServer = SessionManagementAppServerMock(
            threads: [fixture.appServerThread(status: .idle)],
            status: .idle
        )
        let delete = SessionManagementOfficialDeleteMock()
        let backend = makeBackend(appServer: appServer, officialDelete: delete)

        do {
            _ = try await performBoundDelete(fixture, using: backend)
            XCTFail("idle is still loaded and must not be deleted")
        } catch let error as SessionManagementBackendError {
            XCTAssertEqual(error, .mutationBlocked(.idle))
        }
        let deleteCalls = await delete.callCount()
        let statusReads = await appServer.statusReadCount()
        XCTAssertEqual(deleteCalls, 0)
        XCTAssertEqual(statusReads, 1)
    }

    func testDeleteFailsClosedWhenImplicitDescendantBecomesActive() async throws {
        let fixture = try makeFixture(messageCount: 1)
        let child = try addThread(
            to: fixture,
            parentThreadID: fixture.threadID
        )
        let appServer = SessionManagementAppServerMock(
            threads: [
                fixture.appServerThread(status: .notLoaded),
                child.appServerThread(status: .notLoaded),
            ],
            statusByThreadID: [
                fixture.threadID: .notLoaded,
                child.threadID: .active,
            ]
        )
        let delete = SessionManagementOfficialDeleteMock()
        let backend = makeBackend(appServer: appServer, officialDelete: delete)

        do {
            _ = try await performBoundDelete(fixture, using: backend)
            XCTFail("an active implicit descendant must block root deletion")
        } catch let error as SessionManagementBackendError {
            XCTAssertEqual(error, .mutationBlocked(.active))
        }

        let statusReadThreadIDs = await appServer.statusReadThreadIDs()
        let deleteCalls = await delete.callCount()
        XCTAssertEqual(
            statusReadThreadIDs,
            [fixture.threadID, child.threadID]
        )
        XCTAssertEqual(deleteCalls, 0)
    }

    func testDeleteRejectsAncestorQueryThatOmitsKnownDescendant() async throws {
        let fixture = try makeFixture(messageCount: 1)
        let child = try addThread(to: fixture, parentThreadID: fixture.threadID)
        let appServer = SessionManagementAppServerMock(
            threads: [
                fixture.appServerThread(status: .notLoaded),
                child.appServerThread(status: .notLoaded),
            ],
            descendantOverrides: [fixture.threadID: []]
        )
        let delete = SessionManagementOfficialDeleteMock()
        let backend = makeBackend(appServer: appServer, officialDelete: delete)

        do {
            _ = try await performBoundDelete(fixture, using: backend)
            XCTFail("ancestorThreadId scope mismatch must stop deletion")
        } catch let error as SessionManagementBackendError {
            guard case .deletionScopeChanged = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let deleteCalls = await delete.callCount()
        let statusReadThreadIDs = await appServer.statusReadThreadIDs()
        XCTAssertEqual(deleteCalls, 0)
        XCTAssertTrue(statusReadThreadIDs.isEmpty)
    }

    func testDeleteRejectsDuplicateOfficialRowsEvenWhenRowsAreIdentical() async throws {
        let fixture = try makeFixture(messageCount: 1)
        let row = fixture.appServerThread(status: .notLoaded)
        let appServer = SessionManagementAppServerMock(
            threads: [row, row],
            status: .notLoaded
        )
        let delete = SessionManagementOfficialDeleteMock()
        let backend = makeBackend(appServer: appServer, officialDelete: delete)

        do {
            _ = try await performBoundDelete(fixture, using: backend)
            XCTFail("duplicate official IDs must make the deletion scope ambiguous")
        } catch let error as SessionManagementBackendError {
            guard case .deletionScopeChanged = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let deleteCalls = await delete.callCount()
        let statusReads = await appServer.statusReadCount()
        XCTAssertEqual(deleteCalls, 0)
        XCTAssertEqual(statusReads, 0)
    }

    func testDeleteRejectsIncompleteLocalReadOnlyCatalog() async throws {
        let fixture = try makeFixture(messageCount: 1)
        let unsafeLink = fixture.dataSource.sessionsRoot
            .appendingPathComponent("untrusted-rollout.jsonl")
        try FileManager.default.createSymbolicLink(
            atPath: unsafeLink.path,
            withDestinationPath: "/dev/null"
        )
        let appServer = SessionManagementAppServerMock(
            threads: [fixture.appServerThread(status: .notLoaded)],
            status: .notLoaded
        )
        let delete = SessionManagementOfficialDeleteMock()
        let backend = makeBackend(appServer: appServer, officialDelete: delete)

        let catalog = try await backend.loadCatalog(dataSource: fixture.dataSource)
        XCTAssertFalse(catalog.deletionVerificationComplete)
        do {
            _ = try await performBoundDelete(fixture, using: backend)
            XCTFail("an incomplete local scan must block deletion")
        } catch let error as SessionManagementBackendError {
            guard case .deletionScopeChanged(let detail) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(detail.contains("本地只读会话目录不完整"))
        }

        let deleteCalls = await delete.callCount()
        let statusReads = await appServer.statusReadCount()
        XCTAssertEqual(deleteCalls, 0)
        XCTAssertEqual(statusReads, 0)
    }

    func testDeleteRejectsExpectationWithoutRecoveryEvidenceRequirement() async throws {
        let fixture = try makeFixture(messageCount: 1)
        let appServer = SessionManagementAppServerMock(
            threads: [fixture.appServerThread(status: .notLoaded)],
            status: .notLoaded
        )
        let delete = SessionManagementOfficialDeleteMock()
        let backend = makeBackend(appServer: appServer, officialDelete: delete)
        let catalog = try await backend.loadCatalog(dataSource: fixture.dataSource)
        let impact = SessionManagementPresentation.deletionImpact(
            threads: catalog.threads,
            selectedThreadIDs: [fixture.threadID]
        )
        let confirmation = try makeFixtureDeletionConfirmation(
            impact: impact,
            dataSource: fixture.dataSource
        )

        do {
            _ = try await backend.delete(
                rootID: fixture.threadID,
                expectation: SessionManagementDeletionExpectation(
                    confirmation: confirmation,
                    pendingRootIndex: 0,
                    requiresRecoveryEvidence: false
                ),
                recoveryPackages: [:],
                dataSource: fixture.dataSource
            )
            XCTFail("permanent delete must never disable recovery evidence")
        } catch let error as SessionManagementBackendError {
            XCTAssertEqual(
                error,
                .recoveryEvidenceMismatch(fixture.threadID)
            )
        }

        let deleteCalls = await delete.callCount()
        let statusReads = await appServer.statusReadCount()
        XCTAssertEqual(deleteCalls, 0)
        XCTAssertEqual(statusReads, 0)
    }

    func testDeleteFailsClosedWhenImplicitDescendantBecomesAutoResumeProtected() async throws {
        let fixture = try makeFixture(messageCount: 1)
        let child = try addThread(
            to: fixture,
            parentThreadID: fixture.threadID
        )
        let appServer = SessionManagementAppServerMock(
            threads: [
                fixture.appServerThread(status: .notLoaded),
                child.appServerThread(status: .notLoaded),
            ],
            statusByThreadID: [
                fixture.threadID: .notLoaded,
                child.threadID: .notLoaded,
            ]
        )
        let delete = SessionManagementOfficialDeleteMock()
        let protectedIDs = SessionManagementProtectedIDsSequence(
            responses: [
                [],
                [],
                [child.threadID],
            ]
        )
        let backend = makeBackend(
            appServer: appServer,
            officialDelete: delete,
            autoResumeProtectedThreadIDsProvider: {
                protectedIDs.next()
            }
        )

        do {
            _ = try await performBoundDelete(fixture, using: backend)
            XCTFail("a newly protected implicit descendant must block root deletion")
        } catch let error as SessionManagementBackendError {
            XCTAssertEqual(error, .autoResumeProtected(child.threadID))
        }

        let statusReadThreadIDs = await appServer.statusReadThreadIDs()
        let deleteCalls = await delete.callCount()
        XCTAssertEqual(
            statusReadThreadIDs,
            [fixture.threadID, child.threadID]
        )
        XCTAssertEqual(deleteCalls, 0)
    }

    func testDeleteFailsClosedWhenImplicitDescendantRolloutIDDoesNotMatch() async throws {
        let fixture = try makeFixture(messageCount: 1)
        let child = try addThread(
            to: fixture,
            parentThreadID: fixture.threadID,
            rolloutIdentityID: UUID().uuidString.lowercased()
        )
        let appServer = SessionManagementAppServerMock(
            threads: [
                fixture.appServerThread(status: .notLoaded),
                child.appServerThread(status: .notLoaded),
            ],
            statusByThreadID: [
                fixture.threadID: .notLoaded,
                child.threadID: .notLoaded,
            ]
        )
        let delete = SessionManagementOfficialDeleteMock()
        let backend = makeBackend(appServer: appServer, officialDelete: delete)

        do {
            _ = try await performBoundDelete(fixture, using: backend)
            XCTFail("a mismatched implicit descendant rollout must block root deletion")
        } catch let error as SessionManagementBackendError {
            guard case .deletionScopeChanged = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let statusReadThreadIDs = await appServer.statusReadThreadIDs()
        let deleteCalls = await delete.callCount()
        XCTAssertTrue(statusReadThreadIDs.isEmpty)
        XCTAssertEqual(deleteCalls, 0)
    }

    func testDeleteFailsClosedWhenCodexHomeIdentityIsReplaced() async throws {
        let fixture = try makeFixture(messageCount: 1)
        let appServer = SessionManagementAppServerMock(
            threads: [fixture.appServerThread(status: .notLoaded)],
            status: .notLoaded
        )
        let delete = SessionManagementOfficialDeleteMock()
        let backend = makeBackend(appServer: appServer, officialDelete: delete)
        let originalHome = fixture.dataSource.codexHome
        let displacedHome = originalHome
            .deletingLastPathComponent()
            .appendingPathComponent(
                "\(originalHome.lastPathComponent)-displaced-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.moveItem(at: originalHome, to: displacedHome)
        try FileManager.default.createDirectory(
            at: originalHome,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: displacedHome)
        }

        do {
            _ = try await performBoundDelete(fixture, using: backend)
            XCTFail("replacing the bound Codex Home must fail closed")
        } catch let error as SessionManagementBackendError {
            XCTAssertEqual(error, .dataSourceIdentityChanged)
        }

        let statusReads = await appServer.statusReadCount()
        let deleteCalls = await delete.callCount()
        XCTAssertEqual(statusReads, 0)
        XCTAssertEqual(deleteCalls, 0)
    }

    func testDeletionUsesTargetRolloutGateInsteadOfGlobalCodexProcessGate() async throws {
        let fixture = try makeFixture(messageCount: 1, archived: true)
        let appServer = SessionManagementAppServerMock(
            threads: [fixture.appServerThread(status: .notLoaded)],
            status: .notLoaded
        )
        let delete = SessionManagementOfficialDeleteMock()
        let probedPaths = SessionManagementProbedPaths()
        let backend = makeBackend(
            appServer: appServer,
            officialDelete: delete,
            externalWriterDetector: { ["Codex (PID 88)"] },
            openFileHoldersDetector: { path in
                probedPaths.append(path)
                return []
            }
        )

        let confirmation = try await backend.prepareDeletionConfirmation(
            selectedThreadIDs: [fixture.threadID],
            dataSource: fixture.dataSource
        )

        let statusReads = await appServer.statusReadCount()
        let deleteCalls = await delete.callCount()
        XCTAssertGreaterThan(statusReads, 0)
        XCTAssertEqual(deleteCalls, 0)
        XCTAssertEqual(confirmation.impact.affected.map(\.id), [fixture.threadID])
        XCTAssertEqual(Set(probedPaths.values), [fixture.rolloutURL.path])
    }

    func testLiveDeletionRequiresEveryAffectedThreadToBeArchived() async throws {
        let fixture = try makeFixture(messageCount: 1)
        let appServer = SessionManagementAppServerMock(
            threads: [fixture.appServerThread(status: .notLoaded)],
            status: .notLoaded
        )
        let backend = makeBackend(
            appServer: appServer,
            externalWriterDetector: { ["Codex (PID 88)"] }
        )

        let catalog = try await backend.loadCatalog(dataSource: fixture.dataSource)
        let thread = try XCTUnwrap(catalog.threads.first)
        XCTAssertTrue(thread.canArchive)
        XCTAssertFalse(thread.canDelete)
        XCTAssertTrue(
            thread.protectionReasons.contains("Codex 运行中需先官方归档再删除")
        )
        do {
            _ = try await backend.prepareDeletionConfirmation(
                selectedThreadIDs: [thread.id],
                dataSource: fixture.dataSource
            )
            XCTFail("an unarchived live thread must not reach delete preparation")
        } catch let error as SessionManagementBackendError {
            XCTAssertEqual(
                error,
                .liveDeletionRequiresArchive([thread.id])
            )
        }
    }

    func testOpenRolloutHandleBlocksAfterFreshStatusProbe() async throws {
        let fixture = try makeFixture(messageCount: 1)
        let appServer = SessionManagementAppServerMock(
            threads: [fixture.appServerThread(status: .notLoaded)],
            status: .notLoaded
        )
        let delete = SessionManagementOfficialDeleteMock()
        let backend = makeBackend(
            appServer: appServer,
            officialDelete: delete,
            openFileHoldersDetector: { _ in [321] }
        )

        do {
            _ = try await performBoundDelete(fixture, using: backend)
            XCTFail("open rollout handle must block deletion")
        } catch let error as SessionManagementBackendError {
            guard case .externalWriterDetected(let writers) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(writers, ["会话文件占用进程 PID 321"])
        }
        let statusReads = await appServer.statusReadCount()
        let deleteCalls = await delete.callCount()
        XCTAssertEqual(statusReads, 1)
        XCTAssertEqual(deleteCalls, 0)
    }

    func testOpenHandleProbeFailureAlsoFailsClosed() async throws {
        let fixture = try makeFixture(messageCount: 1)
        let appServer = SessionManagementAppServerMock(
            threads: [fixture.appServerThread(status: .notLoaded)],
            status: .notLoaded
        )
        let delete = SessionManagementOfficialDeleteMock()
        let backend = makeBackend(
            appServer: appServer,
            officialDelete: delete,
            openFileHoldersDetector: { _ in throw SessionManagementTestError.probeFailed }
        )

        do {
            _ = try await performBoundDelete(fixture, using: backend)
            XCTFail("failed open-handle probe must block deletion")
        } catch let error as SessionManagementBackendError {
            guard case .externalWriterDetected(let writers) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(writers, ["会话文件占用状态无法确认"])
        }
        let deleteCalls = await delete.callCount()
        XCTAssertEqual(deleteCalls, 0)
    }

    func testRecoveryPackageDoesNotRequireOfficialArchiveAndPreservesSource() async throws {
        let fixture = try makeFixture(messageCount: 3, archived: false)
        let appServer = SessionManagementAppServerMock(
            threads: [fixture.appServerThread(status: .notLoaded)],
            status: .notLoaded
        )
        let backend = makeBackend(appServer: appServer)
        let catalog = try await backend.loadCatalog(dataSource: fixture.dataSource)
        let thread = try XCTUnwrap(catalog.threads.first)
        let sourceBefore = try Data(contentsOf: fixture.rolloutURL)

        let result = try await backend.createRecoveryPackage(
            thread: thread,
            dataSource: fixture.dataSource
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.packageURL.path))
        XCTAssertEqual(try Data(contentsOf: fixture.rolloutURL), sourceBefore)
        XCTAssertEqual(result.manifest.threadID, fixture.threadID)
        XCTAssertEqual(result.manifest.originalByteCount, Int64(sourceBefore.count))
        XCTAssertEqual(
            result.manifest.compression,
            SessionManagementRecoveryPackageManifest.compressionMethod
        )
        XCTAssertFalse(result.manifest.restoreSupported)
        XCTAssertGreaterThan(result.compressedBytes, 0)
        XCTAssertEqual(
            result.packageURL.lastPathComponent,
            "\(fixture.threadID)-\(result.manifest.sha256).ctb-session.zip"
        )

        let reused = try await backend.createRecoveryPackage(
            thread: thread,
            dataSource: fixture.dataSource
        )
        XCTAssertEqual(reused.packageURL, result.packageURL)
        XCTAssertEqual(reused.manifest, result.manifest)

        let test = try CodexThreadDeleteSubprocess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-t", result.packageURL.path],
            timeout: 30
        )
        XCTAssertEqual(test.terminationStatus, 0, test.stderr)
        let members = try CodexThreadDeleteSubprocess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-Z1", result.packageURL.path],
            timeout: 30
        )
        XCTAssertEqual(members.terminationStatus, 0, members.stderr)
        XCTAssertEqual(
            Set(members.stdout.split(whereSeparator: \.isNewline).map(String.init)),
            ["manifest.json", "rollout.jsonl"]
        )
        let manifestRead = try CodexThreadDeleteSubprocess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-p", result.packageURL.path, "manifest.json"],
            timeout: 30
        )
        let manifestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try XCTUnwrap(manifestRead.stdout.data(using: .utf8))
            ) as? [String: Any]
        )
        XCTAssertEqual(manifestObject["threadId"] as? String, fixture.threadID)
        XCTAssertEqual(
            (manifestObject["originalBytes"] as? NSNumber)?.int64Value,
            Int64(sourceBefore.count)
        )
        XCTAssertNil(manifestObject["threadID"])
        XCTAssertNil(manifestObject["originalByteCount"])
        let packageDirectory = result.packageURL.deletingLastPathComponent()
        let packageNames = try FileManager.default.contentsOfDirectory(
            atPath: packageDirectory.path
        )
        XCTAssertEqual(packageNames.filter { $0.hasSuffix(".ctb-session.zip") }.count, 1)
        XCTAssertFalse(packageNames.contains { $0.contains(".partial.zip") })
    }

    func testRecoveryPackageCreatesNewContentAddressedVersionAfterSourceChanges() async throws {
        let fixture = try makeFixture(messageCount: 1, archived: true)
        let appServer = SessionManagementAppServerMock(
            threads: [fixture.appServerThread(status: .notLoaded)],
            status: .notLoaded
        )
        let backend = makeBackend(appServer: appServer)
        let firstCatalog = try await backend.loadCatalog(dataSource: fixture.dataSource)
        let firstThread = try XCTUnwrap(firstCatalog.threads.first)
        let first = try await backend.createRecoveryPackage(
            thread: firstThread,
            dataSource: fixture.dataSource
        )
        let appended = try sessionManagementJSONLine([
            "timestamp": "2026-07-30T00:00:01.000Z",
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": "assistant",
                "content": [[
                    "type": "output_text",
                    "text": "changed",
                ]],
            ],
        ])
        let handle = try FileHandle(forWritingTo: fixture.rolloutURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: appended)
        try handle.close()

        let secondCatalog = try await backend.loadCatalog(dataSource: fixture.dataSource)
        let secondThread = try XCTUnwrap(secondCatalog.threads.first)
        let second = try await backend.createRecoveryPackage(
            thread: secondThread,
            dataSource: fixture.dataSource
        )

        XCTAssertNotEqual(first.manifest.sha256, second.manifest.sha256)
        XCTAssertNotEqual(first.packageURL, second.packageURL)
        let packageNames = try FileManager.default.contentsOfDirectory(
            atPath: second.packageURL.deletingLastPathComponent().path
        )
        XCTAssertEqual(
            packageNames.filter { $0.hasSuffix(".ctb-session.zip") }.count,
            2
        )
    }

    func testPreparedConfirmationFreezesCanonicalRolloutIdentityAndDigest() async throws {
        let fixture = try makeFixture(messageCount: 1, archived: true)
        let appServer = SessionManagementAppServerMock(
            threads: [fixture.appServerThread(status: .notLoaded)],
            status: .notLoaded
        )
        let backend = makeBackend(appServer: appServer)
        let confirmation = try await backend.prepareDeletionConfirmation(
            selectedThreadIDs: [fixture.threadID],
            dataSource: fixture.dataSource
        )
        let snapshot = try XCTUnwrap(
            confirmation.rolloutSnapshotsByThreadID[fixture.threadID]
        )
        XCTAssertEqual(
            snapshot.relativePath,
            "sessions/2026/07/30/\(fixture.rolloutURL.lastPathComponent)"
        )
        XCTAssertEqual(
            snapshot.sha256,
            providerSyncSHA256Hex(fixture.sourceData)
        )
        XCTAssertEqual(
            confirmation.codexHomeIdentity,
            fixture.dataSource.homeIdentity
        )

        let handle = try FileHandle(forWritingTo: fixture.rolloutURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()
        let thread = try XCTUnwrap(
            confirmation.impact.affected.first {
                $0.id == fixture.threadID
            }
        )

        do {
            _ = try await backend.createRecoveryPackage(
                thread: thread,
                dataSource: fixture.dataSource,
                expectedSnapshot: snapshot
            )
            XCTFail("post-confirmation content drift must invalidate packaging")
        } catch let error as SessionManagementBackendError {
            XCTAssertEqual(
                error,
                .recoveryEvidenceMismatch(fixture.threadID)
            )
        }
    }

    func testPreparedConfirmationRejectsCodexHomeReplacementBeforeOfficialDelete() async throws {
        let fixture = try makeFixture(messageCount: 1, archived: true)
        let appServer = SessionManagementAppServerMock(
            threads: [fixture.appServerThread(status: .notLoaded)],
            status: .notLoaded
        )
        let preparationBackend = makeBackend(appServer: appServer)
        let confirmation = try await preparationBackend
            .prepareDeletionConfirmation(
                selectedThreadIDs: [fixture.threadID],
                dataSource: fixture.dataSource
            )
        let thread = try XCTUnwrap(
            confirmation.impact.affected.first {
                $0.id == fixture.threadID
            }
        )
        let recovery = try await preparationBackend.createRecoveryPackage(
            thread: thread,
            dataSource: fixture.dataSource,
            expectedSnapshot:
                confirmation.rolloutSnapshotsByThreadID[thread.id]
        )
        let originalHome = fixture.dataSource.codexHome
        let displacedHome = originalHome
            .deletingLastPathComponent()
            .appendingPathComponent(
                "\(originalHome.lastPathComponent)-confirmed-displaced-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.moveItem(at: originalHome, to: displacedHome)
        try FileManager.default.createDirectory(
            at: originalHome,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: displacedHome)
        }
        let delete = SessionManagementOfficialDeleteMock()
        let deletionBackend = makeBackend(
            appServer: appServer,
            officialDelete: delete
        )

        do {
            _ = try await deletionBackend.delete(
                rootID: thread.id,
                expectation: SessionManagementDeletionExpectation(
                    confirmation: confirmation,
                    pendingRootIndex: 0,
                    requiresRecoveryEvidence: true
                ),
                recoveryPackages: [thread.id: recovery],
                dataSource: fixture.dataSource
            )
            XCTFail("replacing confirmed Codex Home must fail closed")
        } catch let error as SessionManagementBackendError {
            XCTAssertEqual(error, .dataSourceIdentityChanged)
        }
        let deleteCalls = await delete.callCount()
        XCTAssertEqual(deleteCalls, 0)
    }

    func testRecoveryPackageCleansOnlyRestrictedAbandonedArtifacts() async throws {
        let fixture = try makeFixture(messageCount: 1, archived: true)
        let appServer = SessionManagementAppServerMock(
            threads: [fixture.appServerThread(status: .notLoaded)],
            status: .notLoaded
        )
        let backend = makeBackend(appServer: appServer)
        let catalog = try await backend.loadCatalog(dataSource: fixture.dataSource)
        let thread = try XCTUnwrap(catalog.threads.first)
        let initial = try await backend.createRecoveryPackage(
            thread: thread,
            dataSource: fixture.dataSource
        )
        let directory = initial.packageURL.deletingLastPathComponent()
        let stalePartial = directory.appendingPathComponent(
            ".\(fixture.threadID)-\(UUID().uuidString).partial.zip"
        )
        let staleStaging = directory.appendingPathComponent(
            ".\(fixture.threadID)-\(UUID().uuidString).staging",
            isDirectory: true
        )
        let unrelatedPartial = directory.appendingPathComponent(
            ".keep-\(UUID().uuidString).partial.zip"
        )
        let unrelatedStaging = directory.appendingPathComponent(
            ".keep-\(UUID().uuidString).staging",
            isDirectory: true
        )
        try Data("stale".utf8).write(to: stalePartial)
        try FileManager.default.createDirectory(
            at: staleStaging,
            withIntermediateDirectories: false
        )
        try Data("{}".utf8).write(
            to: staleStaging.appendingPathComponent("manifest.json")
        )
        try Data("rollout".utf8).write(
            to: staleStaging.appendingPathComponent("rollout.jsonl")
        )
        try Data("keep".utf8).write(to: unrelatedPartial)
        try FileManager.default.createDirectory(
            at: unrelatedStaging,
            withIntermediateDirectories: false
        )

        _ = try await backend.createRecoveryPackage(
            thread: thread,
            dataSource: fixture.dataSource
        )

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: stalePartial.path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: staleStaging.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: unrelatedPartial.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: unrelatedStaging.path)
        )
    }

    func testRecoveryCleanupRejectsRestrictedPartialSymlink() async throws {
        let fixture = try makeFixture(messageCount: 1, archived: true)
        let appServer = SessionManagementAppServerMock(
            threads: [fixture.appServerThread(status: .notLoaded)],
            status: .notLoaded
        )
        let backend = makeBackend(appServer: appServer)
        let catalog = try await backend.loadCatalog(
            dataSource: fixture.dataSource
        )
        let thread = try XCTUnwrap(catalog.threads.first)
        let package = try await backend.createRecoveryPackage(
            thread: thread,
            dataSource: fixture.dataSource
        )
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
            "session-management-partial-target-\(UUID().uuidString)"
        )
        try Data("outside".utf8).write(to: outside)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        let link = package.packageURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(fixture.threadID)-\(UUID().uuidString).partial.zip"
            )
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: outside
        )

        do {
            _ = try await backend.createRecoveryPackage(
                thread: thread,
                dataSource: fixture.dataSource
            )
            XCTFail("restricted partial symlink must fail closed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("partial"))
        }
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
    }

    func testRecoveryCleanupRejectsRestrictedStagingSymlink() async throws {
        let fixture = try makeFixture(messageCount: 1, archived: true)
        let appServer = SessionManagementAppServerMock(
            threads: [fixture.appServerThread(status: .notLoaded)],
            status: .notLoaded
        )
        let backend = makeBackend(appServer: appServer)
        let catalog = try await backend.loadCatalog(
            dataSource: fixture.dataSource
        )
        let thread = try XCTUnwrap(catalog.threads.first)
        let package = try await backend.createRecoveryPackage(
            thread: thread,
            dataSource: fixture.dataSource
        )
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
            "session-management-staging-target-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: false
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        let link = package.packageURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(fixture.threadID)-\(UUID().uuidString).staging",
                isDirectory: true
            )
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: outside
        )

        do {
            _ = try await backend.createRecoveryPackage(
                thread: thread,
                dataSource: fixture.dataSource
            )
            XCTFail("restricted staging symlink must fail closed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("staging"))
        }
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: outside.path)
                .isEmpty
        )
    }

    func testDeleteRejectsRecoveryEvidenceAfterRolloutChanges() async throws {
        let fixture = try makeFixture(messageCount: 1, archived: true)
        let appServer = SessionManagementAppServerMock(
            threads: [fixture.appServerThread(status: .notLoaded)],
            status: .notLoaded
        )
        let delete = SessionManagementOfficialDeleteMock()
        let backend = makeBackend(appServer: appServer, officialDelete: delete)
        let catalog = try await backend.loadCatalog(dataSource: fixture.dataSource)
        let thread = try XCTUnwrap(catalog.threads.first)
        let impact = SessionManagementPresentation.deletionImpact(
            threads: catalog.threads,
            selectedThreadIDs: [thread.id]
        )
        let confirmation = try makeFixtureDeletionConfirmation(
            impact: impact,
            dataSource: fixture.dataSource
        )
        let recovery = try await backend.createRecoveryPackage(
            thread: thread,
            dataSource: fixture.dataSource,
            expectedSnapshot: confirmation.rolloutSnapshotsByThreadID[thread.id]
        )
        let handle = try FileHandle(forWritingTo: fixture.rolloutURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()

        do {
            _ = try await backend.delete(
                rootID: thread.id,
                expectation: SessionManagementDeletionExpectation(
                    confirmation: confirmation,
                    pendingRootIndex: 0,
                    requiresRecoveryEvidence: true
                ),
                recoveryPackages: [thread.id: recovery],
                dataSource: fixture.dataSource
            )
            XCTFail("changed rollout must invalidate recovery evidence")
        } catch let error as SessionManagementBackendError {
            XCTAssertEqual(error, .recoveryEvidenceMismatch(thread.id))
        }
        let deleteCalls = await delete.callCount()
        XCTAssertEqual(deleteCalls, 0)
    }

    func testPrelaunchVerificationRejectsRolloutPathReplacementBeforeOfficialDelete() async throws {
        let fixture = try makeFixture(messageCount: 1, archived: true)
        let appServer = SessionManagementAppServerMock(
            threads: [fixture.appServerThread(status: .notLoaded)],
            status: .notLoaded
        )
        let preparationBackend = makeBackend(appServer: appServer)
        let confirmation = try await preparationBackend
            .prepareDeletionConfirmation(
                selectedThreadIDs: [fixture.threadID],
                dataSource: fixture.dataSource
            )
        let thread = try XCTUnwrap(
            confirmation.impact.affected.first {
                $0.id == fixture.threadID
            }
        )
        let recovery = try await preparationBackend.createRecoveryPackage(
            thread: thread,
            dataSource: fixture.dataSource,
            expectedSnapshot:
                confirmation.rolloutSnapshotsByThreadID[thread.id]
        )
        let delete = SessionManagementOfficialDeleteMock(
            beforePrelaunchVerification: {
                try replacePathEntryWithIdenticalRegularFile(
                    at: fixture.rolloutURL
                )
            }
        )
        let deletionBackend = makeBackend(
            appServer: appServer,
            officialDelete: delete
        )

        do {
            _ = try await deletionBackend.delete(
                rootID: thread.id,
                expectation: SessionManagementDeletionExpectation(
                    confirmation: confirmation,
                    pendingRootIndex: 0,
                    requiresRecoveryEvidence: true
                ),
                recoveryPackages: [thread.id: recovery],
                dataSource: fixture.dataSource
            )
            XCTFail("a swapped rollout path must stop before the official CLI")
        } catch {
            // The exact lower-level security error is intentionally not part
            // of the user-facing contract; reaching this point is fail-closed.
        }
        let hookCalls = await delete.prelaunchHookCallCount()
        let deleteCalls = await delete.callCount()
        XCTAssertEqual(hookCalls, 1)
        XCTAssertEqual(deleteCalls, 0)
    }

    func testPrelaunchVerificationRejectsRecoveryPackagePathReplacementBeforeOfficialDelete() async throws {
        let fixture = try makeFixture(messageCount: 1, archived: true)
        let appServer = SessionManagementAppServerMock(
            threads: [fixture.appServerThread(status: .notLoaded)],
            status: .notLoaded
        )
        let preparationBackend = makeBackend(appServer: appServer)
        let confirmation = try await preparationBackend
            .prepareDeletionConfirmation(
                selectedThreadIDs: [fixture.threadID],
                dataSource: fixture.dataSource
            )
        let thread = try XCTUnwrap(
            confirmation.impact.affected.first {
                $0.id == fixture.threadID
            }
        )
        let recovery = try await preparationBackend.createRecoveryPackage(
            thread: thread,
            dataSource: fixture.dataSource,
            expectedSnapshot:
                confirmation.rolloutSnapshotsByThreadID[thread.id]
        )
        let delete = SessionManagementOfficialDeleteMock(
            beforePrelaunchVerification: {
                try replacePathEntryWithIdenticalRegularFile(
                    at: recovery.packageURL
                )
            }
        )
        let deletionBackend = makeBackend(
            appServer: appServer,
            officialDelete: delete
        )

        do {
            _ = try await deletionBackend.delete(
                rootID: thread.id,
                expectation: SessionManagementDeletionExpectation(
                    confirmation: confirmation,
                    pendingRootIndex: 0,
                    requiresRecoveryEvidence: true
                ),
                recoveryPackages: [thread.id: recovery],
                dataSource: fixture.dataSource
            )
            XCTFail("a swapped recovery package must stop before the official CLI")
        } catch {
            // See the rollout replacement test above.
        }
        let hookCalls = await delete.prelaunchHookCallCount()
        let deleteCalls = await delete.callCount()
        XCTAssertEqual(hookCalls, 1)
        XCTAssertEqual(deleteCalls, 0)
    }

    func testPrelaunchVerificationRejectsWriterThatAppearsAfterRecoveryValidation() async throws {
        let fixture = try makeFixture(messageCount: 1, archived: true)
        let appServer = SessionManagementAppServerMock(
            threads: [fixture.appServerThread(status: .notLoaded)],
            status: .notLoaded
        )
        let preparationBackend = makeBackend(appServer: appServer)
        let confirmation = try await preparationBackend.prepareDeletionConfirmation(
            selectedThreadIDs: [fixture.threadID],
            dataSource: fixture.dataSource
        )
        let thread = try XCTUnwrap(confirmation.impact.affected.first)
        let recovery = try await preparationBackend.createRecoveryPackage(
            thread: thread,
            dataSource: fixture.dataSource,
            expectedSnapshot: confirmation.rolloutSnapshotsByThreadID[thread.id]
        )
        let writer = SessionManagementWriterProbe()
        let delete = SessionManagementOfficialDeleteMock(
            beforePrelaunchVerification: { writer.beginWriting() }
        )
        let deletionBackend = makeBackend(
            appServer: appServer,
            officialDelete: delete,
            openFileHoldersDetector: { _ in writer.isWriting ? [777] : [] }
        )

        do {
            _ = try await deletionBackend.delete(
                rootID: thread.id,
                expectation: SessionManagementDeletionExpectation(
                    confirmation: confirmation,
                    pendingRootIndex: 0,
                    requiresRecoveryEvidence: true
                ),
                recoveryPackages: [thread.id: recovery],
                dataSource: fixture.dataSource
            )
            XCTFail("a writer appearing at prelaunch must stop the official CLI")
        } catch let error as SessionManagementBackendError {
            guard case .externalWriterDetected(let writers) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(writers, ["会话文件占用进程 PID 777"])
        }
        let hookCalls = await delete.prelaunchHookCallCount()
        let deleteCalls = await delete.callCount()
        XCTAssertEqual(hookCalls, 1)
        XCTAssertEqual(deleteCalls, 0)
    }

    func testTrustedRolloutRejectsSymlinkedPathComponent() async throws {
        let fixture = try makeFixture(messageCount: 1)
        let appServer = SessionManagementAppServerMock(
            threads: [fixture.appServerThread(status: .notLoaded)],
            status: .notLoaded
        )
        let backend = makeBackend(appServer: appServer)
        let year = fixture.dataSource.codexHome
            .appendingPathComponent("sessions/2026", isDirectory: true)
        let relocated = fixture.dataSource.codexHome
            .appendingPathComponent("relocated-2026", isDirectory: true)
        try FileManager.default.moveItem(at: year, to: relocated)
        try FileManager.default.createSymbolicLink(
            at: year,
            withDestinationURL: relocated
        )

        let catalog = try await backend.loadCatalog(dataSource: fixture.dataSource)
        let thread = try XCTUnwrap(
            catalog.threads.first { $0.id == fixture.threadID }
        )
        XCTAssertFalse(thread.rolloutIdentityVerified)
        XCTAssertFalse(thread.canDelete)
        XCTAssertFalse(catalog.deletionVerificationComplete)
    }

    func testRecoveryPackageRejectsSymlinkedPackageDirectoryComponent() async throws {
        let fixture = try makeFixture(messageCount: 1)
        let appServer = SessionManagementAppServerMock(
            threads: [fixture.appServerThread(status: .notLoaded)],
            status: .notLoaded
        )
        let backend = makeBackend(appServer: appServer)
        let catalog = try await backend.loadCatalog(dataSource: fixture.dataSource)
        let thread = try XCTUnwrap(catalog.threads.first)
        let packageParent = fixture.dataSource.codexHome
            .appendingPathComponent("backups_state/codex-token-bar", isDirectory: true)
        try FileManager.default.createDirectory(
            at: packageParent,
            withIntermediateDirectories: true
        )
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
            "session-management-outside-recovery-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createSymbolicLink(
            at: packageParent.appendingPathComponent(
                "session-recovery",
                isDirectory: true
            ),
            withDestinationURL: outside
        )

        do {
            _ = try await backend.createRecoveryPackage(
                thread: thread,
                dataSource: fixture.dataSource
            )
            XCTFail("a symlinked recovery package directory must be rejected")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("恢复包目录")
                    || error.localizedDescription.contains("无跟随")
            )
        }
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty
        )
    }

    private func performBoundDelete(
        _ fixture: SessionManagementFixture,
        using backend: FoundationSessionManagementBackend
    ) async throws -> String {
        let catalog = try await backend.loadCatalog(dataSource: fixture.dataSource)
        let impact = SessionManagementPresentation.deletionImpact(
            threads: catalog.threads,
            selectedThreadIDs: [fixture.threadID]
        )
        let confirmation = try makeFixtureDeletionConfirmation(
            impact: impact,
            dataSource: fixture.dataSource
        )
        return try await backend.delete(
            rootID: fixture.threadID,
            expectation: SessionManagementDeletionExpectation(
                confirmation: confirmation,
                pendingRootIndex: 0,
                requiresRecoveryEvidence: true
            ),
            recoveryPackages: [:],
            dataSource: fixture.dataSource
        )
    }

    private func makeBackend(
        appServer: SessionManagementAppServerMock,
        officialDelete: SessionManagementOfficialDeleteMock =
            SessionManagementOfficialDeleteMock(),
        externalWriterDetector: @escaping @Sendable () -> [String] = { [] },
        openFileHoldersDetector: @escaping @Sendable (String) throws -> [Int32] = { _ in [] },
        autoResumeProtectedThreadIDsProvider:
            @escaping @Sendable () throws -> Set<String> = { [] }
    ) -> FoundationSessionManagementBackend {
        FoundationSessionManagementBackend(
            appServer: appServer,
            officialDelete: officialDelete,
            codexBinaryProvider: { "/fake/codex" },
            mutationGate: {},
            externalWriterDetector: externalWriterDetector,
            openFileHoldersDetector: openFileHoldersDetector,
            autoResumeProtectedThreadIDsProvider:
                autoResumeProtectedThreadIDsProvider
        )
    }

    private func addThread(
        to fixture: SessionManagementFixture,
        parentThreadID: String? = nil,
        forkedFromID: String? = nil,
        rolloutIdentityID: String? = nil,
        archived: Bool = false
    ) throws -> SessionManagementFixtureThread {
        let threadID = UUID().uuidString.lowercased()
        let rolloutURL = fixture.rolloutURL
            .deletingLastPathComponent()
            .appendingPathComponent("rollout-\(threadID).jsonl")
        var payload: [String: Any] = [
            "id": rolloutIdentityID ?? threadID,
            "cwd": fixture.project.path,
            "session_id": "session-\(threadID)",
            "source": parentThreadID == nil ? "cli" : "subagent",
        ]
        if let parentThreadID {
            payload["parent_thread_id"] = parentThreadID
        }
        if let forkedFromID {
            payload["forked_from_id"] = forkedFromID
        }
        let source = try sessionManagementJSONLine([
            "timestamp": "2026-07-30T00:00:00.000Z",
            "type": "session_meta",
            "payload": payload,
        ])
        try source.write(to: rolloutURL, options: .atomic)

        let database = SQLiteDatabaseDriver(url: fixture.dataSource.stateDatabase)
        try database.execute(
            """
            INSERT INTO threads (
                id, rollout_path, title, preview, first_user_message, cwd,
                created_at, updated_at, recency_at, archived, archived_at,
                source, model, git_branch
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(threadID),
                .text(rolloutURL.path),
                .text("Fixture \(threadID)"),
                .text("Fixture preview"),
                .text("Fixture first message"),
                .text(fixture.project.path),
                .int64(1_722_326_400),
                .int64(1_722_326_500),
                .int64(1_722_326_500),
                .int(archived ? 1 : 0),
                archived ? .int64(1_722_326_600) : .null,
                .text(parentThreadID == nil ? "cli" : "subagent"),
                .text("gpt-test"),
                .text("feature/session-test"),
            ]
        )
        return SessionManagementFixtureThread(
            threadID: threadID,
            project: fixture.project,
            rolloutURL: rolloutURL,
            archived: archived,
            forkedFromID: forkedFromID,
            parentThreadID: parentThreadID
        )
    }

    private func makeFixture(
        messageCount: Int,
        appendIncompleteTail: Bool = false,
        archived: Bool = false
    ) throws -> SessionManagementFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "codex-token-bar-session-management-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let dataSource = CodexDataSource(codexHome: root, origin: .userSelected)
        let threadID = UUID().uuidString.lowercased()
        let project = root.appendingPathComponent("project", isDirectory: true)
        let sessions = root.appendingPathComponent(
            "sessions/2026/07/30",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: project,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: sessions,
            withIntermediateDirectories: true
        )
        let rolloutURL = sessions.appendingPathComponent(
            "rollout-\(threadID).jsonl"
        )
        var source = try sessionManagementJSONLine([
            "timestamp": "2026-07-30T00:00:00.000Z",
            "type": "session_meta",
            "payload": [
                "id": threadID,
                "cwd": project.path,
                "session_id": "session-\(threadID)",
                "source": "cli",
            ],
        ])
        for index in 0..<messageCount {
            source.append(try sessionManagementJSONLine([
                "timestamp": "2026-07-30T00:00:00.000Z",
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": index.isMultiple(of: 2) ? "user" : "assistant",
                    "content": [[
                        "type": index.isMultiple(of: 2) ? "input_text" : "output_text",
                        "text": "message-\(index)",
                    ]],
                ],
            ]))
        }
        if appendIncompleteTail {
            source.append(Data(#"{"type":"response_item""#.utf8))
        }
        try source.write(to: rolloutURL, options: .atomic)

        let database = SQLiteDatabaseDriver(url: dataSource.stateDatabase)
        try database.execute(
            """
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                rollout_path TEXT,
                title TEXT,
                preview TEXT,
                first_user_message TEXT,
                cwd TEXT,
                created_at INTEGER,
                updated_at INTEGER,
                recency_at INTEGER,
                archived INTEGER,
                archived_at INTEGER,
                source TEXT,
                model TEXT,
                git_branch TEXT
            )
            """
        )
        try database.execute(
            """
            INSERT INTO threads (
                id, rollout_path, title, preview, first_user_message, cwd,
                created_at, updated_at, recency_at, archived, archived_at,
                source, model, git_branch
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(threadID),
                .text(rolloutURL.path),
                .text("Fixture session"),
                .text("Fixture preview"),
                .text("message-0"),
                .text(project.path),
                .int64(1_722_326_400),
                .int64(1_722_326_500),
                .int64(1_722_326_500),
                .int(archived ? 1 : 0),
                archived ? .int64(1_722_326_600) : .null,
                .text("cli"),
                .text("gpt-test"),
                .text("feature/session-test"),
            ]
        )
        return SessionManagementFixture(
            dataSource: dataSource,
            threadID: threadID,
            project: project,
            rolloutURL: rolloutURL,
            sourceData: source,
            archived: archived
        )
    }
}

private struct SessionManagementFixture {
    let dataSource: CodexDataSource
    let threadID: String
    let project: URL
    let rolloutURL: URL
    let sourceData: Data
    let archived: Bool

    func appServerThread(
        status: SessionManagementThreadStatus
    ) -> SessionManagementAppServerThread {
        SessionManagementAppServerThread(
            id: threadID,
            title: "Fixture session",
            preview: "Fixture preview",
            cwd: project.path,
            rolloutPath: rolloutURL.path,
            createdAt: Date(timeIntervalSince1970: 1_722_326_400),
            updatedAt: Date(timeIntervalSince1970: 1_722_326_500),
            archived: archived,
            status: status,
            source: "cli",
            model: "gpt-test",
            sessionID: "session-\(threadID)",
            forkedFromID: nil,
            parentThreadID: nil
        )
    }
}

private struct SessionManagementFixtureThread {
    let threadID: String
    let project: URL
    let rolloutURL: URL
    let archived: Bool
    let forkedFromID: String?
    let parentThreadID: String?

    func appServerThread(
        status: SessionManagementThreadStatus
    ) -> SessionManagementAppServerThread {
        SessionManagementAppServerThread(
            id: threadID,
            title: "Fixture \(threadID)",
            preview: "Fixture preview",
            cwd: project.path,
            rolloutPath: rolloutURL.path,
            createdAt: Date(timeIntervalSince1970: 1_722_326_400),
            updatedAt: Date(timeIntervalSince1970: 1_722_326_500),
            archived: archived,
            status: status,
            source: parentThreadID == nil ? "cli" : "subagent",
            model: "gpt-test",
            sessionID: "session-\(threadID)",
            forkedFromID: forkedFromID,
            parentThreadID: parentThreadID
        )
    }
}

private actor SessionManagementAppServerMock: SessionManagementAppServerServing {
    private let threads: [SessionManagementAppServerThread]
    private let status: SessionManagementThreadStatus
    private let statusByThreadID: [String: SessionManagementThreadStatus]
    private let descendantOverrides:
        [String: [SessionManagementAppServerThread]]
    private var statusReads = 0
    private var statusReadIDs: [String] = []
    private var archiveCalls = 0
    private var unarchiveCalls = 0

    init(
        threads: [SessionManagementAppServerThread],
        status: SessionManagementThreadStatus? = nil,
        statusByThreadID: [String: SessionManagementThreadStatus] = [:],
        descendantOverrides:
            [String: [SessionManagementAppServerThread]] = [:]
    ) {
        self.threads = threads
        self.status = status ?? threads.first?.status ?? .unknown
        self.statusByThreadID = statusByThreadID
        self.descendantOverrides = descendantOverrides
    }

    func listSessionManagementThreads(
        codexPath _: String,
        dataSource _: CodexDataSource?
    ) async throws -> [SessionManagementAppServerThread] {
        threads
    }

    func listSessionManagementDescendants(
        codexPath _: String,
        dataSource _: CodexDataSource?,
        ancestorThreadID: String
    ) async throws -> [SessionManagementAppServerThread] {
        if let overridden = descendantOverrides[ancestorThreadID] {
            return overridden
        }
        let byID = Dictionary(
            uniqueKeysWithValues: threads.map { ($0.id, $0) }
        )
        return threads.filter { candidate in
            guard candidate.id != ancestorThreadID else { return false }
            var seen = Set<String>()
            var current = candidate.parentThreadID
            while let threadID = current, seen.insert(threadID).inserted {
                if threadID == ancestorThreadID { return true }
                current = byID[threadID]?.parentThreadID
            }
            return false
        }
    }

    func readSessionManagementThreadStatus(
        codexPath _: String,
        dataSource _: CodexDataSource?,
        threadID: String
    ) async throws -> SessionManagementThreadStatus {
        statusReads += 1
        statusReadIDs.append(threadID)
        return statusByThreadID[threadID] ?? status
    }

    func archiveSessionManagementThread(
        codexPath _: String,
        dataSource _: CodexDataSource?,
        threadID _: String
    ) async throws {
        archiveCalls += 1
    }

    func unarchiveSessionManagementThread(
        codexPath _: String,
        dataSource _: CodexDataSource?,
        threadID _: String
    ) async throws {
        unarchiveCalls += 1
    }

    func statusReadCount() -> Int {
        statusReads
    }

    func statusReadThreadIDs() -> [String] {
        statusReadIDs
    }
}

private actor SessionManagementOfficialDeleteMock: SessionManagementOfficialDeleting {
    private let beforePrelaunchVerification: @Sendable () throws -> Void
    private var calls = 0
    private var prelaunchHookCalls = 0

    init(
        beforePrelaunchVerification:
            @escaping @Sendable () throws -> Void = {}
    ) {
        self.beforePrelaunchVerification = beforePrelaunchVerification
    }

    func delete(
        codexPath _: String,
        dataSource _: CodexDataSource,
        threadID _: String,
        prelaunchVerification: @escaping @Sendable () throws -> Void
    ) async throws -> String {
        prelaunchHookCalls += 1
        try beforePrelaunchVerification()
        try prelaunchVerification()
        calls += 1
        return "deleted"
    }

    func callCount() -> Int {
        calls
    }

    func prelaunchHookCallCount() -> Int {
        prelaunchHookCalls
    }
}

private actor GatedSessionManagementService: SessionManagementServicing {
    private var catalogContinuations:
        [CheckedContinuation<SessionManagementCatalog, Error>?] = []
    private var contextContinuations:
        [CheckedContinuation<SessionManagementContextPage, Error>?] = []

    func loadCatalog(
        dataSource _: CodexDataSource
    ) async throws -> SessionManagementCatalog {
        try await withCheckedThrowingContinuation { continuation in
            catalogContinuations.append(continuation)
        }
    }

    func waitForLoadCount(_ expectedCount: Int) async -> Bool {
        for _ in 0..<1_000 {
            if catalogContinuations.count >= expectedCount {
                return true
            }
            await Task.yield()
        }
        return false
    }

    func loadCount() -> Int {
        catalogContinuations.count
    }

    func completeLoad(
        at index: Int,
        with catalog: SessionManagementCatalog
    ) {
        guard catalogContinuations.indices.contains(index),
              let continuation = catalogContinuations[index] else {
            return
        }
        catalogContinuations[index] = nil
        continuation.resume(returning: catalog)
    }

    func prepareDeletionConfirmation(
        selectedThreadIDs _: Set<String>,
        dataSource _: CodexDataSource
    ) async throws -> SessionManagementDeletionConfirmation {
        throw SessionManagementTestError.unsupportedMockCall
    }

    func loadContextPage(
        thread _: SessionManagementThread,
        dataSource _: CodexDataSource,
        beforeOffset _: Int64?,
        pageSize _: Int
    ) async throws -> SessionManagementContextPage {
        try await withCheckedThrowingContinuation { continuation in
            contextContinuations.append(continuation)
        }
    }

    func waitForContextLoadCount(_ expectedCount: Int) async -> Bool {
        for _ in 0..<1_000 {
            if contextContinuations.count >= expectedCount {
                return true
            }
            await Task.yield()
        }
        return false
    }

    func completeContextLoad(
        at index: Int,
        with page: SessionManagementContextPage
    ) {
        guard contextContinuations.indices.contains(index),
              let continuation = contextContinuations[index] else {
            return
        }
        contextContinuations[index] = nil
        continuation.resume(returning: page)
    }

    func archive(
        threadID _: String,
        dataSource _: CodexDataSource
    ) async throws {
        throw SessionManagementTestError.unsupportedMockCall
    }

    func unarchive(
        threadID _: String,
        dataSource _: CodexDataSource
    ) async throws {
        throw SessionManagementTestError.unsupportedMockCall
    }

    func delete(
        rootID _: String,
        expectation _: SessionManagementDeletionExpectation,
        recoveryPackages _: [String: SessionManagementRecoveryPackageResult],
        dataSource _: CodexDataSource
    ) async throws -> String {
        throw SessionManagementTestError.unsupportedMockCall
    }

    func createRecoveryPackage(
        thread _: SessionManagementThread,
        dataSource _: CodexDataSource,
        expectedSnapshot _: SessionManagementRolloutSnapshot?
    ) async throws -> SessionManagementRecoveryPackageResult {
        throw SessionManagementTestError.unsupportedMockCall
    }
}

private actor SessionManagementBatchDeletionServiceMock: SessionManagementServicing {
    private let failingThreadIDs: Set<String>
    private let failingRecoveryThreadIDs: Set<String>
    private let incompleteCatalogLoadNumbers: Set<Int>
    private let retainedSuccessfulDeleteRootIDs: Set<String>
    private var catalog: SessionManagementCatalog
    private var catalogLoadCount = 0
    private var deleteCalls: [String] = []
    private var recoveryCalls: [String] = []
    private var operationEvents: [String] = []

    init(
        threads: [SessionManagementThread],
        failingThreadIDs: Set<String> = [],
        failingRecoveryThreadIDs: Set<String> = [],
        incompleteCatalogLoadNumbers: Set<Int> = [],
        retainedSuccessfulDeleteRootIDs: Set<String> = []
    ) {
        self.failingThreadIDs = failingThreadIDs
        self.failingRecoveryThreadIDs = failingRecoveryThreadIDs
        self.incompleteCatalogLoadNumbers = incompleteCatalogLoadNumbers
        self.retainedSuccessfulDeleteRootIDs = retainedSuccessfulDeleteRootIDs
        catalog = SessionManagementCatalog(
            threads: threads,
            generatedAt: Date(),
            codexHome: "/tmp/session-management-batch-fixture",
            totalBytes: threads.allSatisfy { $0.fileBytes != nil }
                ? threads.reduce(0) { $0 + max(0, $1.fileBytes ?? 0) }
                : nil,
            warnings: [],
            capabilities: .readOnly
        )
    }

    func loadCatalog(
        dataSource _: CodexDataSource
    ) async throws -> SessionManagementCatalog {
        catalogLoadCount += 1
        var result = catalog
        if incompleteCatalogLoadNumbers.contains(catalogLoadCount) {
            result.deletionVerificationComplete = false
        }
        return result
    }

    func prepareDeletionConfirmation(
        selectedThreadIDs _: Set<String>,
        dataSource _: CodexDataSource
    ) async throws -> SessionManagementDeletionConfirmation {
        throw SessionManagementTestError.unsupportedMockCall
    }

    func loadContextPage(
        thread _: SessionManagementThread,
        dataSource _: CodexDataSource,
        beforeOffset _: Int64?,
        pageSize _: Int
    ) async throws -> SessionManagementContextPage {
        throw SessionManagementTestError.unsupportedMockCall
    }

    func archive(
        threadID _: String,
        dataSource _: CodexDataSource
    ) async throws {
        throw SessionManagementTestError.unsupportedMockCall
    }

    func unarchive(
        threadID _: String,
        dataSource _: CodexDataSource
    ) async throws {
        throw SessionManagementTestError.unsupportedMockCall
    }

    func delete(
        rootID: String,
        expectation _: SessionManagementDeletionExpectation,
        recoveryPackages _: [String: SessionManagementRecoveryPackageResult],
        dataSource _: CodexDataSource
    ) async throws -> String {
        deleteCalls.append(rootID)
        operationEvents.append("delete:\(rootID)")
        if failingThreadIDs.contains(rootID) {
            throw SessionManagementTestError.expectedFailure
        }
        if retainedSuccessfulDeleteRootIDs.contains(rootID) {
            return "deleted"
        }
        let impact = SessionManagementPresentation.deletionImpact(
            threads: catalog.threads,
            selectedThreadIDs: [rootID]
        )
        let removedIDs = Set(impact.affected.map(\.id))
        catalog.threads.removeAll { removedIDs.contains($0.id) }
        catalog.totalBytes = catalog.threads.allSatisfy { $0.fileBytes != nil }
            ? catalog.threads.reduce(0) { $0 + max(0, $1.fileBytes ?? 0) }
            : nil
        return "deleted"
    }

    func createRecoveryPackage(
        thread: SessionManagementThread,
        dataSource: CodexDataSource,
        expectedSnapshot: SessionManagementRolloutSnapshot?
    ) async throws -> SessionManagementRecoveryPackageResult {
        recoveryCalls.append(thread.id)
        operationEvents.append("package:\(thread.id)")
        if failingRecoveryThreadIDs.contains(thread.id) {
            throw SessionManagementTestError.expectedFailure
        }
        let sourceIdentity = expectedSnapshot?.fileIdentity
            ?? SessionManagementFileIdentity(
                deviceID: 1,
                fileID: UInt64(bitPattern: Int64(thread.id.hashValue)),
                size: thread.fileBytes ?? 0,
                modifiedAt: thread.fileModifiedAt
            )
        return SessionManagementRecoveryPackageResult(
            packageURL: dataSource.codexHome
                .appendingPathComponent("recovery", isDirectory: true)
                .appendingPathComponent("\(thread.id).ctb-session.zip"),
            manifest: SessionManagementRecoveryPackageManifest(
                schemaVersion: SessionManagementRecoveryPackageManifest.schemaVersion,
                threadID: thread.id,
                createdAt: 0,
                originalRelativePath:
                    expectedSnapshot?.relativePath ?? thread.rolloutPath,
                originalByteCount: sourceIdentity.size,
                sha256:
                    expectedSnapshot?.sha256 ?? String(repeating: "0", count: 64),
                compression: SessionManagementRecoveryPackageManifest.compressionMethod,
                restoreSupported: false
            ),
            compressedBytes: 1,
            sourceIdentity: sourceIdentity,
            packageIdentity: SessionManagementFileIdentity(
                deviceID: 1,
                fileID: UInt64(bitPattern: Int64(thread.id.hashValue)) &+ 1,
                size: 1,
                modifiedAt: nil
            ),
            packageSHA256: String(repeating: "1", count: 64)
        )
    }

    func deletedThreadIDs() -> [String] {
        deleteCalls
    }

    func recoveryThreadIDs() -> [String] {
        recoveryCalls
    }

    func events() -> [String] {
        operationEvents
    }
}

private final class SessionManagementProtectedIDsSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [Set<String>]
    private var index = 0

    init(responses: [Set<String>]) {
        self.responses = responses
    }

    func next() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        guard !responses.isEmpty else { return [] }
        let response = responses[min(index, responses.count - 1)]
        index += 1
        return response
    }
}

private final class SessionManagementProbedPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.withLock { storage }
    }

    func append(_ path: String) {
        lock.withLock { storage.append(path) }
    }
}

private final class SessionManagementWriterProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var writing = false

    var isWriting: Bool {
        lock.withLock { writing }
    }

    func beginWriting() {
        lock.withLock { writing = true }
    }
}

private enum SessionManagementTestError: LocalizedError {
    case probeFailed
    case expectedFailure
    case unsupportedMockCall

    var errorDescription: String? {
        switch self {
        case .probeFailed: return "probe failed"
        case .expectedFailure: return "expected failure"
        case .unsupportedMockCall: return "unsupported mock call"
        }
    }
}

private func makeSessionManagementThread(
    id: String,
    cwd: String = "/tmp/project",
    updatedAt: Date? = nil,
    archived: Bool = false,
    fileBytes: Int64? = 1,
    forkedFromID: String? = nil,
    parentThreadID: String? = nil,
    isSubagent: Bool = false
) -> SessionManagementThread {
    SessionManagementThread(
        id: id,
        title: "Session \(id)",
        preview: "",
        firstUserMessage: "",
        cwd: cwd,
        rolloutPath: "/tmp/\(id).jsonl",
        createdAt: nil,
        updatedAt: updatedAt,
        recencyAt: nil,
        archived: archived,
        archivedAt: nil,
        tokensUsed: nil,
        fileBytes: fileBytes,
        fileModifiedAt: nil,
        status: .notLoaded,
        source: "cli",
        model: "",
        gitBranch: "",
        sessionID: nil,
        forkedFromID: forkedFromID,
        parentThreadID: parentThreadID,
        isSubagent: isSubagent,
        spawnChildCount: 0,
        forkChildCount: forkedFromID == nil ? 0 : 1,
        similarityGroupID: nil,
        similarityReason: nil,
        protectionReasons: [],
        canArchive: true,
        canUnarchive: false,
        canDelete: true,
        rolloutIdentityVerified: true
    )
}

private func makeContextPage(
    threadID: String,
    text: String
) -> SessionManagementContextPage {
    SessionManagementContextPage(
        threadID: threadID,
        messages: [
            SessionManagementContextMessage(
                id: "\(threadID)-\(text)",
                role: "assistant",
                timestamp: nil,
                text: text,
                isTruncated: false,
                byteOffset: 0
            ),
        ],
        nextBeforeOffset: nil,
        hasMoreBefore: false,
        fileIdentity: SessionManagementFileIdentity(
            deviceID: 1,
            fileID: 1,
            size: Int64(text.utf8.count),
            modifiedAt: nil
        ),
        warnings: []
    )
}

private func makeBatchDeletionDataSource(_ label: String) -> CodexDataSource {
    CodexDataSource(
        codexHome: URL(
            fileURLWithPath: "/tmp/session-management-\(label)",
            isDirectory: true
        ),
        origin: .userSelected,
        expectedHomeIdentity: CodexHomeIdentity(
            deviceID: 0xC0DE,
            fileID: UInt64(bitPattern: Int64(label.hashValue))
        )
    )
}

private func makeBatchDeletionConfirmation(
    threads: [SessionManagementThread],
    selectedThreadIDs: Set<String>,
    dataSource: CodexDataSource
) -> SessionManagementDeletionConfirmation {
    let impact = SessionManagementPresentation.deletionImpact(
        threads: threads,
        selectedThreadIDs: selectedThreadIDs
    )
    let snapshots = Dictionary(
        uniqueKeysWithValues: impact.affected.map { thread in
            (
                thread.id,
                SessionManagementRolloutSnapshot(
                    threadID: thread.id,
                    relativePath: thread.rolloutPath,
                    fileIdentity: SessionManagementFileIdentity(
                        deviceID: 1,
                        fileID: UInt64(bitPattern: Int64(thread.id.hashValue)),
                        size: thread.fileBytes ?? 0,
                        modifiedAt: thread.fileModifiedAt
                    ),
                    sha256: String(repeating: "0", count: 64)
                )
            )
        }
    )
    return SessionManagementDeletionConfirmation(
        impact: impact,
        codexHomeIdentity: dataSource.homeIdentity
            ?? CodexHomeIdentity(deviceID: 0, fileID: 0),
        rolloutSnapshotsByThreadID: snapshots
    )
}

private func makeFixtureDeletionConfirmation(
    impact: SessionManagementDeletionImpact,
    dataSource: CodexDataSource
) throws -> SessionManagementDeletionConfirmation {
    guard let homeIdentity = dataSource.homeIdentity else {
        throw SessionManagementTestError.unsupportedMockCall
    }
    let homePath = dataSource.codexHome.standardizedFileURL.path
    var snapshots: [String: SessionManagementRolloutSnapshot] = [:]
    for thread in impact.affected {
        let rolloutURL = URL(fileURLWithPath: thread.rolloutPath)
            .standardizedFileURL
        var metadata = stat()
        guard rolloutURL.path.hasPrefix(homePath + "/"),
              Darwin.lstat(rolloutURL.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw SessionManagementTestError.unsupportedMockCall
        }
        let modifiedAt = Date(
            timeIntervalSince1970:
                TimeInterval(metadata.st_mtimespec.tv_sec)
                + TimeInterval(metadata.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        snapshots[thread.id] = SessionManagementRolloutSnapshot(
            threadID: thread.id,
            relativePath: String(rolloutURL.path.dropFirst(homePath.count + 1)),
            fileIdentity: SessionManagementFileIdentity(
                deviceID: UInt64(metadata.st_dev),
                fileID: UInt64(metadata.st_ino),
                size: Int64(metadata.st_size),
                modifiedAt: modifiedAt
            ),
            sha256: providerSyncSHA256Hex(try Data(contentsOf: rolloutURL))
        )
    }
    return SessionManagementDeletionConfirmation(
        impact: impact,
        codexHomeIdentity: homeIdentity,
        rolloutSnapshotsByThreadID: snapshots
    )
}

private func replacePathEntryWithIdenticalRegularFile(at url: URL) throws {
    let data = try Data(contentsOf: url)
    let replacement = url.deletingLastPathComponent().appendingPathComponent(
        ".\(url.lastPathComponent).replacement-\(UUID().uuidString)"
    )
    try data.write(to: replacement)
    var published = false
    defer {
        if !published {
            try? FileManager.default.removeItem(at: replacement)
        }
    }
    guard Darwin.rename(replacement.path, url.path) == 0 else {
        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [
                NSLocalizedDescriptionKey:
                    "atomic path replacement failed: "
                    + String(cString: strerror(errno)),
            ]
        )
    }
    published = true
}

private func sessionManagementJSONLine(
    _ object: [String: Any]
) throws -> Data {
    var data = try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys]
    )
    data.append(0x0A)
    return data
}
