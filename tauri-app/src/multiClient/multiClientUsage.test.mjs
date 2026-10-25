import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { withSsrModules } from "../test/ssrHarness.mjs";

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
    assert.match(html, /Claude Code/); assert.match(html, /claude-test/); assert.match(html, /思考¹/);
    assert.match(html, /<td>130<\/td>/); assert.match(html, /<td>—<\/td>/);
  });
});
test("Claude quota panel remains unavailable without a captured local provider window", async () => {
  await withSsrModules(async load => {
    const { ClaudeLocalQuotaPanel, MultiClientUsageSettings } = await load("/src/multiClient/MultiClientUsage.tsx");
    assert.match(renderToStaticMarkup(React.createElement(ClaudeLocalQuotaPanel)), /未采集/);
    const settings = renderToStaticMarkup(React.createElement(MultiClientUsageSettings));
    assert.match(settings, /不读取凭据、不联网/); assert.doesNotMatch(settings, /api\.anthropic\.com/);
  });
});
