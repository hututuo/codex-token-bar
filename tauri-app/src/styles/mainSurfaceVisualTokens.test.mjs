import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const css = readFileSync(new URL("./global.css", import.meta.url), "utf8");

test("light surfaces use white primary cards and restrained neutral fills", () => {
  assert.match(css, /--page:\s*#f5f7fa;/);
  assert.match(css, /--panel:\s*#ffffff;/);
  assert.match(css, /--panel-soft:\s*#f4f6f9;/);
  assert.match(css, /--panel-inset:\s*#f8fafc;/);
  assert.match(css, /\.header-context\s*\{[^}]*background:\s*var\(--panel\);/s);
  assert.match(css, /\.header-primary-actions\s*\{[^}]*background:\s*var\(--panel\);/s);
  assert.match(css, /\.header-info-cell\s*\{[^}]*background:\s*transparent;/s);
  assert.match(css, /\.quota-strip\s*\{[^}]*background:\s*var\(--panel\);/s);
});

test("small muted text keeps normal-text contrast on the light auxiliary surface", () => {
  assert.ok(contrastRatio("#667180", "#f4f6f9") >= 4.5);
  assert.ok(contrastRatio("#667180", "#ffffff") >= 4.5);
});

test("application typography uses the four platform-aligned weight tokens", () => {
  for (const token of ["regular", "medium", "semibold", "bold"]) {
    assert.match(css, new RegExp(`--weight-${token}:`));
  }
  assert.doesNotMatch(css, /font-weight:\s*\d{3}\b/);
  const declarations = [...css.matchAll(/font-weight:\s*([^;]+);/g)].map((match) => match[1].trim());
  assert.ok(declarations.length > 200);
  assert.ok(
    declarations.every((value) => (
      /^var\(--weight-(regular|medium|semibold|bold)\)(?:\s*!important)?$/.test(value)
    )),
  );
});

function contrastRatio(foreground, background) {
  const foregroundLuminance = luminance(foreground);
  const backgroundLuminance = luminance(background);
  const lighter = Math.max(foregroundLuminance, backgroundLuminance);
  const darker = Math.min(foregroundLuminance, backgroundLuminance);
  return (lighter + 0.05) / (darker + 0.05);
}

function luminance(hex) {
  const channels = hex.slice(1).match(/.{2}/g).map((channel) => Number.parseInt(channel, 16) / 255);
  const linear = channels.map((value) => (
    value <= 0.04045
      ? value / 12.92
      : ((value + 0.055) / 1.055) ** 2.4
  ));
  return (0.2126 * linear[0]) + (0.7152 * linear[1]) + (0.0722 * linear[2]);
}
