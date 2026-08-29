import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const root = new URL("../", import.meta.url);

test("local Swift and Tauri previews do not inherit a task-scoped Codex Home", async () => {
  const [swiftLauncher, tauriLauncher] = await Promise.all([
    readFile(new URL("scripts/package_app.sh", root), "utf8"),
    readFile(new URL("scripts/open_tauri_debug_app.sh", root), "utf8"),
  ]);

  const dockPolicy = await readFile(
    new URL("scripts/remove_test_dock_entries.sh", root),
    "utf8",
  );

  for (const launcher of [swiftLauncher, tauriLauncher]) {
    assert.match(
      launcher,
      /\/usr\/bin\/open[^\n]*--env CODEX_HOME --env CODEX_SQLITE_HOME/,
    );
    assert.match(launcher, /remove_test_dock_entries\.sh/);
  }

  assert.match(dockPolicy, /local\.codex\.token-bar/);
  assert.match(dockPolicy, /local\.codex\.token-bar\.tauri/);
  assert.match(dockPolicy, /\/Applications\/Codex Token Bar\.app/);
  assert.match(dockPolicy, /defaults export com\.apple\.dock/);
  assert.match(dockPolicy, /defaults import com\.apple\.dock/);
});
