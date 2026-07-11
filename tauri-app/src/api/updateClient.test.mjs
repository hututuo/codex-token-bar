import assert from "node:assert/strict";
import test from "node:test";

import {
  isUnsupportedUpdaterError,
  manualUpdateFailureMessage,
} from "./updateModel.ts";

test("unsupported macOS updater errors are classified without exposing raw text", () => {
  const raw = "Updater is not supported on this platform: darwin-aarch64";

  assert.equal(isUnsupportedUpdaterError(new Error(raw)), true);
  assert.equal(manualUpdateFailureMessage(new Error(raw)), "此平台暂不支持应用内更新");
  assert.equal(manualUpdateFailureMessage(new Error(raw)).includes(raw), false);
});

test("supported-platform failures use a short bounded product message", () => {
  const raw = "network request failed with a very long transport and certificate diagnostic";
  const message = manualUpdateFailureMessage(new Error(raw));

  assert.equal(isUnsupportedUpdaterError(new Error(raw)), false);
  assert.equal(message, "暂时无法检查更新，请稍后重试");
  assert.ok(message.length <= 20);
  assert.equal(message.includes(raw), false);
});
