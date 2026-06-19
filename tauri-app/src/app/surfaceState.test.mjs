import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("dashboard header does not render the local diagnostics strip", async () => {
  const header = await readFile(new URL("../components/DashboardHeader.tsx", import.meta.url), "utf8");

  assert.equal(header.includes("DiagnosticStrip"), false);
  assert.equal(header.includes("diagnostic-strip"), false);
});

test("floating toggle follows saved preference instead of transient visibility", async () => {
  const hook = await readFile(new URL("./useFloatingWindowSurface.ts", import.meta.url), "utf8");
  const toggleBody = hook.slice(hook.indexOf("const toggleFloatingWindow"));

  assert.equal(toggleBody.includes("const nextEnabled = !enabled"), true);
  assert.equal(toggleBody.includes("const nextVisible = !floatingVisible"), false);
  assert.equal(toggleBody.includes("onPreferenceConfirmed(confirmed)"), false);
  assert.equal(toggleBody.includes("setFloatingVisible(confirmed)"), false);
  assert.equal(toggleBody.includes("setFloatingVisible(nextEnabled)"), true);
});

test("debug launcher stops installed release before opening Tauri app", async () => {
  const script = await readFile(
    new URL("../../../scripts/open_tauri_debug_app.sh", import.meta.url),
    "utf8",
  );

  assert.equal(script.includes("stop_installed_app"), true);
  assert.equal(script.includes("/Applications/Codex Token Bar.app/Contents/MacOS/CodexTokenBar"), true);
});
