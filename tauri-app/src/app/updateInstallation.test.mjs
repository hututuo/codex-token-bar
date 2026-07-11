import assert from "node:assert/strict";
import test from "node:test";

import { installPendingUpdate } from "./updateInstallation.ts";
import { createUpdatePublicationGate } from "./updatePublication.ts";

test("a returned successful install leaves installing state and releases its token", async () => {
  const publication = createUpdatePublicationGate();
  const token = publication.beginManual();
  const states = [];
  let installs = 0;

  await installPendingUpdate({
    install: async (_update, onProgress) => {
      installs += 1;
      onProgress("正在安装更新...");
    },
    publication,
    publish: (state) => states.push(state),
    token,
    update: availableUpdate(),
  });

  assert.equal(installs, 1);
  assert.deepEqual(states.map((state) => state.kind), ["installing", "installing", "idle"]);
  assert.equal(states.at(-1).message, "更新已安装，请重新启动应用");
  assert.equal(publication.isCurrent(token), false);
  assert.notEqual(publication.beginManual(), null);
});

test("failed and stale install returns release only their matching token", async () => {
  const publication = createUpdatePublicationGate();
  const failedToken = publication.beginManual();
  const failedStates = [];

  await installPendingUpdate({
    install: async () => { throw new Error("download failed"); },
    publication,
    publish: (state) => failedStates.push(state),
    token: failedToken,
    update: availableUpdate(),
  });

  assert.equal(failedStates.at(-1).kind, "error");
  assert.equal(publication.isCurrent(failedToken), false);

  const staleToken = publication.beginManual();
  const completed = deferred();
  let staleInstalls = 0;
  const staleStates = [];
  const staleInstall = installPendingUpdate({
    install: () => {
      staleInstalls += 1;
      return completed.promise;
    },
    publication,
    publish: (state) => staleStates.push(state),
    token: staleToken,
    update: availableUpdate(),
  });
  publication.finish(staleToken);
  const currentToken = publication.beginManual();
  completed.resolve();
  await staleInstall;

  assert.equal(staleInstalls, 1);
  assert.deepEqual(staleStates.map((state) => state.kind), ["installing"]);
  assert.equal(publication.isCurrent(currentToken), true);
});

function availableUpdate() {
  return {
    body: "",
    status: "available",
    update: { downloadAndInstall() {} },
    version: "0.8.0",
  };
}

function deferred() {
  let resolve;
  const promise = new Promise((complete) => { resolve = complete; });
  return { promise, resolve };
}
