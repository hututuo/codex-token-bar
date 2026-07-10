import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { withSsrModules } from "../test/ssrHarness.mjs";

import {
  acceptDashboardSourceEnvelope,
  acceptDashboardSourceResponse,
  captureDashboardSourceToken,
  createDashboardSourceTransition,
  publishForDashboardSource,
} from "./dashboardSourceTransition.ts";

const COMPLETION_KINDS = [
  "initial",
  "status",
  "fast",
  "precise",
  "quota",
  "thread",
  "live",
  "unread",
  "provider",
];

test("A to auto to B rejects every old controlled completion regardless of release order", async () => {
  let transition = createDashboardSourceTransition();
  transition = acceptedTransition(transition, envelope("/source/A", 1, "manual"));

  const published = [];
  const pendingA = startControlledCompletions("A", transition, () => transition, published);

  transition = acceptedTransition(transition, envelope("/source/auto", 2, "auto"));
  const pendingAuto = startControlledCompletions("auto", transition, () => transition, published);

  transition = acceptedTransition(transition, envelope("/source/B", 3, "manual"));
  const pendingB = startControlledCompletions("B", transition, () => transition, published);

  const releaseOrder = [
    pendingA[2], pendingB[5], pendingAuto[0], pendingB[0], pendingA[8],
    pendingAuto[4], pendingB[8], pendingA[0], pendingB[2], pendingAuto[8],
    pendingB[1], pendingA[4], pendingAuto[2], pendingB[4], pendingA[5],
    pendingAuto[5], pendingB[3], pendingA[1], pendingAuto[1], pendingB[6],
    pendingA[3], pendingAuto[3], pendingB[7], pendingA[6], pendingAuto[6],
    pendingA[7], pendingAuto[7],
  ];
  for (const pending of releaseOrder) {
    pending.resolve();
  }
  await Promise.all([...pendingA, ...pendingAuto, ...pendingB].map(({ promise }) => promise));

  assert.deepEqual(
    published.sort(),
    COMPLETION_KINDS.map((kind) => `B:${kind}`).sort(),
  );
});

test("same canonical source command and event envelopes do not advance deferred generations", () => {
  let transition = createDashboardSourceTransition();

  const a = acceptDashboardSourceEnvelope(transition, envelope("/source/A", 10, "manual"));
  assert.equal(a.accepted, true);
  assert.equal(a.sourceChanged, false);
  transition = a.transition;

  for (const duplicate of [
    envelope("/source/A", 10, "manual"),
    envelope("/source/A", 10, "auto"),
    envelope("/source/A", 10, "manual"),
  ]) {
    const result = acceptDashboardSourceEnvelope(transition, duplicate);
    assert.equal(result.accepted, true);
    assert.equal(result.sourceChanged, false);
    transition = result.transition;
  }
  assert.equal(transition.deferredGeneration, 0);

  const contradictorySameSourceGeneration = acceptDashboardSourceEnvelope(
    transition,
    envelope("/source/A", 11, "manual"),
  );
  assert.equal(contradictorySameSourceGeneration.accepted, false);
  assert.equal(contradictorySameSourceGeneration.transition, transition);

  const automatic = acceptDashboardSourceEnvelope(
    transition,
    envelope("/source/auto", 11, "auto"),
  );
  assert.equal(automatic.sourceChanged, true);
  transition = automatic.transition;
  assert.equal(transition.deferredGeneration, 1);

  const automaticEventDuplicate = acceptDashboardSourceEnvelope(
    transition,
    envelope("/source/auto", 11, "auto"),
  );
  assert.equal(automaticEventDuplicate.sourceChanged, false);
  transition = automaticEventDuplicate.transition;
  assert.equal(transition.deferredGeneration, 1);

  const b = acceptDashboardSourceEnvelope(
    transition,
    envelope("/source/B", 12, "manual"),
  );
  assert.equal(b.sourceChanged, true);
  transition = b.transition;
  assert.equal(transition.deferredGeneration, 2);

  const staleAuto = acceptDashboardSourceEnvelope(
    transition,
    envelope("/source/auto", 11, "auto"),
  );
  assert.equal(staleAuto.accepted, false);
  assert.equal(staleAuto.transition, transition);
  assert.equal(transition.deferredGeneration, 2);
});

test("completion publication requires the exact generation and canonical source", () => {
  let transition = createDashboardSourceTransition();
  transition = acceptedTransition(transition, envelope("/source/A", 1, "manual"));
  const aToken = captureDashboardSourceToken(transition);
  transition = acceptedTransition(transition, envelope("/source/B", 2, "manual"));
  const bToken = captureDashboardSourceToken(transition);
  const published = [];

  assert.equal(publishForDashboardSource(transition, aToken, () => published.push("A")), false);
  assert.equal(publishForDashboardSource(
    transition,
    { ...bToken, canonicalHomeKey: "/source/not-B" },
    () => published.push("wrong-source"),
  ), false);
  assert.equal(publishForDashboardSource(transition, bToken, () => published.push("B")), true);
  assert.deepEqual(published, ["B"]);
});

test("a queued A updater rechecks its token when React executes it after B", () => {
  let transition = createDashboardSourceTransition();
  transition = acceptedTransition(transition, envelope("/source/A", 1, "manual"));
  const aToken = captureDashboardSourceToken(transition);
  const published = [];
  const queuedUpdater = () => publishForDashboardSource(
    transition,
    aToken,
    () => published.push("A"),
  );

  transition = acceptedTransition(transition, envelope("/source/B", 2, "manual"));

  assert.equal(queuedUpdater(), false);
  assert.deepEqual(published, []);
});

test("Rust publisher and desktop listener share the canonical source event name", async () => {
  const [rustCommands, desktopEvents] = await Promise.all([
    readFile(new URL("../../src-tauri/src/commands/dashboard.rs", import.meta.url), "utf8"),
    readFile(new URL("../platform/desktopEvents.ts", import.meta.url), "utf8"),
  ]);

  assert.match(rustCommands, /CODEX_HOME_SOURCE_CHANGED_EVENT: &str = "codex-home-source-changed"/);
  assert.match(desktopEvents, /CODEX_HOME_SOURCE_CHANGED_EVENT = "codex-home-source-changed"/);
});

test("failed getCodexHome leaves source uninitialized so real generation one remains admissible", () => {
  let transition = createDashboardSourceTransition();

  const unavailable = acceptDashboardSourceResponse(transition, null);
  assert.equal(unavailable.accepted, false);
  assert.equal(unavailable.transition.sourceToken, null);
  transition = unavailable.transition;

  const real = acceptDashboardSourceResponse(
    transition,
    envelope("/source/real", 1, "manual"),
  );
  assert.equal(real.accepted, true);
  assert.equal(real.initialized, true);
  assert.equal(real.transition.sourceToken.canonicalHomeKey, "/source/real");
});

test("failed getCodexHome remains visible while dashboard data is still unavailable", async () => {
  await withSsrModules(async (load) => {
    const { visibleDashboardState } = await load("/src/state/dashboardState.ts");
    const visible = visibleDashboardState({
      codexHome: {
        path: "无法读取 Codex Home",
        exists: false,
        source: "读取失败",
      },
      platform: null,
      dashboard: null,
      liveRate: null,
      liveThreadOptions: [],
      repair: null,
      diagnostics: [],
      loading: false,
    });

    assert.equal(visible.codexHome.path, "无法读取 Codex Home");
    assert.equal(visible.codexHome.source, "读取失败");
  });
});

test("same-source save reloads initial data without clearing fast state thread or live feed", async () => {
  const source = await readFile(new URL("./useDashboardData.ts", import.meta.url), "utf8");
  const start = source.indexOf("const refreshCurrentSource");
  const end = source.indexOf("const {", start);
  const refreshBody = source.slice(start, end);

  assert.match(refreshBody, /setSourceLoadGeneration/);
  assert.doesNotMatch(refreshBody, /setFastSnapshotLoaded/);
  assert.doesNotMatch(refreshBody, /setSelectedLiveThreadId/);
  assert.doesNotMatch(refreshBody, /setLiveRateRetryGeneration/);
});

function acceptedTransition(transition, sourceEnvelope) {
  const result = acceptDashboardSourceEnvelope(transition, sourceEnvelope);
  assert.equal(result.accepted, true);
  return result.transition;
}

function envelope(canonicalHomeKey, transitionGeneration, source) {
  return {
    codexHome: {
      path: canonicalHomeKey,
      exists: true,
      source,
    },
    canonicalHomeKey,
    transitionGeneration,
  };
}

function startControlledCompletions(sourceName, transition, currentTransition, published) {
  return COMPLETION_KINDS.map((kind) => {
    const controlled = controlledPromise();
    const token = captureDashboardSourceToken(transition);
    controlled.promise.then(() => {
      publishForDashboardSource(currentTransition(), token, () => {
        published.push(`${sourceName}:${kind}`);
      });
    });
    return controlled;
  });
}

function controlledPromise() {
  let resolvePromise;
  const promise = new Promise((resolve) => {
    resolvePromise = resolve;
  });
  return {
    promise,
    resolve: () => resolvePromise(),
  };
}
