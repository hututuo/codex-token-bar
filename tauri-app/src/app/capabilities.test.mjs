import assert from "node:assert/strict";
import { readdir, readFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";

const CAPABILITIES_DIR = new URL("../../src-tauri/capabilities/", import.meta.url);

test("Tauri capabilities keep updater and restart permissions main-window only", async () => {
  const permissions = await permissionsByWindow();

  assert.ok(permissions.main.has("updater:default"));
  assert.ok(permissions.main.has("process:allow-restart"));

  for (const surface of ["floating", "status"]) {
    assert.ok(permissions[surface], `${surface} capability is present`);
    assert.equal(permissions[surface].has("updater:default"), false, surface);
    assert.equal(permissions[surface].has("process:allow-restart"), false, surface);
  }
});

test("Tauri capabilities give floating and status only surface-safe frontend APIs", async () => {
  const permissions = await permissionsByWindow();

  assert.notDeepEqual([...permissions.main].sort(), [...permissions.floating].sort());
  assert.notDeepEqual([...permissions.main].sort(), [...permissions.status].sort());

  assert.ok(permissions.floating.has("core:window:allow-set-size"));
  assert.ok(permissions.floating.has("core:window:allow-set-position"));
  assert.ok(permissions.floating.has("core:window:allow-start-dragging"));
  assert.ok(permissions.floating.has("core:event:allow-listen"));
  assert.ok(permissions.floating.has("core:event:allow-emit"));

  assert.ok(permissions.status.has("core:window:allow-is-visible"));
  assert.ok(permissions.status.has("core:event:allow-listen"));
  assert.ok(permissions.status.has("core:event:allow-emit"));
  assert.equal(permissions.status.has("core:window:allow-start-dragging"), false);
});

test("Tauri config uses a conservative packaged-app CSP instead of disabling CSP", async () => {
  const raw = await readFile(new URL("../../src-tauri/tauri.conf.json", import.meta.url), "utf8");
  const config = JSON.parse(raw);
  const csp = config.app?.security?.csp;

  assert.equal(typeof csp, "string");
  assert.match(csp, /default-src 'self'/);
  assert.match(csp, /script-src 'self'/);
  assert.match(csp, /connect-src .*ipc:/);
  assert.match(csp, /style-src .*'unsafe-inline'/);
  assert.match(csp, /img-src [^;]*blob:/);
  assert.notEqual(csp, null);
});

async function permissionsByWindow() {
  const files = (await readdir(CAPABILITIES_DIR))
    .filter((file) => file.endsWith(".json"))
    .sort();
  const byWindow = {};

  for (const file of files) {
    const raw = await readFile(new URL(file, CAPABILITIES_DIR), "utf8");
    const capability = JSON.parse(raw);
    for (const window of capability.windows ?? []) {
      byWindow[window] ??= new Set();
      for (const permission of capability.permissions ?? []) {
        byWindow[window].add(permission);
      }
    }
  }

  assert.deepEqual(
    Object.keys(byWindow).sort(),
    ["floating", "main", "status"],
    `capability files: ${files.map((file) => path.basename(file)).join(", ")}`,
  );
  return byWindow;
}
