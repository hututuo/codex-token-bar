import assert from "node:assert/strict";
import test from "node:test";

import {
  loadPreciseDashboardSingleFlight,
  markPreciseDashboardSourceDirty,
  preciseDashboardFlightInProgress,
} from "./preciseDashboardSingleFlight.ts";
import { canonicalAttributionBoundaryKey } from "./attributionBoundary.ts";

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

test("a no-change periodic request reuses the last successful precise snapshot", async () => {
  const token = sourceToken("recent-success");
  let invocationCount = 0;
  const loader = async () => {
    invocationCount += 1;
    return preciseSnapshot(41);
  };

  assert.equal(
    (await loadPreciseDashboardSingleFlight(token, loader, undefined, { force: true }).result).revision,
    41,
  );

  const published = [];
  const periodic = loadPreciseDashboardSingleFlight(
    token,
    loader,
    (snapshot) => published.push(snapshot?.revision),
    { force: false, publishedGeneration: "41" },
  );
  assert.equal(invocationCount, 1, "a clean cadence tick must not invoke native precise again");
  assert.equal((await periodic.result).revision, 41);
  await nextTurn();
  assert.deepEqual(published, [41]);
});

test("an unchanged probe with an advanced published generation forces native precise", async () => {
  const token = sourceToken("advanced-generation");
  let invocationCount = 0;
  await loadPreciseDashboardSingleFlight(
    token,
    async () => {
      invocationCount += 1;
      return preciseSnapshot(42);
    },
    undefined,
    { force: true },
  ).result;

  const refreshed = loadPreciseDashboardSingleFlight(
    token,
    async () => {
      invocationCount += 1;
      return preciseSnapshot(43);
    },
    undefined,
    { force: false, publishedGeneration: "43" },
  );
  assert.equal((await refreshed.result).revision, 43);
  assert.equal(invocationCount, 2);
});

test("missing or invalid published generation proofs fail safe to native precise", async () => {
  for (const publishedGeneration of [undefined, "", "01", "not-a-generation"]) {
    const token = sourceToken(`invalid-generation-${String(publishedGeneration)}`);
    let invocationCount = 0;
    await loadPreciseDashboardSingleFlight(
      token,
      async () => {
        invocationCount += 1;
        return preciseSnapshot(50);
      },
      undefined,
      { force: true },
    ).result;

    const refreshed = loadPreciseDashboardSingleFlight(
      token,
      async () => {
        invocationCount += 1;
        return preciseSnapshot(51);
      },
      undefined,
      { force: false, publishedGeneration },
    );
    assert.equal((await refreshed.result).revision, 51);
    assert.equal(invocationCount, 2);
  }
});

test("a published generation from another source cannot authorize this source cache", async () => {
  const sourceA = sourceToken("generation-source-a");
  const sourceB = sourceToken("generation-source-b");
  let sourceALoads = 0;
  await loadPreciseDashboardSingleFlight(
    sourceA,
    async () => {
      sourceALoads += 1;
      return preciseSnapshot(60);
    },
    undefined,
    { force: true },
  ).result;
  await loadPreciseDashboardSingleFlight(
    sourceB,
    async () => preciseSnapshot(61),
    undefined,
    { force: true },
  ).result;

  const sourceARefresh = loadPreciseDashboardSingleFlight(
    sourceA,
    async () => {
      sourceALoads += 1;
      return preciseSnapshot(62);
    },
    undefined,
    { force: false, publishedGeneration: "61" },
  );
  assert.equal((await sourceARefresh.result).revision, 62);
  assert.equal(sourceALoads, 2);
});

test("a periodic request arriving during an owner does not enqueue a trailing full scan", async () => {
  const token = sourceToken("in-flight-periodic");
  const pending = deferred();
  let invocationCount = 0;
  const loader = () => {
    invocationCount += 1;
    return pending.promise;
  };

  const owner = loadPreciseDashboardSingleFlight(token, loader, undefined, { force: true });
  const periodic = loadPreciseDashboardSingleFlight(token, loader, undefined, { force: false });
  assert.equal(invocationCount, 1);
  pending.resolve(preciseSnapshot(42));
  await Promise.all([owner.result, periodic.result]);
  await nextTurn();
  assert.equal(invocationCount, 1);
});

test("the source-scoped flight join check stays true only while the owner is active", async () => {
  const token = sourceToken("flight-join-check");
  const pending = deferred();
  const owner = loadPreciseDashboardSingleFlight(
    token,
    () => pending.promise,
    undefined,
    { force: true },
  );
  assert.equal(preciseDashboardFlightInProgress(token), true);
  pending.resolve(preciseSnapshot(55));
  await owner.result;
  assert.equal(preciseDashboardFlightInProgress(token), false);
});

test("a new dirty generation during an owner keeps one trailing precise run", async () => {
  const token = sourceToken("dirty-during-owner");
  const loads = [];
  const loader = () => {
    const pending = deferred();
    loads.push(pending);
    return pending.promise;
  };

  const owner = loadPreciseDashboardSingleFlight(token, loader, undefined, { force: true });
  markPreciseDashboardSourceDirty(token);
  assert.equal(loads.length, 1);
  loads[0].resolve(preciseSnapshot(60));
  await nextTurn();
  assert.equal(loads.length, 2, "dirty observed before the owner settles needs one trailing run");
  loads[1].resolve(preciseSnapshot(61));
  assert.equal((await owner.result).revision, 61);
});

test("different non-manual trigger reasons share one trailing owner", async () => {
  const token = sourceToken("reasoned-trailing");
  const loads = [];
  const loader = () => {
    const pending = deferred();
    loads.push(pending);
    return pending.promise;
  };

  const owner = loadPreciseDashboardSingleFlight(
    token,
    loader,
    undefined,
    attributionRequest("quota", "quota-1"),
  );
  const duplicate = loadPreciseDashboardSingleFlight(
    token,
    loader,
    undefined,
    attributionRequest("attribution", "quota-1"),
  );
  const catchUp = loadPreciseDashboardSingleFlight(
    token,
    loader,
    undefined,
    attributionRequest("catch-up", "quota-2"),
  );
  const attribution = loadPreciseDashboardSingleFlight(
    token,
    loader,
    undefined,
    attributionRequest("attribution", "quota-3"),
  );
  assert.equal(loads.length, 1);
  assert.equal(duplicate.result, owner.result, "the same attribution boundary joins without trailing");

  loads[0].resolve(preciseSnapshot(91));
  await nextTurn();
  assert.equal(loads.length, 2, "the active owner admits one trailing round for the burst");
  loads[1].resolve(preciseSnapshot(92));

  const results = await Promise.all([owner.result, catchUp.result, attribution.result]);
  results.forEach((result) => assert.equal(result.preciseAttributionGeneration, 92));
  assert.equal(loads.length, 2);
});

test("repeated quota/catch-up/attribution requests reuse one settled revision", async () => {
  const token = sourceToken("reasoned-settled");
  const boundary = "2026-08-06T00:00:00.000Z";
  let invocationCount = 0;
  const loader = async () => {
    invocationCount += 1;
    return preciseSnapshot(100 + invocationCount, boundary);
  };

  await loadPreciseDashboardSingleFlight(
    token,
    loader,
    undefined,
    boundaryRequest("quota", boundary),
  ).result;
  for (const reason of ["quota", "catch-up", "attribution"]) {
    const repeated = loadPreciseDashboardSingleFlight(
      token,
      loader,
      undefined,
      boundaryRequest(reason, boundary),
    );
    assert.equal((await repeated.result).preciseAttributionGeneration, 101);
  }
  assert.equal(invocationCount, 1, "same trigger revision must not start serial full scans");
});

test("a real trigger revision advance runs precise once and then coalesces repeats", async () => {
  const token = sourceToken("reasoned-forward");
  const firstBoundary = "2026-08-06T00:00:00.000Z";
  const nextBoundary = "2026-08-06T00:00:01.000Z";
  let invocationCount = 0;
  let coverage = firstBoundary;
  const loader = async () => {
    invocationCount += 1;
    return preciseSnapshot(110 + invocationCount, coverage);
  };

  await loadPreciseDashboardSingleFlight(
    token,
    loader,
    undefined,
    boundaryRequest("quota", firstBoundary),
  ).result;
  coverage = nextBoundary;
  const advanced = loadPreciseDashboardSingleFlight(
    token,
    loader,
    undefined,
    boundaryRequest("quota", nextBoundary),
  );
  assert.equal((await advanced.result).preciseAttributionGeneration, 112);
  const repeated = loadPreciseDashboardSingleFlight(
    token,
    loader,
    undefined,
    boundaryRequest("catch-up", nextBoundary),
  );
  assert.equal((await repeated.result).preciseAttributionGeneration, 112);
  assert.equal(invocationCount, 2);
});

test("millisecond renderings coalesce quota/attribution and attribution/catch-up boundaries", async () => {
  const transitions = [
    ["quota", "attribution"],
    ["attribution", "catch-up"],
  ];
  for (const [firstReason, secondReason] of transitions) {
    const token = sourceToken(`canonical-boundary-${firstReason}`);
    let invocationCount = 0;
    let coverageTimestamp = "2026-08-06T00:00:00.123Z";
    const loader = async () => {
      invocationCount += 1;
      return preciseSnapshot(150 + invocationCount, coverageTimestamp);
    };
    const firstTimestamp = "2026-08-06T00:00:00.123Z";
    const sameSecondTimestamp = "2026-08-06T00:00:00.000Z";
    const nextSecondTimestamp = "2026-08-06T00:00:01.000Z";

    await loadPreciseDashboardSingleFlight(
      token,
      loader,
      undefined,
      attributionRequest(firstReason, canonicalAttributionBoundaryKey(firstTimestamp)),
    ).result;
    await loadPreciseDashboardSingleFlight(
      token,
      loader,
      undefined,
      attributionRequest(secondReason, canonicalAttributionBoundaryKey(sameSecondTimestamp)),
    ).result;
    assert.equal(invocationCount, 1, `${firstReason}->${secondReason} must share one second`);

    coverageTimestamp = nextSecondTimestamp;
    await loadPreciseDashboardSingleFlight(
      token,
      loader,
      undefined,
      attributionRequest(secondReason, canonicalAttributionBoundaryKey(nextSecondTimestamp)),
    ).result;
    assert.equal(invocationCount, 2, "a new Unix second must trigger a fresh full");
  }
});

test("cadence coverage gates quota during and after settlement", async () => {
  const token = sourceToken("coverage-cadence-quota");
  const boundary99 = "2026-08-06T00:01:39.000Z";
  const boundary100 = "2026-08-06T00:01:40.000Z";
  const boundary101 = "2026-08-06T00:01:41.000Z";
  const loads = [];
  let invocationCount = 0;
  let nextCoverage = boundary100;
  const loader = () => {
    invocationCount += 1;
    const pending = deferred();
    loads.push({ pending, coverage: nextCoverage });
    return pending.promise;
  };

  const cadence = loadPreciseDashboardSingleFlight(
    token,
    loader,
    undefined,
    { force: false },
  );
  const quotaDuringOwner = loadPreciseDashboardSingleFlight(
    token,
    loader,
    undefined,
    boundaryRequest("quota", boundary99),
  );
  assert.equal(invocationCount, 1);
  loads[0].pending.resolve(preciseSnapshot(180, loads[0].coverage));
  await Promise.all([cadence.result, quotaDuringOwner.result]);
  assert.equal(invocationCount, 1, "C=100 covers quota K=99 without trailing");

  await loadPreciseDashboardSingleFlight(
    token,
    loader,
    undefined,
    boundaryRequest("catch-up", boundary99),
  ).result;
  assert.equal(invocationCount, 1, "settled C=100 still covers quota K=99");

  nextCoverage = boundary101;
  const newerQuota = loadPreciseDashboardSingleFlight(
    token,
    loader,
    undefined,
    boundaryRequest("quota", boundary101),
  );
  loads[1].pending.resolve(preciseSnapshot(181, loads[1].coverage));
  await newerQuota.result;
  assert.equal(invocationCount, 2, "K=101 starts exactly one new native full");
});

test("attribution coverage reuses lower/equal boundaries and loads a newer one", async () => {
  const token = sourceToken("coverage-attribution");
  const boundary99 = "2026-08-06T00:01:39.000Z";
  const boundary100 = "2026-08-06T00:01:40.000Z";
  const boundary101 = "2026-08-06T00:01:41.000Z";
  let invocationCount = 0;
  let nextCoverage = boundary100;
  const loader = async () => {
    invocationCount += 1;
    return preciseSnapshot(190 + invocationCount, nextCoverage);
  };

  await loadPreciseDashboardSingleFlight(
    token,
    loader,
    undefined,
    boundaryRequest("attribution", boundary100),
  ).result;
  await loadPreciseDashboardSingleFlight(
    token,
    loader,
    undefined,
    boundaryRequest("quota", boundary99),
  ).result;
  await loadPreciseDashboardSingleFlight(
    token,
    loader,
    undefined,
    boundaryRequest("catch-up", boundary100),
  ).result;
  assert.equal(invocationCount, 1, "C=100 covers K=99 and K=100");

  nextCoverage = boundary101;
  await loadPreciseDashboardSingleFlight(
    token,
    loader,
    undefined,
    boundaryRequest("attribution", boundary101),
  ).result;
  assert.equal(invocationCount, 2, "K=101 is a real newer boundary");
});

test("an active owner tracks the maximum attribution boundary and runs one trailing full", async () => {
  const token = sourceToken("coverage-max");
  const boundary99 = "2026-08-06T00:01:39.000Z";
  const boundary100 = "2026-08-06T00:01:40.000Z";
  const boundary101 = "2026-08-06T00:01:41.000Z";
  const loads = [];
  let invocationCount = 0;
  const loader = () => {
    invocationCount += 1;
    const pending = deferred();
    loads.push(pending);
    return pending.promise;
  };

  const owner = loadPreciseDashboardSingleFlight(token, loader, undefined, { force: false });
  const lower = loadPreciseDashboardSingleFlight(
    token,
    loader,
    undefined,
    boundaryRequest("quota", boundary99),
  );
  const middle = loadPreciseDashboardSingleFlight(
    token,
    loader,
    undefined,
    boundaryRequest("attribution", boundary100),
  );
  const higher = loadPreciseDashboardSingleFlight(
    token,
    loader,
    undefined,
    boundaryRequest("catch-up", boundary101),
  );
  assert.equal(invocationCount, 1);

  loads[0].resolve(preciseSnapshot(200, boundary100));
  await nextTurn();
  assert.equal(invocationCount, 2, "C=100 misses max K=101 once");
  loads[1].resolve(preciseSnapshot(201, boundary101));
  const results = await Promise.all([owner.result, lower.result, middle.result, higher.result]);
  results.forEach((result) => assert.equal(result.preciseAttributionGeneration, 201));
  assert.equal(invocationCount, 2, "max-boundary requests share one trailing full");
});

test("a boundary queued in the settlement turn still contributes to the maximum", async () => {
  const token = sourceToken("coverage-settlement-turn");
  const boundary100 = "2026-08-06T00:01:40.000Z";
  const boundary101 = "2026-08-06T00:01:41.000Z";
  const loads = [];
  let invocationCount = 0;
  const loader = () => {
    invocationCount += 1;
    const pending = deferred();
    loads.push(pending);
    return pending.promise;
  };

  const owner = loadPreciseDashboardSingleFlight(token, loader, undefined, { force: false });
  loads[0].resolve(preciseSnapshot(210, boundary100));
  let queuedBoundary;
  queueMicrotask(() => {
    queuedBoundary = loadPreciseDashboardSingleFlight(
      token,
      loader,
      undefined,
      boundaryRequest("attribution", boundary101),
    );
  });
  await nextTurn();
  assert.equal(invocationCount, 2, "the settlement-turn K=101 request asks for one trailing full");
  loads[1].resolve(preciseSnapshot(211, boundary101));
  await Promise.all([owner.result, queuedBoundary.result]);
  assert.equal(invocationCount, 2);
});

test("invalid, stale, and failed attribution boundaries never reuse coverage", async () => {
  const token = sourceToken("coverage-fail-safe");
  const boundary100 = "2026-08-06T00:01:40.000Z";
  let invocationCount = 0;
  const loader = async () => {
    invocationCount += 1;
    if (invocationCount === 1) {
      return { preciseRecentUsageFresh: false, preciseRecentUsageCoveredAt: boundary100 };
    }
    return preciseSnapshot(220 + invocationCount, boundary100);
  };

  await loadPreciseDashboardSingleFlight(
    token,
    loader,
    undefined,
    boundaryRequest("attribution", boundary100),
  ).result;
  assert.equal(invocationCount, 2, "stale first result gets one bounded trailing attempt");
  await loadPreciseDashboardSingleFlight(
    token,
    loader,
    undefined,
    {
      force: true,
      reason: "attribution",
      revision: boundary100,
      dedupeDomain: "attribution-boundary",
      dedupeKey: undefined,
    },
  ).result;
  assert.equal(invocationCount, 3, "missing key cannot reuse a settled boundary");
});

test("a boundary owner retries one transient loader error but never loops", async () => {
  const token = sourceToken("coverage-error");
  const boundary100 = "2026-08-06T00:01:40.000Z";
  let invocationCount = 0;
  const loader = async () => {
    invocationCount += 1;
    if (invocationCount === 1) {
      throw new Error("transient precise read");
    }
    return preciseSnapshot(230 + invocationCount, boundary100);
  };

  const result = await loadPreciseDashboardSingleFlight(
    token,
    loader,
    undefined,
    boundaryRequest("attribution", boundary100),
  ).result;
  assert.equal(result.preciseAttributionGeneration, 232);
  assert.equal(invocationCount, 2, "one error gets one bounded recovery attempt");
});

test("an insufficient trailing boundary leaves the source dirty for the next request", async () => {
  const token = sourceToken("coverage-trailing-stale");
  const boundary99 = "2026-08-06T00:01:39.000Z";
  const boundary100 = "2026-08-06T00:01:40.000Z";
  let invocationCount = 0;
  const loader = async () => {
    invocationCount += 1;
    return preciseSnapshot(240 + invocationCount, invocationCount < 3 ? boundary99 : boundary100);
  };

  const first = await loadPreciseDashboardSingleFlight(
    token,
    loader,
    undefined,
    boundaryRequest("attribution", boundary100),
  ).result;
  assert.equal(first.preciseRecentUsageCoveredAt, boundary99);
  assert.equal(invocationCount, 2, "one insufficient trailing attempt is bounded");

  const recovered = await loadPreciseDashboardSingleFlight(
    token,
    loader,
    undefined,
    boundaryRequest("catch-up", boundary100),
  ).result;
  assert.equal(recovered.preciseRecentUsageCoveredAt, boundary100);
  assert.equal(invocationCount, 3, "dirty state prevents stale coverage reuse");
});

test("invalid or missing attribution keys never reuse a settled raw revision", async () => {
  const token = sourceToken("invalid-boundary");
  let invocationCount = 0;
  const loader = async () => {
    invocationCount += 1;
    return preciseSnapshot(170 + invocationCount);
  };
  const invalidRequest = (reason) => ({
    force: true,
    reason,
    revision: "2026-08-06T00:00:00.123Z",
    dedupeDomain: "attribution-boundary",
    dedupeKey: undefined,
  });

  await loadPreciseDashboardSingleFlight(token, loader, undefined, invalidRequest("quota")).result;
  await loadPreciseDashboardSingleFlight(token, loader, undefined, invalidRequest("attribution")).result;
  assert.equal(invocationCount, 2, "missing canonical keys must fail safe to native");

  const malformedRequest = {
    force: true,
    reason: "quota",
    revision: "bad-time",
    dedupeDomain: "attribution-boundary",
    dedupeKey: "bad-time",
  };
  await loadPreciseDashboardSingleFlight(token, loader, undefined, malformedRequest).result;
  await loadPreciseDashboardSingleFlight(token, loader, undefined, malformedRequest).result;
  assert.equal(invocationCount, 4, "non-canonical keys must fail safe to native");
});

test("wake coalescing is scoped to one wake event key", async () => {
  const token = sourceToken("wake-key");
  let invocationCount = 0;
  const loader = async () => {
    invocationCount += 1;
    return preciseSnapshot(115 + invocationCount);
  };

  const wakeRequest = (key) => ({
    force: true,
    reason: "wake",
    revision: key,
    dedupeDomain: "wake",
    dedupeKey: key,
  });
  await loadPreciseDashboardSingleFlight(token, loader, undefined, wakeRequest("wake-1")).result;
  await loadPreciseDashboardSingleFlight(token, loader, undefined, wakeRequest("wake-1")).result;
  await loadPreciseDashboardSingleFlight(token, loader, undefined, wakeRequest("wake-2")).result;
  assert.equal(invocationCount, 2);
});

test("completed attribution keys survive wake completion and dirty invalidates every domain", async () => {
  const token = sourceToken("completed-domains");
  const boundary = "2026-08-06T00:00:00.000Z";
  let invocationCount = 0;
  const loader = async () => {
    invocationCount += 1;
    return preciseSnapshot(125 + invocationCount, boundary);
  };
  const wakeRequest = (key) => ({
    force: true,
    reason: "wake",
    revision: key,
    dedupeDomain: "wake",
    dedupeKey: key,
  });

  await loadPreciseDashboardSingleFlight(
    token,
    loader,
    undefined,
    boundaryRequest("quota", boundary),
  ).result;
  await loadPreciseDashboardSingleFlight(token, loader, undefined, wakeRequest("wake-W")).result;
  await loadPreciseDashboardSingleFlight(
    token,
    loader,
    undefined,
    boundaryRequest("catch-up", boundary),
  ).result;
  assert.equal(invocationCount, 2, "a later wake must not evict attribution completion");

  markPreciseDashboardSourceDirty(token);
  await loadPreciseDashboardSingleFlight(
    token,
    loader,
    undefined,
    boundaryRequest("quota", boundary),
  ).result;
  await loadPreciseDashboardSingleFlight(token, loader, undefined, wakeRequest("wake-W")).result;
  assert.equal(invocationCount, 4, "source dirty must invalidate all completed domains");
});

test("one active owner records attribution and wake keys on its fresh trailing result", async () => {
  const token = sourceToken("mixed-owner-domains");
  const boundary = "2026-08-06T00:00:00.000Z";
  const loads = [];
  const loader = () => {
    const pending = deferred();
    loads.push(pending);
    return pending.promise;
  };
  const wakeRequest = (key) => ({
    force: true,
    reason: "wake",
    revision: key,
    dedupeDomain: "wake",
    dedupeKey: key,
  });

  const owner = loadPreciseDashboardSingleFlight(
    token,
    loader,
    undefined,
    boundaryRequest("quota", boundary),
  );
  const wake = loadPreciseDashboardSingleFlight(token, loader, undefined, wakeRequest("wake-W"));
  assert.equal(loads.length, 1);
  loads[0].resolve(preciseSnapshot(131));
  await nextTurn();
  assert.equal(loads.length, 2);
  loads[1].resolve(preciseSnapshot(132));
  await Promise.all([owner.result, wake.result]);

  await loadPreciseDashboardSingleFlight(
    token,
    loader,
    undefined,
    boundaryRequest("catch-up", boundary),
  ).result;
  await loadPreciseDashboardSingleFlight(token, loader, undefined, wakeRequest("wake-W")).result;
  assert.equal(loads.length, 2, "both domains must be covered by the fresh trailing result");
});

test("a completed attribution key joins a later wake owner without a trailing round", async () => {
  const token = sourceToken("completed-before-wake");
  const boundary = "2026-08-06T00:00:00.000Z";
  let invocationCount = 0;
  const wakeLoad = deferred();
  const loader = () => {
    invocationCount += 1;
    return invocationCount === 2
      ? wakeLoad.promise
      : Promise.resolve(preciseSnapshot(135 + invocationCount));
  };
  const wakeRequest = {
    force: true,
    reason: "wake",
    revision: "wake-W",
    dedupeDomain: "wake",
    dedupeKey: "wake-W",
  };

  await loadPreciseDashboardSingleFlight(
    token,
    loader,
    undefined,
    boundaryRequest("quota", boundary),
  ).result;
  const wake = loadPreciseDashboardSingleFlight(token, loader, undefined, wakeRequest);
  const repeatedAttribution = loadPreciseDashboardSingleFlight(
    token,
    loader,
    undefined,
    boundaryRequest("catch-up", boundary),
  );
  assert.equal(repeatedAttribution.result, wake.result);
  assert.equal(invocationCount, 2, "the completed attribution key must not enqueue trailing");

  wakeLoad.resolve(preciseSnapshot(138));
  await Promise.all([wake.result, repeatedAttribution.result]);
  await loadPreciseDashboardSingleFlight(
    token,
    loader,
    undefined,
    boundaryRequest("quota", boundary),
  ).result;
  await loadPreciseDashboardSingleFlight(token, loader, undefined, wakeRequest).result;
  assert.equal(invocationCount, 2, "fresh wake result must cover both completed domains");

  markPreciseDashboardSourceDirty(token);
  await loadPreciseDashboardSingleFlight(
    token,
    loader,
    undefined,
    boundaryRequest("quota", boundary),
  ).result;
  await loadPreciseDashboardSingleFlight(token, loader, undefined, wakeRequest).result;
  assert.equal(invocationCount, 4, "real dirty must invalidate both domains");
});

test("manual and retry/unknown requests remain fail-safe after a coalescible success", async () => {
  const token = sourceToken("reasoned-fail-safe");
  let invocationCount = 0;
  const loader = async () => {
    invocationCount += 1;
    return preciseSnapshot(120 + invocationCount);
  };

  await loadPreciseDashboardSingleFlight(
    token,
    loader,
    undefined,
    attributionRequest("quota", "revision-1"),
  ).result;
  await loadPreciseDashboardSingleFlight(
    token,
    loader,
    undefined,
    { force: true, reason: "manual", revision: "revision-1" },
  ).result;
  await loadPreciseDashboardSingleFlight(
    token,
    loader,
    undefined,
    { force: true, reason: "unknown", revision: "revision-1" },
  ).result;
  assert.equal(invocationCount, 3);

  const retryLoader = async () => {
    invocationCount += 1;
    if (invocationCount === 4) {
      throw new Error("retryable precise failure");
    }
    return preciseSnapshot(130 + invocationCount);
  };
  await assert.rejects(
    loadPreciseDashboardSingleFlight(
      token,
      retryLoader,
      undefined,
      { force: true, reason: "retry", revision: "revision-1" },
    ).result,
    /retryable precise failure/,
  );
  const recovered = loadPreciseDashboardSingleFlight(
    token,
    retryLoader,
    undefined,
    { force: true, reason: "retry", revision: "revision-1" },
  );
  assert.equal((await recovered.result).preciseAttributionGeneration, 135);
  assert.equal(invocationCount, 5);
});

test("reasoned settled coalescing remains isolated across source keys", async () => {
  const sourceA = sourceToken("reasoned-source-a");
  const sourceB = sourceToken("reasoned-source-b");
  const boundary = "2026-08-06T00:00:00.000Z";
  let sourceALoads = 0;
  let sourceBLoads = 0;
  await loadPreciseDashboardSingleFlight(
    sourceA,
    async () => {
      sourceALoads += 1;
      return preciseSnapshot(140, boundary);
    },
    undefined,
    boundaryRequest("quota", boundary),
  ).result;
  const sourceBRequest = loadPreciseDashboardSingleFlight(
    sourceB,
    async () => {
      sourceBLoads += 1;
      return preciseSnapshot(141, boundary);
    },
    undefined,
    boundaryRequest("quota", boundary),
  );
  assert.equal((await sourceBRequest.result).preciseAttributionGeneration, 141);
  const sourceARepeat = loadPreciseDashboardSingleFlight(
    sourceA,
    async () => {
      sourceALoads += 1;
      return preciseSnapshot(142, boundary);
    },
    undefined,
    boundaryRequest("catch-up", boundary),
  );
  assert.equal((await sourceARepeat.result).preciseAttributionGeneration, 140);
  assert.equal(sourceALoads, 1);
  assert.equal(sourceBLoads, 1);
});

test("a failed forced refresh leaves the source dirty so the next periodic tick retries", async () => {
  const token = sourceToken("retry-after-failure");
  let invocationCount = 0;
  const goodLoader = async () => {
    invocationCount += 1;
    return preciseSnapshot(43);
  };
  await loadPreciseDashboardSingleFlight(token, goodLoader, undefined, { force: true }).result;

  const failing = loadPreciseDashboardSingleFlight(
    token,
    async () => {
      invocationCount += 1;
      throw new Error("native precise failed");
    },
    undefined,
    { force: true },
  );
  await assert.rejects(failing.result, /native precise failed/);

  const recovered = loadPreciseDashboardSingleFlight(
    token,
    async () => {
      invocationCount += 1;
      return preciseSnapshot(44);
    },
    undefined,
    { force: false },
  );
  assert.equal((await recovered.result).revision, 44);
  assert.equal(invocationCount, 3);
});

test("a source-dirty marker bypasses the periodic last-good snapshot", async () => {
  const token = sourceToken("source-dirty");
  let invocationCount = 0;
  const loader = async () => {
    invocationCount += 1;
    return preciseSnapshot(50 + invocationCount);
  };
  await loadPreciseDashboardSingleFlight(token, loader, undefined, { force: true }).result;
  markPreciseDashboardSourceDirty(token);
  const refreshed = loadPreciseDashboardSingleFlight(token, loader, undefined, { force: false });
  assert.equal((await refreshed.result).revision, 52);
  assert.equal(invocationCount, 2);
});

test("a failed trailing run keeps the source dirty for the next cadence retry", async () => {
  const token = sourceToken("failed-trailing-retry");
  const loads = [];
  const loader = () => {
    const pending = deferred();
    loads.push(pending);
    return pending.promise;
  };

  const first = loadPreciseDashboardSingleFlight(token, loader, undefined, { force: true });
  const forced = loadPreciseDashboardSingleFlight(token, loader, undefined, { force: true });
  loads[0].resolve(preciseSnapshot(70));
  await nextTurn();
  loads[1].reject(new Error("trailing probe refresh failed"));
  assert.equal((await first.result).revision, 70);
  assert.equal((await forced.result).revision, 70);

  const retry = loadPreciseDashboardSingleFlight(
    token,
    async () => preciseSnapshot(71),
    undefined,
    { force: false },
  );
  assert.equal((await retry.result).revision, 71);
});

test("Home transition generations never reuse another source cache and old entries are bounded", async () => {
  const tokens = [sourceToken("cache-a"), sourceToken("cache-b"), sourceToken("cache-c")];
  const loads = new Map();
  for (const [index, token] of tokens.entries()) {
    loads.set(token.canonicalHomeKey, 0);
    await loadPreciseDashboardSingleFlight(
      token,
      async () => {
        loads.set(token.canonicalHomeKey, loads.get(token.canonicalHomeKey) + 1);
        return preciseSnapshot(80 + index);
      },
      undefined,
      { force: true },
    ).result;
  }

  const switchedBack = loadPreciseDashboardSingleFlight(
    tokens[0],
    async () => {
      loads.set(tokens[0].canonicalHomeKey, loads.get(tokens[0].canonicalHomeKey) + 1);
      return preciseSnapshot(90);
    },
    undefined,
    { force: false },
  );
  assert.equal((await switchedBack.result).revision, 90);
  assert.equal(loads.get(tokens[0].canonicalHomeKey), 2);
});

function sourceToken(suffix) {
  return {
    transitionGeneration: 1,
    canonicalHomeKey: `/home/${suffix}`,
    physicalHomeKey: `device:${suffix}`,
  };
}

function attributionRequest(reason, key) {
  return {
    force: true,
    reason,
    revision: key,
    dedupeDomain: "attribution-boundary",
    dedupeKey: key,
  };
}

function boundaryRequest(reason, timestamp, force = true) {
  return {
    force,
    reason,
    revision: timestamp,
    dedupeDomain: "attribution-boundary",
    dedupeKey: canonicalAttributionBoundaryKey(timestamp),
  };
}

function preciseSnapshot(revision, coveredAt = "2026-08-06T00:00:00.000Z") {
  return {
    revision,
    preciseRecentUsageFresh: true,
    preciseRecentUsageCoveredAt: coveredAt,
    preciseAttributionGeneration: revision,
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
