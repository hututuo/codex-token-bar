import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const root = new URL("../", import.meta.url);

test("local Swift and Tauri previews do not inherit a task-scoped Codex Home", async () => {
  const [swiftLauncher, tauriLauncher] = await Promise.all([
    readFile(new URL("scripts/package_app.sh", root), "utf8"),
    readFile(new URL("scripts/open_tauri_debug_app.sh", root), "utf8"),
  ]);

  for (const launcher of [swiftLauncher, tauriLauncher]) {
    assert.match(
      launcher,
      /\/usr\/bin\/open[^\n]*--env CODEX_HOME --env CODEX_SQLITE_HOME/,
    );
  }
});
