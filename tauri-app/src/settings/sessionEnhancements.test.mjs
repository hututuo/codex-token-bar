import assert from "node:assert/strict";
import test from "node:test";
import { withSsrModules } from "../test/ssrHarness.mjs";

test("session enhancement settings preserve defaults and clamp conversation width", async () => {
  await withSsrModules(async (load) => {
    const {
      DEFAULT_SESSION_ENHANCEMENTS,
      sanitizeSessionEnhancements,
    } = await load("/src/settings/sessionEnhancements.ts");

    assert.deepEqual(sanitizeSessionEnhancements(undefined), DEFAULT_SESSION_ENHANCEMENTS);
    assert.deepEqual(sanitizeSessionEnhancements({
      markdownExport: false,
      pasteFix: true,
      conversationViewMaxWidth: 9_999,
    }), {
      ...DEFAULT_SESSION_ENHANCEMENTS,
      markdownExport: false,
      pasteFix: true,
      conversationViewMaxWidth: 4_000,
    });
    assert.equal(sanitizeSessionEnhancements({ conversationViewMaxWidth: 10 }).conversationViewMaxWidth, 320);
  });
});
