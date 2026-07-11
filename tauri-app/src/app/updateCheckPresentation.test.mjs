import assert from "node:assert/strict";
import test from "node:test";

import { automaticUpdateNotice } from "./updateCheckPresentation.ts";

test("unsupported and failed automatic checks stay silent", () => {
  assert.equal(automaticUpdateNotice({
    kind: "completed",
    value: { status: "unsupported", message: "此平台暂不支持应用内更新" },
  }), null);
  assert.equal(automaticUpdateNotice({ kind: "failed", error: new Error("network") }), null);
});

test("automatic availability creates a notice without installing", () => {
  let installs = 0;
  const update = { downloadAndInstall: () => { installs += 1; } };
  const notice = automaticUpdateNotice({
    kind: "completed",
    value: { status: "available", version: "0.8.0", body: "", update },
  });

  assert.equal(notice.kind, "available");
  assert.equal(notice.message, "发现新版本 0.8.0");
  assert.equal(notice.update.update, update);
  assert.equal(installs, 0);
});
