import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  bestCodexCrowdRadarModel,
  crowdRadarModelLabel,
  normalizeCodexCrowdRadarPayload,
  pagedCodexCrowdRadarModels,
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
      { model: "gpt-5.6-terra", effort: "ultra", graded: 45, passed: 36, passRate: 0.795, cells: 45 },
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

test("crowd radar compacts DeepSeek variants for floating and detail labels", () => {
  assert.equal(crowdRadarModelLabel({ model: "DeepSeek V4 Flash", effort: "max" }), "DS F max");
  assert.equal(crowdRadarModelLabel({ model: "DeepSeek V4 Pro", effort: "high" }), "DS P high");
  assert.equal(crowdRadarModelLabel({ model: "DeepSeek R1", effort: "medium" }), "DS R1 medium");
  assert.equal(crowdRadarModelLabel({ model: "DSH V4 Flash", effort: "max" }), "DSH F max");
  assert.equal(crowdRadarModelLabel({ model: "DSH-V4-Pro", effort: "high" }), "DSH P high");
  assert.equal(crowdRadarModelLabel({ model: "grok-4.6", effort: "xhigh" }), "G4.6 XH");
  assert.equal(crowdRadarModelLabel({ model: "k3", effort: "high" }), "K3 H");
  assert.equal(crowdRadarModelLabel({ model: "glm-5.3", effort: "max" }), "GLM5.3 max");
});

test("crowd radar hides rankings with fewer than 45 judged samples", () => {
  const snapshot = {
    models: [
      { model: "grok-4.6", effort: "high", passRate: 0.9, scoreSamples: 44 },
      { model: "grok-4.6", effort: "xhigh", passRate: 0.8, scoreSamples: 45 },
    ],
    recentModels: [],
    realtimeAvailable: true,
  };
  assert.deepEqual(rankedCodexCrowdRadarModels(snapshot).map((row) => row.effort), ["xhigh"]);
});

test("crowd radar paginates three ranked results per page", () => {
  const models = Array.from({ length: 7 }, (_, index) => ({
    model: `model-${index + 1}`,
    effort: "high",
    passRate: (50 - index) / 50,
    scoreSamples: 50,
  }));
  const snapshot = { models, recentModels: [], realtimeAvailable: true };
  assert.deepEqual(pagedCodexCrowdRadarModels(snapshot, 0).map((row) => row.model), ["model-1", "model-2", "model-3"]);
  assert.deepEqual(pagedCodexCrowdRadarModels(snapshot, 1).map((row) => row.model), ["model-4", "model-5", "model-6"]);
  assert.deepEqual(pagedCodexCrowdRadarModels(snapshot, 2).map((row) => row.model), ["model-7"]);
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
  assert.deepEqual(rankedCodexCrowdRadarModels(snapshot, 2), []);
  assert.deepEqual(rankedCodexCrowdRadarModels(snapshot, 2, "recent"), []);
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
  assert.equal(snapshot.models.length, 0);
  assert.equal(snapshot.recentModels.length, 2);
  assert.deepEqual(snapshot.recentModels[0], {
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
  assert.equal(snapshot.recentModels.length, 2);
  assert.equal(snapshot.recentModels[1].passRate, 0.8);
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
  assert.deepEqual(snapshot.recentModels[0], {
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

test("crowd radar accepts the published intelligence-efficiency points fallback", () => {
  const snapshot = normalizeCodexCrowdRadarPayload({
    table: null,
    tableError: "live table unavailable",
    leaderboard: {
      source_updated_at: "2026-07-31T23:47:20+08:00",
      points: [{
        model: "gpt-5.6-sol",
        effort: "low",
        iq: 70.9821,
        passed: 53,
        valid_tasks: 112,
        latest_graded_at: "2026-07-31T14:54:08+00:00",
      }],
    },
  });

  assert.equal(snapshot.generatedAt, "2026-07-31T23:47:20+08:00");
  assert.equal(snapshot.taskCount, 112);
  assert.equal(snapshot.realtimeAvailable, false);
  assert.deepEqual(snapshot.recentModels[0], {
    model: "gpt-5.6-sol",
    effort: "low",
    graded: 112,
    passed: 53,
    passRate: 70.9821 / 150,
    cells: 112,
    scorePassed: 53,
    scoreSamples: 112,
    latestGradedAt: "2026-07-31T14:54:08+00:00",
  });
  assert.equal(snapshot.models.length, 0);
});

test("published or old cumulative points never become the realtime ranking", () => {
  const snapshot = normalizeCodexCrowdRadarPayload({
    table: null,
    tableError: "live table unavailable",
    leaderboard: {
      schema: 2,
      type: "distributed_intelligence_efficiency",
      source_updated_at: "2026-08-07T04:50:48+08:00",
      points: [{
        model: "gpt-5.6-sol",
        effort: "low",
        passed: 0,
        valid_tasks: 3,
        latest_graded_at: "2026-08-06T04:39:08+00:00",
      }],
    },
  });

  assert.equal(snapshot.realtimeAvailable, false);
  assert.deepEqual(rankedCodexCrowdRadarModels(snapshot), []);
  assert.deepEqual(rankedCodexCrowdRadarModels(snapshot, 1, "recent"), []);
});

test("recovery scheduling is short, bounded, and has no fourth retry", async () => {
  const source = readFileSync(new URL("./codexCrowdRadarClient.ts", import.meta.url), "utf8");
  assert.match(source, /crowdRadarReadInFlight/);
  assert.match(source, /crowdRadarReadFailure/);
  assert.match(source, /CROWD_RADAR_FAILURE_COOLDOWN_MS = 10_000/);
  const module = await import("./codexCrowdRadarClient.ts");
  assert.equal(module.nextCodexCrowdRadarRecoveryDelayMs(0), 2_000);
  assert.equal(module.nextCodexCrowdRadarRecoveryDelayMs(1), 8_000);
  assert.equal(module.nextCodexCrowdRadarRecoveryDelayMs(2), null);
});

test("crowd radar keeps source freshness and fallback errors visible", () => {
  const snapshot = normalizeCodexCrowdRadarPayload({
    observedAt: "2026-08-08T09:00:00Z",
    table: null,
    tableError: "Crowd Radar table sources failed: site timeout",
    tableProvenance: {
      source: "legacy-api",
      endpoint: "https://api.codexradar.com/api/v1/table",
      attempts: 1,
      fresh: true,
      stale: false,
      freshness_basis: "network_observation",
      fallbackUsed: true,
      sourceFailures: ["Crowd Radar table/site timeout"],
      attemptErrors: [],
      server_date: "Fri, 08 Aug 2026 09:00:00 GMT",
      server_age_seconds: "2",
    },
    leaderboard: {
      points: [{
        model: "gpt-5.6-luna",
        effort: "max",
        iq: 120,
        passed: 8,
        valid_tasks: 10,
      }],
    },
    leaderboardProvenance: {
      source: "published",
      endpoint: "https://codexradar.com/data/intelligence-efficiency.json",
      attempts: 2,
      fresh: true,
      stale: false,
      fallback_used: false,
      source_failures: [],
      attempt_errors: ["attempt 1: temporary transport failure"],
      server_age_seconds: 3,
    },
  });

  assert.equal(snapshot.provenance?.observedAt, "2026-08-08T09:00:00Z");
  assert.equal(snapshot.provenance?.table?.source, "legacy-api");
  assert.equal(snapshot.provenance?.table?.fresh, true);
  assert.equal(snapshot.provenance?.table?.stale, false);
  assert.equal(snapshot.provenance?.table?.freshnessBasis, "network_observation");
  assert.equal(snapshot.provenance?.table?.fallbackUsed, true);
  assert.equal(snapshot.provenance?.table?.serverAgeSeconds, 2);
  assert.equal(snapshot.provenance?.leaderboard?.attempts, 2);
  assert.equal(snapshot.provenance?.leaderboard?.attemptErrors.length, 1);
  assert.equal(snapshot.endpointErrors?.length, 3);
  assert.match(snapshot.endpointErrors?.[0] ?? "", /table sources failed/);
  assert.match(snapshot.endpointErrors?.[1] ?? "", /table\/site timeout/);
  assert.match(snapshot.endpointErrors?.[2] ?? "", /temporary transport failure/);
});

test("crowd radar keeps freshness unknown when cache headers are absent", () => {
  const snapshot = normalizeCodexCrowdRadarPayload({
    table: {
      combos: [{ model: "gpt-5.6-sol", effort: "low" }],
      tasks: [{ id: "one" }],
      cells: {
        "one|gpt-5.6-sol|low": { ran_by: [{ passed: true }] },
      },
    },
    tableProvenance: {
      fresh: null,
      stale: null,
      freshnessBasis: "network_observation",
    },
  });

  assert.equal(snapshot.provenance?.table?.fresh, null);
  assert.equal(snapshot.provenance?.table?.stale, null);
  assert.equal(snapshot.realtimeAvailable, true);
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
        scorePassed: 45,
        scoreSamples: 45,
        latestGradedAt: null,
      },
      {
        model: "gpt-5.6-sol",
        effort: "low",
        graded: 1,
        passed: 1,
        passRate: 1,
        cells: 1,
        scorePassed: 45,
        scoreSamples: 45,
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
