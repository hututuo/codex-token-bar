import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const currentDir = dirname(fileURLToPath(import.meta.url));
const previewSource = readFileSync(join(currentDir, "FloatingPanelPreview.tsx"), "utf8");
const floatingWindowSource = readFileSync(join(currentDir, "FloatingWindowApp.tsx"), "utf8");
const stylesSource = readFileSync(join(currentDir, "../styles/global.css"), "utf8");
const settingsPanelSource = readFileSync(
  join(currentDir, "../components/liveRate/LiveRateSettingsPanel.tsx"),
  "utf8",
);

test("ripple uses compositor layers instead of realtime canvas drawing", () => {
  assert.match(previewSource, /<FloatingUnreadRippleLayers \/>/);
  assert.match(stylesSource, /\.unread-ripple-source/);
  assert.match(stylesSource, /\.unread-ripple-ring/);
  assert.doesNotMatch(previewSource, /<canvas/);
  assert.doesNotMatch(previewSource, /getContext\("2d"\)/);
  assert.doesNotMatch(previewSource, /window\.setInterval/);
  assert.doesNotMatch(previewSource, /drawUnreadRippleCanvasFrame/);
  assert.doesNotMatch(previewSource, /preserveAspectRatio="none"/);
  assert.doesNotMatch(previewSource, /<svg className="unread-ripple-svg"/);
});

test("ripple renderer keeps the Swift-style reflection math", () => {
  assert.doesNotMatch(previewSource, /--ripple-delay/);
  assert.match(previewSource, /const RIPPLE_RINGS = \[/);
  assert.match(previewSource, /const RIPPLE_SOURCES = \[/);
  assert.match(previewSource, /data-ripple-source/);
  assert.match(previewSource, /\{ x: 50, y: -50, strength: 0\.84, delay: 0\.24 \}/);
  assert.match(previewSource, /\{ x: 50, y: 250, strength: 0\.52, delay: 0\.48 \}/);
  assert.match(previewSource, /\{ x: -50, y: 50, strength: 0\.66, delay: 0\.34 \}/);
  assert.match(previewSource, /unread-ripple-ring unread-ripple-ring--\$\{ringIndex\}/);
  const ringMatches = previewSource.match(/\{ offset: -?\d+(?:\.\d+)?, alpha: \d(?:\.\d+)?, thickness: \d(?:\.\d+)? \}/g) ?? [];
  assert.equal(ringMatches.length, 5);
});

test("ripple renderer avoids javascript frame timers", () => {
  assert.doesNotMatch(previewSource, /requestAnimationFrame/);
  assert.doesNotMatch(previewSource, /setInterval/);
  assert.doesNotMatch(previewSource, /setTimeout/);
  assert.doesNotMatch(previewSource, /function refreshUnreadRippleLayout/);
});

test("ripple renderer keeps visible ring strength without edge rebound glow", () => {
  assert.match(stylesSource, /opacity: calc\(var\(--ripple-ring-alpha, 1\) \* var\(--ripple-source-strength, 1\) \* 0\.64\);/);
  assert.match(stylesSource, /border: var\(--ripple-ring-thickness, 2px\) solid rgba\(var\(--floating-effect-rgb\), 0\.62\);/);
  assert.match(stylesSource, /rgba\(255, 255, 255, 0\.20\)/);
  assert.doesNotMatch(previewSource, /function drawEdgeContact/);
  assert.doesNotMatch(previewSource, /function drawEdgeGlow/);
  assert.doesNotMatch(previewSource, /function gaussian/);
});

test("ripple reaches panel edges with wider ring spacing", () => {
  assert.match(stylesSource, /--ripple-max-radius: 265%/);
  assert.match(previewSource, /offset: -8\.4/);
  assert.match(previewSource, /offset: -16\.8/);
  assert.match(previewSource, /offset: -25\.2/);
  assert.match(previewSource, /offset: -33\.6/);
});

test("ripple effect layer uses the actual floating panel edge", () => {
  assert.match(stylesSource, /\.unread-effect\s*{[\s\S]*?inset: 0;[\s\S]*?border-radius: inherit;/);
  assert.doesNotMatch(stylesSource, /\.unread-effect\s*{[\s\S]*?inset: 5px;/);
  assert.match(stylesSource, /\.unread-effect\s*{[\s\S]*?overflow: hidden;/);
});

test("ripple effect does not add a static center disk", () => {
  const match = /\.unread-effect--ripple\s*{([\s\S]*?)}/.exec(stylesSource);
  assert.ok(match, "ripple effect style should exist");
  assert.doesNotMatch(match[1], /radial-gradient\(circle at 50% 50%/);
});

test("floating panel keeps muted pace text black metrics rounded corners and corner close button", () => {
  assert.match(stylesSource, /\.floating-panel-surface\s*{[\s\S]*?border-radius: calc\(12px \* var\(--floating-scale\)\);/);
  assert.match(previewSource, /className="floating-rate-readout"/);
  assert.match(stylesSource, /\.floating-topline\s*{[\s\S]*?grid-template-columns: calc\(96px \* var\(--floating-scale\)\) minmax\(0, 1fr\);[\s\S]*?padding-right: calc\(25px \* var\(--floating-scale\)\);/);
  assert.match(stylesSource, /\.floating-rate-readout\s*{[\s\S]*?grid-template-columns: calc\(64px \* var\(--floating-scale\)\) calc\(23px \* var\(--floating-scale\)\);/);
  assert.match(stylesSource, /\.floating-topline strong\s*{[\s\S]*?font-size: calc\(20px \* var\(--floating-scale\)\);[\s\S]*?font-variant-numeric: tabular-nums;/);
  assert.match(stylesSource, /\.floating-rate-readout > span\s*{[\s\S]*?font-size: calc\(8\.6px \* var\(--floating-scale\)\);/);
  assert.match(previewSource, /function FloatingRateMeter/);
  assert.match(previewSource, /fullScale=\{settings\.tokenRateFullScale\}/);
  assert.match(previewSource, /floating-rate-meter--with-status/);
  assert.match(previewSource, /floating-rate-meter--solo/);
  assert.match(previewSource, /hasStatusText \? <em>{statusText}<\/em> : null/);
  assert.match(previewSource, /tokensPerSecond \/ maxValue/);
  assert.match(stylesSource, /\.floating-rate-track\s*{[\s\S]*?height: calc\(5\.5px \* var\(--floating-scale\)\);/);
  assert.match(stylesSource, /\.floating-rate-meter--with-status \.floating-rate-track\s*{[\s\S]*?top: calc\(22px \* var\(--floating-scale\)\);/);
  assert.match(stylesSource, /\.floating-rate-meter--solo \.floating-rate-track\s*{[\s\S]*?top: calc\(12\.25px \* var\(--floating-scale\)\);/);
  assert.match(stylesSource, /\.floating-rate-track i\s*{[\s\S]*?width: var\(--rate-fill, 0%\);/);
  assert.match(stylesSource, /\.floating-rate-meter em\s*{[\s\S]*?font-size: calc\(10\.2px \* var\(--floating-scale\)\);[\s\S]*?white-space: nowrap;/);
  assert.match(stylesSource, /\.floating-usage-status-card\s*{[\s\S]*?max-width: min\(calc\(174px \* var\(--floating-scale\)\), 100%\);[\s\S]*?font-size: calc\(13\.6px \* var\(--floating-scale\)\);/);
  assert.match(stylesSource, /\.floating-metrics\s*{[\s\S]*?font-size: calc\(9\.4px \* var\(--floating-scale\)\);/);
  assert.match(stylesSource, /\.floating-panel-surface\s*{[\s\S]*?padding: calc\(7px \* var\(--floating-scale\)\) calc\(10px \* var\(--floating-scale\)\);/);
  assert.match(stylesSource, /\.floating-panel-surface > :not\(\.unread-effect\):not\(\.floating-close-button\)\s*{/);
  assert.match(stylesSource, /\.floating-close-button\s*{[\s\S]*?position: absolute;[\s\S]*?top: calc\(1px \* var\(--floating-scale\)\);[\s\S]*?right: calc\(1px \* var\(--floating-scale\)\);/);
});

test("floating radar shows multiple sorted model IQ scores", () => {
  assert.match(previewSource, /secondaryModelRows/);
  assert.match(previewSource, /secondaryModelRows\(snapshot\.modelIq\)\.slice\(0, 3\)/);
  assert.match(previewSource, /className="floating-radar-models"/);
  assert.match(previewSource, /compactModelName\(row\.label\)\} \{displayRadarNumber\(row\.point\.score, 1\)/);
});

test("clickable disclosure arrows are right aligned and vertically centered", () => {
  assert.match(stylesSource, /\.floating-popup-buttons button span\s*{[\s\S]*?display: inline-grid;[\s\S]*?place-items: center;/);
  assert.match(stylesSource, /\.quota-reset-card b\s*{[\s\S]*?display: inline-grid;[\s\S]*?place-items: center;/);
  assert.match(stylesSource, /\.reset-credit-summary-row > b\s*{[\s\S]*?display: grid;[\s\S]*?place-items: center;/);
  assert.match(stylesSource, /\.radar-detail-toggle b\s*{[\s\S]*?display: inline-grid;[\s\S]*?place-items: center;/);
});

test("shimmer sweep exits the floating panel before the animation pause", () => {
  const match = /@keyframes unread-shimmer-sweep[\s\S]*?translateX\((\d+)%\) rotate\(12deg\);[\s\S]*?}/.exec(stylesSource);
  assert.ok(match, "unread-shimmer-sweep keyframes should define an end translateX percent");
  assert.ok(Number(match[1]) >= 500, "shimmer should travel past the visible panel before pausing");
});

test("shimmer sweep runs at sixty five percent of the previous speed", () => {
  const match = /\.unread-effect--shimmer::before\s*{[\s\S]*?animation:\s*unread-shimmer-sweep\s+([\d.]+)s/.exec(
    stylesSource,
  );
  assert.ok(match, "shimmer animation should declare its duration");
  assert.equal(Number(match[1]), 3.23);
});

test("floating gradient palette exposes color direction and type controls", () => {
  assert.match(settingsPanelSource, /SettingsCalloutShell[\s\S]*?title="悬浮窗样式"/);
  assert.match(settingsPanelSource, /computeBoundedSettingsCalloutFrame/);
  assert.match(settingsPanelSource, /getBoundingClientRect\(\)/);
  assert.match(settingsPanelSource, /window\.addEventListener\("pointerdown", closeForOutsidePointer, true\)/);
  assert.match(settingsPanelSource, /window\.addEventListener\("focusin", closeForOutsideFocus, true\)/);
  assert.match(settingsPanelSource, /window\.addEventListener\("keydown", closeForEscape, true\)/);
  assert.match(settingsPanelSource, /window\.addEventListener\("blur", closeForWindowBlur\)/);
  assert.match(settingsPanelSource, /aria-label="渐变起始颜色"/);
  assert.match(settingsPanelSource, /aria-label="渐变结束颜色"/);
  assert.match(settingsPanelSource, /aria-label="渐变方向"/);
  assert.match(settingsPanelSource, /aria-label="渐变类型"/);
  assert.match(settingsPanelSource, /<option value="conic">环向<\/option>/);
  assert.match(floatingWindowSource, /conic-gradient\(from \$\{settings\.gradientDirection\} at 50% 50%/);
});
