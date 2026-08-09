import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("DashboardHeader CSS keeps a compact top band and a wrapping status strip", async () => {
  const css = await readFile(new URL("../../styles/global.css", import.meta.url), "utf8");
  assert.match(css, /\.dash-head\s*\{[^}]*display:\s*grid/s);
  assert.match(css, /\.account-row\s*\{[^}]*margin-bottom:\s*4px/s);
  assert.match(css, /\.dash-head\s*\{[^}]*border-radius:\s*14px/s);
  assert.match(css, /\.dash-head__top\s*\{[^}]*display:\s*flex/s);
  assert.match(css, /\.dash-head__mark\s*\{[^}]*width:\s*30px[^}]*height:\s*30px/s);
  assert.match(css, /\.dash-head__strip\s*\{[^}]*display:\s*grid/s);
  assert.match(css, /\.dash-head__strip\s*\{[^}]*grid-template-columns:[^}]*minmax\(130px, 0\.7fr\)[^}]*minmax\(230px, 1\.45fr\)/s);
  assert.match(css, /@media \(max-width: 820px\)[\s\S]*?\.dash-head__strip\s*\{[^}]*grid-template-columns:\s*minmax\(120px, 0\.8fr\) minmax\(220px, 1\.4fr\)/s);
  assert.match(css, /\.dash-head__menu\s*\{[^}]*position:\s*absolute/s);
  assert.match(css, /\.dash-head__menu\s*\{[^}]*z-index:\s*42/s);
  assert.match(css, /\.dash-head__platform > small\s*\{[^}]*display:\s*flex/s);
});
