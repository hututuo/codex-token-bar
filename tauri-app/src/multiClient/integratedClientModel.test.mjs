import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { withSsrModules } from "../test/ssrHarness.mjs";
test("retained source does not display Codex during loading", async () =>
  withSsrModules(async (load) => {
    const { scopeClients } = await load(
      "/src/multiClient/integratedClientModel.ts",
    );
    assert.deepEqual(scopeClients("claudeCode", []), ["claudeCode"]);
    assert.deepEqual(scopeClients("all", ["gemini", "gemini"]), [
      "codex",
      "gemini",
    ]);
    assert.deepEqual(scopeClients("broken", []), ["codex"]);
  }));
test("quota adapters convert Codex fractions once, preserve Claude percent and unknown versus zero", async () =>
  withSsrModules(async (load) => {
    const { quotaItems, defaultQuotaSelection, orderedQuotaItems } = await load(
      "/src/multiClient/integratedClientModel.ts",
    );
    const items = quotaItems(
      {
        fiveHour: { availability: "measured", remainingPercent: 0 },
        sevenDay: { availability: "measured", remainingPercent: 0.92 },
      },
      { state: "notConnected", windows: [] },
      true,
    );
    assert.deepEqual(
      items.map((i) => i.remaining),
      [0, 92],
    );
    const selected = {
      ...defaultQuotaSelection,
      enabled: ["claudeCode:5h"],
      hidden: ["claudeCode:7d"],
      order: ["claudeCode:5h", "codex:7d"],
    };
    assert.deepEqual(
      orderedQuotaItems(items, selected, ["claudeCode"]).map((i) => i.id),
      [],
    );
    assert.deepEqual(
      orderedQuotaItems(items, selected, ["codex"]).map((i) => i.remaining),
      [92, 0],
    );
  }));
test("Claude quota only shows measured usable windows, including zero remaining", async () =>
  withSsrModules(async (load) => {
    const { quotaItems } = await load("/src/multiClient/integratedClientModel.ts");
    for (const state of ["missing", "notConnected", "stale", "invalid", "unavailable"])
      assert.equal(quotaItems(undefined, {state, windows:[{label:"5h", usedPercent:20}]}, true).filter(i => i.client === "claudeCode").length, 0);
    const items=quotaItems(undefined, {state:"available", windows:[{label:"5h",usedPercent:100}]}, true);
    assert.deepEqual(items.filter(i=>i.client === "claudeCode").map(i=>[i.id,i.remaining]), [["claudeCode:5h",0]]);
    const invalid=quotaItems(undefined, {state:"available",windows:[{label:"5h",usedPercent:NaN},{label:"7d",usedPercent:0}]}, true);
    assert.deepEqual(invalid.filter(i=>i.client === "claudeCode").map(i=>i.remaining), [100]);
  }));
test("left and right are distinct half arcs, never two upper semicircles", async () =>
  withSsrModules(async (load) => {
    const { PairedQuotaRing } = await load(
      "/src/multiClient/IntegratedClients.tsx",
    );
    const left = {
      id: "codex:7d",
      client: "codex",
      window: "7d",
      remaining: 92,
      resetsAt: null,
      source: "local",
      status: "",
    };
    const right = {
      ...left,
      id: "claudeCode:5h",
      client: "claudeCode",
      window: "5h",
      remaining: null,
      status: "未接入",
    };
    const html = renderToStaticMarkup(
      React.createElement(PairedQuotaRing, { left, right }),
    );
    assert.match(html, /rotate\(91 30 30\)/);
    assert.match(html, /rotate\(-89 30 30\)/);
    assert.match(html, /左侧 Codex 7d 92%/);
    assert.match(html, /右侧 Claude Code 5h —/);
    assert.doesNotMatch(html, /NaN|Infinity/);
  }));
test("auto shortens by height and never drops explicitly selected items", async () =>
  withSsrModules(async (load) => {
    const { railLayout, orderedQuotaItems, defaultQuotaSelection } = await load(
      "/src/multiClient/integratedClientModel.ts",
    );
    assert.equal(railLayout(2, "auto", true, 900).short, false);
    assert.equal(railLayout(4, "auto", true, 900).short, true);
    for (const n of [2, 4, 6, 10, 50, 500])
      for (const mode of ["auto", "long", "short"])
        assert.ok(railLayout(n, mode, true, 620).height <= 620);
    const items = Array.from({ length: 100 }, (_, i) => ({
      id: `codex:${i}`,
      client: "codex",
    }));
    assert.equal(
      orderedQuotaItems(items, defaultQuotaSelection, ["codex"]).length,
      100,
    );
  }));

test("PRO without 5h renders a whole ring; Claude keeps both independent halves", async () =>
  withSsrModules(async (load) => {
    const { quotaRingGroups, decodeQuotaSelection } = await load(
      "/src/multiClient/integratedClientModel.ts",
    );
    const { PairedQuotaRing } = await load(
      "/src/multiClient/IntegratedClients.tsx",
    );
    const codex = {
      id: "codex:7d",
      client: "codex",
      window: "7d",
      remaining: 92,
      status: "",
    };
    const claude = ["5h", "7d"].map((window) => ({
      id: `claudeCode:${window}`,
      client: "claudeCode",
      window,
      remaining: null,
      status: "未接入",
    }));
    const groups = quotaRingGroups([codex, ...claude]);
    assert.equal(groups.length, 2);
    assert.equal(groups[0].right, undefined);
    assert.equal(groups[1].right.id, "claudeCode:7d");
    const full = renderToStaticMarkup(
      React.createElement(PairedQuotaRing, groups[0]),
    );
    assert.match(full, /data-mode="single"/);
    assert.match(full, /stroke-dasharray="163.36"/);
    assert.doesNotMatch(full, /stroke-dasharray="80 163.36"/);
    const paired = renderToStaticMarkup(
      React.createElement(PairedQuotaRing, groups[1]),
    );
    assert.match(paired, /data-mode="paired"/);
    assert.match(paired, /左侧 Claude Code 5h —/);
    assert.match(paired, /右侧 Claude Code 7d —/);
    assert.equal(
      decodeQuotaSelection('{"order":["codex:7d"]}').pairAcrossClients,
      false,
    );
  }));

test("30-day chart conserves the first partially covered raw bucket", async () =>
  withSsrModules(async (load) => {
    const { projectClientChart } = await load(
      "/src/multiClient/multiClientProduct.ts",
    );
    const now = 1800000123,
      cutoff = now - 30 * 86400;
    const rows = [
      {
        client: "claudeCode",
        startUnix: Math.floor(cutoff / 300) * 300,
        inputTokens: 13,
        outputTokens: 7,
        requests: 1,
      },
    ];
    assert.equal(
      projectClientChart([], rows, 30, now, ["claudeCode"]).reduce(
        (total, row) => total + row.tokens,
        0,
      ),
      20,
    );
  }));

test("the nested quota track keeps its four-pixel box and unknown fill stays hidden", async () => {
  const { Window } = await import("happy-dom");
  const { readFile } = await import("node:fs/promises");
  const dom = new Window();
  try {
    dom.document.head.innerHTML = `<style>${await readFile(new URL("../quota-sidebar/QuotaSidebar.css", import.meta.url), "utf8")}${await readFile(new URL("./integratedClients.css", import.meta.url), "utf8")}</style>`;
    dom.document.body.innerHTML =
      '<div class="qs-bars"><span class="integrated-quota-track" style="height:46px"><span class="qs-bar qs-unknown"><i style="height:0%"></i></span></span></div>';
    const track = dom.document.querySelector(".qs-bar");
    assert.equal(dom.getComputedStyle(track).display, "block");
    assert.equal(dom.getComputedStyle(track).width, "4px");
    assert.equal(dom.getComputedStyle(track.querySelector("i")).opacity, "0");
  } finally {
    dom.close();
  }
});

test("unknown cache counts are excluded rather than interpreted as misses", async () =>
  withSsrModules(async (load) => {
    const { cacheCoverage } = await load(
      "/src/multiClient/clientCacheCoverage.ts",
    );
    const rows = [
      {
        client: "claudeCode",
        inputTokens: 100,
        cacheReadTokens: 80,
        cacheReadComplete: true,
      },
      {
        client: "gemini",
        inputTokens: 1000,
        cacheReadTokens: 0,
        cacheReadComplete: false,
      },
    ];
    assert.deepEqual(
      cacheCoverage({ inputTokens: 100, cachedInputTokens: 90 }, rows, [
        "codex",
        "claudeCode",
        "gemini",
      ]),
      { input: 200, cached: 170, unknownInput: 1000, ratio: 0.85 },
    );
    assert.equal(cacheCoverage(undefined, rows, ["gemini"]).ratio, null);
  }));

test("brand cap is independent from quota fill and shares the original ring size", async () =>
  withSsrModules(async (load) => {
    const { quotaFill, clientBrand, clientSidebarMetrics, quotaTrackHeight } = await load("/src/multiClient/integratedClientModel.ts");
    assert.equal(clientSidebarMetrics.ringSize, 49);
    assert.equal(quotaFill({ window: "5h" }), "#B6EF75");
    assert.equal(quotaFill({ window: "7d" }), "#B4ACFF");
    assert.notEqual(quotaFill({window:"7d"}), clientBrand.codex);
    for (const height of [8, 24, 46]) assert.equal(quotaTrackHeight(height), height);
    const { PairedQuotaRing } = await load("/src/multiClient/IntegratedClients.tsx");
    const item = { id:"codex:7d", client:"codex", window:"7d", remaining:72, status:"", source:"test" };
    const html = renderToStaticMarkup(React.createElement(PairedQuotaRing, { left:item, colors:{"codex:7d":"#123456"} }));
    assert.match(html, /width:49px;height:49px/);
    assert.match(html, /stroke="#123456"/);
    assert.match(html, /background:#3941FF/);
  }));

test("paired quota captions map windows left/right then name the client once", async () =>
  withSsrModules(async load => {
    const { PairedQuotaRing, ClientQuotaSettings } = await load("/src/multiClient/IntegratedClients.tsx");
    const left = {id:"claudeCode:5h",client:"claudeCode",window:"5h",remaining:62,source:"mock",status:""};
    const right = {...left,id:"claudeCode:7d",window:"7d",remaining:84};
    const html = renderToStaticMarkup(React.createElement(PairedQuotaRing,{left,right}));
    const windows = html.slice(html.indexOf('class="integrated-ring-windows"'), html.indexOf('class="integrated-ring-clients"'));
    assert.ok(windows.indexOf("5小时") < windows.indexOf("7天"));
    assert.equal((html.match(/class="integrated-ring-legend"/g) || []).length, 1);
    assert.match(html, /左侧 Claude Code 5h 62%/);
    assert.match(html, /右侧 Claude Code 7d 84%/);
    const settings = renderToStaticMarkup(React.createElement(ClientQuotaSettings, {}));
    for (const title of ["额度填充颜色", "恢复默认颜色"]) assert.ok(settings.includes(title));
    assert.doesNotMatch(settings, /竖条长度|长条|短条|将不同客户端/);
  }));
