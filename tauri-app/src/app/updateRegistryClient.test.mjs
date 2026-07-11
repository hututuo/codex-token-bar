import assert from "node:assert/strict";
import test from "node:test";
import {
  mountUpdateStateReconciler,
  shouldApplyRegistryState,
} from "./updateStateReconciler.ts";
import { createUpdateClient } from "../api/updateClientCore.ts";

const available = { status: "available", message: "available", version: "0.8.0", body: "notes", date: null, revision: 2 };
const none = { status: "none", message: "已是最新版", revision: 3 };

test("mounted lifecycle subscribes before authoritative read and event wins read race", async () => {
  const order = [];
  const published = [];
  let listener;
  const stop = mountUpdateStateReconciler({
    listen: async callback => { order.push("listen"); listener = callback; return () => order.push("unlisten"); },
    read: async () => { order.push("read"); listener(available); return { ...none, revision: 1 }; },
    phase: () => "idle",
    publish: state => published.push(state),
  });
  await tick();
  assert.deepEqual(order.slice(0, 2), ["listen", "read"]);
  assert.equal(published.at(-1).version, "0.8.0");
  stop();
});

test("read failure keeps healthy listener and late unmount immediately unlistens", async () => {
  let listener;
  let unlistenCount = 0;
  let releaseListen;
  const stop = mountUpdateStateReconciler({
    listen: callback => { listener = callback; return new Promise(resolve => { releaseListen = () => resolve(() => { unlistenCount += 1; }); }); },
    read: async () => { throw new Error("read failed"); },
    phase: () => "idle",
    publish: () => {},
  });
  stop();
  releaseListen();
  await tick();
  assert.equal(unlistenCount, 1);
  assert.equal(typeof listener, "function");
});

test("listen failure installs bounded authoritative reconcile and cancellation clears it", async () => {
  const scheduled = [];
  const cancelled = [];
  const published = [];
  const stop = mountUpdateStateReconciler({
    listen: async () => { throw new Error("listen failed"); },
    read: async () => none,
    phase: () => "idle",
    publish: state => published.push(state),
    schedule: (callback, delay) => { scheduled.push({ callback, delay }); return 7; },
    cancel: timer => cancelled.push(timer),
    retryMs: 1234,
  });
  await tick();
  assert.equal(published.at(-1).status, "none");
  assert.equal(scheduled[0].delay, 1234);
  stop();
  assert.deepEqual(cancelled, [7]);
});

test("none clears available while registry events cannot overwrite checking or installing", () => {
  assert.equal(shouldApplyRegistryState("available", none), true);
  assert.equal(shouldApplyRegistryState("checking", none), false);
  assert.equal(shouldApplyRegistryState("installing", available), false);
  assert.equal(shouldApplyRegistryState("idle", available), true);
});

test("client uses fake invoke/event bridge and always releases install progress listener", async () => {
  const calls = [];
  const listeners = new Map();
  let unlistenCount = 0;
  const client = createUpdateClient({
    runtime: () => true,
    unsupportedMessage: "unsupported",
    invoke: async (command, payload) => {
      calls.push([command, payload]);
      if (command === "read_app_update_state") return { status: "available", message: "v", version: "0.8.0", body: "", date: null, revision: 4 };
      if (command === "check_app_update") return { status: "none", message: "none", version: null, body: null, date: null, revision: 5 };
    },
    listen: async (event, callback) => { listeners.set(event, callback); return () => { unlistenCount += 1; }; },
  });
  assert.equal((await client.read()).version, "0.8.0");
  assert.equal((await client.check()).status, "none");
  await client.install("0.8.0");
  assert.deepEqual(calls.at(-1), ["install_app_update", { version: "0.8.0" }]);
  assert.equal(unlistenCount, 1);
});

function tick() {
  return new Promise(resolve => setTimeout(resolve, 0));
}
