import assert from "node:assert/strict";
import test from "node:test";
import {
  attributionPersistenceFenceIsCurrent,
  attributionPersistenceOwnerInitializedStorageKey,
  attributionPersistenceOwnerStorageKey,
  holdAttributionPersistenceLock,
  publishAttributionPersistenceOwnerFence,
  readAttributionPersistenceOwnerState,
} from "./persistenceOwner.ts";

const OWNER_A = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const OWNER_B = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";

function storage() {
  const values = new Map();
  return {
    values,
    getItem(key) { return values.get(key) ?? null; },
    setItem(key, value) { values.set(key, value); },
    removeItem(key) { values.delete(key); },
  };
}

test("an exclusive holder publishes a verifiable fencing generation", async () => {
  const target = storage();
  const abort = new AbortController();
  let first;
  await holdAttributionPersistenceLock("home-a", abort.signal, async () => {
    first = publishAttributionPersistenceOwnerFence("home-a", OWNER_A, 1_000, 500, target);
    assert.equal(first.healthy, true);
    assert.equal(first.isOwner, true);
    assert.equal(first.transition, "initialize");
    assert.equal(attributionPersistenceFenceIsCurrent("home-a", first.lease, target), true);
  });
});

test("exclusive lock serializes takeover and the old fence fails closed", async () => {
  const target = storage();
  const abortA = new AbortController();
  const abortB = new AbortController();
  let releaseA;
  const holdA = new Promise((resolve) => { releaseA = resolve; });
  let enteredA;
  const acquiredA = new Promise((resolve) => { enteredA = resolve; });
  let first;
  const operationA = holdAttributionPersistenceLock("home-a", abortA.signal, async () => {
    first = publishAttributionPersistenceOwnerFence("home-a", OWNER_A, 1_000, 100, target);
    enteredA();
    await holdA;
  });
  await acquiredA;

  let bEntered = false;
  let takeover;
  const operationB = holdAttributionPersistenceLock("home-a", abortB.signal, async () => {
    bEntered = true;
    takeover = publishAttributionPersistenceOwnerFence("home-a", OWNER_B, 1_101, 100, target);
  });
  await Promise.resolve();
  assert.equal(bEntered, false, "the second writer must wait for the first lock holder");
  releaseA();
  await operationA;
  await operationB;

  assert.equal(takeover.healthy, true);
  assert.equal(takeover.isOwner, true);
  assert.equal(takeover.transition, "takeover");
  assert.equal(takeover.lease.sequence, first.lease.sequence + 1);
  assert.notEqual(takeover.lease.observationEpoch, first.lease.observationEpoch);
  assert.equal(attributionPersistenceFenceIsCurrent("home-a", first.lease, target), false);
  assert.equal(attributionPersistenceFenceIsCurrent("home-a", takeover.lease, target), true);
  assert.equal(readAttributionPersistenceOwnerState("home-a", target).lease.ownerID, OWNER_B);
});

test("a corrupt owner lease fails closed for quarantine instead of being overwritten", () => {
  const target = storage();
  const key = attributionPersistenceOwnerStorageKey("home-a");
  target.values.set(key, "{broken");
  assert.equal(readAttributionPersistenceOwnerState("home-a", target).healthy, false);
  const claim = publishAttributionPersistenceOwnerFence("home-a", OWNER_A, 1_000, 100, target);
  assert.equal(claim.healthy, false);
  assert.equal(target.values.get(key), "{broken");
});

test("a missing owner row after initialization is fenced as takeover, not first use", () => {
  const target = storage();
  const first = publishAttributionPersistenceOwnerFence(
    "home-a",
    OWNER_A,
    1_000,
    100,
    target,
  );
  target.removeItem(attributionPersistenceOwnerStorageKey("home-a"));

  const replacement = publishAttributionPersistenceOwnerFence(
    "home-a",
    OWNER_B,
    1_101,
    100,
    target,
  );
  assert.equal(first.transition, "initialize");
  assert.equal(replacement.transition, "takeover");
  assert.equal(replacement.isOwner, true);
  assert.equal(attributionPersistenceFenceIsCurrent("home-a", first.lease, target), false);
});

test("a corrupt initialization marker cannot be rewritten as first use", () => {
  const target = storage();
  const markerKey = attributionPersistenceOwnerInitializedStorageKey("home-a");
  target.setItem(markerKey, "broken");
  const claim = publishAttributionPersistenceOwnerFence(
    "home-a",
    OWNER_A,
    1_000,
    100,
    target,
  );
  assert.equal(claim.healthy, false);
  assert.equal(claim.isOwner, false);
  assert.equal(target.getItem(markerKey), "broken");
});

test("deleting the initialization marker invalidates an otherwise intact fence", () => {
  const target = storage();
  const claim = publishAttributionPersistenceOwnerFence(
    "home-a",
    OWNER_A,
    1_000,
    100,
    target,
  );
  target.removeItem(attributionPersistenceOwnerInitializedStorageKey("home-a"));
  assert.equal(attributionPersistenceFenceIsCurrent("home-a", claim.lease, target), false);
  const replacement = publishAttributionPersistenceOwnerFence(
    "home-a",
    OWNER_B,
    1_101,
    100,
    target,
  );
  assert.equal(replacement.transition, "takeover");
});
