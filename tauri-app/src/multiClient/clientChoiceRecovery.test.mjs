import assert from "node:assert/strict";
import test from "node:test";
import { Window } from "happy-dom";
import { withSsrModules } from "../test/ssrHarness.mjs";

const channels = {
  dashboard: "multi-client-display-scope-changed",
  sidebar: "multi-client-sidebar-display-scope-changed",
  quota: "multi-client-quota-selection-changed",
};
const keys = {
  dashboard: "multiClient.displayScope.v1",
  sidebar: "multiClient.sidebarDisplayScope.v1",
  quota: "multiClient.quotaSelection.v1",
};

async function withChoices(run, options = {}) {
  const dom = new Window({ url: "http://localhost/" });
  const descriptors = new Map();
  for (const [key, value] of Object.entries({
    window: dom, document: dom.document, navigator: dom.navigator,
    localStorage: dom.localStorage, HTMLElement: dom.HTMLElement, Event: dom.Event,
    IS_REACT_ACT_ENVIRONMENT: true,
  })) {
    descriptors.set(key, Object.getOwnPropertyDescriptor(globalThis, key));
    Object.defineProperty(globalThis, key, { configurable: true, writable: true, value });
  }
  const callbacks = new Map(), listeners = new Map(), attempts = [], emitted = [];
  let sequence = 0;
  const native = {
    attempts, emitted, listeners,
    publish(event, payload) {
      for (const [id, listener] of [...listeners]) {
        if (listener.event === event) callbacks.get(listener.handler)?.({ event, id, payload });
      }
    },
  };
  dom.__TAURI_EVENT_PLUGIN_INTERNALS__ = { unregisterListener(_event, id) { listeners.delete(id); } };
  dom.__TAURI_INTERNALS__ = {
    transformCallback(callback) { const id = ++sequence; callbacks.set(id, callback); return id; },
    async invoke(command, args = {}) {
      if (command.startsWith("plugin:event|")) {
        attempts.push({ command, event: args.event });
        // Record invalid requests without creating an unhandled rejection in the old
        // implementation: the explicit assertion below is the regression oracle.
        if (command === "plugin:event|listen") {
          if (options.rejectListen) throw new Error("simulated listener unavailable");
          const id = ++sequence;
          if (options.listenBarrier) await options.listenBarrier;
          listeners.set(id, args);
          return id;
        }
        if (command === "plugin:event|emit") {
          emitted.push({ event: args.event, payload: args.payload });
          native.publish(args.event, args.payload);
        }
        return;
      }
      if (command === "refresh_multi_client_usage") {
        return { preferences: [], summaries: [], diagnostics: [], updatedAt: null };
      }
      // The diagnostics journal may send best-effort startup diagnostics.
      if (command === "record_startup_event") return;
      throw new Error(`Unexpected command: ${command}`);
    },
  };
  const React = await import("react");
  const { createRoot } = await import("react-dom/client");
  const container = dom.document.createElement("div");
  dom.document.body.append(container);
  const root = createRoot(container);
  let mounted = true;
  try {
    await withSsrModules(async load => {
      const hooks = await load("/src/multiClient/useClientScope.ts");
      const values = new Map();
      function Probe({ name, quota = false }) {
        const value = quota ? hooks.useClientQuotaSelection() : hooks.useClientScope();
        values.set(name, value);
        return React.createElement("span", { "data-choice": name }, quota ? JSON.stringify(value.selection) : value.raw);
      }
      async function render(surface = "dashboard") {
        await React.act(async () => root.render(React.createElement(React.Fragment, null,
          React.createElement(hooks.ClientScopeBoundary, { surface },
            React.createElement(Probe, { name: "first" }), React.createElement(Probe, { name: "second" })),
          React.createElement(hooks.ClientScopeBoundary, { surface: "sidebar" }, React.createElement(Probe, { name: "sidebar" })),
          React.createElement(Probe, { name: "quota", quota: true }))));
      }
      await run({ React, dom, native, values, render, container, async unmount() {
        await React.act(async () => root.unmount()); mounted = false;
      } });
    });
  } finally {
    if (mounted) await React.act(async () => root.unmount());
    for (const [key, descriptor] of descriptors) {
      if (descriptor) Object.defineProperty(globalThis, key, descriptor); else delete globalThis[key];
    }
    dom.close();
  }
}

test("all three persisted choices use distinct valid native channels without renaming existing preferences", async () => {
  await withChoices(async ({ React, dom, native, values, render, unmount }) => {
    dom.localStorage.setItem(keys.dashboard, "claudeCode");
    dom.localStorage.setItem(keys.sidebar, "all");
    const selection = { enabled: ["codex:5h"], order: ["codex:5h"] };
    dom.localStorage.setItem(keys.quota, JSON.stringify(selection));
    await render();
    assert.equal(values.get("first").raw, "claudeCode");
    assert.equal(values.get("sidebar").raw, "all");
    assert.ok(native.attempts.every(({ event }) => /^[A-Za-z0-9_:/-]+$/.test(event)),
      "storage keys containing dots must never be sent as Tauri event names");
    assert.deepEqual(new Set(native.attempts.map(({ event }) => event)), new Set(Object.values(channels)));
    await React.act(async () => values.get("first").setScope("codex"));
    assert.equal(dom.localStorage.getItem(keys.dashboard), "codex");
    assert.equal(values.get("second").raw, "codex");
    assert.equal(values.get("sidebar").raw, "all");
    assert.deepEqual(native.emitted.at(-1), { event: channels.dashboard, payload: "codex" });
    await React.act(async () => values.get("quota").save(selection));
    assert.equal(dom.localStorage.getItem(keys.quota), JSON.stringify(selection));
    assert.equal(native.emitted.at(-1).event, channels.quota);
    await React.act(async () => native.publish(channels.dashboard, "claudeDesktop"));
    assert.equal(values.get("first").raw, "claudeDesktop");
    assert.equal(dom.localStorage.getItem(keys.dashboard), "claudeDesktop");
    await unmount();
    assert.equal(native.listeners.size, 0);
  });
});

test("a mounted surface switch reads its own persisted choice rather than retaining the prior surface", async () => {
  await withChoices(async ({ dom, values, render }) => {
    dom.localStorage.setItem(keys.dashboard, "codex");
    dom.localStorage.setItem(keys.sidebar, "claudeCode");
    await render();
    assert.equal(values.get("first").raw, "codex");
    await render("sidebar");
    assert.equal(values.get("first").raw, "claudeCode");
  });
});

test("storage failures preserve in-memory choice and same-window publication", async () => {
  await withChoices(async ({ React, dom, native, values, render }) => {
    await render();
    const prototype = Object.getPrototypeOf(dom.localStorage);
    const descriptor = Object.getOwnPropertyDescriptor(prototype, "setItem");
    try {
      Object.defineProperty(prototype, "setItem", {
        configurable: true, value() { throw new Error("storage disabled"); },
      });
      await React.act(async () => values.get("first").setScope("claudeCode"));
      assert.equal(values.get("first").raw, "claudeCode");
      assert.equal(values.get("second").raw, "claudeCode");
      await React.act(async () => native.publish(channels.dashboard, "claudeDesktop"));
      assert.equal(values.get("first").raw, "claudeDesktop");
    } finally {
      Object.defineProperty(prototype, "setItem", descriptor);
    }
  });
});

test("unavailable native subscription is diagnosed without disabling local choices", async () => {
  await withChoices(async ({ React, values, render }) => {
    await render();
    await React.act(async () => values.get("first").setScope("claudeCode"));
    assert.equal(values.get("second").raw, "claudeCode");
  }, { rejectListen: true });
});

test("listeners that resolve after unmount are released", async () => {
  let release;
  const listenBarrier = new Promise(resolve => { release = resolve; });
  await withChoices(async ({ React, native, render, unmount }) => {
    await render();
    await unmount();
    await React.act(async () => { release(); await listenBarrier; });
    assert.equal(native.listeners.size, 0);
  }, { listenBarrier });
});
