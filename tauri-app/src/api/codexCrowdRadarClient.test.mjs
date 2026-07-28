import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  bestCodexCrowdRadarModel,
  crowdRadarModelLabel,
  normalizeCodexCrowdRadarPayload,
  rankedCodexCrowdRadarModels,
} from "./codexCrowdRadarClient.ts";

test("crowd radar picks the highest pass rate and formats model family", () => {
  const snapshot = {
    generatedAt: "2026-07-16T00:00:00Z",
    taskCount: 112,
    cellCount: 1904,
    contributorCount: 130,
    pendingGrades: 1,
    errorGrades: 7,
    models: [
      { model: "gpt-5.6-sol", effort: "max", graded: 79, passed: 53, passRate: 0.675, cells: 77 },
      { model: "gpt-5.6-luna", effort: "high", graded: 61, passed: 43, passRate: 0.705, cells: 60 },
      { model: "gpt-5.6-terra", effort: "ultra", graded: 45, passed: 36, passRate: 0.795, cells: 44 },
    ],
    recentModels: [],
    realtimeAvailable: true,
  };
  const best = bestCodexCrowdRadarModel(snapshot);
  const leaders = rankedCodexCrowdRadarModels(snapshot, 3);
  assert.deepEqual(leaders.map((row) => row.model), ["gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.6-sol"]);
  assert.equal(best?.model, "gpt-5.6-terra");
  assert.equal(crowdRadarModelLabel(best), "Terra ultra");
  assert.equal((best.passRate * 150).toFixed(1), "119.3");
});

test("crowd radar reads through the bounded native command instead of browser CORS", () => {
  const source = readFileSync(new URL("./codexCrowdRadarClient.ts", import.meta.url), "utf8");
  assert.match(source, /callCommandStrict<unknown>\(/);
  assert.match(source, /read_codex_crowd_radar_payload/);
  assert.match(source, /CROWD_RADAR_COMMAND_TIMEOUT_MS = 22_000/);
  assert.doesNotMatch(source, /fetch\(TABLE_ENDPOINT/);
  assert.doesNotMatch(source, /fetch\(LEADERBOARD_ENDPOINT/);
});

test("crowd radar uses each cell latest run by default and p/n for recent mode", () => {
  const snapshot = normalizeCodexCrowdRadarPayload({
    table: {
      baseline_generated_at: "2026-07-20T23:21:14Z",
      combos: [
        { model: "gpt-5.6-sol", effort: "max" },
        { model: "gpt-5.6-terra", effort: "ultra" },
      ],
      tasks: [{ id: "one" }, { id: "two" }],
      cells: {
        "one|gpt-5.6-sol|max": {
          n: 3,
          p: 1,
          ran_by: [{ passed: true, graded_at: "2026-07-22T20:00:00Z" }],
        },
        "two|gpt-5.6-sol|max": {
          n: 3,
          p: 0,
          ran_by: [{ passed: true, graded_at: "2026-07-22T23:00:00Z" }],
        },
        "one|gpt-5.6-terra|ultra": {
          n: 3,
          p: 3,
          ran_by: [{ passed: true, graded_at: "2026-07-22T21:00:00Z" }],
        },
        "two|gpt-5.6-terra|ultra": {
          n: 3,
          p: 3,
          ran_by: [{ passed: false, graded_at: "2026-07-22T22:00:00Z" }],
        },
      },
    },
    leaderboard: {
      models: [
        {
          model: "gpt-5.6-sol",
          effort: "max",
          graded: 440,
          passed: 288,
          cells: 112,
          cells_passed: 78,
          pass_rate: 0.696,
        },
        {
          model: "gpt-5.6-terra",
          effort: "ultra",
          graded: 700,
          passed: 500,
          cells: 112,
          cells_passed: 84,
          pass_rate: 0.75,
        },
      ],
      contributors: [{ login: "one" }, { login: "two" }],
      pending_grades: 3,
      error_grades: 4,
    },
  });

  assert.equal(snapshot.generatedAt, "2026-07-22T23:00:00Z");
  assert.equal(snapshot.taskCount, 2);
  assert.equal(snapshot.cellCount, 4);
  assert.equal(snapshot.contributorCount, 2);
  assert.equal(snapshot.pendingGrades, 3);
  assert.equal(snapshot.errorGrades, 4);
  assert.equal(snapshot.realtimeAvailable, true);
  assert.deepEqual(snapshot.models[0], {
    model: "gpt-5.6-sol",
    effort: "max",
    graded: 440,
    passed: 288,
    passRate: 1,
    cells: 112,
    scorePassed: 2,
    scoreSamples: 2,
    latestGradedAt: "2026-07-22T23:00:00Z",
  });
  assert.deepEqual(
    rankedCodexCrowdRadarModels(snapshot, 2).map((row) => row.model),
    ["gpt-5.6-sol", "gpt-5.6-terra"],
  );
  assert.deepEqual(
    rankedCodexCrowdRadarModels(snapshot, 2, "recent").map((row) => row.model),
    ["gpt-5.6-terra", "gpt-5.6-sol"],
  );
  assert.equal(snapshot.recentModels[0].scorePassed, 1);
  assert.equal(snapshot.recentModels[0].scoreSamples, 6);
});

test("crowd radar normalizer tolerates wrappers aliases strings maps and malformed rows", () => {
  const snapshot = normalizeCodexCrowdRadarPayload({
    table: {
      response: {
        data: {
          generated_at: "2026-07-21T00:00:00Z",
          task_list: { one: {}, two: {}, three: {} },
          cell_map: [{}, {}, {}, {}],
        },
      },
    },
    leaderboard: {
      payload: {
        result: {
          rankings: {
            "gpt-5.6-sol|max": {
              judged_count: "10",
              pass_count: "8",
              success_rate: "80%",
              task_results: { one: {}, two: {} },
            },
            terra: {
              model_name: "gpt-5.6-terra",
              reasoning_effort: "ultra",
              samples: "5",
              successes: "4",
              iq_score: "120",
              covered_tasks: "5",
            },
            broken: "not an object",
          },
          volunteers: { a: {}, b: {}, c: {} },
          queued_grades: "2",
          failed_grades: "1",
        },
      },
    },
  });

  assert.equal(snapshot.generatedAt, "2026-07-21T00:00:00Z");
  assert.equal(snapshot.taskCount, 3);
  assert.equal(snapshot.cellCount, 4);
  assert.equal(snapshot.contributorCount, 3);
  assert.equal(snapshot.pendingGrades, 2);
  assert.equal(snapshot.errorGrades, 1);
  assert.equal(snapshot.realtimeAvailable, false);
  assert.equal(snapshot.models.length, 2);
  assert.deepEqual(snapshot.models[0], {
    model: "gpt-5.6-sol",
    effort: "max",
    graded: 10,
    passed: 8,
    passRate: 0.8,
    cells: 2,
    scorePassed: 2,
    scoreSamples: 2,
    latestGradedAt: null,
  });
  assert.deepEqual(snapshot.recentModels, snapshot.models);
  assert.equal(snapshot.models[1].passRate, 0.8);
});

test("crowd radar normalizer derives votes from task maps and rejects meaningless payloads", () => {
  const snapshot = normalizeCodexCrowdRadarPayload({
    table: null,
    tableError: "table unavailable",
    leaderboard: {
      data: {
        model_stats: [{
          name: "gpt-5.6-luna-high",
          tasks: {
            one: { votes: "3", pass_votes: "2" },
            two: { votes: 2, pass_votes: 2 },
          },
        }],
        tasks: ["one", "two"],
      },
    },
  });
  assert.deepEqual(snapshot.models[0], {
    model: "gpt-5.6-luna",
    effort: "high",
    graded: 5,
    passed: 4,
    passRate: 0.8,
    cells: 2,
    scorePassed: 2,
    scoreSamples: 2,
    latestGradedAt: null,
  });
  assert.equal(snapshot.taskCount, 2);
  assert.equal(snapshot.realtimeAvailable, false);

  assert.throws(
    () => normalizeCodexCrowdRadarPayload({
      table: {},
      leaderboard: null,
      leaderboardError: "leaderboard unavailable",
    }),
    /leaderboard unavailable/,
  );
});

test("crowd radar table remains usable without leaderboard and accepts string task ids", () => {
  const snapshot = normalizeCodexCrowdRadarPayload({
    table: {
      combos: [{ model: "gpt-5.6-sol", effort: "high" }],
      tasks: ["one", "two"],
      cells: {
        "one|gpt-5.6-sol|high": {
          n: 3,
          p: 2,
          ran_by: [{ passed: true, graded_at: "2026-07-23T01:00:00Z" }],
        },
        "two|gpt-5.6-sol|high": {
          n: 2,
          p: 1,
          ran_by: [{ passed: false, graded_at: "2026-07-23T02:00:00Z" }],
        },
      },
    },
    leaderboard: null,
    leaderboardError: "leaderboard unavailable",
  });

  assert.equal(snapshot.realtimeAvailable, true);
  assert.equal(snapshot.generatedAt, "2026-07-23T02:00:00Z");
  assert.equal(snapshot.models[0].graded, 2);
  assert.equal(snapshot.models[0].scorePassed, 1);
  assert.equal(snapshot.models[0].scoreSamples, 2);
  assert.equal(snapshot.recentModels[0].scorePassed, 3);
  assert.equal(snapshot.recentModels[0].scoreSamples, 5);
});

test("crowd radar tie order ignores cumulative graded totals", () => {
  const snapshot = {
    generatedAt: "",
    taskCount: 1,
    cellCount: 2,
    contributorCount: 0,
    pendingGrades: 0,
    errorGrades: 0,
    models: [
      {
        model: "gpt-5.6-terra",
        effort: "ultra",
        graded: 9_999,
        passed: 9_999,
        passRate: 1,
        cells: 1,
        scorePassed: 1,
        scoreSamples: 1,
        latestGradedAt: null,
      },
      {
        model: "gpt-5.6-sol",
        effort: "low",
        graded: 1,
        passed: 1,
        passRate: 1,
        cells: 1,
        scorePassed: 1,
        scoreSamples: 1,
        latestGradedAt: null,
      },
    ],
    recentModels: [],
    realtimeAvailable: true,
  };

  assert.deepEqual(
    rankedCodexCrowdRadarModels(snapshot, 2).map((row) => row.model),
    ["gpt-5.6-sol", "gpt-5.6-terra"],
  );
});
