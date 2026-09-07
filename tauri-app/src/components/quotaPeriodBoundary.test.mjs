import test from "node:test";
import assert from "node:assert/strict";
import { firstCompleteQuotaBucketStart, lastCompleteQuotaBucketEnd } from "./quotaPeriodBoundary.ts";

test("every reset second retains all complete buckets at both period edges", () => {
  const base = 1_800_000_000;
  for (let offset = 0; offset < 300; offset++) {
    assert.equal(firstCompleteQuotaBucketStart(base + offset), base + (offset === 0 ? 0 : 300));
    assert.equal(lastCompleteQuotaBucketEnd(base + 604800 + offset), base + 604800);
  }
});
