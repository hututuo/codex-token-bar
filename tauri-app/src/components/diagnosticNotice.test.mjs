import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { withSsrModules } from "../test/ssrHarness.mjs";

test("technical errors stay hidden until the user opens logs", async () => {
  await withSsrModules(async load => {
    const { DiagnosticNotice } = await load("/src/components/DiagnosticNotice.tsx");
    const html = renderToStaticMarkup(React.createElement(DiagnosticNotice, {
      summary: "额度读取失败", logs: "operationFailed secret-path invalid utf-8",
    }));
    assert.match(html, /额度读取失败/);
    assert.match(html, /查看日志/);
    assert.match(html, /aria-expanded="false"/);
    assert.doesNotMatch(html, /operationFailed|secret-path|invalid utf-8|textarea/);
  });
});

test("opening logs reveals details and copies current and history sections", async () => {
  const { Window } = await import("happy-dom");
  const window = new Window();
  const previous = new Map();
  for (const [name, value] of Object.entries({ window, document: window.document, navigator: window.navigator, HTMLElement: window.HTMLElement, IS_REACT_ACT_ENVIRONMENT: true })) {
    previous.set(name, Object.getOwnPropertyDescriptor(globalThis, name));
    Object.defineProperty(globalThis, name, { configurable: true, writable: true, value });
  }
  try {
    await withSsrModules(async load => {
      const { DiagnosticNotice } = await load("/src/components/DiagnosticNotice.tsx");
      const { createRoot } = await import("react-dom/client");
      const container = window.document.createElement("div");
      window.document.body.append(container);
      const root = createRoot(container);
      let copied = "";
      Object.defineProperty(window.navigator, "clipboard", { configurable: true, value: { writeText: async text => { copied = text; } } });
      try {
        await React.act(async () => root.render(React.createElement(DiagnosticNotice, {summary: "额度读取失败", logs: "quota-error-42"})));
        assert.equal(container.querySelector("textarea"), null);
        await React.act(async () => container.querySelector("button").click());
        assert.match(window.document.querySelector("textarea").value, /quota-error-42/);
        await React.act(async () => [...window.document.querySelectorAll("button")].find(button => button.textContent === "一键复制全部日志").click());
        assert.match(copied, /quota-error-42/);
        assert.match(window.document.body.textContent, /已复制/);
      } finally { await React.act(async () => root.unmount()); }
    });
  } finally {
    for (const [name, descriptor] of previous) {
      if (descriptor) Object.defineProperty(globalThis, name, descriptor); else delete globalThis[name];
    }
    window.close();
  }
});

test("toolbar log entry has no status row or log content until opened", async () => {
  await withSsrModules(async load => {
    const { DiagnosticNotice } = await load("/src/components/DiagnosticNotice.tsx");
    const html = renderToStaticMarkup(React.createElement(DiagnosticNotice, {summary: "不应展示的正常提示", logs: "", buttonOnly: true}));
    assert.match(html, /完整日志/);
    assert.doesNotMatch(html, /不应展示|role="status"|textarea|<dialog/);
    assert.match(html, /dash-head__action/);
  });
});
