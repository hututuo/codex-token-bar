import assert from "node:assert/strict";
import test from "node:test";
import {readFile} from "node:fs/promises";
import React from "react";
import {renderToStaticMarkup} from "react-dom/server";
import {Window} from "happy-dom";
import {withSsrModules} from "../test/ssrHarness.mjs";

test("quota detail cards preserve Pro windows, unknowns, resets, custom color and pace across shared fixtures",async()=>withSsrModules(async load=>{
  const fixture=JSON.parse(await readFile(new URL("../../../Tests/SharedFixtures/quota-detail-cards.json",import.meta.url),"utf8"));
  const {ClientQuotaDetailRings}=await load("/src/multiClient/ClientQuotaViews.tsx");
  for(const item of fixture.cases){
    const items=item.items.map(row=>({...row,resetsAt:null,source:"本地缓存"}));
    const w=new Window();
    try{
      w.document.body.innerHTML=renderToStaticMarkup(React.createElement(ClientQuotaDetailRings,{items,expected:{"codex:5h":.4,"codex:7d":.5}}));
      const cards=[...w.document.querySelectorAll(".integrated-quota-card")];
      assert.deepEqual(cards.map(row=>row.dataset.quotaId),items.map(row=>row.id),item.name);
      for(const row of items){
        const card=cards.find(card=>card.dataset.quotaId===row.id);
        assert.ok(card.getAttribute("aria-label").includes(row.remaining===null?"—":`${row.remaining}%`));
        assert.ok(card.textContent.includes(row.status));
        assert.equal(card.querySelector(".integrated-full-ring")!==null,!row.id.endsWith(":api"));
        if(!row.id.endsWith(":api"))assert.ok(card.textContent.includes("重置时间未知"));
      }
    }finally{w.close();}
  }
  const {ClientQuotaDetailCard}=await load("/src/multiClient/ClientQuotaViews.tsx");
  const html=renderToStaticMarkup(React.createElement(ClientQuotaDetailCard,{item:{...fixture.cases[0].items[0],resetsAt:"2026-11-10T12:00:00Z",source:"local"},fill:"#123456",expected:.5}));
  assert.match(html,/#123456/);assert.match(html,/rotate\(180 50 50\)/);assert.match(html,/重置 /);
  const css=await readFile(new URL("./integratedClients.css",import.meta.url),"utf8");
  assert.match(css,/\.integrated-full-rings\s*\{[^}]*grid-template-columns:\s*minmax\(0,\s*1fr\)/);
  assert.match(css,/\.integrated-quota-card\s*\{[^}]*width:\s*100%/);
  assert.match(css,/\.integrated-quota-window-info\s*\{[^}]*flex:\s*1/);
}));
