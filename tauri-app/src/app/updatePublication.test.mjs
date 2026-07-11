import assert from "node:assert/strict";
import test from "node:test";

import { createUpdateCheckScheduler } from "./updateCheckScheduler.ts";
import { createUpdatePublicationGate } from "./updatePublication.ts";

test("manual check keeps publication ownership when an automatic trigger joins", async () => {
  const checked = deferred();
  const installed = deferred();
  const publications = [];
  let checks = 0;
  let installs = 0;
  const scheduler = createUpdateCheckScheduler({
    check: () => {
      checks += 1;
      return checked.promise;
    },
    now: () => 1_000,
    storageKey: "test:manual-first-publication",
  });
  const publication = createUpdatePublicationGate();

  const manual = (async () => {
    const token = publication.beginManual();
    publications.push("checking");
    const outcome = await scheduler.runManual();
    if (outcome.kind !== "completed" || !publication.isCurrent(token)) {
      return;
    }
    publications.push("available");
    publications.push("installing");
    installs += 1;
    await installed.promise;
    publication.finish(token);
  })();

  const automatic = (async () => {
    const subscriber = publication.subscribeAutomatic();
    const outcome = await scheduler.runAutomatic();
    if (outcome.kind === "completed" && subscriber?.settle()) {
      publications.push("automatic-available");
    }
  })();

  assert.equal(checks, 1);
  checked.resolve({ status: "available", version: "0.8.0" });
  await waitFor(() => publications.at(-1) === "installing");

  assert.deepEqual(publications, ["checking", "available", "installing"]);
  assert.equal(installs, 1);
  assert.equal(publication.beginManual(), null);

  installed.resolve();
  await Promise.all([manual, automatic]);
});

test("a newer manual generation invalidates an older automatic publication", () => {
  const publication = createUpdatePublicationGate();
  const automatic = publication.subscribeAutomatic();
  const manual = publication.beginManual();

  assert.notEqual(automatic, null);
  assert.equal(automatic.settle(), false);
  assert.equal(publication.isCurrent(manual), true);
  assert.ok(manual.generation > automatic.token.generation);
});

test("canceling one automatic subscriber preserves the shared generation for an active subscriber", async () => {
  const checked = deferred();
  let checks = 0;
  const publications = [];
  const scheduler = createUpdateCheckScheduler({
    check: () => {
      checks += 1;
      return checked.promise;
    },
    now: () => 1_000,
    storageKey: "test:automatic-subscriber-leases",
  });
  const publication = createUpdatePublicationGate();
  const subscribe = (name) => {
    const subscriber = publication.subscribeAutomatic();
    const result = scheduler.runAutomatic().then((outcome) => {
      if (outcome.kind === "completed" && subscriber?.settle()) {
        publications.push(name);
      }
    });
    return { result, subscriber };
  };

  const oldEffect = subscribe("old-effect");
  oldEffect.subscriber.cancel();
  const activeEffect = subscribe("active-effect");
  assert.equal(checks, 1);
  assert.equal(oldEffect.subscriber.token.generation, activeEffect.subscriber.token.generation);

  checked.resolve({ status: "available", version: "0.8.0" });
  await Promise.all([oldEffect.result, activeEffect.result]);

  assert.deepEqual(publications, ["active-effect"]);
  assert.equal(activeEffect.subscriber.settle(), false);
});

function deferred() {
  let resolve;
  const promise = new Promise((complete) => { resolve = complete; });
  return { promise, resolve };
}

async function waitFor(predicate) {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    if (predicate()) {
      return;
    }
    await Promise.resolve();
  }
  assert.fail("condition did not become true");
}
