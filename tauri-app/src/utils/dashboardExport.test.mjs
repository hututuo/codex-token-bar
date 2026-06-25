import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { dashboardToCsv } from "./dashboardExport.ts";

test("dashboardToCsv exports daily token rows with Swift-compatible columns", () => {
  const csv = dashboardToCsv({
    activityDays: [
      { calls: 2, date: "2026-06-24", tokens: 1234 },
      { calls: 3, date: "2026-06-25", tokens: 5678 },
    ],
  });

  assert.equal(csv, "date,tokens,calls\n2026-06-24,1234,2\n2026-06-25,5678,3");
});

test("dashboard header exposes the CSV export action", async () => {
  const source = await readFile(new URL("../components/DashboardHeader.tsx", import.meta.url), "utf8");

  assert.match(source, /导出 CSV/);
  assert.match(source, /onExportCsv/);
});
