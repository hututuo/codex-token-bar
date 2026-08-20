import assert from "node:assert/strict";
import test from "node:test";

import { withSsrModules } from "../test/ssrHarness.mjs";

const payload = {
  code: "indexUpgradeRequired",
  component: "schema",
  stored: "12",
  supported: "9",
  message: "需要升级软件",
};

test("precise index upgrade errors use a stable structured code", async () => {
  await withSsrModules(async (load) => {
    const { classifyPreciseIndexUpgradeRequired } = await load("/src/api/preciseIndexCompatibility.ts");
    const wrapped = new Error(JSON.stringify(payload));
    assert.deepEqual(classifyPreciseIndexUpgradeRequired(wrapped), {
      component: "schema",
      stored: "12",
      supported: "9",
      message: "需要升级软件",
    });
  });
});

test("localized prose alone cannot be misclassified as upgrade-required", async () => {
  await withSsrModules(async (load) => {
    const { classifyPreciseIndexUpgradeRequired } = await load("/src/api/preciseIndexCompatibility.ts");
    assert.equal(
      classifyPreciseIndexUpgradeRequired(new Error("索引版本太高，需要升级软件")),
      null,
    );
  });
});

test("typed upgrade error retains the structured compatibility details", async () => {
  await withSsrModules(async (load) => {
    const {
      classifyPreciseIndexUpgradeRequired,
      PreciseIndexUpgradeRequiredError,
    } = await load("/src/api/preciseIndexCompatibility.ts");
    const details = classifyPreciseIndexUpgradeRequired(new Error(JSON.stringify(payload)));
    assert.ok(details);
    const error = new PreciseIndexUpgradeRequiredError(details);
    assert.equal(error.details.stored, "12");
    assert.equal(error.name, "PreciseIndexUpgradeRequiredError");
  });
});
