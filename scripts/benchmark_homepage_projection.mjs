#!/usr/bin/env node
import assert from "node:assert/strict";
import { mkdir, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { performance } from "node:perf_hooks";
import { withSsrModules } from "../tauri-app/src/test/ssrHarness.mjs";

// Synthetic numeric-only inputs. No app startup, history read, database, or network.
// A timing report is evidence about this pure projection, not screen-presented FPS.
const args = process.argv.slice(2);
assert.ok(args.length === 0 || args.length === 2 && args[0] === "--output",
  "Usage: node scripts/benchmark_homepage_projection.mjs [--output report.json]");
const asOf = Date.parse("2026-10-30T08:00:00Z") / 1000;
const report = await withSsrModules(async load => {
  const { emptyDashboardSnapshot } = await load("/src/api/fallback/dashboardFallback.ts");
  const { projectOriginalDashboard } = await load("/src/multiClient/originalDashboardProjection.ts");
  const results = [];
  for (const count of [288, 8640]) {
    const original = emptyDashboardSnapshot();
    original.generatedAt = new Date(asOf * 1000).toISOString();
    original.recentUsage24h = Array.from({ length: count }, (_, index) => point(asOf - (count - index - 1) * 300));
    original.recentUsage7d = original.recentUsage24h.filter((_, index) => index % 12 === 0);
    original.recentUsage30d = original.recentUsage24h.filter((_, index) => index % 72 === 0);
    const clients = {
      preferences: [], diagnostics: [], updatedAt: original.generatedAt,
      summaries: [{ client: "claudeCode", model: "claude-sonnet-4-6", inputTokens: count * 1000,
        outputTokens: count * 200, cacheReadTokens: count * 800, cacheWriteTokens: 0,
        requests: count, cacheReadComplete: true, lastSeen: original.generatedAt }],
      todaySummaries: [], sevenDaySummaries: [],
      dailyBuckets: Array.from({ length: Math.ceil(count / 288) }, (_, index) => ({
        client: "claudeCode", startUnix: asOf - index * 86400,
        inputTokens: 1000, outputTokens: 200, cacheReadTokens: 800, cacheWriteTokens: 0, requests: 1,
      })),
      trendBuckets: original.recentUsage24h.map(row => ({
        client: "claudeCode", startUnix: row.startUnix,
        inputTokens: 1000, outputTokens: 200, cacheReadTokens: 800, cacheWriteTokens: 0, requests: 1,
      })),
    };
    const allowed = ["codex", "claudeCode"];
    let output;
    const prepare = () => { output = projectOriginalDashboard(original, clients, allowed); };
    for (let index = 0; index < 4; index += 1) prepare();
    const samples = [];
    for (let index = 0; index < 20; index += 1) {
      const started = performance.now();
      prepare();
      samples.push(performance.now() - started);
    }
    assert.equal(output.recentUsage24h.length, count, "every source bin must remain represented");
    assert.equal(output.recentUsage24h.reduce((total, row) => total + row.tokens, 0), count * 2400);
    assert.equal(output.recentUsage24h.reduce((total, row) => total + row.calls, 0), count * 2);
    assert.equal(output.recentUsage24h.at(-1).cacheHitRate, 0.8);
    const sorted = samples.toSorted((a, b) => a - b);
    results.push({ inputCodexBins: count, inputClientBins: count, outputBins: output.recentUsage24h.length,
      samples: samples.length, medianMs: sorted[10], p95Ms: sorted[18], maxMs: sorted.at(-1),
      preservedTokens: output.recentUsage24h.reduce((total, row) => total + row.tokens, 0) });
  }
  return { fixture: "synthetic numeric Codex + Claude CLI, full represented history",
    node: process.version, asOf: new Date(asOf * 1000).toISOString(), results,
    note: "Pure main-thread projection timings only; excludes React rendering, native SwiftUI, and presented FPS. Each redundant projection costs another full call on a source publication." };
});
const serialized = JSON.stringify(report, null, 2) + "\n";
if (args.length) {
  const destination = resolve(args[1]);
  await mkdir(dirname(destination), { recursive: true });
  await writeFile(destination, serialized);
}
process.stdout.write(serialized);

function point(startUnix) {
  return {
    startUnix, label: new Date(startUnix * 1000).toISOString(), tokens: 1200, calls: 1,
    inputTokens: 1000, cachedInputTokens: 800, outputTokens: 200, cacheHitRate: 0.8,
    fiveHourRemainingPercent: null, sevenDayRemainingPercent: null,
  };
}
