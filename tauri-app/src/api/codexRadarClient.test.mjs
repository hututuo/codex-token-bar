import assert from "node:assert/strict";
import test from "node:test";

import { withSsrModules } from "../test/ssrHarness.mjs";

globalThis.window = {
  clearTimeout: globalThis.clearTimeout.bind(globalThis),
  setTimeout: globalThis.setTimeout.bind(globalThis),
};

test("initial Codex Radar root failure reports diagnostics without fake snapshot data", async () => {
  await withSsrModules(async (load) => {
    const { __resetCodexRadarCacheForTests, readCodexRadarState } = await load("/src/api/codexRadarClient.ts");
    __resetCodexRadarCacheForTests();
    withFetchQueue([
      response("upstream unavailable", { status: 503 }),
    ]);

    const state = await readCodexRadarState(null, { force: true });

    assert.equal(state.snapshot, null);
    assert.equal(state.staleDataDisplayed, false);
    assert.equal(state.feedStaleDataDisplayed, false);
    assert.deepEqual(state.diagnostics.map((item) => item.category), ["http_server"]);
    assert.match(state.diagnostics[0].message, /Codex 雷达读取失败/);
    assert.match(state.statusText, /Codex 雷达读取失败/);
  });
});

test("empty Codex Radar root payload is treated as a failure without fake IQ data", async () => {
  await withSsrModules(async (load) => {
    const { __resetCodexRadarCacheForTests, readCodexRadarState } = await load("/src/api/codexRadarClient.ts");
    __resetCodexRadarCacheForTests();
    withFetchQueue([
      jsonResponse({}),
    ]);

    const state = await readCodexRadarState(null, { force: true });

    assert.equal(state.snapshot, null);
    assert.deepEqual(state.diagnostics.map((item) => item.category), ["empty_radar_payload"]);
    assert.match(state.statusText, /空数据/);
  });
});

test("a changed IQ block no longer makes the Radar client reject healthy window and quota data", async () => {
  await withSsrModules(async (load) => {
    const { __resetCodexRadarCacheForTests, readCodexRadarState } = await load("/src/api/codexRadarClient.ts");
    __resetCodexRadarCacheForTests();
    const partial = snapshotFixture();
    partial.prediction = { unexpected_v3: { value: 1 } };
    partial.model_iq.latest = { score: { new_shape: 125 } };
    partial.model_iq.quota_radar = {
      rows: [{ tier: "Plus", seven_d: "97.24", basis: "estimated" }],
    };
    withFetchQueue([
      jsonResponse(partial),
      textResponse(feedFixture("partial-radar")),
    ]);

    const state = await readCodexRadarState(null, { force: true });

    assert.equal(state.snapshot?.window.message, "当前没有开启的速蹬窗口");
    assert.equal(state.snapshot?.modelIq.latest.scoreAvailable, false);
    assert.equal(state.snapshot?.modelIq.quotaRadar?.rows[0].sevenD, 97.24);
    assert.deepEqual(state.snapshot?.feedItems.map((item) => item.guid), ["partial-radar"]);
    assert.equal(state.diagnostics.length, 0);
  });
});

test("Codex Radar root failures keep machine-readable categories", async () => {
  await withSsrModules(async (load) => {
    const { __resetCodexRadarCacheForTests, readCodexRadarState } = await load("/src/api/codexRadarClient.ts");
    for (const [status, category] of [
      [401, "http_auth"],
      [429, "http_rate_limited"],
      [503, "http_server"],
      [418, "http_other"],
    ]) {
      __resetCodexRadarCacheForTests();
      withFetchQueue([response("error", { status })]);
      const state = await readCodexRadarState(null, { force: true });
      assert.deepEqual(state.diagnostics.map((item) => item.category), [category]);
    }

    __resetCodexRadarCacheForTests();
    globalThis.fetch = async () => {
      throw new TypeError("Failed to fetch");
    };
    assert.deepEqual(
      (await readCodexRadarState(null, { force: true })).diagnostics.map((item) => item.category),
      ["network_fetch"],
    );

    __resetCodexRadarCacheForTests();
    withFetchQueue([response("{", { status: 200 })]);
    assert.deepEqual(
      (await readCodexRadarState(null, { force: true })).diagnostics.map((item) => item.category),
      ["parse_failure"],
    );
  });
});

test("public Codex Radar summary fetch uses current.json without authorization", async () => {
  await withSsrModules(async (load) => {
    const { __resetCodexRadarCacheForTests, readCodexRadarState } = await load("/src/api/codexRadarClient.ts");
    __resetCodexRadarCacheForTests();
    const calls = withFetchQueue([
      jsonResponse(snapshotFixture()),
      textResponse(feedFixture("radar-public")),
    ]);

    await readCodexRadarState(null, { force: true });

    assert.equal(String(calls[0].input), "https://codexradar.com/current.json");
    assert.equal(calls[0].init?.headers?.Authorization, undefined);
    assert.equal(calls[0].init?.headers?.authorization, undefined);
  });
});

test("successful Radar refreshes publish one shared snapshot to every surface", async () => {
  await withSsrModules(async (load) => {
    const {
      __resetCodexRadarCacheForTests,
      readCodexRadarState,
      subscribeCodexRadarState,
    } = await load("/src/api/codexRadarClient.ts");
    __resetCodexRadarCacheForTests();
    withFetchQueue([
      jsonResponse(snapshotFixture({ monitored_at: "2026-07-13T08:00:00+08:00" })),
      textResponse(feedFixture("radar-old")),
      jsonResponse(snapshotFixture({ monitored_at: "2026-07-13T08:10:00+08:00" })),
      textResponse(feedFixture("radar-current")),
    ]);
    const observed = [];
    const unsubscribe = subscribeCodexRadarState((state) => {
      observed.push(state.snapshot?.monitoredAt ?? null);
    });

    await readCodexRadarState(null, { force: true });
    await readCodexRadarState(null, { force: true });
    unsubscribe();

    assert.deepEqual(observed, [
      "2026-07-13T08:00:00+08:00",
      "2026-07-13T08:10:00+08:00",
    ]);
  });
});


test("Codex Radar root failure after success preserves prior snapshot and marks stale data", async () => {
  await withSsrModules(async (load) => {
    const { __resetCodexRadarCacheForTests, readCodexRadarState } = await load("/src/api/codexRadarClient.ts");
    __resetCodexRadarCacheForTests();
    withFetchQueue([
      jsonResponse(snapshotFixture({ monitored_at: "2026-07-06T02:00:00+08:00", recommended_action: "wait" })),
      textResponse(feedFixture("radar-a")),
      response("gateway", { status: 502 }),
    ]);

    const first = await readCodexRadarState(null, { force: true });
    const stale = await readCodexRadarState(first.snapshot, { force: true });

    assert.equal(stale.snapshot?.recommendedAction, "wait");
    assert.deepEqual(stale.snapshot?.feedItems.map((item) => item.guid), ["radar-a"]);
    assert.equal(stale.snapshot?.staleDataDisplayed, true);
    assert.equal(stale.staleDataDisplayed, true);
    assert.deepEqual(stale.diagnostics.map((item) => item.category), ["http_server", "stale_cached_data"]);
    assert.match(stale.statusText, /显示上次成功数据/);
  });
});

test("Codex Radar RSS failure preserves previous feed while refreshing root snapshot", async () => {
  await withSsrModules(async (load) => {
    const { __resetCodexRadarCacheForTests, readCodexRadarState } = await load("/src/api/codexRadarClient.ts");
    __resetCodexRadarCacheForTests();
    withFetchQueue([
      jsonResponse(snapshotFixture({ monitored_at: "2026-07-06T02:00:00+08:00", recommended_action: "wait" })),
      textResponse(feedFixture("radar-a")),
      jsonResponse(snapshotFixture({ monitored_at: "2026-07-06T02:10:00+08:00", recommended_action: "run" })),
      response("rss down", { status: 500 }),
    ]);

    const first = await readCodexRadarState(null, { force: true });
    const partial = await readCodexRadarState(first.snapshot, { force: true });

    assert.equal(partial.snapshot?.monitoredAt, "2026-07-06T02:10:00+08:00");
    assert.equal(partial.snapshot?.recommendedAction, "run");
    assert.deepEqual(partial.snapshot?.feedItems.map((item) => item.guid), ["radar-a"]);
    assert.equal(partial.snapshot?.staleDataDisplayed, false);
    assert.equal(partial.snapshot?.feedStaleDataDisplayed, true);
    assert.deepEqual(partial.diagnostics.map((item) => item.category), ["rss_failure"]);
  });
});

test("Codex Radar full success clears previous stale diagnostics", async () => {
  await withSsrModules(async (load) => {
    const { __resetCodexRadarCacheForTests, readCodexRadarState } = await load("/src/api/codexRadarClient.ts");
    __resetCodexRadarCacheForTests();
    withFetchQueue([
      jsonResponse(snapshotFixture({ monitored_at: "2026-07-06T02:00:00+08:00" })),
      textResponse(feedFixture("radar-a")),
      jsonResponse(snapshotFixture({ monitored_at: "2026-07-06T02:10:00+08:00" })),
      response("rss down", { status: 500 }),
      jsonResponse(snapshotFixture({ monitored_at: "2026-07-06T02:20:00+08:00" })),
      textResponse(feedFixture("radar-b")),
    ]);

    const first = await readCodexRadarState(null, { force: true });
    const partial = await readCodexRadarState(first.snapshot, { force: true });
    const recovered = await readCodexRadarState(partial.snapshot, { force: true });

    assert.equal(recovered.snapshot?.monitoredAt, "2026-07-06T02:20:00+08:00");
    assert.deepEqual(recovered.snapshot?.feedItems.map((item) => item.guid), ["radar-b"]);
    assert.equal(recovered.snapshot?.staleDataDisplayed, false);
    assert.equal(recovered.snapshot?.feedStaleDataDisplayed, false);
    assert.deepEqual(recovered.snapshot?.diagnostics, []);
    assert.deepEqual(recovered.diagnostics, []);
  });
});

function withFetchQueue(queue) {
  const calls = [...queue];
  const observed = [];
  globalThis.fetch = async (input, init) => {
    observed.push({ input, init });
    const next = calls.shift();
    assert.ok(next, "unexpected extra fetch call");
    return next;
  };
  return observed;
}

function response(body, { status = 200 } = {}) {
  return {
    ok: status >= 200 && status < 300,
    status,
    async json() {
      return JSON.parse(String(body));
    },
    async text() {
      return String(body);
    },
  };
}

function jsonResponse(body, options) {
  return response(JSON.stringify(body), options);
}

function textResponse(body, options) {
  return response(body, options);
}

function snapshotFixture(overrides = {}) {
  return {
    schema_version: "1",
    service: "codex-radar",
    monitored_at: "2026-07-06T02:00:00+08:00",
    timezone: "Asia/Shanghai",
    window_open: false,
    status: "normal",
    recommended_action: "wait",
    window: {
      open: false,
      status: "closed",
      action: "wait",
      message: "当前没有开启的速蹬窗口",
      title: "无窗口",
      scope: "Codex 用户",
    },
    prediction: {
      level: "low",
      probability_24h: 0.12,
      probability_48h: 0.24,
      expected_window: "未来 24-48 小时",
      summary: "保持观察",
      positive_signals: [],
      negative_signals: [],
      updated_at: "2026-07-06T02:00:00+08:00",
    },
    links: {
      html: "https://codexradar.com",
      rss: "https://codexradar.com/feed.xml",
    },
    model_iq: {
      latest: {
        date: "2026-07-06-pm",
        score: 100,
        status: "green",
        passed: 4,
        tasks: 5,
        invalid: 0,
        valid_tasks: 5,
        total_tokens: 10000,
        input_tokens: 6000,
        cached_input_tokens: 2000,
        output_tokens: 4000,
        wall_seconds: 120,
        wall_time_human: "2m",
        model: "gpt-5.5",
        reasoning_effort: "high",
        cost_usd: 1,
      },
      recent_days: [],
      comparisons: {},
    },
    codex_environment: {
      schema_version: "1",
      type: "radar",
      updated_at: "2026-07-06T02:00:00+08:00",
      complaint_pressure: "low",
      official_news: [],
      status_incidents: [],
      complaint_examples: [],
      role_counts: {},
    },
    ...overrides,
  };
}

function feedFixture(guid) {
  return `
    <rss>
      <channel>
        <item>
          <title>提醒 ${guid}</title>
          <link>https://codexradar.com/#${guid}</link>
          <guid>${guid}</guid>
          <pubDate>2026-07-06 02:00</pubDate>
          <description>测试提醒</description>
        </item>
      </channel>
    </rss>
  `;
}
