import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";

import { withSsrModules } from "../test/ssrHarness.mjs";

test("status quota projection distinguishes unavailable compatibility zero from measured endpoints", async () => {
  await withSsrModules(async (load) => {
    const { StatusQuotaProjection } = await load("/src/status/StatusQuotaProjection.tsx");

    for (const fixture of quotaFixtures()) {
      const html = renderToStaticMarkup(React.createElement(StatusQuotaProjection, {
        fiveHour: quotaLimit("5h", fixture.availability, fixture.remainingPercent),
        sevenDay: quotaLimit("7d", fixture.availability, fixture.remainingPercent),
      }));

      if (fixture.availability === "unavailable") {
        assert.match(html, /role="status"/);
        assert.doesNotMatch(html, /\b0%\b/);
        assert.doesNotMatch(html, /\b100%\b/);
        assert.doesNotMatch(html, /aria-valuenow=/);
      } else {
        assert.match(html, new RegExp(`${fixture.remainingPercent * 100}%`));
      }
    }
  });
});

function quotaFixtures() {
  return [
    { availability: "unavailable", remainingPercent: 0 },
    { availability: "unavailable", remainingPercent: null },
    { availability: "measured", remainingPercent: 0 },
    { availability: "measured", remainingPercent: 1 },
  ];
}

function quotaLimit(label, availability, remainingPercent) {
  return {
    label,
    availability,
    remainingPercent,
    usedPercent: typeof remainingPercent === "number" ? 1 - remainingPercent : null,
    resetsAt: "待读取",
    resetsAtUnix: null,
  };
}
