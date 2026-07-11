import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, readFile, writeFile, mkdir, readdir, stat } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const scriptsDir = path.dirname(fileURLToPath(import.meta.url));
const macScript = path.join(scriptsDir, "sign_tauri_windows_release.sh");

async function makeFixture(options = {}) {
  const root = await mkdtemp(path.join(os.tmpdir(), "token-bar-release-"));
  const releaseDir = path.join(root, "release");
  await mkdir(releaseDir);
  const assets = [
    ["windows-x86_64", "x64", "CodexTokenBar-v0.7.2-windows-x64-setup.exe", "fixture-x64"],
    ["windows-aarch64", "arm64", "CodexTokenBar-v0.7.2-windows-arm64-setup.exe", "fixture-arm64"],
  ];
  const manifestAssets = [];
  for (const [platform, arch, filename, content] of assets) {
    const file = path.join(releaseDir, filename);
    await writeFile(file, content);
    const { stdout: sha256 } = await execFileAsync("shasum", ["-a", "256", file]);
    manifestAssets.push({
      version: "0.7.2",
      platform,
      arch,
      filename,
      bytes: (await stat(file)).size,
      sha256: sha256.split(/\s+/)[0],
    });
  }
  if (options.badHash) manifestAssets[0].sha256 = "0".repeat(64);
  if (options.missingArch) manifestAssets.pop();
  await writeFile(
    path.join(releaseDir, "build-manifest.json"),
    `${JSON.stringify({ version: "0.7.2", assets: manifestAssets }, null, 2)}\n`,
  );
  if (options.missingFile) {
    await execFileAsync("rm", [path.join(releaseDir, assets[0][2])]);
  }

  const key = path.join(root, "test.key");
  await writeFile(key, "TEST_PRIVATE_KEY_DO_NOT_LEAK");
  const signer = path.join(root, "stub-signer.sh");
  await writeFile(
    signer,
    `#!/bin/sh\nset -eu\nfile=""\nfor arg in "$@"; do file="$arg"; done\ncase "$file" in *arm64*) ${options.failSign ? "exit 42" : ":"};; esac\nprintf 'stub-signature:%s\\n' "$(basename "$file")" > "$file.sig"\n`,
    { mode: 0o755 },
  );
  const binDir = path.join(root, "bin");
  await mkdir(binDir);
  const fileCommand = path.join(binDir, "file");
  await writeFile(
    fileCommand,
    `#!/bin/sh\ncase "$2" in *arm64*) echo '${options.badArch ? "PE32+ executable x86-64" : "PE32+ executable Aarch64"}';; *) echo 'PE32+ executable x86-64';; esac\n`,
    { mode: 0o755 },
  );
  return { root, releaseDir, key, signer, binDir };
}

async function runSignerFixture(options = {}) {
  const fixture = await makeFixture(options);
  try {
    const result = await execFileAsync("bash", [
      macScript,
      "--version", "0.7.2",
      "--repo", "hututuo/codex-token-bar",
      "--release-dir", fixture.releaseDir,
      "--key-path", fixture.key,
      "--signer", fixture.signer,
    ], { env: { ...process.env, PATH: `${fixture.binDir}:${process.env.PATH}` } });
    return { ...fixture, ...result, ok: true };
  } catch (error) {
    return { ...fixture, ...error, ok: false };
  }
}

test("Mac signing publishes complete metadata for both Windows platforms", async () => {
  const result = await runSignerFixture();
  assert.equal(result.ok, true, result.stderr);
  const latest = JSON.parse(await readFile(path.join(result.releaseDir, "latest-windows.json"), "utf8"));
  assert.deepEqual(Object.keys(latest.platforms), ["windows-aarch64", "windows-x86_64"]);
  for (const [platform, entry] of Object.entries(latest.platforms)) {
    assert.match(entry.url, new RegExp(`^https://github.com/hututuo/codex-token-bar/releases/download/v0\\.7\\.2/.+${platform === "windows-aarch64" ? "arm64" : "x64"}.+\\.exe$`));
    assert.match(entry.signature, /^stub-signature:/);
  }
  const sums = await readFile(path.join(result.releaseDir, "SHA256SUMS-v0.7.2-windows.txt"), "utf8");
  const lines = sums.trim().split("\n");
  assert.deepEqual(lines, [...lines].sort((a, b) => a.split("  ")[1].localeCompare(b.split("  ")[1])));
  assert.equal(lines.length, 4);
  const published = await Promise.all((await readdir(result.releaseDir)).map(name => readFile(path.join(result.releaseDir, name), "utf8")));
  assert.doesNotMatch(published.join("") + result.stdout + result.stderr, /TEST_PRIVATE_KEY_DO_NOT_LEAK/);
});

for (const [name, options] of [
  ["missing installer", { missingFile: true }],
  ["hash mismatch", { badHash: true }],
  ["missing architecture", { missingArch: true }],
  ["PE architecture mismatch", { badArch: true }],
  ["signer failure", { failSign: true }],
]) {
  test(`Mac signing rejects ${name} without partial metadata`, async () => {
    const result = await runSignerFixture(options);
    assert.equal(result.ok, false);
    for (const filename of ["latest-windows.json", "SHA256SUMS-v0.7.2-windows.txt"]) {
      await assert.rejects(readFile(path.join(result.releaseDir, filename), "utf8"), { code: "ENOENT" });
    }
    assert.equal((await readdir(result.releaseDir)).some(filename => filename.endsWith(".sig")), false);
  });
}
