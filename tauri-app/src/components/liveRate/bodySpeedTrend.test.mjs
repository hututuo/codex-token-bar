import assert from "node:assert/strict";
import test from "node:test";
import { withSsrModules } from "../../test/ssrHarness.mjs";

test("speed trend separates models and leaves unmeasured buckets disconnected", async () => {
    await withSsrModules(async load => {
        const { trendSegments } = await load("/src/components/liveRate/BodySpeedTrend.tsx");
        const p = (model, bucketStart, tokensPerSecond = 50) => ({ model, bucketStart, tokensPerSecond, outputTokens: 100, durationSeconds: 2, sampleCount: 1 });
        const result = trendSegments([p("a", 0), p("b", 0), p("a", 300), p("a", 900), p("a", 1200, NaN)], 300);
        assert.deepEqual(result.map(rows => rows.map(p => [p.model, p.bucketStart])), [[["a", 0], ["a", 300]], [["a", 900]], [["b", 0]]]);
    });
});
