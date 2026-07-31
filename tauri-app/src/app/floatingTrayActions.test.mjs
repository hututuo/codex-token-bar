import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

test("floating panel double click opens dashboard instead of starting a drag", async () => {
  const floatingWindow = await readFile(new URL("../floating/FloatingWindowApp.tsx", import.meta.url), "utf8");
  const floatingPanel = await readFile(new URL("../floating/FloatingPanelPreview.tsx", import.meta.url), "utf8");

  assert.match(floatingWindow, /function openDashboardWindow\(\)/);
  assert.match(floatingWindow, /desktopPlatform\.showDashboardWindow\(\)/);
  assert.match(floatingWindow, /event\.detail >= 2/);
  assert.match(floatingPanel, /onOpenDashboard\?: \(\) => void/);
  assert.match(floatingPanel, /onDoubleClick=\{onOpenDashboard\}/);
});

test("status tray left click toggles status panel while its menu opens dashboard or quits", async () => {
  const surfaces = await readFile(new URL("../../src-tauri/src/platform/surfaces.rs", import.meta.url), "utf8");

  assert.match(surfaces, /const STATUS_TRAY_SHOW_DASHBOARD_ID/);
  assert.match(surfaces, /const STATUS_TRAY_QUIT_ID/);
  assert.match(surfaces, /MenuItem::with_id\(app,\s*STATUS_TRAY_SHOW_DASHBOARD_ID,\s*"打开主界面"/);
  assert.match(surfaces, /MenuItem::with_id\(app,\s*STATUS_TRAY_QUIT_ID,\s*"退出"/);
  assert.match(surfaces, /\.menu\(&menu\)/);
  assert.match(surfaces, /\.show_menu_on_left_click\(false\)/);
  assert.match(surfaces, /button: MouseButton::Left[\s\S]*?schedule_status_panel_toggle/);
  assert.match(
    surfaces,
    /fn schedule_status_panel_toggle[\s\S]*?tokio::time::sleep[\s\S]*?run_on_main_thread[\s\S]*?toggle_status_panel_at_tray/,
  );
  assert.match(surfaces, /event_id == STATUS_TRAY_SHOW_DASHBOARD_ID[\s\S]*?schedule_dashboard_show/);
  assert.match(
    surfaces,
    /fn schedule_dashboard_show[\s\S]*?tokio::time::sleep[\s\S]*?run_on_main_thread[\s\S]*?show_dashboard_window/,
  );
  assert.doesNotMatch(surfaces, /event_id == STATUS_TRAY_SHOW_DASHBOARD_ID[\s\S]*?show_status_panel_at_tray\(app/);
  assert.match(
    surfaces,
    /fn create_status_panel_window[\s\S]*?\.shadow\(true\)[\s\S]*?\.transparent\(true\)[\s\S]*?\.visible\(false\)/,
  );
  assert.match(surfaces, /app\.exit\(0\)/);
});
