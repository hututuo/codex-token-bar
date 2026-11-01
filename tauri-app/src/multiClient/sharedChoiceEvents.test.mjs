import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import { Window } from "happy-dom";
import { withSsrModules } from "../test/ssrHarness.mjs";

const storageKeys = {
  home: "multiClient.displayScope.v1",
  sidebar: "multiClient.sidebarDisplayScope.v1",
  quota: "multiClient.quotaSelection.v1",
};
const channels = {
  home: "multi-client-display-scope-changed",
  sidebar: "multi-client-sidebar-display-scope-changed",
  quota: "multi-client-quota-selection-changed",
};
const nativeEventName = /^[A-Za-z0-9_/:\-]+$/;

test("stored client choices use distinct valid native channels without migrating storage keys", async () => {
  await withChoices({}, async ({ dom, native, mount }) => {
    dom.localStorage.setItem(storageKeys.home, "claudeCode");
    dom.localStorage.setItem(storageKeys.sidebar, "codex");
    dom.localStorage.setItem(storageKeys.quota, JSON.stringify({ hidden: ["codex:5h"] }));
    await mount();
    assert.equal(dom.document.querySelector("#home").textContent, "claudeCode");
    assert.equal(dom.document.querySelector("#sidebar").textContent, "codex");
    assert.equal(dom.document.querySelector("#quota").textContent, "codex:5h");
    assert.deepEqual(new Set(native.listens.map(x => x.event)), new Set(Object.values(channels)));
    assert.ok(native.listens.every(x => nativeEventName.test(x.event)), "native listen must never receive dotted storage keys");
    assert.equal(dom.localStorage.length, 3);
  });
});

test("local selections update same-window consumers and emit on the matching native channel", async () => {
  await withChoices({}, async ({ dom, native, mount }) => {
    await mount();
    await React.act(async () => dom.document.querySelector("#home").click());
    assert.equal(dom.document.querySelector("#home-copy").textContent, "claudeCode");
    assert.equal(dom.document.querySelector("#sidebar").textContent, "all");
    assert.equal(dom.localStorage.getItem(storageKeys.home), "claudeCode");
    assert.equal(dom.localStorage.getItem(storageKeys.sidebar), null);
    await React.act(async () => dom.document.querySelector("#sidebar").click());
    await React.act(async () => dom.document.querySelector("#quota").click());
    assert.deepEqual(native.emits.map(x => x.event), Object.values(channels));
    assert.ok(native.emits.every(x => nativeEventName.test(x.event)));
    assert.equal(dom.localStorage.getItem(storageKeys.sidebar), "claudeCode");
    assert.deepEqual(JSON.parse(dom.localStorage.getItem(storageKeys.quota)).hidden, ["codex:7d"]);
    for (const channel of Object.values(channels)) assert.equal(dom.localStorage.getItem(channel), null);
  });
});

test("native publications update only their own persisted choice and do not echo", async () => {
  await withChoices({}, async ({ dom, native, mount }) => {
    await mount();
    await React.act(async () => native.deliver(channels.home, "claudeCode"));
    assert.equal(dom.document.querySelector("#home").textContent, "claudeCode");
    assert.equal(dom.document.querySelector("#home-copy").textContent, "claudeCode");
    assert.equal(dom.document.querySelector("#sidebar").textContent, "all");
    await React.act(async () => native.deliver(channels.sidebar, "codex"));
    assert.equal(dom.document.querySelector("#sidebar").textContent, "codex");
    assert.equal(dom.document.querySelector("#home").textContent, "claudeCode");
    await React.act(async () => native.deliver(channels.quota, JSON.stringify({ hidden: ["codex:5h"] })));
    assert.equal(dom.document.querySelector("#quota").textContent, "codex:5h");
    await React.act(async () => native.deliver(channels.home, { unexpected: true }));
    assert.equal(dom.localStorage.getItem(storageKeys.home), "claudeCode");
    assert.equal(dom.localStorage.getItem(storageKeys.sidebar), "codex");
    assert.equal(native.emits.length, 0);
  });
});

test("rejected native subscriptions and emissions are diagnosed without losing local choices", async () => {
  await withChoices({ rejectListen: true, rejectEmit: true }, async ({ dom, native, warnings, mount }) => {
    await mount();
    await React.act(async () => dom.document.querySelector("#home").click());
    assert.equal(dom.localStorage.getItem(storageKeys.home), "claudeCode");
    assert.equal(dom.document.querySelector("#home-copy").textContent, "claudeCode");
    assert.ok(warnings.some(x => x.includes(`platform:listen:${channels.home}`)));
    assert.ok(warnings.some(x => x.includes(`platform:emit:${channels.home}`)));
    assert.ok(native.listens.every(x => nativeEventName.test(x.event)));
  });
});

test("subscriptions resolving after unmount are immediately released", async () => {
  await withChoices({ deferListen: true }, async ({ native, mount, unmount }) => {
    await mount();
    assert.equal(native.pending.length, 4);
    await unmount();
    await React.act(async () => native.pending.splice(0).forEach(resolve => resolve()));
    assert.equal(native.registrations.size, 0);
    assert.equal(native.unlistens.length, 4);
  });
});

async function withChoices(options, run) {
  const dom = new Window({ url: "http://localhost/" });
  const globals = { window: dom, document: dom.document, navigator: dom.navigator,
    localStorage: dom.localStorage, HTMLElement: dom.HTMLElement, Event: dom.Event,
    IS_REACT_ACT_ENVIRONMENT: true };
  const saved = new Map(Object.keys(globals).map(key => [key, Object.getOwnPropertyDescriptor(globalThis, key)]));
  for (const [key, value] of Object.entries(globals)) Object.defineProperty(globalThis, key, { configurable: true, writable: true, value });
  const native = installNativeEvents(dom, options);
  const warnings = [], previousWarn = console.warn;
  console.warn = (...args) => warnings.push(args.join(" "));
  let root;
  const unmount = async () => {
    if (root) {
      const mounted = root;
      root = undefined;
      await React.act(async () => mounted.unmount());
    }
  };
  try {
    await withSsrModules(async load => {
      const { ClientScopeBoundary, useClientScope, useClientQuotaSelection } = await load("/src/multiClient/useClientScope.ts");
      function Scope({ id }) {
        const { raw, setScope } = useClientScope();
        return React.createElement("button", { id, onClick: () => setScope("claudeCode") }, raw);
      }
      function Quota() {
        const { selection, save } = useClientQuotaSelection();
        return React.createElement("button", { id: "quota", onClick: () => save({ ...selection, hidden: ["codex:7d"] }) }, selection.hidden.join(","));
      }
      const mount = async () => {
        const { createRoot } = await import("react-dom/client");
        root = createRoot(dom.document.body);
        await React.act(async () => root.render(React.createElement(React.Fragment, null,
          React.createElement(Scope, { id: "home" }), React.createElement(Scope, { id: "home-copy" }),
          React.createElement(ClientScopeBoundary, { surface: "sidebar" }, React.createElement(Scope, { id: "sidebar" })),
          React.createElement(Quota))));
      };
      await run({ dom, native, warnings, mount, unmount });
    });
  } finally {
    await unmount();
    console.warn = previousWarn;
    for (const [key, descriptor] of saved) {
      if (descriptor) Object.defineProperty(globalThis, key, descriptor);
      else delete globalThis[key];
    }
    dom.close();
  }
}

function installNativeEvents(dom, options) {
  let sequence = 0;
  const callbacks = new Map(), registrations = new Map();
  const listens = [], emits = [], unlistens = [], pending = [];
  dom.__TAURI_EVENT_PLUGIN_INTERNALS__ = { unregisterListener() {} };
  dom.__TAURI_INTERNALS__ = {
    transformCallback(callback) { const id = ++sequence; callbacks.set(id, callback); return id; },
    async invoke(command, args) {
      if (command === "refresh_multi_client_usage") return { preferences: [], summaries: [], diagnostics: [], updatedAt: null };
      if (command === "plugin:event|listen") {
        listens.push(args);
        if (options.rejectListen) throw new Error("synthetic listener failure");
        const id = ++sequence;
        registrations.set(id, args);
        if (options.deferListen) await new Promise(resolve => pending.push(resolve));
        return id;
      }
      if (command === "plugin:event|unlisten") {
        unlistens.push(args);
        registrations.delete(args.eventId);
        return;
      }
      if (command === "plugin:event|emit") {
        emits.push(args);
        if (options.rejectEmit) throw new Error("synthetic emit failure");
        return;
      }
      throw new Error(`Unexpected test command: ${command}`);
    },
  };
  return { listens, emits, unlistens, registrations, pending,
    deliver(event, payload) {
      for (const [id, entry] of registrations) if (entry.event === event) callbacks.get(entry.handler)({ event, id, payload });
    },
  };
}
