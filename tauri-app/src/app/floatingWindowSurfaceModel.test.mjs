import assert from "node:assert/strict";
import test from "node:test";
import {
  floatingCommandPreferenceConfirmation,
  floatingCommandVisibleState,
  shouldConfirmFloatingHiddenEvent,
} from "./floatingWindowSurfaceModel.ts";

test("successful floating surface commands confirm the native visibility as preference", () => {
  const showResult = { ok: true, value: true };
  const hideResult = { ok: true, value: false };

  assert.equal(floatingCommandVisibleState(showResult, false), true);
  assert.equal(floatingCommandPreferenceConfirmation(showResult), true);
  assert.equal(floatingCommandVisibleState(hideResult, true), false);
  assert.equal(floatingCommandPreferenceConfirmation(hideResult), false);
});

test("failed or timed-out floating commands keep current visibility and do not confirm preference", () => {
  const timedOutShow = {
    ok: false,
    fallback: false,
    error: "Command timed out after 2000ms",
  };
  const failedHide = {
    ok: false,
    fallback: true,
    error: "hide failed",
  };

  assert.equal(floatingCommandVisibleState(timedOutShow, true), true);
  assert.equal(floatingCommandPreferenceConfirmation(timedOutShow), null);
  assert.equal(floatingCommandVisibleState(failedHide, false), false);
  assert.equal(floatingCommandPreferenceConfirmation(failedHide), null);
});

test("real hidden-window events only confirm disabled preference after settings are loaded", () => {
  assert.equal(shouldConfirmFloatingHiddenEvent(false, true), false);
  assert.equal(shouldConfirmFloatingHiddenEvent(true, false), false);
  assert.equal(shouldConfirmFloatingHiddenEvent(true, true), true);
});
