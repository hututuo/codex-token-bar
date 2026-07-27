import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const script = fileURLToPath(new URL("./patch_codex_desktop_sidebar.sh", import.meta.url));

function makeApp(
  root,
  name,
  bundleIdentifier = "com.openai.codex",
  shortVersion = "1.2.3",
  buildVersion = "456",
) {
  const app = path.join(root, name);
  const contents = path.join(app, "Contents");
  const resources = path.join(contents, "Resources");
  mkdirSync(resources, { recursive: true });
  writeFileSync(
    path.join(contents, "Info.plist"),
    `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>${bundleIdentifier}</string>
<key>CFBundleShortVersionString</key><string>${shortVersion}</string>
<key>CFBundleVersion</key><string>${buildVersion}</string>
</dict></plist>`,
  );
  writeFileSync(path.join(resources, "app.asar"), "fixture");
  return app;
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function makeRollbackBackup(root, app, overrides = {}) {
  const backup = path.join(root, "20260727-190000");
  mkdirSync(backup, { recursive: true });
  writeFileSync(path.join(backup, "app.asar.before"), "original");
  const infoPlist = readFileSync(path.join(app, "Contents", "Info.plist"));
  const currentAsar = readFileSync(path.join(app, "Contents", "Resources", "app.asar"));
  writeFileSync(
    path.join(backup, "backup-metadata.json"),
    JSON.stringify({
      schemaVersion: 1,
      bundleIdentifier: "com.openai.codex",
      bundleShortVersion: "1.2.3",
      bundleVersion: "456",
      infoPlistSha256: sha256(infoPlist),
      originalAsarSha256: sha256(Buffer.from("original")),
      installedPatchedAsarSha256: sha256(currentAsar),
      ...overrides,
    }),
  );
  return backup;
}

function resolveApp({ root, explicit = "" }) {
  return spawnSync("bash", [script, "resolve-app"], {
    encoding: "utf8",
    env: {
      ...process.env,
      CODEX_APP_PATH: explicit,
      CODEX_APP_DISCOVERY_ROOTS: root,
      CODEX_APP_MDFIND_DISABLE: "1",
    },
  });
}

function validateRollback({ app, backup }) {
  return spawnSync(
    "bash",
    [
      script,
      "rollback",
      "--app",
      app,
      "--backup",
      backup,
      "--dry-run",
      "--no-quit",
      "--no-open",
    ],
    {
      encoding: "utf8",
      env: {
        ...process.env,
        CODEX_APP_MDFIND_DISABLE: "1",
      },
    },
  );
}

test("sidebar patch discovers a renamed Codex app in a bounded root", () => {
  const root = mkdtempSync(path.join(tmpdir(), "codex-sidebar-renamed-"));
  const app = makeApp(root, "Renamed Desktop Client.app");

  const result = resolveApp({ root });

  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout.trim(), app);
});

test("sidebar patch keeps an explicit validated app ahead of discovery", () => {
  const root = mkdtempSync(path.join(tmpdir(), "codex-sidebar-explicit-"));
  makeApp(root, "Discovered.app");
  const explicit = makeApp(root, "Explicit.app");

  const result = resolveApp({ root, explicit });

  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout.trim(), explicit);
});

test("sidebar patch ignores apps with the wrong bundle identifier", () => {
  const root = mkdtempSync(path.join(tmpdir(), "codex-sidebar-wrong-bundle-"));
  makeApp(root, "Unrelated.app", "example.unrelated");

  const result = resolveApp({ root });

  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Codex app/);
});

test("sidebar patch discovery does not recurse beyond direct app children", () => {
  const root = mkdtempSync(path.join(tmpdir(), "codex-sidebar-bounded-"));
  const nested = path.join(root, "Nested");
  makeApp(nested, "Hidden.app");

  const result = resolveApp({ root });

  assert.notEqual(result.status, 0);
});

test("sidebar patch quits by bundle identifier rather than a fixed app name", () => {
  const source = readFileSync(script, "utf8");

  assert.match(source, /tell application id "com\.openai\.codex" to quit/);
  assert.doesNotMatch(source, /quit app "Codex"/);
  assert.doesNotMatch(source, /pgrep -x Codex/);
});

test("sidebar rollback accepts only the app and patched ASAR recorded by the backup", () => {
  const root = mkdtempSync(path.join(tmpdir(), "codex-sidebar-rollback-match-"));
  const app = makeApp(root, "Codex.app");
  const backup = makeRollbackBackup(root, app);

  const result = validateRollback({ app, backup });

  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Dry run only/);
});

test("sidebar rollback rejects a backup created for another Codex version", () => {
  const root = mkdtempSync(path.join(tmpdir(), "codex-sidebar-rollback-version-"));
  const app = makeApp(root, "Codex.app");
  const backup = makeRollbackBackup(root, app, {
    bundleShortVersion: "1.2.2",
  });

  const result = validateRollback({ app, backup });

  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /version/i);
});

test("sidebar rollback rejects an app ASAR changed after the recorded patch", () => {
  const root = mkdtempSync(path.join(tmpdir(), "codex-sidebar-rollback-asar-"));
  const app = makeApp(root, "Codex.app");
  const backup = makeRollbackBackup(root, app, {
    installedPatchedAsarSha256: sha256(Buffer.from("different patch")),
  });

  const result = validateRollback({ app, backup });

  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /ASAR/i);
});

test("sidebar rollback rejects a legacy backup without machine-readable identity", () => {
  const root = mkdtempSync(path.join(tmpdir(), "codex-sidebar-rollback-legacy-"));
  const app = makeApp(root, "Codex.app");
  const backup = path.join(root, "20260727-180000");
  mkdirSync(backup, { recursive: true });
  writeFileSync(path.join(backup, "app.asar.before"), "original");

  const result = validateRollback({ app, backup });

  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /backup-metadata\.json/);
});
