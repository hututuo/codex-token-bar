import assert from "node:assert/strict";
import test from "node:test";

import {
  floatingWindowLeftForDetails,
  runningModelDetailsPlacement,
} from "./floatingWindowPlacement.ts";

test("running model details flip to the leading side at the right edge", () => {
  const placement = runningModelDetailsPlacement({
    windowLeft: 900,
    surfaceWidth: 308,
    expandedWidth: 586,
    workAreaLeft: 0,
    workAreaRight: 1_200,
  });

  assert.equal(placement, "leading");
  assert.equal(
    floatingWindowLeftForDetails({
      baseLeft: 900,
      surfaceWidth: 308,
      expandedWidth: 586,
      placement,
    }),
    622,
  );
});

test("running model details stay trailing when the right side has room", () => {
  const placement = runningModelDetailsPlacement({
    windowLeft: 120,
    surfaceWidth: 308,
    expandedWidth: 586,
    workAreaLeft: 0,
    workAreaRight: 1_200,
  });

  assert.equal(placement, "trailing");
  assert.equal(
    floatingWindowLeftForDetails({
      baseLeft: 120,
      surfaceWidth: 308,
      expandedWidth: 586,
      placement,
    }),
    120,
  );
});
