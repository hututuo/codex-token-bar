import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { withSsrModules } from "../test/ssrHarness.mjs";
import {act} from "react";
import {createRoot} from "react-dom/client";
import {Window} from "happy-dom";

test("new clients default to no collection and no visible surfaces", async () => {
  await withSsrModules(async load => {
    const { defaultClientPreferences } = await load("/src/multiClient/MultiClientUsage.tsx");
    assert.deepEqual(defaultClientPreferences.map(p => p.client), ["claudeCode", "claudeDesktop", "deepseek", "gemini", "opencode"]);
    assert.ok(defaultClientPreferences.every(p => !p.enabled && !p.showSidebar && !p.showMenuBar));
  });
});
test("unknown token fields remain unknown and reasoning is labeled as an output subset", async () => {
  await withSsrModules(async load => {
    const { MultiClientUsageTable, defaultClientPreferences, tokenAmount } = await load("/src/multiClient/MultiClientUsage.tsx");
    assert.equal(tokenAmount(null), "—"); assert.equal(tokenAmount(0), "0");
    const html = renderToStaticMarkup(React.createElement(MultiClientUsageTable, { snapshot: {
      preferences: defaultClientPreferences, diagnostics: [], updatedAt: null,
      summaries: [{ client: "claudeCode", model: "claude-test", inputTokens: 130, outputTokens: 20,
        cacheReadTokens: 100, cacheWriteTokens: 10, reasoningTokens: null, requests: 1, lastSeen: "2026-10-25T00:00:00Z" }],
    } }));
    assert.match(html, /Claude CLI/); assert.doesNotMatch(html, /Claude Code/);
    assert.match(html, /claude-test/); assert.match(html, /思考¹/);
    assert.match(html, /<td>130<\/td>/); assert.match(html, /<td>—<\/td>/);
  });
});
test("Claude quota panel remains unavailable without a captured local provider window", async () => {
  await withSsrModules(async load => {
    const { ClaudeLocalQuotaPanel, MultiClientUsageSettings } = await load("/src/multiClient/MultiClientUsage.tsx");
    assert.match(renderToStaticMarkup(React.createElement(ClaudeLocalQuotaPanel)), /额度未接入/);
    const settings = renderToStaticMarkup(React.createElement(MultiClientUsageSettings));
    assert.match(settings, /不读取凭据、不联网/); assert.doesNotMatch(settings, /api\.anthropic\.com/);
  });
});

test("local Claude quota is still visible when transcript storage fails",async()=>{
  const w=new Window();const prior={window:globalThis.window,document:globalThis.document,IS_REACT_ACT_ENVIRONMENT:globalThis.IS_REACT_ACT_ENVIRONMENT};
  globalThis.window=w;globalThis.document=w.document;globalThis.IS_REACT_ACT_ENVIRONMENT=true;
  const calls=[];let root;
  w.__TAURI_INTERNALS__={invoke:async command=>{
    calls.push(command);
    if(command==='refresh_multi_client_usage')throw new Error('fixture usage storage unavailable');
    assert.equal(command,'read_claude_local_quota');
    return {state:'available',fiveHour:{usedPercent:25,resetsAt:'2026-10-28T20:00:00Z'},sevenDay:null};
  }};
  try {
    await withSsrModules(async load=>{
      const {useMultiClientUsage}=await load('/src/multiClient/MultiClientUsage.tsx');
      function Readout(){const {snapshot}=useMultiClientUsage();return React.createElement('div',null,JSON.stringify(snapshot.quotas??[]));}
      const host=w.document.createElement('div');w.document.body.append(host);root=createRoot(host);
      await act(async()=>root.render(React.createElement(Readout)));
      assert.deepEqual(calls,['refresh_multi_client_usage','read_claude_local_quota']);
      assert.match(host.textContent,/claudeCode/);assert.match(host.textContent,/"usedPercent":25/);
    });
  } finally {if(root)await act(async()=>root.unmount());Object.assign(globalThis,prior);await w.happyDOM.abort();}
});
