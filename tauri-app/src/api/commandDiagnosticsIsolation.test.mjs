import assert from "node:assert/strict";
import test from "node:test";
import { withSsrModules } from "../test/ssrHarness.mjs";

test("diagnostic observer failures preserve native success, fallback and original rejection", async (t) => {
  const previousWindow = Object.getOwnPropertyDescriptor(globalThis, "window");
  const originalError = new Error("original native rejection");
  const nativeResult = { value: 42 };
  let rejectNative = true;
  Object.defineProperty(globalThis, "window", { configurable: true, writable: true, value: {
    __TAURI_INTERNALS__: { invoke: () => rejectNative ? Promise.reject(originalError) : Promise.resolve(nativeResult) },
  } });
  try {
    await withSsrModules(async (load) => {
      const api = await load("/src/api/command.ts");
      const names = ["isolation_fallback", "isolation_optional", "isolation_strict"];
      // Seed through the same loaded command module: separate SSR imports have
      // separate diagnostic stores and would not exercise the command's state.
      for (const name of names) await api.callCommand(name, null, undefined, null);
      rejectNative = false;
      let throwListener = false;
      const stopBad = api.subscribeCommandDiagnostics(() => {
        if (throwListener) throw new Error("broken command observer");
      });
      let updates = 0;
      const stopGood = api.subscribeCommandDiagnostics(() => { updates++; });
      throwListener = true;
      t.mock.method(console, "warn", () => { throw new Error("broken warning sink"); });
      try {
        assert.equal(await api.callCommand(names[0], null, undefined, null), nativeResult);
        assert.equal(await api.callCommandOptional(names[1], undefined, null), nativeResult);
        assert.equal(await api.callCommandStrict(names[2], undefined, null), nativeResult);
        assert.equal(updates, 4, "each successful command clears its old error and notifies the healthy observer");
        assert.equal(api.getCommandDiagnosticsSnapshot().length, 0);

        rejectNative = true;
        assert.equal(await api.callCommand(names[0], "fallback", undefined, null), "fallback");
        assert.equal(await api.callCommandOptional(names[1], undefined, null), null);
        await assert.rejects(api.callCommandStrict(names[2], undefined, null), error => error === originalError);
        assert.ok(updates > 4);
        assert.equal(api.getCommandDiagnosticsSnapshot().length, 3);
        for (const entry of api.getCommandDiagnosticsSnapshot()) assert.equal(entry.message, originalError.message);
        await new Promise(resolve => setImmediate(resolve));
      } finally {
        stopBad(); stopGood();
      }
    });
  } finally {
    if (previousWindow) Object.defineProperty(globalThis, "window", previousWindow);
    else delete globalThis.window;
  }
});
