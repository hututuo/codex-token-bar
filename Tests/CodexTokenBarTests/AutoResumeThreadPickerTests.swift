import Foundation
import XCTest
@testable import CodexTokenBar

final class AutoResumeThreadPickerTests: XCTestCase {
    func testGroupsByProjectWithoutDeduplicatingAndShowsOneHundredRecentTitles() {
        let mainCWD = "/Users/test/main-project"
        let mainThreads = (0..<125).map { index in
            AutoResumeThreadDescriptor(
                id: "main-\(index)",
                title: "完整会话标题 \(index)",
                cwd: mainCWD,
                updatedAt: Date(timeIntervalSince1970: TimeInterval(10_000 - index))
            )
        }
        let threads = mainThreads + [
            AutoResumeThreadDescriptor(
                id: "other-1",
                title: "另一个项目",
                cwd: "/Users/test/other-project",
                updatedAt: Date(timeIntervalSince1970: 20_000)
            ),
        ]

        let projects = AutoResumeThreadPicker.projects(from: threads)
        XCTAssertEqual(projects.count, 2)
        XCTAssertEqual(projects.first?.cwd, "/Users/test/other-project")
        XCTAssertEqual(projects.first { $0.cwd == mainCWD }?.threadCount, 125)

        let projectID = AutoResumeThreadPicker.projectID(for: "\(mainCWD)/")
        XCTAssertEqual(AutoResumeThreadPicker.threads(from: threads, projectID: projectID).count, 125)
        let visible = AutoResumeThreadPicker.visibleThreads(
            from: threads,
            projectID: projectID,
            query: ""
        )
        XCTAssertEqual(AutoResumeThreadPicker.visibleThreadLimit, 100)
        XCTAssertEqual(visible.count, 100)
        XCTAssertEqual(visible.prefix(3).map(\.displayTitle), [
            "完整会话标题 0",
            "完整会话标题 1",
            "完整会话标题 2",
        ])
    }

    func testSearchesWholeProjectBeforeLimitAndRetainsSavedOlderSelection() {
        let cwd = "/Users/test/project"
        let threads = (0..<130).map { index in
            AutoResumeThreadDescriptor(
                id: "thread-\(index)",
                title: index == 125 ? "只在旧会话里的针" : "普通会话 \(index)",
                cwd: cwd,
                updatedAt: Date(timeIntervalSince1970: TimeInterval(1_000 - index))
            )
        }
        let projectID = AutoResumeThreadPicker.projectID(for: cwd)

        XCTAssertEqual(
            AutoResumeThreadPicker.visibleThreads(
                from: threads,
                projectID: projectID,
                query: "针"
            ).map(\.id),
            ["thread-125"]
        )

        let withOldSelection = AutoResumeThreadPicker.visibleThreads(
            from: threads,
            projectID: projectID,
            query: "",
            selectedThreadID: "thread-125"
        )
        XCTAssertEqual(withOldSelection.count, 100)
        XCTAssertEqual(withOldSelection.last?.id, "thread-125")
    }
}
