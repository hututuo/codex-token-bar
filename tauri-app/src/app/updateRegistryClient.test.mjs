import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const dashboardUrl = new URL("./DashboardApp.tsx", import.meta.url);
const clientUrl = new URL("../api/updateClient.ts", import.meta.url);
const rustUrl = new URL("../../src-tauri/src/commands/update.rs", import.meta.url);

test("late dashboard hydrates cached registry state before subscribing to events", async () => {
  const source = await readFile(dashboardUrl, "utf8");
  assert.match(source, /readCachedAppUpdate\(\)\.then\(publish\)\.then\(async \(\) =>/);
  assert.match(source, /listenForAppUpdateState\(publish\)/);
  assert.ok(source.indexOf("readCachedAppUpdate().then") < source.indexOf("listenForAppUpdateState(publish)"));
});

test("dashboard has no automatic timer, visibility, focus, or localStorage update owner", async () => {
  const source = await readFile(dashboardUrl, "utf8");
  for (const forbidden of ["setInterval", "localStorage", "useAutomaticUpdateChecks", "visibilitychange", 'addEventListener("focus"', "updateCheckScheduler"]) {
    assert.equal(source.includes(forbidden), false, forbidden);
  }
});

test("manual check and confirmed install use Rust registry commands without direct updater plugin", async () => {
  const [client, dashboard, rust] = await Promise.all([
    readFile(clientUrl, "utf8"), readFile(dashboardUrl, "utf8"), readFile(rustUrl, "utf8"),
  ]);
  assert.match(client, /invoke<AppUpdateSnapshot>\("read_app_update_state"\)/);
  assert.match(client, /invoke<AppUpdateSnapshot>\("check_app_update"\)/);
  assert.match(client, /invoke\("install_app_update", \{ version \}\)/);
  assert.doesNotMatch(client, /plugin-updater|downloadAndInstall|\bcheck\s*\(/);
  assert.match(dashboard, /window\.confirm/);
  assert.match(dashboard, /installAppUpdate\(update\.version/);
  assert.match(rust, /checked\.version\.as_deref\(\) != Some\(version\.as_str\(\)\)/);
});

test("automatic registry is app-level, evented, persisted atomically, and tray-fallback aware", async () => {
  const rust = await readFile(rustUrl, "utf8");
  assert.match(rust, /WAKE_INTERVAL: Duration = Duration::from_secs\(60\)/);
  assert.match(rust, /CHECK_INTERVAL_MS: i64 = 4 \* 60 \* 60 \* 1_000/);
  assert.match(rust, /atomic_file::write_atomically/);
  assert.match(rust, /app\.emit\(UPDATE_STATE_EVENT/);
  assert.match(rust, /set_update_available_tray_fallback/);
  assert.match(rust, /last_notified_version/);
});
