import assert from "node:assert/strict";
import test from "node:test";
import { Window } from "happy-dom";
import { withSsrModules } from "../../test/ssrHarness.mjs";

test("disabled attribution renders no trigger and performs no segment or bucket storage writes", async () => {
  const window = new Window({ url: "http://localhost/" });
  const restoreGlobals = installDomGlobals(window);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  window.localStorage.setItem("sharedAccountAttributionEnabled", "false");
  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { QuotaStrip } = await load("/src/components/QuotaStrip.tsx");
      const container = window.document.createElement("div");
      window.document.body.append(container);
      const root = createRoot(container);
      const nowUnix = Math.floor(Date.now() / 1_000);
      const quotaUpdatedAtUnix = Math.floor((nowUnix - 60) / 300) * 300;
      try {
        await React.act(async () => root.render(React.createElement(QuotaStrip, {
          attributionIdentity: { scopeKey: "sha256:opaque", plan: "Pro", limit: "codex" },
          preciseDataAvailable: true,
          preciseDataCoveredAt: new Date(quotaUpdatedAtUnix * 1_000).toISOString(),
          preciseDataFresh: true,
          ...observerProps(),
          quotaUpdatedAt: new Date(quotaUpdatedAtUnix * 1_000).toISOString(),
          recentUsage24h: [point(quotaUpdatedAtUnix - 300)],
          snapshot: quotaSnapshot(nowUnix + 6 * 24 * 60 * 60),
          sourceHomeIdentity: "home-a",
        })));

        assert.equal(container.querySelector(".shared-attribution-trigger"), null);
        assert.deepEqual(
          storageKeys(window.localStorage).filter((key) => key.startsWith("sharedAccountAttributionSegment:")),
          [],
        );
        assert.deepEqual(
          storageKeys(window.localStorage).filter((key) => key.startsWith("sharedAccountAttributionBuckets:")),
          [],
        );
      } finally {
        await React.act(async () => root.unmount());
      }
    });
  } finally {
    delete globalThis.IS_REACT_ACT_ENVIRONMENT;
    restoreGlobals();
    window.close();
  }
});

test("expired reset waits for quota refresh without wall-clock-rejecting durable cleanup metadata", async () => {
  const window = new Window({ url: "http://localhost/" });
  const restoreGlobals = installDomGlobals(window);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { QuotaStrip } = await load("/src/components/QuotaStrip.tsx");
      const container = window.document.createElement("div");
      window.document.body.append(container);
      const root = createRoot(container);
      const nowUnix = Math.floor(Date.now() / 1_000);
      const quotaUpdatedAtUnix = Math.floor((nowUnix - 600) / 300) * 300;
      try {
        await React.act(async () => root.render(React.createElement(QuotaStrip, {
          attributionIdentity: { scopeKey: "sha256:opaque", plan: "Pro", limit: "codex" },
          preciseDataAvailable: true,
          preciseDataCoveredAt: new Date(quotaUpdatedAtUnix * 1_000).toISOString(),
          preciseDataFresh: true,
          ...observerProps(),
          quotaUpdatedAt: new Date(quotaUpdatedAtUnix * 1_000).toISOString(),
          recentUsage24h: [point(quotaUpdatedAtUnix - 300)],
          snapshot: quotaSnapshot(nowUnix - 1),
          sourceHomeIdentity: "home-a",
        })));

        assert.match(container.querySelector(".shared-attribution-trigger")?.textContent ?? "", /等待额度刷新/);
        assert.equal(storageKeys(window.localStorage).some((key) => key.startsWith("sharedAccountAttributionBuckets:")), true);
        assert.equal(storageKeys(window.localStorage).some((key) => key.startsWith("sharedAccountAttributionSegment:")), true);
      } finally {
        await React.act(async () => root.unmount());
      }
    });
  } finally {
    delete globalThis.IS_REACT_ACT_ENVIRONMENT;
    restoreGlobals();
    window.close();
  }
});

test("an older or failed precise series cannot write raw token high-water", async () => {
  const window = new Window({ url: "http://localhost/" });
  const restoreGlobals = installDomGlobals(window);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { QuotaStrip } = await load("/src/components/QuotaStrip.tsx");
      const container = window.document.createElement("div");
      window.document.body.append(container);
      const root = createRoot(container);
      const nowUnix = Math.floor(Date.now() / 1_000);
      const quotaUpdatedAtUnix = Math.floor((nowUnix - 60) / 300) * 300;
      try {
        await React.act(async () => root.render(React.createElement(QuotaStrip, {
          attributionIdentity: { scopeKey: "sha256:opaque", plan: "Pro", limit: "codex" },
          preciseDataAvailable: true,
          preciseDataCoveredAt: new Date((quotaUpdatedAtUnix - 1) * 1_000).toISOString(),
          preciseDataFresh: false,
          ...observerProps(),
          quotaUpdatedAt: new Date(quotaUpdatedAtUnix * 1_000).toISOString(),
          recentUsage24h: [point(quotaUpdatedAtUnix - 300)],
          snapshot: quotaSnapshot(nowUnix + 6 * 24 * 60 * 60),
          sourceHomeIdentity: "home-a",
        })));

        assert.match(container.querySelector(".shared-attribution-trigger")?.textContent ?? "", /精确用量待刷新/);
        assert.equal(
          storageKeys(window.localStorage).some((key) => key.startsWith("sharedAccountAttributionBuckets:")),
          false,
        );
      } finally {
        await React.act(async () => root.unmount());
      }
    });
  } finally {
    delete globalThis.IS_REACT_ACT_ENVIRONMENT;
    restoreGlobals();
    window.close();
  }
});

test("a ready segment whose durable high-water row disappeared is quarantined for rebaseline", async () => {
  const window = new Window({ url: "http://localhost/" });
  const restoreGlobals = installDomGlobals(window);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { QuotaStrip } = await load("/src/components/QuotaStrip.tsx");
      const {
        attributionSegmentStorageKey,
        readAttributionSegment,
        writeAttributionSegment,
      } = await load("/src/components/sharedAccountAttribution/segment.ts");
      const container = window.document.createElement("div");
      window.document.body.append(container);
      const root = createRoot(container);
      const nowUnix = Math.floor(Date.now() / 1_000);
      const observedAt = Math.floor((nowUnix - 600) / 300) * 300;
      const resetAt = nowUnix + 6 * 24 * 60 * 60;
      const segmentKey = attributionSegmentStorageKey("home-a");
      const durable = {
        resetAtUnix: resetAt,
        scopeKey: "sha256:account-a",
        plan: "Pro",
        limit: "codex",
        segmentStartUnix: resetAt - 7 * 24 * 60 * 60,
        baselineAccountUsedPercent: 10,
        baselineReady: true,
        baselineObservedAtUnix: observedAt,
        highWaterInitialized: true,
        accountUsedObservedPercent: 10,
        comparisonUpdatedAtUnix: observedAt,
        quotaMovementPendingUntilUnix: null,
        quotaMovementObservedAtUnix: null,
        requiredLocalObservationAfterUnix: observedAt,
        cutoverReason: "none",
        cutoverDetectedAtUnix: null,
        cutoverRecoveredAtUnix: null,
        continuityGapID: null,
        observedAtUnix: observedAt,
      };
      assert.equal(writeAttributionSegment(segmentKey, durable, window.localStorage), true);
      seedObserver(window.localStorage, "home-a");

      try {
        await React.act(async () => root.render(React.createElement(QuotaStrip, {
          attributionIdentity: { scopeKey: "sha256:account-a", plan: "Pro", limit: "codex" },
          preciseDataAvailable: true,
          preciseDataCoveredAt: new Date(observedAt * 1_000).toISOString(),
          preciseDataFresh: true,
          ...observerProps(),
          quotaUpdatedAt: new Date(observedAt * 1_000).toISOString(),
          recentUsage24h: [point(observedAt - 300)],
          snapshot: quotaSnapshot(resetAt),
          sourceHomeIdentity: "home-a",
        })));

        assert.match(
          container.querySelector(".shared-attribution-trigger")?.textContent ?? "",
          /损坏记录已隔离/,
        );
        assert.equal(
          storageKeys(window.localStorage).some((key) => key.startsWith("sharedAccountAttributionBuckets:")),
          true,
        );
        const rebaseline = readAttributionSegment(segmentKey, window.localStorage);
        assert.equal(rebaseline.baselineReady, false);
        assert.equal(rebaseline.cutoverReason, "continuityGap");
        assert.equal(
          storageKeys(window.localStorage).some((key) => key.startsWith("sharedAccountAttributionQuarantine:v1:")),
          true,
        );
      } finally {
        await React.act(async () => root.unmount());
      }
    });
  } finally {
    delete globalThis.IS_REACT_ACT_ENVIRONMENT;
    restoreGlobals();
    window.close();
  }
});

test("a pending account switch persists post-boundary raw buckets without calculating a residual", async () => {
  const window = new Window({ url: "http://localhost/" });
  const restoreGlobals = installDomGlobals(window);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { QuotaStrip } = await load("/src/components/QuotaStrip.tsx");
      const {
        attributionSegmentStorageKey,
        readAttributionSegment,
        writeAttributionSegment,
      } = await load("/src/components/sharedAccountAttribution/segment.ts");
      const container = window.document.createElement("div");
      window.document.body.append(container);
      const root = createRoot(container);
      const nowUnix = Math.floor(Date.now() / 1_000);
      const baseBoundary = Math.floor((nowUnix - 1_200) / 300) * 300;
      const switchObservedAt = baseBoundary + 120;
      const segmentStart = baseBoundary + 300;
      const preciseCoveredAt = baseBoundary + 600;
      const resetAt = nowUnix + 6 * 24 * 60 * 60;
      const segmentKey = attributionSegmentStorageKey("home-a");
      writeAttributionSegment(segmentKey, {
        resetAtUnix: resetAt,
        scopeKey: "sha256:account-a",
        plan: "Pro",
        limit: "codex",
        segmentStartUnix: resetAt - 7 * 24 * 60 * 60,
        baselineAccountUsedPercent: 0,
        baselineReady: true,
        baselineObservedAtUnix: switchObservedAt - 300,
        highWaterInitialized: false,
        accountUsedObservedPercent: 10,
        comparisonUpdatedAtUnix: switchObservedAt - 300,
        quotaMovementPendingUntilUnix: null,
        quotaMovementObservedAtUnix: null,
        requiredLocalObservationAfterUnix: null,
        cutoverReason: "none",
        cutoverDetectedAtUnix: null,
        cutoverRecoveredAtUnix: null,
        continuityGapID: null,
        observedAtUnix: switchObservedAt - 300,
      }, window.localStorage);
      seedObserver(window.localStorage, "home-a");

      try {
        await React.act(async () => root.render(React.createElement(QuotaStrip, {
          attributionIdentity: { scopeKey: "sha256:account-b", plan: "Pro", limit: "codex" },
          preciseDataAvailable: true,
          preciseDataCoveredAt: new Date(preciseCoveredAt * 1_000).toISOString(),
          preciseDataFresh: true,
          ...observerProps(),
          quotaUpdatedAt: new Date(switchObservedAt * 1_000).toISOString(),
          recentUsage24h: [point(segmentStart)],
          snapshot: quotaSnapshot(resetAt),
          sourceHomeIdentity: "home-a",
        })));

        assert.match(container.querySelector(".shared-attribution-trigger")?.textContent ?? "", /切号基线待刷新/);
        const pendingSegment = readAttributionSegment(segmentKey, window.localStorage);
        assert.equal(pendingSegment?.scopeKey, "sha256:account-b");
        assert.equal(pendingSegment?.baselineReady, false);
        assert.equal(pendingSegment?.segmentStartUnix, segmentStart);
        const bucketKeys = storageKeys(window.localStorage)
          .filter((key) => key.startsWith("sharedAccountAttributionBuckets:v4:"));
        assert.equal(bucketKeys.length, 1);
        const rawRecord = JSON.parse(window.localStorage.getItem(bucketKeys[0]));
        assert.equal(rawRecord.buckets[String(segmentStart)].inputTokens, 1_000_000);
      } finally {
        await React.act(async () => root.unmount());
      }
    });
  } finally {
    delete globalThis.IS_REACT_ACT_ENVIRONMENT;
    restoreGlobals();
    window.close();
  }
});

test("stored partial usage advances one unchanged comparison at the next 5m boundary", async () => {
  const window = new Window({ url: "http://localhost/" });
  const restoreGlobals = installDomGlobals(window);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { QuotaStrip } = await load("/src/components/QuotaStrip.tsx");
      const {
        attributionSegmentStorageKey,
        readAttributionSegment,
        writeAttributionSegment,
      } = await load("/src/components/sharedAccountAttribution/segment.ts");
      const container = window.document.createElement("div");
      window.document.body.append(container);
      const root = createRoot(container);
      const nowUnix = Math.floor(Date.now() / 1_000);
      const bucketStart = Math.floor((nowUnix - 1_200) / 300) * 300;
      const comparisonAt = bucketStart + 120;
      const nextBoundary = bucketStart + 300;
      const resetAt = nowUnix + 6 * 24 * 60 * 60;
      const segmentKey = attributionSegmentStorageKey("home-a");
      writeAttributionSegment(segmentKey, {
        resetAtUnix: resetAt,
        scopeKey: "sha256:account-a",
        plan: "Pro",
        limit: "codex",
        segmentStartUnix: resetAt - 7 * 24 * 60 * 60,
        baselineAccountUsedPercent: 0,
        baselineReady: true,
        baselineObservedAtUnix: comparisonAt,
        highWaterInitialized: false,
        accountUsedObservedPercent: 10,
        comparisonUpdatedAtUnix: comparisonAt,
        quotaMovementPendingUntilUnix: null,
        quotaMovementObservedAtUnix: null,
        requiredLocalObservationAfterUnix: null,
        cutoverReason: "none",
        cutoverDetectedAtUnix: null,
        cutoverRecoveredAtUnix: null,
        continuityGapID: null,
        observedAtUnix: comparisonAt,
      }, window.localStorage);
      seedObserver(window.localStorage, "home-a");
      const refreshes = [];

      try {
        await React.act(async () => root.render(React.createElement(QuotaStrip, {
          attributionIdentity: { scopeKey: "sha256:account-a", plan: "Pro", limit: "codex" },
          onAttributionPreciseRefreshNeeded: (value) => refreshes.push(value),
          preciseDataAvailable: true,
          preciseDataCoveredAt: new Date((comparisonAt + 30) * 1_000).toISOString(),
          preciseDataFresh: true,
          ...observerProps(),
          quotaUpdatedAt: new Date(nextBoundary * 1_000).toISOString(),
          recentUsage24h: [point(bucketStart)],
          snapshot: quotaSnapshot(resetAt),
          sourceHomeIdentity: "home-a",
        })));

        assert.deepEqual(refreshes, [new Date(nextBoundary * 1_000).toISOString()]);
        assert.equal(
          readAttributionSegment(segmentKey, window.localStorage)?.comparisonUpdatedAtUnix,
          nextBoundary,
        );
        assert.match(
          container.querySelector(".shared-attribution-trigger")?.textContent ?? "",
          /精确用量待刷新/,
        );
      } finally {
        await React.act(async () => root.unmount());
      }
    });
  } finally {
    delete globalThis.IS_REACT_ACT_ENVIRONMENT;
    restoreGlobals();
    window.close();
  }
});

test("persisted exact-read gap holds state, then recovery creates and clears a continuity cutover", async () => {
  const window = new Window({ url: "http://localhost/" });
  const restoreGlobals = installDomGlobals(window);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { QuotaStrip } = await load("/src/components/QuotaStrip.tsx");
      const {
        attributionSegmentStorageKey,
        completedBucketBoundary,
        readAttributionSegment,
        writeAttributionSegment,
      } = await load("/src/components/sharedAccountAttribution/segment.ts");
      const {
        markPreciseUsageContinuityGap,
        readPreciseUsageContinuityGap,
      } = await load("/src/state/preciseUsageContinuity.ts");
      const container = window.document.createElement("div");
      window.document.body.append(container);
      const root = createRoot(container);
      const nowUnix = Math.floor(Date.now() / 1_000);
      const boundary = Math.floor((nowUnix - 1_200) / 300) * 300;
      const gapDetectedAt = boundary + 30;
      const recoveryCoverageAt = boundary + 120;
      const recoveryQuotaAt = boundary + 180;
      const resetAt = nowUnix + 6 * 24 * 60 * 60;
      const segmentKey = attributionSegmentStorageKey("home-a");
      const durable = {
        resetAtUnix: resetAt,
        scopeKey: "sha256:account-a",
        plan: "Pro",
        limit: "codex",
        segmentStartUnix: resetAt - 7 * 24 * 60 * 60,
        baselineAccountUsedPercent: 0,
        baselineReady: true,
        baselineObservedAtUnix: boundary,
        highWaterInitialized: false,
        accountUsedObservedPercent: 10,
        comparisonUpdatedAtUnix: boundary,
        quotaMovementPendingUntilUnix: null,
        quotaMovementObservedAtUnix: null,
        requiredLocalObservationAfterUnix: null,
        cutoverReason: "none",
        cutoverDetectedAtUnix: null,
        cutoverRecoveredAtUnix: null,
        continuityGapID: null,
        observedAtUnix: boundary,
      };
      writeAttributionSegment(segmentKey, durable, window.localStorage);
      seedObserver(window.localStorage, "home-a");
      markPreciseUsageContinuityGap("home-a", gapDetectedAt, window.localStorage);

      const render = async ({ fresh, coveredAt, quotaAt, usedPercent }) => {
        const nextSnapshot = quotaSnapshot(resetAt);
        nextSnapshot.sevenDay.usedPercent = usedPercent;
        nextSnapshot.sevenDay.remainingPercent = 1 - usedPercent;
        await React.act(async () => root.render(React.createElement(QuotaStrip, {
          attributionIdentity: { scopeKey: "sha256:account-a", plan: "Pro", limit: "codex" },
          preciseDataAvailable: true,
          preciseDataCoveredAt: new Date(coveredAt * 1_000).toISOString(),
          preciseDataFresh: fresh,
          ...observerProps(),
          quotaUpdatedAt: new Date(quotaAt * 1_000).toISOString(),
          recentUsage24h: [],
          snapshot: nextSnapshot,
          sourceHomeIdentity: "home-a",
        })));
      };

      try {
        await render({
          fresh: false,
          coveredAt: boundary,
          quotaAt: recoveryQuotaAt,
          usedPercent: 0.2,
        });
        assert.deepEqual(readAttributionSegment(segmentKey, window.localStorage), durable);
        assert.notEqual(readPreciseUsageContinuityGap("home-a", window.localStorage), null);

        await render({
          fresh: true,
          coveredAt: recoveryCoverageAt,
          quotaAt: recoveryQuotaAt,
          usedPercent: 0.2,
        });
        const pending = readAttributionSegment(segmentKey, window.localStorage);
        assert.equal(pending.cutoverReason, "continuityGap");
        assert.equal(pending.baselineReady, false);
        assert.equal(pending.segmentStartUnix, completedBucketBoundary(recoveryCoverageAt));
        assert.notEqual(readPreciseUsageContinuityGap("home-a", window.localStorage), null);
        assert.match(
          container.querySelector(".shared-attribution-trigger")?.textContent ?? "",
          /连续性基线待刷新/,
        );

        const baselineQuotaAt = Math.max(pending.segmentStartUnix, recoveryQuotaAt + 1);
        await render({
          fresh: true,
          coveredAt: baselineQuotaAt,
          quotaAt: baselineQuotaAt,
          usedPercent: 0.21,
        });
        const finalized = readAttributionSegment(segmentKey, window.localStorage);
        assert.equal(finalized.baselineReady, true);
        assert.equal(finalized.baselineAccountUsedPercent, 21);
        assert.equal(finalized.cutoverReason, "continuityGap");
        assert.equal(readPreciseUsageContinuityGap("home-a", window.localStorage), null);
      } finally {
        await React.act(async () => root.unmount());
      }
    });
  } finally {
    delete globalThis.IS_REACT_ACT_ENVIRONMENT;
    restoreGlobals();
    window.close();
  }
});

test("native unsafe scans never advance state and each clean episode creates one pending cutover", async () => {
  const window = new Window({ url: "http://localhost/" });
  const restoreGlobals = installDomGlobals(window);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { QuotaStrip } = await load("/src/components/QuotaStrip.tsx");
      const {
        attributionSegmentStorageKey,
        readAttributionSegment,
      } = await load("/src/components/sharedAccountAttribution/segment.ts");
      const container = window.document.createElement("div");
      window.document.body.append(container);
      const root = createRoot(container);
      const nowUnix = Math.floor(Date.now() / 1_000);
      const firstObservedAt = Math.floor((nowUnix - 1_800) / 300) * 300;
      const resetAt = nowUnix + 6 * 24 * 60 * 60;
      const unsafeA = "11111111-aaaa-4aaa-8aaa-111111111111";
      const unsafeB = "22222222-bbbb-4bbb-8bbb-222222222222";
      const acknowledgements = [];
      let refreshes = 0;
      const shared = {
        attributionIdentity: { scopeKey: "sha256:account-a", plan: "Pro", limit: "codex" },
        onAttributionSafetyAcknowledge: async (...values) => {
          acknowledgements.push(values);
          return true;
        },
        onAttributionSafetyRefreshNeeded: () => { refreshes += 1; },
        preciseDataAvailable: true,
        ...observerProps(),
        recentUsage24h: [point(firstObservedAt - 300)],
        snapshot: quotaSnapshot(resetAt),
        sourceHomeIdentity: "home-a",
      };
      seedObserver(window.localStorage, "home-a");
      try {
        await React.act(async () => root.render(React.createElement(QuotaStrip, {
          ...shared,
          preciseDataCoveredAt: new Date(firstObservedAt * 1_000).toISOString(),
          preciseDataFresh: true,
          preciseAttributionGeneration: 2,
          preciseAttributionUnsafeSinceGeneration: 2,
          preciseAttributionUnsafeID: unsafeA,
          preciseAttributionCurrentScanUnsafe: true,
          quotaUpdatedAt: new Date(firstObservedAt * 1_000).toISOString(),
        })));
        assert.match(container.textContent, /本机历史安全检查中/);
        assert.equal(readAttributionSegment(
          attributionSegmentStorageKey("home-a"),
          window.localStorage,
        ), null);
        assert.equal(acknowledgements.length, 0);

        const firstCleanAt = firstObservedAt + 300;
        await React.act(async () => root.render(React.createElement(QuotaStrip, {
          ...shared,
          preciseDataCoveredAt: new Date(firstCleanAt * 1_000).toISOString(),
          preciseDataFresh: true,
          preciseAttributionGeneration: 3,
          preciseAttributionUnsafeSinceGeneration: 2,
          preciseAttributionUnsafeID: unsafeA,
          preciseAttributionCurrentScanUnsafe: false,
          quotaUpdatedAt: new Date(firstCleanAt * 1_000).toISOString(),
        })));
        const pendingA = readAttributionSegment(
          attributionSegmentStorageKey("home-a"),
          window.localStorage,
        );
        assert.equal(pendingA.continuityGapID, unsafeA);
        assert.equal(pendingA.baselineReady, false);
        assert.deepEqual(acknowledgements, [[
          TEST_OBSERVER.preciseAttributionProvenanceEpoch,
          unsafeA,
          3,
        ]]);

        const readyAt = firstCleanAt + 600;
        await React.act(async () => root.render(React.createElement(QuotaStrip, {
          ...shared,
          preciseDataCoveredAt: new Date(readyAt * 1_000).toISOString(),
          preciseDataFresh: true,
          preciseAttributionGeneration: 4,
          preciseAttributionUnsafeSinceGeneration: null,
          preciseAttributionUnsafeID: null,
          preciseAttributionCurrentScanUnsafe: false,
          quotaUpdatedAt: new Date(readyAt * 1_000).toISOString(),
        })));
        const readyA = readAttributionSegment(
          attributionSegmentStorageKey("home-a"),
          window.localStorage,
        );
        assert.equal(readyA.baselineReady, true);

        const unsafeBAt = readyAt + 300;
        await React.act(async () => root.render(React.createElement(QuotaStrip, {
          ...shared,
          preciseDataCoveredAt: new Date(unsafeBAt * 1_000).toISOString(),
          preciseDataFresh: true,
          preciseAttributionGeneration: 5,
          preciseAttributionUnsafeSinceGeneration: 5,
          preciseAttributionUnsafeID: unsafeB,
          preciseAttributionCurrentScanUnsafe: true,
          quotaUpdatedAt: new Date(unsafeBAt * 1_000).toISOString(),
        })));
        assert.equal(readAttributionSegment(
          attributionSegmentStorageKey("home-a"),
          window.localStorage,
        ).baselineReady, true);
        assert.equal(acknowledgements.length, 1);

        const cleanBAt = unsafeBAt + 300;
        await React.act(async () => root.render(React.createElement(QuotaStrip, {
          ...shared,
          preciseDataCoveredAt: new Date(cleanBAt * 1_000).toISOString(),
          preciseDataFresh: true,
          preciseAttributionGeneration: 6,
          preciseAttributionUnsafeSinceGeneration: 5,
          preciseAttributionUnsafeID: unsafeB,
          preciseAttributionCurrentScanUnsafe: false,
          quotaUpdatedAt: new Date(cleanBAt * 1_000).toISOString(),
        })));
        const pendingB = readAttributionSegment(
          attributionSegmentStorageKey("home-a"),
          window.localStorage,
        );
        assert.equal(pendingB.continuityGapID, unsafeB);
        assert.equal(pendingB.baselineReady, false);
        assert.equal(acknowledgements.length, 2);
        assert.equal(refreshes, 0);
      } finally {
        await React.act(async () => root.unmount());
      }
    });
  } finally {
    delete globalThis.IS_REACT_ACT_ENVIRONMENT;
    restoreGlobals();
    window.close();
  }
});

test("an expired owner takes over even when corrupt continuity first needs quarantine", async () => {
  const window = new Window({ url: "http://localhost/" });
  const restoreGlobals = installDomGlobals(window);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { QuotaStrip } = await load("/src/components/QuotaStrip.tsx");
      const {
        attributionPersistenceOwnerStorageKey,
        readAttributionPersistenceOwnerState,
      } = await load("/src/components/sharedAccountAttribution/persistenceOwner.ts");
      const {
        attributionSegmentStorageKey,
        readAttributionSegment,
      } = await load("/src/components/sharedAccountAttribution/segment.ts");
      const {
        preciseUsageContinuityStorageKey,
        readPreciseUsageContinuityGap,
      } = await load(
        "/src/state/preciseUsageContinuity.ts",
      );
      const container = window.document.createElement("div");
      window.document.body.append(container);
      const root = createRoot(container);
      const nowUnix = Math.floor(Date.now() / 1_000);
      const observedAt = Math.floor((nowUnix - 900) / 300) * 300;
      const resetAt = nowUnix + 6 * 24 * 60 * 60;
      const oldEpoch = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
      window.localStorage.setItem(
        attributionPersistenceOwnerStorageKey("home-a"),
        JSON.stringify({
          ownerID: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
          observationEpoch: oldEpoch,
          sequence: 4,
          leaseUntilUnixMs: Date.now() - 1,
        }),
      );
      window.localStorage.setItem(
        preciseUsageContinuityStorageKey("home-a"),
        "{broken-continuity",
      );
      seedObserver(window.localStorage, "home-a");
      let refreshes = 0;
      try {
        await React.act(async () => root.render(React.createElement(QuotaStrip, {
          attributionIdentity: { scopeKey: "sha256:account-a", plan: "Pro", limit: "codex" },
          onAttributionSafetyRefreshNeeded: () => { refreshes += 1; },
          preciseDataAvailable: true,
          preciseDataCoveredAt: new Date(observedAt * 1_000).toISOString(),
          preciseDataFresh: true,
          ...observerProps(),
          quotaUpdatedAt: new Date(observedAt * 1_000).toISOString(),
          recentUsage24h: [point(observedAt - 300)],
          snapshot: quotaSnapshot(resetAt),
          sourceHomeIdentity: "home-a",
        })));
        const owner = readAttributionPersistenceOwnerState("home-a", window.localStorage).lease;
        assert.equal(owner.sequence, 5);
        assert.notEqual(owner.observationEpoch, oldEpoch);
        assert.notEqual(readPreciseUsageContinuityGap("home-a", window.localStorage), null);
        const pending = readAttributionSegment(
          attributionSegmentStorageKey("home-a"),
          window.localStorage,
        );
        assert.equal(pending.baselineReady, false);
        assert.equal(pending.cutoverReason, "continuityGap");
        assert.equal(refreshes, 1);
      } finally {
        await React.act(async () => root.unmount());
      }
    });
  } finally {
    delete globalThis.IS_REACT_ACT_ENVIRONMENT;
    restoreGlobals();
    window.close();
  }
});

test("a precise-read failure is persisted only after the Web-Lock owner receives it", async () => {
  const window = new Window({ url: "http://localhost/" });
  const restoreGlobals = installDomGlobals(window);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { QuotaStrip } = await load("/src/components/QuotaStrip.tsx");
      const { publishPreciseUsageFailure } = await load(
        "/src/state/preciseUsageFailureChannel.ts",
      );
      const { readPreciseUsageContinuityGap } = await load(
        "/src/state/preciseUsageContinuity.ts",
      );
      const container = window.document.createElement("div");
      window.document.body.append(container);
      const root = createRoot(container);
      const nowUnix = Math.floor(Date.now() / 1_000);
      const observedAt = Math.floor((nowUnix - 900) / 300) * 300;
      seedObserver(window.localStorage, "home-a");
      let refreshes = 0;
      try {
        await React.act(async () => root.render(React.createElement(QuotaStrip, {
          attributionIdentity: { scopeKey: "sha256:account-a", plan: "Pro", limit: "codex" },
          onAttributionSafetyRefreshNeeded: () => { refreshes += 1; },
          preciseDataAvailable: true,
          preciseDataCoveredAt: new Date(observedAt * 1_000).toISOString(),
          preciseDataFresh: true,
          ...observerProps(),
          quotaUpdatedAt: new Date(observedAt * 1_000).toISOString(),
          recentUsage24h: [point(observedAt - 300)],
          snapshot: quotaSnapshot(nowUnix + 6 * 24 * 60 * 60),
          sourceHomeIdentity: "home-a",
        })));
        assert.equal(readPreciseUsageContinuityGap("home-a", window.localStorage), null);

        await React.act(async () => {
          publishPreciseUsageFailure("home-a", observedAt);
          await Promise.resolve();
        });

        const gap = readPreciseUsageContinuityGap("home-a", window.localStorage);
        assert.notEqual(gap, null);
        assert.equal(gap.detectedAtUnix, observedAt);
        assert.equal(refreshes, 1);
      } finally {
        await React.act(async () => root.unmount());
      }
    });
  } finally {
    delete globalThis.IS_REACT_ACT_ENVIRONMENT;
    restoreGlobals();
    window.close();
  }
});

function point(startUnix) {
  return {
    label: "bucket",
    startUnix,
    tokens: 1_000_000,
    calls: 1,
    inputTokens: 1_000_000,
    cachedInputTokens: 0,
    outputTokens: 0,
    cacheHitRate: 0,
    fiveHourRemainingPercent: null,
    sevenDayRemainingPercent: 0.9,
    sourceContributionEpoch: "dom-epoch-a",
    sourceContributions: [{
      sourceId: "opaque-source-a",
      tokens: 1_000_000,
      calls: 1,
      inputTokens: 1_000_000,
      cachedInputTokens: 0,
      outputTokens: 0,
    }],
  };
}

function quotaSnapshot(resetAtUnix) {
  return {
    fiveHour: {
      label: "5h",
      availability: "measured",
      remainingPercent: 0.8,
      usedPercent: 0.2,
      resetsAt: "2h",
      resetsAtUnix: resetAtUnix - 5 * 24 * 60 * 60,
    },
    sevenDay: {
      label: "7d",
      availability: "measured",
      remainingPercent: 0.9,
      usedPercent: 0.1,
      resetsAt: "6天",
      resetsAtUnix: resetAtUnix,
    },
    resetCredit: { availableCount: 0, status: "empty", credits: [] },
    paceLabel: "稳定",
  };
}

function storageKeys(storage) {
  return Array.from({ length: storage.length }, (_, index) => storage.key(index)).filter(Boolean);
}

const TEST_OBSERVER = {
  preciseObserverEpoch: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  preciseObserverStartedAtUnixMicros: 1_000_000,
  preciseObserverSequence: 0,
  preciseAttributionProvenanceEpoch: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
  preciseAttributionGeneration: 1,
  preciseAttributionUnsafeSinceGeneration: null,
  preciseAttributionUnsafeID: null,
  preciseAttributionCurrentScanUnsafe: false,
};

function observerProps() {
  return TEST_OBSERVER;
}

function seedObserver(storage, sourceHomeIdentity) {
  let hash = 0x811c9dc5;
  for (let index = 0; index < sourceHomeIdentity.length; index += 1) {
    hash ^= sourceHomeIdentity.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193);
  }
  const identityHash = (hash >>> 0).toString(16).padStart(8, "0");
  storage.setItem(
    `sharedAccountAttributionPreciseObserver:v1:${identityHash}`,
    JSON.stringify({
      epoch: TEST_OBSERVER.preciseObserverEpoch,
      startedAtUnixMicros: TEST_OBSERVER.preciseObserverStartedAtUnixMicros,
      sequence: TEST_OBSERVER.preciseObserverSequence,
    }),
  );
}

function installDomGlobals(window) {
  const values = {
    window,
    document: window.document,
    navigator: window.navigator,
    Node: window.Node,
    Element: window.Element,
    HTMLElement: window.HTMLElement,
    SVGElement: window.SVGElement,
    Event: window.Event,
    CustomEvent: window.CustomEvent,
    StorageEvent: window.StorageEvent,
    KeyboardEvent: window.KeyboardEvent,
    MutationObserver: window.MutationObserver,
    ResizeObserver: window.ResizeObserver,
    getComputedStyle: window.getComputedStyle.bind(window),
  };
  const previous = new Map();
  for (const [name, value] of Object.entries(values)) {
    previous.set(name, Object.getOwnPropertyDescriptor(globalThis, name));
    Object.defineProperty(globalThis, name, { configurable: true, value, writable: true });
  }
  return () => {
    for (const [name, descriptor] of previous) {
      if (descriptor) Object.defineProperty(globalThis, name, descriptor);
      else delete globalThis[name];
    }
  };
}
