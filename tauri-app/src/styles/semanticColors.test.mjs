import assert from "node:assert/strict";
import test from "node:test";

import {
  quotaPaceAccent,
  radarActionAccent,
  radarScoreAccent,
  radarScorePercent,
  semanticMetricColor,
  semanticMetricRgb,
} from "./semanticColors.ts";

test("semantic metric colors move continuously from red through amber and green to blue", () => {
  assert.deepEqual(semanticMetricRgb(0), { red: 202, green: 60, blue: 73 });
  assert.deepEqual(semanticMetricRgb(35), { red: 204, green: 139, blue: 38 });
  assert.deepEqual(semanticMetricRgb(70), { red: 31, green: 158, blue: 94 });
  assert.deepEqual(semanticMetricRgb(100), { red: 20, green: 105, blue: 204 });
  assert.deepEqual(semanticMetricRgb(52.5), { red: 118, green: 149, blue: 66 });
  assert.equal(semanticMetricColor(100), "rgb(20 105 204)");
});

test("semantic metric colors clamp invalid and out-of-range values", () => {
  assert.deepEqual(semanticMetricRgb(Number.NaN), semanticMetricRgb(0));
  assert.deepEqual(semanticMetricRgb(-20), semanticMetricRgb(0));
  assert.deepEqual(semanticMetricRgb(140), semanticMetricRgb(100));
});

test("radar score prefers the executed task ratio and falls back to normalized IQ", () => {
  assert.equal(radarScorePercent({ passed: 8, tasks: 10, score: 25 }), 80);
  assert.equal(radarScorePercent({ passed: 0, tasks: 0, score: 150 }), 100);
  assert.equal(radarScorePercent({ passed: 0, tasks: 0, score: 75 }), 50);
  assert.equal(radarScoreAccent({ passed: 10, tasks: 10, score: 150 }), "rgb(31 158 94)");
});

test("actions and pace labels use restrained fixed semantic accents", () => {
  assert.equal(radarActionAccent("wait"), "rgb(204 139 38)");
  assert.equal(radarActionAccent("run"), "rgb(31 158 94)");
  assert.equal(radarActionAccent("closed"), "rgb(202 60 73)");
  assert.equal(radarActionAccent("unknown"), "rgb(20 105 204)");
  assert.equal(quotaPaceAccent("用得太快，先省着"), "rgb(202 60 73)");
  assert.equal(quotaPaceAccent("最后几小时，别梭哈"), "rgb(202 60 73)");
  assert.equal(quotaPaceAccent("节奏很好"), "rgb(31 158 94)");
  assert.equal(quotaPaceAccent("余量很足，使劲蹬"), "rgb(20 105 204)");
});
