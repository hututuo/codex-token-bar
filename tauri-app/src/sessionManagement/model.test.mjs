import assert from "node:assert/strict";
import test from "node:test";
import { withSsrModules } from "../test/ssrHarness.mjs";

const NOW = new Date("2026-07-30T08:00:00.000Z");

test("session collections keep main, fork and subagent relationships separate", async () => {
  await withSsrModules(async (load) => {
    const { buildSessionCollections, buildSessionProjects } = await load("/src/sessionManagement/model.ts");
    const threads = [
      thread({ id: "root", cwd: "/work/alpha", forkChildCount: 1 }),
      thread({ id: "fork", cwd: "/work/alpha", forkedFromId: "root" }),
      thread({ id: "agent", cwd: "/work/alpha", isSubagent: true, parentThreadId: "root" }),
      thread({ id: "archived", archived: true, cwd: "/work/beta" }),
    ];
    const collections = Object.fromEntries(
      buildSessionCollections(threads, NOW).map((entry) => [entry.id, entry.count]),
    );

    assert.deepEqual(collections, {
      all: 3,
      recent: 3,
      archived: 1,
      large: 0,
      forks: 1,
      similar: 0,
      subagents: 1,
    });
    assert.deepEqual(buildSessionProjects(threads).map((project) => (
      [project.label, project.count]
    )), [["alpha", 2], ["beta", 1]]);
  });
});

test("filter searches the complete metadata set, sorts large and least-recent sessions", async () => {
  await withSsrModules(async (load) => {
    const { filterSessionThreads } = await load("/src/sessionManagement/model.ts");
    const threads = [
      thread({ id: "new-small", title: "Alpha", fileBytes: 20_000_000, recencyAt: 1_785_283_200 }),
      thread({ id: "old-large", title: "Beta", fileBytes: 2_000_000_000, recencyAt: 1_767_225_600 }),
      thread({ id: "agent-large", title: "Gamma", fileBytes: 3_000_000_000, isSubagent: true, recencyAt: 1_735_689_600 }),
      thread({ id: "unknown-large", title: "Unknown", fileBytes: 4_000_000_000, recencyAt: null, updatedAt: null, createdAt: null }),
    ];

    assert.deepEqual(filterSessionThreads(threads, {
      collection: "large",
      query: "",
      sort: "size",
      minimumSizeBytes: 10_000_000,
      idleDays: null,
      now: NOW,
    }).map((entry) => entry.id), ["unknown-large", "agent-large", "old-large", "new-small"]);
    assert.deepEqual(filterSessionThreads(threads, {
      collection: "all",
      query: "beta",
      sort: "recent",
      now: NOW,
    }).map((entry) => entry.id), ["old-large"]);
    assert.deepEqual(filterSessionThreads(threads, {
      collection: "large",
      query: "",
      sort: "leastRecent",
      minimumSizeBytes: 10_000_000,
      idleDays: 90,
      now: NOW,
    }).map((entry) => entry.id), ["agent-large", "old-large"]);
  });
});

test("fork collection contains only generated branches and supports old-session filtering", async () => {
  await withSsrModules(async (load) => {
    const { filterSessionThreads } = await load("/src/sessionManagement/model.ts");
    const threads = [
      thread({ id: "source", forkChildCount: 2, recencyAt: 1_735_689_600 }),
      thread({ id: "old-fork", forkedFromId: "source", recencyAt: 1_735_689_600 }),
      thread({ id: "new-fork", forkedFromId: "source", recencyAt: 1_785_283_200 }),
    ];

    assert.deepEqual(filterSessionThreads(threads, {
      collection: "forks",
      query: "",
      sort: "leastRecent",
      idleDays: 90,
      now: NOW,
    }).map((entry) => entry.id), ["old-fork"]);
  });
});

test("dangerous actions fail closed for active and protected sessions", async () => {
  await withSsrModules(async (load) => {
    const { eligibilityForMutation } = await load(
      "/src/sessionManagement/model.ts",
    );
    const unloaded = thread({ id: "unloaded", canDelete: true, status: "notLoaded" });
    const idle = thread({ id: "idle", canDelete: true, status: "idle" });
    const active = thread({ id: "active", canDelete: true, status: "active" });
    const pinned = thread({
      id: "pinned",
      canDelete: true,
      status: "notLoaded",
      protectionReasons: ["已固定"],
    });
    const eligibility = eligibilityForMutation([unloaded, idle, active, pinned], "delete");
    const recoveryEligibility = eligibilityForMutation(
      [unloaded, idle, active, pinned],
      "recoveryArchive",
    );

    assert.deepEqual(eligibility.eligible.map((entry) => entry.id), ["unloaded"]);
    assert.deepEqual(eligibility.blocked.map((entry) => entry.id), ["idle", "active", "pinned"]);
    assert.deepEqual(
      recoveryEligibility.eligible.map((entry) => entry.id),
      ["unloaded"],
      "an unloaded safe session can be packaged without first entering official archive",
    );
    assert.match(eligibility.reason, /已保留全部选择/);
    assert.match(eligibility.reason, /3 个仍在运行、加载或受保护/);
  });
});

test("session navigation advances and returns one hierarchy level at a time", async () => {
  await withSsrModules(async (load) => {
    const { nextSessionNavigationStage } = await load("/src/sessionManagement/model.ts");

    assert.equal(nextSessionNavigationStage("projects", "chooseCollection"), "sessions");
    assert.equal(nextSessionNavigationStage("sessions", "chooseThread"), "detail");
    assert.equal(nextSessionNavigationStage("detail", "back"), "sessions");
    assert.equal(nextSessionNavigationStage("sessions", "back"), "projects");
    assert.equal(nextSessionNavigationStage("projects", "back"), "projects");
  });
});

test("context pages merge without duplicate messages and preserve byte order", async () => {
  await withSsrModules(async (load) => {
    const { mergeContextMessages } = await load("/src/sessionManagement/model.ts");
    const merged = mergeContextMessages(
      [message("later", 200), message("same", 100)],
      [message("earlier", 10), message("same", 100)],
    );
    assert.deepEqual(merged.map((entry) => entry.id), ["earlier", "same", "later"]);
  });
});

test("delete impact expands every spawned descendant, removes redundant roots and keeps forks external", async () => {
  await withSsrModules(async (load) => {
    const { sessionDeletionImpact } = await load("/src/sessionManagement/model.ts");
    const root = thread({ id: "root", fileBytes: 100 });
    const child = thread({ id: "child", parentThreadId: "root", isSubagent: true, fileBytes: 200 });
    const grandchild = thread({
      id: "grandchild",
      parentThreadId: "child",
      isSubagent: true,
      fileBytes: 300,
    });
    const fork = thread({ id: "fork", forkedFromId: "child", fileBytes: 400 });
    const impact = sessionDeletionImpact(
      [root, child, grandchild, fork],
      [child, root],
    );

    assert.deepEqual(impact.effectiveRoots.map((entry) => entry.id), ["root"]);
    assert.deepEqual(impact.affected.map((entry) => entry.id), ["root", "child", "grandchild"]);
    assert.deepEqual(impact.indirectDescendants.map((entry) => entry.id), ["grandchild"]);
    assert.deepEqual(impact.externalForkReferences.map((entry) => entry.id), ["fork"]);
    assert.equal(impact.totalBytes, 600);
  });
});

test("delete impact fails closed when any implicit descendant is loaded or has unknown bytes", async () => {
  await withSsrModules(async (load) => {
    const { sessionDeletionImpact } = await load("/src/sessionManagement/model.ts");
    const root = thread({ id: "root", fileBytes: 100 });
    const activeChild = thread({
      id: "child",
      parentThreadId: "root",
      isSubagent: true,
      status: "active",
      fileBytes: null,
    });
    const impact = sessionDeletionImpact([root, activeChild], [root]);

    assert.deepEqual(impact.blockedAffected.map((entry) => entry.id), ["child"]);
    assert.equal(impact.totalBytes, null);
  });
});

test("actual Rust JSON fixture preserves Unix seconds and missing values", async () => {
  await withSsrModules(async (load) => {
    const { filterSessionThreads, formatSessionBytes, formatSessionTimestamp } = await load(
      "/src/sessionManagement/model.ts",
    );
    const parsed = JSON.parse(`{
      "threads":[{
        "id":"actual-json","title":"Actual","preview":"","cwd":"/work/actual",
        "createdAt":1785398400,"updatedAt":null,"recencyAt":1785398400,
        "archived":false,"archivedAt":null,"tokensUsed":null,"fileBytes":null,
        "fileModifiedAt":null,"status":"notLoaded","source":null,"model":null,
        "sessionId":null,"forkedFromId":null,"parentThreadId":null,"isSubagent":false,
        "spawnChildCount":0,"forkChildCount":0,"similarityGroupId":null,
        "similarityReason":null,"protectionReasons":[],"canArchive":true,
        "canUnarchive":false,"canDelete":true
      }],
      "generatedAt":1785398400
    }`);
    assert.equal(filterSessionThreads(parsed.threads, {
      collection: "all",
      query: "",
      sort: "recent",
      now: NOW,
    })[0].id, "actual-json");
    assert.match(formatSessionTimestamp(parsed.generatedAt), /2026/);
    assert.equal(formatSessionBytes(parsed.threads[0].fileBytes), "—");
  });
});

function thread(overrides = {}) {
  return {
    id: "thread",
    title: "Thread",
    preview: "Preview",
    cwd: "/work/project",
    createdAt: 1_751_328_000,
    updatedAt: 1_785_283_200,
    recencyAt: 1_785_283_200,
    archived: false,
    archivedAt: null,
    tokensUsed: 100,
    fileBytes: 1024,
    fileModifiedAt: 1_785_283_200,
    status: "notLoaded",
    source: "vscode",
    model: "gpt-5.6-sol",
    sessionId: "session",
    forkedFromId: null,
    parentThreadId: null,
    isSubagent: false,
    spawnChildCount: 0,
    forkChildCount: 0,
    similarityGroupId: null,
    similarityReason: null,
    protectionReasons: [],
    canArchive: true,
    canUnarchive: false,
    canDelete: true,
    ...overrides,
  };
}

function message(id, offset) {
  return {
    id,
    role: "user",
    content: id,
    timestamp: null,
    offset,
    kind: "message",
  };
}
