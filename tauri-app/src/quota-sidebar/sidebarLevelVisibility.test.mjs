import assert from "node:assert/strict";
import test from "node:test";
import { withSsrModules } from "../test/ssrHarness.mjs";

test("compact and expanded projections apply their own hidden lists plus master hidden", async () => {
  await withSsrModules(async load => {
    const { normalizeSidebarLayout } = await load("/src/quota-sidebar/sidebarLayoutModel.ts");
    const { visibleSidebarItems } = await load("/src/quota-sidebar/sidebarLayoutPresentation.ts");
    const layout = normalizeSidebarLayout({
      version: 1,
      hidden: ["models"],
      hiddenCompact: ["speed", "quota:codex"],
      hiddenExpanded: ["tasks", "quota:claudeCode"],
    });
    const quotas = [
      { id: "codex:7d", client: "codex", window: "7d", remaining: 70 },
      { id: "claudeCode:7d", client: "claudeCode", window: "7d", remaining: 80 },
    ];

    const compact = visibleSidebarItems(layout, quotas, true, "compact");
    assert.equal(compact.includes("speed"), false);
    assert.equal(compact.includes("quota:codex"), false);
    assert.equal(compact.includes("tasks"), true);
    assert.equal(compact.includes("quota:claudeCode"), true);
    assert.equal(compact.includes("models"), false, "master hidden applies at both levels");

    const expanded = visibleSidebarItems(layout, quotas, true, "expanded");
    assert.equal(expanded.includes("speed"), true);
    assert.equal(expanded.includes("quota:codex"), true);
    assert.equal(expanded.includes("tasks"), false);
    assert.equal(expanded.includes("quota:claudeCode"), false);
    assert.equal(expanded.includes("models"), false, "master hidden applies at both levels");
  });
});
