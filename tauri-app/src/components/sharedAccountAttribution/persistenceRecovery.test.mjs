import assert from "node:assert/strict";
import test from "node:test";
import { preciseUsageContinuityStorageKey } from "../../state/preciseUsageContinuity.ts";
import { quarantineAndRebaselineAttributionPersistence } from "./persistenceRecovery.ts";

function storage() {
  const values = new Map();
  return {
    values,
    getItem(key) { return values.get(key) ?? null; },
    setItem(key, value) { values.set(key, value); },
    removeItem(key) { values.delete(key); },
  };
}

test("corrupt attribution persistence is quarantined and replaced by a rebaseline gap", () => {
  const target = storage();
  const segmentKey = "sharedAccountAttributionSegment:v7:deadbeef";
  const continuityKey = preciseUsageContinuityStorageKey("home-a");
  target.values.set(segmentKey, "{broken-segment");
  target.values.set(continuityKey, "{broken-continuity");

  const recovered = quarantineAndRebaselineAttributionPersistence(
    "home-a",
    [segmentKey, continuityKey],
    123,
    target,
  );
  assert.equal(recovered.healthy, true);
  assert.equal(recovered.quarantined, true);
  assert.equal(target.values.has(segmentKey), false);
  assert.match(target.values.get(recovered.quarantineKey), /broken-segment/);
  const gap = JSON.parse(target.values.get(continuityKey));
  assert.equal(gap.id, recovered.gapID);
  assert.equal(gap.detectedAtUnix, 123);
});

test("a concurrent repair is never removed by a stale quarantine attempt", () => {
  const values = new Map([["corrupt", "old"]]);
  let reads = 0;
  const target = {
    getItem(key) {
      if (key === "corrupt") {
        reads += 1;
        if (reads === 2) values.set(key, "new-valid-value");
      }
      return values.get(key) ?? null;
    },
    setItem(key, value) { values.set(key, value); },
    removeItem(key) { values.delete(key); },
  };
  const recovered = quarantineAndRebaselineAttributionPersistence(
    "home-a",
    ["corrupt"],
    123,
    target,
  );
  assert.equal(recovered.healthy, false);
  assert.equal(values.get("corrupt"), "new-valid-value");
});
