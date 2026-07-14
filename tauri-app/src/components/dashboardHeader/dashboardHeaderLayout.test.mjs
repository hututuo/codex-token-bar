import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("DashboardHeader CSS keeps information and primary actions on separate stable rows", async () => {
  const css = await readFile(new URL("../../styles/global.css", import.meta.url), "utf8");
  const toolbar = css.slice(css.indexOf(".header-toolbar {"), css.indexOf(".header-context,"));
  const actions = css.slice(css.indexOf(".header-context,"), css.indexOf(".source-label,"));

  assert.match(toolbar, /display:\s*grid/);
  assert.match(toolbar, /grid-template-columns:\s*minmax\(0, 1fr\)/);
  assert.match(toolbar, /grid-template-rows:\s*auto auto/);
  assert.match(toolbar, /min-width:\s*0/);
  assert.match(actions, /min-width:\s*0/);
  assert.match(actions, /white-space:\s*nowrap/);
  assert.match(actions, /justify-content:\s*center/);
  assert.doesNotMatch(toolbar + actions, /flex-wrap:\s*wrap/);
  assert.match(actions, /\.header-context\s*\{[^}]*border:\s*1px solid var\(--line\)/s);
  assert.match(actions, /\.header-primary-actions\s*\{[^}]*border:\s*1px solid var\(--line\)/s);
  assert.match(actions, /\.header-rail-divider\s*\{[^}]*width:\s*1px/s);
  assert.match(css, /\.header-primary-actions \.toolbar-button\s*\{[^}]*border-radius:\s*6px/s);
  assert.doesNotMatch(css, /\.header-primary-actions \.toolbar-button\s*\{[^}]*border:\s*1px/s);
});
