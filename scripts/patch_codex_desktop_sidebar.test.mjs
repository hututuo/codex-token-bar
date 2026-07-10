import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const script = fileURLToPath(new URL("./patch_codex_desktop_sidebar.sh", import.meta.url));

function makeApp(root, name, bundleIdentifier = "com.openai.codex") {
  const app = path.join(root, name);
  const contents = path.join(app, "Contents");
  const resources = path.join(contents, "Resources");
  mkdirSync(resources, { recursive: true });
  writeFileSync(
    path.join(contents, "Info.plist"),
    `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>${bundleIdentifier}</string>
</dict></plist>`,
  );
  writeFileSync(path.join(resources, "app.asar"), "fixture");
  return app;
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
