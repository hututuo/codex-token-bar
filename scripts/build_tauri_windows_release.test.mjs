import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const scriptsDir = path.dirname(fileURLToPath(import.meta.url));
const windowsScript = path.join(scriptsDir, "build_tauri_windows_release.ps1");

test("Windows build disables updater artifacts without reading a signing key", async () => {
  const source = await readFile(windowsScript, "utf8");
  assert.match(source, /--config/);
  assert.match(source, /createUpdaterArtifacts[\\\"]*\s*:\s*false/);
  assert.doesNotMatch(source, /TAURI_SIGNING_PRIVATE_KEY|latest-windows\.json|\.sig\b/);
});

test("Windows build emits a stable secret-free build manifest", async () => {
  const source = await readFile(windowsScript, "utf8");
  assert.match(source, /build-manifest\.json/);
  for (const field of ["version", "platform", "filename", "bytes", "sha256"]) {
    assert.match(source, new RegExp(`\\b${field}\\b`, "i"));
  }
  assert.match(source, /Sort-Object Platform/);
});
