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
  assert.doesNotMatch(toolbar + actions, /flex-wrap:\s*wrap/);
});
