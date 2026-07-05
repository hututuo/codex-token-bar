import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const currentDir = dirname(fileURLToPath(import.meta.url));
const quotaStripSource = readFileSync(join(currentDir, "../QuotaStrip.tsx"), "utf8");
const stylesSource = readFileSync(join(currentDir, "../../styles/global.css"), "utf8");

test("reset credit details use a fixed viewport layer instead of being clipped by the quota strip", () => {
  assert.match(quotaStripSource, /className="reset-credit-panel-layer"/);
  assert.match(quotaStripSource, /role="dialog"/);
  assert.match(stylesSource, /\.reset-credit-panel-layer\s*{[\s\S]*?position: fixed;[\s\S]*?inset: 0;/);
  assert.match(stylesSource, /\.reset-credit-panel\s*{[\s\S]*?width: min\(560px, calc\(100vw - 48px\)\);[\s\S]*?max-height: calc\(100vh - 102px\);/);
});

test("quota read warning keeps a styled inline retry affordance", () => {
  assert.match(stylesSource, /\.quota-read-warning\s*{/);
  assert.match(stylesSource, /\.quota-warning-refresh\s*{/);
});
