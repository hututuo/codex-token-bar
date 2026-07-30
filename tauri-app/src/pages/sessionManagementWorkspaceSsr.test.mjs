import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { withSsrModules } from "../test/ssrHarness.mjs";

const SOURCE_TOKEN = {
  canonicalHomeKey: "/fixture/codex",
  physicalHomeKey: "unix:1:2",
  transitionGeneration: 7,
};

test("session management renders a real loading workspace before native metadata resolves", async () => {
  await withSsrModules(async (load) => {
    const { SessionManagementWorkspace } = await load("/src/pages/SessionManagementWorkspace.tsx");
    const html = renderToStaticMarkup(React.createElement(SessionManagementWorkspace, {
      client: clientStub(),
      onClose: () => {},
      open: true,
      sourceToken: SOURCE_TOKEN,
    }));

    assert.match(html, /role="dialog"/);
    assert.match(html, /aria-label="会话管理"/);
    assert.match(html, /智能集合/);
    assert.match(html, /项目/);
    assert.match(html, /搜索全部会话元数据/);
    assert.match(html, /官方归档/);
    assert.match(html, /创建深度压缩恢复包/);
    assert.match(html, /选择一个会话/);
    assert.doesNotMatch(html, /演示数据|示例会话|假数据/);
  });
});

test("session management stays unmounted while closed", async () => {
  await withSsrModules(async (load) => {
    const { SessionManagementWorkspace } = await load("/src/pages/SessionManagementWorkspace.tsx");
    const html = renderToStaticMarkup(React.createElement(SessionManagementWorkspace, {
      client: clientStub(),
      onClose: () => {},
      open: false,
      sourceToken: SOURCE_TOKEN,
    }));
    assert.equal(html, "");
  });
});

function clientStub() {
  return {
    listCatalog: async () => { throw new Error("SSR should not run effects"); },
    readContextPage: async () => { throw new Error("SSR should not run effects"); },
    archive: async () => ({ results: [], warnings: [] }),
    unarchive: async () => ({ results: [], warnings: [] }),
    prepareDeleteConfirmation: async () => { throw new Error("SSR should not run effects"); },
    delete: async () => ({ results: [], warnings: [] }),
    createRecoveryArchives: async () => ({ results: [], warnings: [] }),
  };
}
