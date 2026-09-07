import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";
import ts from "typescript";

async function harness() {
  const calls = [];
  const source = await readFile(new URL("./useRealFloatingGuide.ts", import.meta.url), "utf8");
  const compiled = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
  const exports = {};
  vm.runInNewContext(compiled, { exports, DOMException, AbortController, performance, require(name) {
    if (name.endsWith("floatingGeometryLifecycle")) return { runFloatingGeometryChange: action => action() };
    if (name.endsWith("desktopBridge")) return { warnPlatformFailure: () => {} };
    if (name === "@tauri-apps/api/core") return { invoke: async command => calls.push(command) };
    return {};
  }});
  const dock = { guideDetach: async () => calls.push("detach"), endGuide: () => calls.push("end"), initialize: () => calls.push("initialize") };
  const session = new exports.RealFloatingGuideSession({ current: dock }, complete => calls.push(complete ? "complete" : "dismiss"));
  session.original = { x: 1, y: 2, width: 100, height: 50 };
  session.restorableFrame = async () => session.original;
  session.releaseGeometry = () => calls.push("release");
  return { session, calls };
}

test("skip drains in-flight playback before restoring the original frame", async () => {
  const { session, calls } = await harness();
  let unblock;
  session.play = () => new Promise(resolve => { unblock = () => { calls.push("last-demo-frame"); resolve(); }; });
  const replay = session.replay();
  const finishing = session.finish(true);
  await Promise.resolve();
  assert.deepEqual(calls, []);
  unblock();
  await Promise.all([replay, finishing]);
  assert.ok(calls.indexOf("last-demo-frame") < calls.indexOf("set_floating_dock_frame"));
  assert.equal(calls.at(-1), "complete");
  assert.ok(calls.includes("release"));
});

test("playback failure dismisses this presentation without marking the guide completed", async () => {
  const { session, calls } = await harness();
  session.play = async () => { throw new Error("overlay unavailable"); };
  await session.replay();
  assert.equal(calls.at(-1), "dismiss");
  assert.equal(calls.includes("complete"), false);
  assert.ok(calls.includes("release"));
});

test("restore failure still releases the guide and geometry lease", async () => {
  const { session, calls } = await harness();
  session.restorableFrame = async () => { throw new Error("display disconnected"); };
  await session.finish(false);
  assert.ok(calls.includes("end"));
  assert.ok(calls.includes("release"));
  assert.equal(calls.at(-1), "dismiss");
});

test("effect cleanup does not notify an unmounted presentation", async () => {
  const { session, calls } = await harness();
  await session.finish(false, false);
  assert.equal(calls.includes("dismiss"), false);
  assert.equal(calls.includes("complete"), false);
  assert.ok(calls.includes("release"));
});


test("original attachment is scheduled only after guide cancellation is released", async () => {
  const { session, calls } = await harness();
  session.attached = true;
  await session.finish(true);
  assert.equal(calls.filter(call => call === "end").length, 1);
  assert.ok(calls.indexOf("end") < calls.indexOf("initialize"));
});


test("display scale or work area changes abort the active demonstration", async () => {
  const { session } = await harness();
  session.workArea = { x: 0, y: 0, width: 1000, height: 800 };
  session.lastDisplayCheck = -1000;
  session.geometry = async () => ({ area: session.workArea, scale: 2 });
  await assert.rejects(session.validateDisplay(), /Display configuration changed/);
  session.lastDisplayCheck = -1000;
  session.geometry = async () => ({ area: { ...session.workArea, width: 800 }, scale: 1 });
  await assert.rejects(session.validateDisplay(), /Display configuration changed/);
});
