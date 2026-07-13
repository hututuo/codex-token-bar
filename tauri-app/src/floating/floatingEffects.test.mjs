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

test("ripple uses a Swift-style sprite image atlas instead of realtime DOM canvas drawing", () => {
  assert.match(previewSource, /<FloatingUnreadRippleSprite effectRgb=\{effectRgb\} \/>/);
  assert.match(previewSource, /function renderRippleAtlas/);
  assert.match(stylesSource, /\.unread-ripple-sprite/);
  assert.match(previewSource, /<img/);
  assert.match(previewSource, /URL\.createObjectURL/);
  assert.match(previewSource, /URL\.revokeObjectURL/);
  assert.match(previewSource, /canvas\.toBlob/);
  assert.doesNotMatch(previewSource, /<canvas/);
  assert.doesNotMatch(previewSource, /toDataURL/);
  assert.doesNotMatch(previewSource, /window\.setInterval/);
  assert.doesNotMatch(previewSource, /drawUnreadRippleCanvasFrame/);
  assert.doesNotMatch(previewSource, /preserveAspectRatio="none"/);
  assert.doesNotMatch(previewSource, /<svg className="unread-ripple-svg"/);
});

test("ripple renderer keeps the Swift-style reflection math", () => {
  assert.match(previewSource, /const RIPPLE_CYCLE_SECONDS = 3\.25/);
  assert.match(previewSource, /const RIPPLE_ACTIVE_FRACTION = 0\.92/);
  assert.match(previewSource, /const RIPPLE_TARGET_FPS = 30/);
  assert.match(previewSource, /Math\.max\(Math\.max\(request\.width, request\.height\) \* 0\.82, request\.height \* 2\.25\)/);
  assert.match(previewSource, /point: \{ x: center\.x, y: -center\.y \}, arrivalDistance: center\.y, strength: 0\.84, isDirect: false/);
  assert.match(previewSource, /point: \{ x: center\.x, y: center\.y \+ 2 \* request\.height \}[\s\S]*?arrivalDistance: request\.height \+ center\.y[\s\S]*?strength: 0\.52[\s\S]*?isDirect: false/);
  assert.match(previewSource, /point: \{ x: -center\.x, y: center\.y \}, arrivalDistance: center\.x, strength: 0\.66, isDirect: false/);
  const ringMatches = previewSource.match(/\{ offset: -?\d+(?:\.\d+)? \* request\.scale, alpha: \d(?:\.\d+)?, thickness: \d(?:\.\d+)? \}/g) ?? [];
  assert.equal(ringMatches.length, 5);
});

test("ripple renderer avoids javascript frame timers", () => {
  assert.doesNotMatch(previewSource, /setInterval/);
  assert.doesNotMatch(previewSource, /setTimeout/);
  assert.doesNotMatch(previewSource, /function refreshUnreadRippleLayout/);
});

test("ripple renderer keeps Swift frame cache budget without edge contact glow", () => {
  assert.match(previewSource, /const RIPPLE_MAX_FRAME_SEQUENCE_BYTES = 48 \* 1024 \* 1024/);
  assert.match(previewSource, /function cappedRippleBackingScale/);
  assert.doesNotMatch(previewSource, /function drawEdgeContact/);
  assert.doesNotMatch(previewSource, /function drawEdgeGlow/);
  assert.doesNotMatch(previewSource, /function gaussian/);
  assert.doesNotMatch(previewSource, /amount \* 0\.27/);
});

test("ripple uses Swift ring spacing and discrete frame playback", () => {
  assert.match(previewSource, /offset: -6\.2 \* request\.scale/);
  assert.match(previewSource, /offset: -12\.4 \* request\.scale/);
  assert.match(previewSource, /offset: -18\.6 \* request\.scale/);
  assert.match(previewSource, /offset: -24\.8 \* request\.scale/);
  assert.match(stylesSource, /animation-name: unread-ripple-sprite;/);
  assert.match(stylesSource, /animation-duration: 3\.25s;/);
  assert.match(stylesSource, /transform: translate3d\(0, var\(--ripple-frame-shift, -100%\), 0\);/);
  assert.doesNotMatch(stylesSource, /background-position/);
});

test("ripple effect layer uses the actual floating panel edge", () => {
  assert.match(stylesSource, /\.unread-effect\s*{[\s\S]*?inset: 0;[\s\S]*?border-radius: inherit;/);
  assert.doesNotMatch(stylesSource, /\.unread-effect\s*{[\s\S]*?inset: 5px;/);
  assert.match(stylesSource, /\.unread-effect\s*{[\s\S]*?overflow: hidden;/);
});

test("ripple effect does not add a static center disk", () => {
  const match = /\.unread-effect--ripple\s*{([\s\S]*?)}/.exec(stylesSource);
  assert.ok(match, "ripple effect style should exist");
  assert.match(match[1], /background:\s*transparent;/);
  assert.doesNotMatch(match[1], /radial-gradient\(circle at 50% 50%/);
});

test("ripple sprite inherits the floating panel radius and renders against the outer effect layer", () => {
  assert.match(previewSource, /const containerComputed = element\.parentElement \? getComputedStyle\(element\.parentElement\) : computed/);
  assert.match(previewSource, /cornerRadius: readRippleCornerRadius\(containerComputed, width, height\)/);
  assert.match(stylesSource, /\.unread-ripple-sprite\s*{[\s\S]*?border-radius: inherit;/);
});

test("ripple atlas rebuilds on color changes without waiting for resize", () => {
  assert.match(previewSource, /<FloatingUnreadRippleSprite[\s\S]*?effectRgb=\{effectRgb\}/);
  assert.match(previewSource, /effectRgb: RippleRGB/);
  assert.match(previewSource, /useMemo\(\(\) => normalizeRippleRGB\(effectRgb\), \[effectRgb\]\)/);
  assert.match(previewSource, /}, \[normalizedEffectRgb\]\);/);
});

test("ripple atlas ignores stale async render results", () => {
  assert.match(previewSource, /renderGenerationRef/);
  assert.match(previewSource, /const generation = renderGenerationRef\.current \+ 1/);
  assert.match(previewSource, /renderGenerationRef\.current = generation/);
  assert.match(previewSource, /renderGenerationRef\.current !== generation/);
  assert.match(previewSource, /URL\.revokeObjectURL\(nextAtlas\.url\)/);
});

test("floating panel keeps muted pace text black metrics rounded corners and corner close button", () => {
  assert.match(stylesSource, /\.floating-panel-surface\s*{[\s\S]*?border-radius: calc\(12px \* var\(--floating-scale\)\);/);
  assert.match(previewSource, /className="floating-rate-readout"/);
  assert.match(stylesSource, /\.floating-topline\s*{[\s\S]*?grid-template-columns: calc\(86px \* var\(--floating-scale\)\) minmax\(0, 1fr\);[\s\S]*?padding-right: calc\(17px \* var\(--floating-scale\)\);/);
  assert.match(stylesSource, /\.floating-rate-readout\s*{[\s\S]*?grid-template-columns: calc\(58px \* var\(--floating-scale\)\) calc\(20px \* var\(--floating-scale\)\);/);
  assert.match(stylesSource, /\.floating-topline strong\s*{[\s\S]*?font-size: calc\(19px \* var\(--floating-scale\)\);[\s\S]*?font-variant-numeric: tabular-nums;/);
  assert.match(stylesSource, /\.floating-rate-readout > span\s*{[\s\S]*?font-size: calc\(8px \* var\(--floating-scale\)\);/);
  assert.match(previewSource, /function FloatingRateMeter/);
  assert.match(previewSource, /fullScale=\{settings\.tokenRateFullScale\}/);
  assert.match(previewSource, /floating-rate-meter--with-status/);
  assert.match(previewSource, /floating-rate-meter--solo/);
  assert.match(previewSource, /hasStatusText \? <FloatingStatusText text=\{statusText\} \/> : null/);
  assert.match(previewSource, /rateFillStyle\(snapshot\.tokensPerSecond, scaleLimit\)/);
  assert.match(stylesSource, /\.floating-rate-track\s*{[\s\S]*?height: calc\(5\.5px \* var\(--floating-scale\)\);/);
  assert.match(stylesSource, /\.floating-rate-meter--with-status \.floating-rate-track\s*{[\s\S]*?top: calc\(22px \* var\(--floating-scale\)\);/);
  assert.match(stylesSource, /\.floating-rate-meter--solo \.floating-rate-track\s*{[\s\S]*?top: calc\(12\.25px \* var\(--floating-scale\)\);/);
  assert.match(stylesSource, /\.rate-fill\s*{[\s\S]*?transform: scaleX\(var\(--rate-fill-scale, 0\)\);/);
  assert.match(stylesSource, /\.floating-status-text em\s*{[\s\S]*?font-size: calc\(9\.8px \* var\(--floating-scale\)\);[\s\S]*?text-overflow: clip;[\s\S]*?white-space: nowrap;/);
  assert.match(stylesSource, /\.floating-usage-status-card\s*{[\s\S]*?width: 100%;[\s\S]*?max-width: 100%;[\s\S]*?font-size: calc\(12\.6px \* var\(--floating-scale\)\);/);
  assert.match(stylesSource, /\.floating-metrics\s*{[\s\S]*?font-size: calc\(9\.4px \* var\(--floating-scale\)\);/);
  assert.match(stylesSource, /\.floating-panel-surface\s*{[\s\S]*?padding: calc\(7px \* var\(--floating-scale\)\) calc\(10px \* var\(--floating-scale\)\);/);
  assert.match(stylesSource, /\.floating-panel-surface > :not\(\.unread-effect\):not\(\.floating-close-button\)\s*{/);
  assert.match(stylesSource, /\.floating-close-button\s*{[\s\S]*?position: absolute;[\s\S]*?top: calc\(1px \* var\(--floating-scale\)\);[\s\S]*?right: calc\(1px \* var\(--floating-scale\)\);/);
});

test("floating pace text keeps the Swift-style status and card count in one line", () => {
  assert.match(previewSource, /FloatingStatusText/);
  assert.doesNotMatch(previewSource, /floatingResetCreditLabel/);
  assert.match(previewSource, /floatingRateBarStatusText\(snapshot\)/);
  assert.match(previewSource, /floatingStandaloneStatusText\(snapshot\)/);
  assert.doesNotMatch(previewSource, /卡--/);
  assert.doesNotMatch(stylesSource, /\.floating-status-badge\s*{/);
  assert.match(stylesSource, /\.floating-status-text\s*{[\s\S]*?display: block;/);
  assert.match(stylesSource, /\.floating-usage-status\s*{[\s\S]*?justify-content: center;/);
  assert.match(stylesSource, /\.floating-usage-status-card\s*{[\s\S]*?box-sizing: border-box;[\s\S]*?width: 100%;[\s\S]*?text-align: center;[\s\S]*?white-space: nowrap;/);
  assert.match(stylesSource, /\.floating-usage-status-card \.floating-status-text em\s*{[\s\S]*?text-overflow: clip;[\s\S]*?white-space: nowrap;/);
  assert.match(stylesSource, /\.floating-rate-meter \.floating-status-text em\s*{[\s\S]*?text-align: left;/);
  assert.match(stylesSource, /\.floating-topline em\s*{[\s\S]*?overflow: visible;[\s\S]*?text-overflow: clip;/);
  assert.doesNotMatch(stylesSource, /\.floating-status-text em\s*{[^}]*text-overflow: ellipsis;/);
});

test("floating radar shows multiple sorted model IQ scores", () => {
  assert.match(previewSource, /secondaryModelRows/);
  assert.match(previewSource, /uniqueFloatingRadarRows\(secondaryModelRows\(snapshot\.modelIq\), 2\)/);
  assert.match(previewSource, /className="floating-radar-models"/);
  assert.match(previewSource, /compactRadarModelName\(primary\.label\)/);
  assert.match(previewSource, /compactRadarModelName\(row\.label\).*displayRadarNumber\(row\.point\.score, 1\)/s);
  assert.doesNotMatch(previewSource, /function floatingRadar(?:Primary|Short)ModelLabel/);
  assert.match(stylesSource, /\.floating-radar-models\s*{[\s\S]*?display: block;[\s\S]*?text-overflow: clip;/);
  assert.match(stylesSource, /\.floating-radar\s*{[\s\S]*?grid-template-columns: minmax\(0, 0\.74fr\) minmax\(0, 1\.26fr\);/);
  assert.match(previewSource, /className="floating-radar-dot"/);
  assert.match(stylesSource, /\.floating-radar strong\s*{[\s\S]*?display: grid;[\s\S]*?grid-template-columns: calc\(4px \* var\(--floating-scale\)\) max-content minmax\(0, 1fr\);/);
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
