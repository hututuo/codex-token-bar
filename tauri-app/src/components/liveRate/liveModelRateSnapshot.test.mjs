import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { Window } from "happy-dom";
import { withSsrModules } from "../../test/ssrHarness.mjs";
import { runningThreadFixture } from "../../test/runningThreadFixture.mjs";
import { liveModelRateSnapshot, modelRateSlices, normalizedModelRates, activityRateSources } from "./modelRatePresentation.ts";

const fixture = JSON.parse(await readFile(new URL("../../../../Tests/SharedFixtures/live-model-rates.json", import.meta.url), "utf8"));
test("shared rates preserve source identity, residuals, ring order and every client in both modes and palettes", () => {
  for (const mode of ["bar", "agentSpeed"]) for (const grouping of ["model", "client"]) {
    const value = liveModelRateSnapshot(fixture.sources, true, mode, grouping);
    assert.equal(value.total, fixture.total);
    assert.deepEqual(value.rows.map(row => row.id), fixture[grouping + "Order"]);
    assert.deepEqual(value.rows.map(row => row.tokensPerSecond), fixture.rates);
    assert.deepEqual(value.rows.map(row => row.barFraction), [.5, .75, 1, .25]);
    assert.deepEqual(value.rows.map(row => row.share), [.2, .3, .4, .1]);
    assert.deepEqual(value.modelRates, fixture.modelSlices);
    assert.deepEqual(value.colorRates, fixture[grouping + "Slices"]);
    assert.equal(modelRateSlices(value.colorRates).reduce((sum, row) => sum + row.tokensPerSecond, 0), value.total);
    const disabled = liveModelRateSnapshot(fixture.sources, false, mode, grouping);
    assert.equal(disabled.available, false); assert.equal(disabled.total, 0); assert.deepEqual(disabled.rows, []);
    const switched = structuredClone(fixture.sources); switched[0].sourceKey = "home-b:8"; switched[0].available = false;
    const next = liveModelRateSnapshot(switched, true, mode, grouping);
    assert.notEqual(next.sourceKey, value.sourceKey); assert.equal(next.total, 50);
    assert.ok(next.rows.every(row => row.client !== "codex"));
  }
});
test("one Codex algorithm is selected and bad values cannot enter the ring or model rows", () => {
  const upstream = [{client:"codex",model:"gpt-6-astra",outputTps:90},{client:"claudeCode",model:"claude-sonnet-4-6",outputTps:30}];
  for (const [mode,total] of [["bar",80],["agentSpeed",120]]) {
    const sources = activityRateSources(fixture.sources[0].rates, upstream, ["codex","claudeCode"], mode, 50);
    assert.equal(liveModelRateSnapshot(sources,true,mode,"model").total,total);
  }
  for (const value of [NaN, Infinity, -1, 0]) {
    assert.deepEqual(normalizedModelRates([{model:"m",tokensPerSecond:value}]),[]);
    assert.deepEqual(normalizedModelRates([{model:"m",tokensPerSecond:50}],value),[]);
  }
  assert.deepEqual(normalizedModelRates([{model:"m",tokensPerSecond:80}],20),[{model:"m",tokensPerSecond:20}]);
  assert.deepEqual(normalizedModelRates([{model:"m",tokensPerSecond:Number.MAX_VALUE},{model:"m",tokensPerSecond:Number.MAX_VALUE}]),[]);
});
test("production rail and detail legend consume the same frozen total, colors, order and scale", async () => {
  await withSsrModules(async load => {
    const { SidebarRailContent } = await load("/src/quota-sidebar/QuotaSidebarApp.tsx");
    const { LiveModelRateBars } = await load("/src/components/liveRate/LiveModelRateBars.tsx");
    const dom = new Window();
    try {
      for (const grouping of ["model", "client"]) {
        const liveRates = liveModelRateSnapshot(fixture.sources,true,"bar",grouping);
        const data = { liveRates, snapshot: { tokensPerSecond:999,modelRates:[],liveRateAvailable:true,todayModelBreakdowns:[],fiveHourAvailability:"absent",sevenDayAvailability:"absent" },
          runningThreads: runningThreadFixture({total:0,status:"ready"}) };
        dom.document.body.innerHTML = renderToStaticMarkup(React.createElement(React.Fragment,null,
          React.createElement(SidebarRailContent,{data,state:{mode:"hover",tab:"quota",pinned:false},onOpen(){}}),
          React.createElement(LiveModelRateBars,{snapshot:liveRates})));
        assert.equal(dom.document.querySelector(".qs-rate-trigger strong").getAttribute("aria-label"),"100.0");
        assert.match(dom.document.querySelector(".live-model-rate-bars header").textContent,/100\.0 tok\/s/);
        const rows=[...dom.document.querySelectorAll(".live-model-rate-row")];
        assert.deepEqual(rows.map(row=>row.dataset.client+":"+row.dataset.model),fixture[grouping+"Order"]);
        const spec=JSON.parse(dom.document.querySelector(".qs-rate-trigger svg").dataset.strokeSpec)[0];
        for (const [index,row] of rows.entries()) {
          const segment=spec.segments.find(segment=>segment.id===liveRates.rows[index].colorKey);
          const swatch=dom.document.createElement("i");swatch.style.background=segment.color;
          assert.equal(row.querySelector(".live-model-rate-dot").style.background,swatch.style.background);
          assert.equal(row.querySelector(".live-model-rate-track i").style.width,`${liveRates.rows[index].barFraction*100}%`);
        }
      }
    } finally { dom.close(); }
  });
});
