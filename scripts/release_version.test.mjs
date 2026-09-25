import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
// Git may check text out as CRLF on Windows; version identity is unchanged.
const read = path => readFileSync(join(root, path), "utf8").replace(/\r\n/g, "\n");
test("all tracked application versions agree before a release can be packaged", () => {
  const version = JSON.parse(read("tauri-app/package.json")).version;
  const lock = JSON.parse(read("tauri-app/package-lock.json"));
  assert.equal(lock.version, version);
  assert.equal(lock.packages[""].version, version);
  assert.equal(JSON.parse(read("tauri-app/src-tauri/tauri.conf.json")).version, version);
  assert.equal(read("tauri-app/src-tauri/Cargo.toml").match(/^version = "([^"]+)"/m)?.[1], version);
  assert.equal(read("tauri-app/src-tauri/Cargo.lock").match(/name = "codex-token-bar"\nversion = "([^"]+)"/)?.[1], version);
  assert.ok(read("scripts/build_tauri_windows_release.ps1").includes(`[string]$Version = "${version}"`));
  assert.ok(read("scripts/build_release.sh").includes(`APP_VERSION:-${version}`));
  assert.ok(read("scripts/package_app.sh").includes(`APP_VERSION:-${version}`));
});
test("Swift bundle metadata uses the same version without building or opening the app", {
  skip: process.platform === "win32" ? "Swift bundle packaging requires the Unix shell lane" : false,
}, () => {
  const folder = mkdtempSync(join(tmpdir(), "tokenbar-version-"));
  try {
    const path = join(folder, "Info.plist");
    const env = { ...process.env }; delete env.APP_VERSION; delete env.APP_BUILD;
    execFileSync("bash", [join(root, "scripts/package_app.sh"), "--write-info-plist", path], { env });
    const plist = readFileSync(path, "utf8");
    const version = JSON.parse(read("tauri-app/package.json")).version;
    assert.equal(plist.match(/<key>CFBundleShortVersionString<\/key>\s*<string>([^<]+)<\/string>/)?.[1], version);
    const [major, minor, patch] = version.split(".").map(Number);
    assert.equal(plist.match(/<key>CFBundleVersion<\/key>\s*<string>([^<]+)<\/string>/)?.[1], String(major * 10000 + minor * 100 + patch));
  } finally { rmSync(folder, { recursive: true, force: true }); }
});
