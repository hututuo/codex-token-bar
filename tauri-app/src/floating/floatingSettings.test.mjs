import test from "node:test";
import assert from "node:assert/strict";
import {
  FLOATING_DEFAULT_HEIGHT,
  FLOATING_MIN_HEIGHT,
  DEFAULT_FLOATING_SETTINGS,
  sanitizeFloatingSettings,
} from "./floatingSettings.ts";

test("floating height separates Swift-style protection from the default expanded content", () => {
  assert.equal(FLOATING_MIN_HEIGHT, 88);
  assert.equal(FLOATING_DEFAULT_HEIGHT, 112);
});

test("sanitizeFloatingSettings keeps valid gradient palette values", () => {
  const settings = sanitizeFloatingSettings({
    opacity: 0.78,
    scale: 1.22,
    tokenRateFullScale: 260,
    unreadEffect: "shimmer",
    gradientStart: "#ABCDEF",
    gradientEnd: "#123456",
    gradientDirection: "90deg",
    gradientType: "conic",
  });

  assert.equal(settings.gradientStart, "#abcdef");
  assert.equal(settings.gradientEnd, "#123456");
  assert.equal(settings.gradientDirection, "90deg");
  assert.equal(settings.gradientType, "conic");
  assert.equal(settings.tokenRateFullScale, 260);
});

test("sanitizeFloatingSettings falls back for invalid gradient palette values", () => {
  const settings = sanitizeFloatingSettings({
    opacity: 2,
    scale: 3,
    tokenRateFullScale: 900,
    unreadEffect: "sparkle",
    gradientStart: "blue",
    gradientEnd: "#12",
    gradientDirection: "270deg",
    gradientType: "mesh",
  });

  assert.equal(settings.opacity, 1);
  assert.equal(settings.scale, 1.38);
  assert.equal(settings.unreadEffect, DEFAULT_FLOATING_SETTINGS.unreadEffect);
  assert.equal(settings.gradientStart, DEFAULT_FLOATING_SETTINGS.gradientStart);
  assert.equal(settings.gradientEnd, DEFAULT_FLOATING_SETTINGS.gradientEnd);
  assert.equal(settings.gradientDirection, DEFAULT_FLOATING_SETTINGS.gradientDirection);
  assert.equal(settings.gradientType, DEFAULT_FLOATING_SETTINGS.gradientType);
  assert.equal(settings.tokenRateFullScale, 400);
});

test("sanitizeFloatingSettings defaults missing token rate full scale to Swift-style 200 tok/s", () => {
  const settings = sanitizeFloatingSettings({});

  assert.equal(DEFAULT_FLOATING_SETTINGS.tokenRateFullScale, 200);
  assert.equal(settings.tokenRateFullScale, 200);
});
