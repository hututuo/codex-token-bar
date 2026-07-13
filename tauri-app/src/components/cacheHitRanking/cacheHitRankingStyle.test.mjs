import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const currentDir = dirname(fileURLToPath(import.meta.url));
const stylesSource = readFileSync(join(currentDir, "../../styles/global.css"), "utf8");

test("cache hit ranking keeps quota gradient separate from hit-meter tone styling", () => {
  assert.match(
    stylesSource,
    /\.quota-track-fill\s*\{[\s\S]*--metric-color:[\s\S]*var\(--metric-color\)/m,
  );
  assert.match(
    stylesSource,
    /\.hit-meter span\s*\{[\s\S]*var\(--cache-hit-tone, var\(--accent\)\)/m,
  );
  assert.doesNotMatch(stylesSource, /\.hit-meter span\s*\{[^}]*var\(--metric-color\)/m);
});
