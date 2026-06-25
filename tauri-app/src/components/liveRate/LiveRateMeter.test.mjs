import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("live rate meter keeps one focused rate instrument with configurable full scale", async () => {
  const source = await readFile(new URL("./LiveRateMeter.tsx", import.meta.url), "utf8");

  assert.match(source, /fullScale: number/);
  assert.match(source, /onFullScaleChange/);
  assert.match(source, /量程 \{scaleLimit\} tok\/s/);
  assert.match(source, /className="rate-scale-slider"/);
  assert.match(source, /min="50"/);
  assert.match(source, /max="400"/);
  assert.doesNotMatch(source, /metric-card/);
  assert.doesNotMatch(source, /todayTokens/);
  assert.doesNotMatch(source, /requestCount/);
});
