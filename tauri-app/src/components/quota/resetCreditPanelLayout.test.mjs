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

test("reset credit disclosure keeps the whole summary row clickable and uses a large vector chevron", () => {
  assert.match(
    quotaStripSource,
    /className="reset-credit-summary-row"[\s\S]*?aria-expanded=\{expanded\}[\s\S]*?onClick=\{onToggle\}/,
  );
  assert.match(
    quotaStripSource,
    /className="reset-credit-disclosure"[\s\S]*?viewBox="0 0 20 20"/,
  );
  assert.match(
    stylesSource,
    /\.reset-credit-summary-row\s*{[\s\S]*?grid-template-columns:\s*30px minmax\(0, 1fr\) auto 28px;[\s\S]*?width:\s*100%;/,
  );
  assert.match(
    stylesSource,
    /\.reset-credit-disclosure\s*{[\s\S]*?width:\s*20px;[\s\S]*?height:\s*20px;/,
  );
});
