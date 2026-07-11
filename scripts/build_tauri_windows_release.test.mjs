import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const scriptsDir = path.dirname(fileURLToPath(import.meta.url));
const windowsScript = path.join(scriptsDir, "build_tauri_windows_release.ps1");
const windowsSelfTest = path.join(scriptsDir, "build_tauri_windows_release.selftest.ps1");

test("Windows build publishes a clean unsigned directory in one rename", async () => {
  const source = await readFile(windowsScript, "utf8");
  assert.match(source, /windows-build/);
  assert.match(source, /Build output already exists/);
  assert.match(source, /StagingDir/);
  assert.match(source, /Publish-NoClobber|publish-no-replace/);
  assert.doesNotMatch(source, /Move-Item[^\n]+\$StagingDir[^\n]+\$BuildDir/);
  assert.doesNotMatch(source, /TAURI_SIGNING_PRIVATE_KEY|latest-windows\.json|\.sig\b|SHA256SUMS/);
});

test("Windows build passes a temporary config file and protects tracked config", async () => {
  const source = await readFile(windowsScript, "utf8");
  assert.match(source, /ConfigPath/);
  assert.match(source, /createUpdaterArtifacts/);
  assert.match(source, /--config\s+\$ConfigPath/);
  assert.doesNotMatch(source, /\$BuildConfig\s*=\s*['\"]\{/);
  assert.match(source, /TauriConfigHashBefore/);
  assert.match(source, /Tracked tauri config changed/);
  assert.match(source, /Remove-Item[^\n]+\$ConfigPath/);
});

test("Windows build clears each NSIS output and accepts exactly one fresh versioned installer", async () => {
  const source = await readFile(windowsScript, "utf8");
  assert.match(source, /Remove-Item[^\n]+\$BundleDir/);
  assert.match(source, /Installers\.Count\s+-ne\s+1/);
  assert.match(source, /BuildStartedAt/);
  assert.match(source, /LastWriteTimeUtc/);
  assert.match(source, /Regex.*Version|\[regex\].*Version/i);
  assert.match(source, /InstallerPattern/);
  assert.match(source, /\^Codex Token Bar_/);
  assert.match(source, /setup\\\.exe\$/);
  assert.match(source, /\[regex\]::Escape\(\$Label\)/);
});

test("Windows installer version matching is anchored and rejects a superstring version", async () => {
  const source = await readFile(windowsScript, "utf8");
  assert.doesNotMatch("Codex Token Bar_10.7.20_x64-setup.exe", /^Codex Token Bar_0\.7\.2_(x64|arm64)-setup\.exe$/);
  assert.doesNotMatch("Codex Token Bar_0.7.2_arm64-setup.exe", /^Codex Token Bar_0\.7\.2_x64-setup\.exe$/);
  assert.match(source, /\[regex\]::Escape\(\$Version\)/);
});

test("Windows build manifest remains stable and secret-free", async () => {
  const source = await readFile(windowsScript, "utf8");
  assert.match(source, /build-manifest\.json/);
  for (const field of ["version", "platform", "arch", "filename", "bytes", "sha256"]) {
    assert.match(source, new RegExp(`\\b${field}\\b`, "i"));
  }
  assert.match(source, /Sort-Object Platform/);
});

test("PowerShell self-test captures config argv, stale output cleanup, and rerun immutability", async () => {
  const source = await readFile(windowsSelfTest, "utf8");
  assert.match(source, /ReleaseSelfTestCalls/);
  assert.match(source, /--config/);
  assert.match(source, /stale-0\.6\.0-setup\.exe/);
  assert.match(source, /Build output already exists/);
  assert.match(source, /existing windows-build changed byte-for-byte/);
  assert.match(source, /arm64.*fail|FailArm64/i);
  assert.match(source, /manifest.*fail|FailManifest/i);
  assert.match(source, /publish.*conflict|FinalConflict/i);
});

const pwsh = ["pwsh", "powershell"].find(command => {
  try {
    execFileSync(command, ["-NoProfile", "-Command", "$PSVersionTable.PSVersion.ToString()"], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
});

test("PowerShell fixture captures npm argv and preserves an existing build set", { skip: pwsh ? false : "pwsh/powershell unavailable on this Mac" }, () => {
  const result = spawnSync(pwsh, ["-NoProfile", "-File", windowsSelfTest], { encoding: "utf8" });
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  assert.match(result.stdout, /PASS: Windows release build self-test/);
});
