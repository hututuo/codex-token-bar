import XCTest
@testable import CodexTokenBar

final class CodexCrowdRadarTests: XCTestCase {
    func testBestModelUsesPassRateAndConvertsToIQ() {
        let snapshot = CodexCrowdRadarSnapshot(
            generatedAt: "2026-07-16T00:00:00Z",
            taskCount: 112,
            cellCount: 1_904,
            contributorCount: 130,
            pendingGrades: 1,
            errorGrades: 7,
            models: [
                CodexCrowdRadarModel(model: "gpt-5.6-sol", effort: "max", graded: 79, passed: 53, passRate: 0.675, cells: 77),
                CodexCrowdRadarModel(model: "gpt-5.6-luna", effort: "high", graded: 61, passed: 43, passRate: 0.705, cells: 60),
                CodexCrowdRadarModel(model: "gpt-5.6-terra", effort: "ultra", graded: 45, passed: 36, passRate: 0.795, cells: 44)
            ]
        )
        XCTAssertEqual(snapshot.rankedModels.map(\.label), ["Terra ultra", "Luna high", "Sol max"])
        XCTAssertEqual(snapshot.bestModel?.label, "Terra ultra")
        XCTAssertEqual(snapshot.bestModel?.iq ?? 0, 119.25, accuracy: 0.001)
    }

    func testParserDecodesCurrentDirectResponseShape() throws {
        let table = Data(#"""
        {
          "baseline_generated_at": "2026-07-20T23:21:14Z",
          "combos": [
            {"model":"gpt-5.6-sol","effort":"max"},
            {"model":"gpt-5.6-terra","effort":"ultra"}
          ],
          "tasks": [{"id":"one"},{"id":"two"}],
          "cells": {
            "one|gpt-5.6-sol|max": {
              "n":3,"p":1,
              "ran_by":[{"passed":true,"graded_at":"2026-07-22T20:00:00Z"}]
            },
            "two|gpt-5.6-sol|max": {
              "n":3,"p":0,
              "ran_by":[{"passed":true,"graded_at":"2026-07-22T23:00:00Z"}]
            },
            "one|gpt-5.6-terra|ultra": {
              "n":3,"p":3,
              "ran_by":[{"passed":true,"graded_at":"2026-07-22T21:00:00Z"}]
            },
            "two|gpt-5.6-terra|ultra": {
              "n":3,"p":3,
              "ran_by":[{"passed":false,"graded_at":"2026-07-22T22:00:00Z"}]
            }
          }
        }
        """#.utf8)
        let leaderboard = Data(#"""
        {
          "models": [
            {
              "model":"gpt-5.6-sol","effort":"max","graded":440,
              "passed":288,"cells":112,"cells_passed":78,"pass_rate":0.696
            },
            {
              "model":"gpt-5.6-terra","effort":"ultra","graded":700,
              "passed":500,"cells":112,"cells_passed":84,"pass_rate":0.75
            }
          ],
          "contributors": [{"login":"one"},{"login":"two"}],
          "pending_grades": 3,
          "error_grades": 4
        }
        """#.utf8)

        let snapshot = try CodexCrowdRadarParser.decode(
            tableData: table,
            leaderboardData: leaderboard
        )

        XCTAssertEqual(snapshot.generatedAt, "2026-07-22T23:00:00Z")
        XCTAssertEqual(snapshot.taskCount, 2)
        XCTAssertEqual(snapshot.cellCount, 4)
        XCTAssertEqual(snapshot.contributorCount, 2)
        XCTAssertEqual(snapshot.pendingGrades, 3)
        XCTAssertEqual(snapshot.errorGrades, 4)
        XCTAssertTrue(snapshot.realtimeAvailable)
        XCTAssertEqual(snapshot.models.first?.model, "gpt-5.6-sol")
        XCTAssertEqual(snapshot.models.first?.graded, 440)
        XCTAssertEqual(snapshot.models.first?.scorePassed, 2)
        XCTAssertEqual(snapshot.models.first?.scoreSamples, 2)
        XCTAssertEqual(snapshot.models.first?.passRate ?? 0, 1, accuracy: 0.0001)
        XCTAssertEqual(
            snapshot.rankedModels(for: .realtime).map(\.model),
            ["gpt-5.6-sol", "gpt-5.6-terra"]
        )
        XCTAssertEqual(
            snapshot.rankedModels(for: .recent).map(\.model),
            ["gpt-5.6-terra", "gpt-5.6-sol"]
        )
        XCTAssertEqual(snapshot.recentModels.first?.scorePassed, 1)
        XCTAssertEqual(snapshot.recentModels.first?.scoreSamples, 6)
    }

    func testParserToleratesWrappersAliasesStringsMapsAndMalformedRows() throws {
        let table = Data(#"""
        {"response":{"data":{
          "generated_at":"2026-07-21T00:00:00Z",
          "task_list":{"one":{},"two":{},"three":{}},
          "cell_map":[{},{},{},{}]
        }}}
        """#.utf8)
        let leaderboard = Data(#"""
        {"payload":{"result":{
          "rankings":{
            "gpt-5.6-sol|max":{
              "judged_count":"10","pass_count":"8","success_rate":"80%",
              "task_results":{"one":{},"two":{}}
            },
            "terra":{
              "model_name":"gpt-5.6-terra","reasoning_effort":"ultra",
              "samples":"5","successes":"4","iq_score":"120","covered_tasks":"5"
            },
            "broken":"not an object"
          },
          "volunteers":{"a":{},"b":{},"c":{}},
          "queued_grades":"2",
          "failed_grades":"1"
        }}}
        """#.utf8)

        let snapshot = try CodexCrowdRadarParser.decode(
            tableData: table,
            leaderboardData: leaderboard
        )

        XCTAssertEqual(snapshot.generatedAt, "2026-07-21T00:00:00Z")
        XCTAssertEqual(snapshot.taskCount, 3)
        XCTAssertEqual(snapshot.cellCount, 4)
        XCTAssertEqual(snapshot.contributorCount, 3)
        XCTAssertEqual(snapshot.pendingGrades, 2)
        XCTAssertEqual(snapshot.errorGrades, 1)
        XCTAssertFalse(snapshot.realtimeAvailable)
        XCTAssertTrue(snapshot.models.isEmpty)
        let sol = try XCTUnwrap(snapshot.recentModels.first { $0.model == "gpt-5.6-sol" })
        XCTAssertEqual(sol.effort, "max")
        XCTAssertEqual(sol.graded, 10)
        XCTAssertEqual(sol.passed, 8)
        XCTAssertEqual(sol.passRate, 0.8, accuracy: 0.0001)
        XCTAssertEqual(sol.cells, 2)
        let terra = try XCTUnwrap(snapshot.recentModels.first { $0.model == "gpt-5.6-terra" })
        XCTAssertEqual(terra.passRate, 0.8, accuracy: 0.0001)
    }

    func testParserDerivesVotesFromTaskMapWhenTableIsUnavailable() throws {
        let leaderboard = Data(#"""
        {"data":{
          "model_stats":[{
            "name":"gpt-5.6-luna-high",
            "tasks":{
              "one":{"votes":"3","pass_votes":"2"},
              "two":{"votes":2,"pass_votes":2}
            }
          }],
          "tasks":["one","two"]
        }}
        """#.utf8)

        let snapshot = try CodexCrowdRadarParser.decode(
            tableData: nil,
            leaderboardData: leaderboard
        )

        let luna = try XCTUnwrap(snapshot.recentModels.first)
        XCTAssertEqual(luna.model, "gpt-5.6-luna")
        XCTAssertEqual(luna.effort, "high")
        XCTAssertEqual(luna.graded, 5)
        XCTAssertEqual(luna.passed, 4)
        XCTAssertEqual(luna.passRate, 0.8, accuracy: 0.0001)
        XCTAssertEqual(luna.cells, 2)
        XCTAssertEqual(snapshot.taskCount, 2)
        XCTAssertFalse(snapshot.realtimeAvailable)
    }

    func testParserKeepsLeaderboardWhenOptionalTableJSONIsMalformed() throws {
        let leaderboard = Data(#"""
        {"models":[{
          "model":"gpt-5.6-sol","effort":"max","graded":10,
          "passed":8,"pass_rate":0.8,"cells":2
        }]}
        """#.utf8)

        let snapshot = try CodexCrowdRadarParser.decode(
            tableData: Data("not-json".utf8),
            leaderboardData: leaderboard
        )

        XCTAssertEqual(snapshot.recentModels.first?.model, "gpt-5.6-sol")
        XCTAssertEqual(snapshot.taskCount, 0)
        XCTAssertEqual(snapshot.cellCount, 0)
        XCTAssertFalse(snapshot.realtimeAvailable)
    }

    func testParserAcceptsPublishedPointsWithoutPresentingThemAsRealtime() throws {
        let leaderboard = Data(#"""
        {
          "schema": 2,
          "type": "distributed_intelligence_efficiency",
          "source_updated_at": "2026-08-07T04:50:48+08:00",
          "points": [{
            "model": "gpt-5.6-sol",
            "effort": "low",
            "passed": 0,
            "valid_tasks": 3,
            "latest_graded_at": "2026-08-06T04:39:08+00:00"
          }]
        }
        """#.utf8)

        let snapshot = try CodexCrowdRadarParser.decode(
            tableData: nil,
            leaderboardData: leaderboard
        )

        XCTAssertEqual(snapshot.generatedAt, "2026-08-07T04:50:48+08:00")
        XCTAssertFalse(snapshot.realtimeAvailable)
        XCTAssertTrue(snapshot.rankedModels(for: .realtime).isEmpty)
        let recent = try XCTUnwrap(snapshot.rankedModels(for: .recent).first)
        XCTAssertEqual(recent.model, "gpt-5.6-sol")
        XCTAssertEqual(recent.scorePassed, 0)
        XCTAssertEqual(recent.scoreSamples, 3)
        XCTAssertEqual(recent.passRate, 0, accuracy: 0.0001)
    }

    func testParserKeepsTableWhenLeaderboardIsUnavailableAndAcceptsStringTaskIDs() throws {
        let table = Data(#"""
        {
          "combos":[{"model":"gpt-5.6-sol","effort":"high"}],
          "tasks":["one","two"],
          "cells":{
            "one|gpt-5.6-sol|high":{
              "n":3,"p":2,
              "ran_by":[{"passed":true,"graded_at":"2026-07-23T01:00:00Z"}]
            },
            "two|gpt-5.6-sol|high":{
              "n":2,"p":1,
              "ran_by":[{"passed":false,"graded_at":"2026-07-23T02:00:00Z"}]
            }
          }
        }
        """#.utf8)

        let snapshot = try CodexCrowdRadarParser.decode(
            tableData: table,
            leaderboardData: nil
        )

        XCTAssertTrue(snapshot.realtimeAvailable)
        XCTAssertEqual(snapshot.generatedAt, "2026-07-23T02:00:00Z")
        XCTAssertEqual(snapshot.models.first?.graded, 2)
        XCTAssertEqual(snapshot.models.first?.scorePassed, 1)
        XCTAssertEqual(snapshot.models.first?.scoreSamples, 2)
        XCTAssertEqual(snapshot.recentModels.first?.scorePassed, 3)
        XCTAssertEqual(snapshot.recentModels.first?.scoreSamples, 5)
    }

    func testTieOrderDoesNotUseCumulativeGradedTotals() {
        let snapshot = CodexCrowdRadarSnapshot(
            generatedAt: "",
            taskCount: 1,
            cellCount: 2,
            contributorCount: 0,
            pendingGrades: 0,
            errorGrades: 0,
            models: [
                CodexCrowdRadarModel(
                    model: "gpt-5.6-terra",
                    effort: "ultra",
                    graded: 9_999,
                    passed: 9_999,
                    passRate: 1,
                    cells: 1,
                    scorePassed: 1,
                    scoreSamples: 1
                ),
                CodexCrowdRadarModel(
                    model: "gpt-5.6-sol",
                    effort: "low",
                    graded: 1,
                    passed: 1,
                    passRate: 1,
                    cells: 1,
                    scorePassed: 1,
                    scoreSamples: 1
                )
            ]
        )

        XCTAssertEqual(snapshot.rankedModels.map(\.model), ["gpt-5.6-sol", "gpt-5.6-terra"])
    }

    func testParserRejectsPayloadWithoutRankableModels() throws {
        let leaderboard = Data(#"{"models":[{"model":"gpt-5.6-sol","effort":"max"}]}"#.utf8)
        XCTAssertThrowsError(try CodexCrowdRadarParser.decode(
            tableData: nil,
            leaderboardData: leaderboard
        )) { error in
            XCTAssertEqual(error as? CodexRadarReaderError, .emptyPayload)
        }
    }

    func testLiveCurrentCrowdRadarPayloadWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["CODEX_TOKEN_BAR_RUN_LIVE_CROWD_RADAR_TEST"] == "1" else {
            throw XCTSkip("Set CODEX_TOKEN_BAR_RUN_LIVE_CROWD_RADAR_TEST=1 for the live public API test")
        }
        let snapshot = try await LiveCodexCrowdRadarReader().readCrowdRadar()
        XCTAssertGreaterThanOrEqual(snapshot.models.count, 3)
        XCTAssertGreaterThanOrEqual(snapshot.rankedModels.count, 3)
        XCTAssertGreaterThan(snapshot.taskCount, 0)
        XCTAssertGreaterThan(snapshot.cellCount, 0)
    }
}
