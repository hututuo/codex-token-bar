import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

test("Windows parent/child frame commit uses suppressed redraw, restoration and a paint barrier", () => {
  const source = readFileSync(new URL("../../src-tauri/src/commands/surface.rs", import.meta.url), "utf8");
  const impl = source.slice(source.indexOf("fn apply_windows_floating_frame_and_viewport("));
  assert.doesNotMatch(impl, /(?:BeginDeferWindowPos|EndDeferWindowPos|DeferWindowPos)\s*\(/);
  assert.match(impl, /GetParent\(webview_parent/);
  assert.match(impl, /SWP_NOREDRAW \| SWP_NOCOPYBITS/);
  assert.match(impl, /restored_outer = set_frame/);
  assert.match(impl, /restored_child = set_frame/);
  assert.match(impl, /RedrawWindow\(outer\.0/);
  assert.match(impl, /DwmFlush\(\)/);
  assert.match(source, /wait_for_paint: true/);
});


test("WebView2 delivers floating presses to the dock controller instead of a native drag region", () => {
  const css = readFileSync(new URL("../styles/global.css", import.meta.url), "utf8");
  const rule = /\.floating-panel-surface \{([\s\S]*?)\n\}/.exec(css)?.[1];
  assert.ok(rule);
  assert.match(rule, /-webkit-app-region:\s*no-drag/);
  assert.doesNotMatch(rule, /-webkit-app-region:\s*drag\s*;/);
  const panel = readFileSync(new URL("./FloatingPanelPreview.tsx", import.meta.url), "utf8");
  assert.match(panel, /onMouseDown=\{previewMode \? undefined : onDragStart\}/);
});
