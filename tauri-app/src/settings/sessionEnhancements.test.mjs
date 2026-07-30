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
      sessionDelete: true,
      markdownExport: false,
      pasteFix: true,
      conversationViewMaxWidth: 9_999,
    }), {
      ...DEFAULT_SESSION_ENHANCEMENTS,
      markdownExport: false,
      pasteFix: true,
      conversationViewMaxWidth: 4_000,
    });
    assert.equal(
      sanitizeSessionEnhancements({ sessionDelete: true }).sessionDelete,
      false,
      "legacy persisted delete opt-ins must migrate to fail-closed",
    );
    assert.equal(sanitizeSessionEnhancements({ conversationViewMaxWidth: 10 }).conversationViewMaxWidth, 320);
  });
});
