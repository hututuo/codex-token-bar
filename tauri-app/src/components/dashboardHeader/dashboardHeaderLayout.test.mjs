import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("DashboardHeader CSS keeps information and primary actions on separate stable rows", async () => {
  const css = await readFile(new URL("../../styles/global.css", import.meta.url), "utf8");
  const toolbar = css.slice(css.indexOf(".header-toolbar {"), css.indexOf(".header-context,"));
  const shared = css.slice(css.indexOf(".header-context,"), css.indexOf(".header-primary-actions .toolbar-button"));

  assert.match(toolbar, /display:\s*grid/);
  assert.match(toolbar, /grid-template-columns:\s*minmax\(0, 1fr\)/);
  assert.match(toolbar, /grid-template-rows:\s*auto auto/);
  assert.match(toolbar, /min-width:\s*0/);
  assert.match(shared, /min-width:\s*0/);
  assert.match(shared, /white-space:\s*nowrap/);
  assert.match(css, /\.header-context\s*\{[^}]*display:\s*grid/s);
  assert.match(css, /\.header-context\s*\{[^}]*grid-template-columns:\s*minmax\(150px, 0\.74fr\) minmax\(280px, 1\.42fr\) minmax\(190px, 0\.86fr\)/s);
  assert.match(css, /\.header-context\s*\{[^}]*gap:\s*6px/s);
  assert.match(css, /\.header-info-cell\s*\{[^}]*display:\s*grid/s);
  assert.match(css, /\.header-info-main\s*\{[^}]*display:\s*inline-flex/s);
  assert.match(css, /\.header-primary-actions\s*\{[^}]*justify-content:\s*center/s);
  assert.doesNotMatch(toolbar + shared, /flex-wrap:\s*wrap/);
  assert.match(css, /\.header-context\s*\{[^}]*border:\s*1px solid var\(--line\)/s);
  assert.match(css, /\.header-primary-actions\s*\{[^}]*border:\s*1px solid var\(--line\)/s);
  assert.match(css, /\.header-action-divider\s*\{[^}]*width:\s*1px/s);
  assert.match(css, /\.header-primary-actions \.toolbar-button\s*\{[^}]*border-radius:\s*6px/s);
  assert.doesNotMatch(css, /\.header-primary-actions \.toolbar-button\s*\{[^}]*border:\s*1px/s);
});
