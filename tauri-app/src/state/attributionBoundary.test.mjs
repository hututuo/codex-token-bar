import assert from "node:assert/strict";
import test from "node:test";

import { canonicalAttributionBoundaryKey } from "./attributionBoundary.ts";

test("equivalent RFC3339 spellings share one five-minute attribution key", () => {
  const withMillis = canonicalAttributionBoundaryKey("2026-08-06T00:00:00.123Z");
  const onSecond = canonicalAttributionBoundaryKey("2026-08-06T00:00:00.000Z");
  const withOffset = canonicalAttributionBoundaryKey("2026-08-06T02:00:00.999+02:00");

  assert.equal(withMillis, onSecond);
  assert.equal(onSecond, withOffset);
});

test("timestamps in one five-minute bucket share a boundary", () => {
  assert.equal(
    canonicalAttributionBoundaryKey("2026-08-06T00:00:00.999Z"),
    canonicalAttributionBoundaryKey("2026-08-06T00:04:59.000Z"),
  );
  assert.notEqual(
    canonicalAttributionBoundaryKey("2026-08-06T00:00:00.999Z"),
    canonicalAttributionBoundaryKey("2026-08-06T00:05:00.000Z"),
  );
});

test("missing and non-RFC3339 values fail safe", () => {
  for (const value of [null, undefined, "", "bad-time", "2026-08-06", "123"]) {
    assert.equal(canonicalAttributionBoundaryKey(value), undefined, String(value));
  }
});
