import assert from "node:assert/strict";
import test from "node:test";
import { createProviderRepairAutoScanController } from "./autoScanController.ts";

test("provider repair auto scan is one-shot across busy false true false transitions", () => {
  const controller = createProviderRepairAutoScanController();

  assert.equal(controller.shouldStart(true), true);
  assert.equal(controller.shouldStart(false), false);
  assert.equal(controller.shouldStart(true), false);
});

test("provider repair auto scan can run again after panel remount creates a new controller", () => {
  const firstMount = createProviderRepairAutoScanController();
  const secondMount = createProviderRepairAutoScanController();

  assert.equal(firstMount.shouldStart(true), true);
  assert.equal(firstMount.shouldStart(true), false);
  assert.equal(secondMount.shouldStart(true), true);
});
