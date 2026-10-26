import assert from "node:assert/strict";
import test from "node:test";
import { withSsrModules } from "../test/ssrHarness.mjs";

test("Claude-only scope never borrows Codex task counts or live speed",async()=>{
 await withSsrModules(async load=>{
  const{normalizeSidebarLayout}=await load('/src/quota-sidebar/sidebarLayoutModel.ts');
  const{sidebarLayoutItems}=await load('/src/quota-sidebar/sidebarLayoutPresentation.ts');
  const quota={id:'claudeCode:5h',client:'claudeCode',window:'5h',remaining:62};
  const config=normalizeSidebarLayout(null);
  const claude=sidebarLayoutItems(config,[quota],false);
  for(const id of ['tasks','speed','models'])assert.equal(claude.includes(id),false,id);
  assert.equal(claude.includes('quota:claudeCode'),true);
  const combined=sidebarLayoutItems(config,[quota],true);
  assert.equal(combined.includes('tasks'),true);
 });
});

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
