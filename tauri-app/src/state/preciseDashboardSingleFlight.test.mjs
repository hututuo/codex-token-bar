import assert from "node:assert/strict";
import test from "node:test";

import { loadPreciseDashboardSingleFlight } from "./preciseDashboardSingleFlight.ts";

test("precise dashboard requests coalesce and run at most one trailing refresh", async () => {
  const token = sourceToken("single-flight");
  const loads = [];
  let invocationCount = 0;
  const loader = () => {
    invocationCount += 1;
    const pending = deferred();
    loads.push(pending);
    return pending.promise;
  };

  const requests = Array.from(
    { length: 5 },
    () => loadPreciseDashboardSingleFlight(token, loader),
  );
  assert.equal(invocationCount, 1);
  requests.forEach((request) => assert.equal(request.result, requests[0].result));

  loads[0].resolve({ revision: 1 });
  await nextTurn();
  assert.equal(invocationCount, 2, "a burst must schedule exactly one trailing refresh");

  const duringTrailing = loadPreciseDashboardSingleFlight(token, loader);
  assert.equal(duringTrailing.result, requests[0].result);
  assert.equal(invocationCount, 2, "requests during the trailing refresh must not add a third run");

  loads[1].resolve({ revision: 2 });
  const results = await Promise.all([
    ...requests.map((request) => request.result),
    duringTrailing.result,
  ]);
  results.forEach((result) => assert.equal(result.revision, 2));

  const fresh = loadPreciseDashboardSingleFlight(token, loader);
  assert.equal(invocationCount, 3, "a settled cycle must allow the next real refresh");
  loads[2].resolve({ revision: 3 });
  assert.equal((await fresh.result).revision, 3);
});

test("a coalesced trailing refresh can recover a failed first run", async () => {
  const token = sourceToken("retry");
  const loads = [];
  const loader = () => {
    const pending = deferred();
    loads.push(pending);
    return pending.promise;
  };

  const first = loadPreciseDashboardSingleFlight(token, loader);
  const coalesced = loadPreciseDashboardSingleFlight(token, loader);
  loads[0].reject(new Error("transient index generation"));
  await nextTurn();
  assert.equal(loads.length, 2);
  loads[1].resolve({ revision: 9 });

  assert.equal((await first.result).revision, 9);
  assert.equal((await coalesced.result).revision, 9);
});

test("a failed unshared cycle is removed before the next request", async () => {
  const token = sourceToken("failed-cycle");
  await assert.rejects(
    loadPreciseDashboardSingleFlight(
      token,
      async () => {
        throw new Error("fatal read");
      },
    ).result,
    /fatal read/,
  );

  const recovered = await loadPreciseDashboardSingleFlight(
    token,
    async () => ({ revision: 10 }),
  ).result;
  assert.equal(recovered.revision, 10);
});

test("a failed trailing refresh preserves the first successful snapshot", async () => {
  for (const trailingOutcome of ["null", "reject"]) {
    const token = sourceToken(`fallback-${trailingOutcome}`);
    const loads = [];
    const loader = () => {
      const pending = deferred();
      loads.push(pending);
      return pending.promise;
    };

    const first = loadPreciseDashboardSingleFlight(token, loader);
    const coalesced = loadPreciseDashboardSingleFlight(token, loader);
    loads[0].resolve({ revision: 21 });
    await nextTurn();
    if (trailingOutcome === "null") {
      loads[1].resolve(null);
    } else {
      loads[1].reject(new Error("trailing failed"));
    }

    assert.equal((await first.result).revision, 21);
    assert.equal((await coalesced.result).revision, 21);
  }
});

test("only the latest subscriber publishes and UI waiters expire independently", async () => {
  const token = sourceToken("latest-subscriber");
  const loads = [];
  const published = [];
  const loader = () => {
    const pending = deferred();
    loads.push(pending);
    return pending.promise;
  };

  const retired = loadPreciseDashboardSingleFlight(
    token,
    loader,
    (snapshot) => published.push(["retired", snapshot?.revision]),
  );
  const current = loadPreciseDashboardSingleFlight(
    token,
    loader,
    (snapshot) => published.push(["current", snapshot?.revision]),
  );
  retired.unsubscribe();
  await retired.waitForUiBudget(1);
  assert.deepEqual(published, []);

  loads[0].resolve({ revision: 30 });
  await nextTurn();
  loads[1].resolve({ revision: 31 });
  await current.result;
  assert.deepEqual(published, [["current", 31]]);
});

test("a subscriber can start a fresh same-source cycle during settlement", async () => {
  const token = sourceToken("reentrant");
  const published = [];
  let invocationCount = 0;
  let reentrant;
  const loader = async () => {
    invocationCount += 1;
    return { revision: invocationCount };
  };

  const first = loadPreciseDashboardSingleFlight(
    token,
    loader,
    (snapshot) => {
      published.push(["first", snapshot?.revision]);
      reentrant = loadPreciseDashboardSingleFlight(
        token,
        loader,
        (nextSnapshot) => published.push(["reentrant", nextSnapshot?.revision]),
      );
    },
  );
  await first.result;
  await reentrant.result;

  assert.equal(invocationCount, 2);
  assert.deepEqual(published, [
    ["first", 1],
    ["reentrant", 2],
  ]);
});

function sourceToken(suffix) {
  return {
    transitionGeneration: 1,
    canonicalHomeKey: `/home/${suffix}`,
    physicalHomeKey: `device:${suffix}`,
  };
}

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

function nextTurn() {
  return new Promise((resolve) => setImmediate(resolve));
}
