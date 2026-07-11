import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { access, mkdir, mkdtemp, readFile, readdir, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const scriptsDir = path.dirname(fileURLToPath(import.meta.url));
const macScript = path.join(scriptsDir, "sign_tauri_windows_release.sh");
const version = "0.7.2";
const installerNames = [
  `CodexTokenBar-v${version}-windows-arm64-setup.exe`,
  `CodexTokenBar-v${version}-windows-x64-setup.exe`,
];

function sha256(data) {
  return createHash("sha256").update(data).digest("hex");
}

async function snapshotDirectory(directory) {
  const snapshot = {};
  for (const name of (await readdir(directory)).sort()) {
    snapshot[name] = await readFile(path.join(directory, name));
  }
  return snapshot;
}

async function makeFixture(options = {}) {
  const root = await mkdtemp(path.join(os.tmpdir(), "token-bar-release-"));
  const buildDir = path.join(root, "windows-build");
  const releaseDir = path.join(root, "windows");
  await mkdir(buildDir);
  const assets = [
    ["windows-x86_64", "x64", installerNames[1], "fixture-x64"],
    ["windows-aarch64", "arm64", installerNames[0], "fixture-arm64"],
  ];
  const manifestAssets = [];
  for (const [platform, arch, filename, content] of assets) {
    const file = path.join(buildDir, filename);
    await writeFile(file, content);
    manifestAssets.push({
      version,
      platform,
      arch,
      filename,
      bytes: (await stat(file)).size,
      sha256: sha256(content),
    });
  }
  if (options.badHash) manifestAssets[0].sha256 = "0".repeat(64);
  if (options.missingArch) manifestAssets.pop();
  await writeFile(
    path.join(buildDir, "build-manifest.json"),
    `${JSON.stringify({ version, assets: manifestAssets }, null, 2)}\n`,
  );
  if (options.missingFile) {
    const { rm } = await import("node:fs/promises");
    await rm(path.join(buildDir, assets[0][2]));
  }

  const key = path.join(root, "test.key");
  await writeFile(key, "TEST_PRIVATE_KEY_DO_NOT_LEAK");
  const signerProgram = path.join(root, "stub-signer.mjs");
  await writeFile(signerProgram, `
import { createHash } from "node:crypto";
import { writeFileSync } from "node:fs";
import path from "node:path";
const file = process.argv.at(-1);
if (${Boolean(options.failSign)} && file.includes("arm64")) process.exit(42);
const name = path.basename(file);
const seed = createHash("sha256").update(name).digest();
const fileSignature = Buffer.alloc(74);
fileSignature.write("Ed", 0, "ascii");
for (let i = 2; i < fileSignature.length; i += 1) fileSignature[i] = seed[i % seed.length];
const trustedSignature = Buffer.alloc(64);
for (let i = 0; i < trustedSignature.length; i += 1) trustedSignature[i] = seed[(i + 7) % seed.length];
const minisign = [
  "untrusted comment: signature from tauri secret key",
  fileSignature.toString("base64"),
  "trusted comment: timestamp:1700000000\\tfile:" + name,
  trustedSignature.toString("base64"),
].join("\\n") + "\\n";
let envelope = Buffer.from(minisign, "utf8").toString("base64");
if (${Boolean(options.corruptSignature)}) {
  const encoded = Buffer.from(envelope, "ascii");
  encoded[0] ^= 1;
  envelope = encoded.toString("ascii");
}
writeFileSync(file + ".sig", envelope);
`);
  const signer = path.join(root, "stub-signer.sh");
  await writeFile(signer, `#!/bin/sh\nexec '${process.execPath}' '${signerProgram}' "$@"\n`, { mode: 0o755 });

  const binDir = path.join(root, "bin");
  await mkdir(binDir);
  await writeFile(
    path.join(binDir, "file"),
    `#!/bin/sh\ncase "$2" in *arm64*) echo '${options.badArch ? "PE32+ executable x86-64" : "PE32+ executable Aarch64"}';; *) echo 'PE32+ executable x86-64';; esac\n`,
    { mode: 0o755 },
  );
  if (options.failMetadata || options.failChecksum) {
    await writeFile(
      path.join(binDir, "node"),
      `#!/bin/sh\nif [ "$2" = '${options.failMetadata ? "write-metadata" : "write-checksums"}' ]; then exit 43; fi\nexec '${process.execPath}' "$@"\n`,
      { mode: 0o755 },
    );
  }
  if (options.outputExists) {
    await mkdir(releaseDir);
    for (const name of [
      ...installerNames,
      ...installerNames.map(filename => `${filename}.sig`),
      `SHA256SUMS-v${version}-windows.txt`,
      "build-manifest.json",
      "latest-windows.json",
    ]) {
      await writeFile(path.join(releaseDir, name), `OLD_BYTES:${name}`);
    }
  }
  return { root, buildDir, releaseDir, key, signer, binDir };
}

async function runSignerFixture(options = {}) {
  const fixture = await makeFixture(options);
  const buildSnapshot = await snapshotDirectory(fixture.buildDir);
  const outputSnapshot = options.outputExists ? await snapshotDirectory(fixture.releaseDir) : null;
  const env = {
    ...process.env,
    PATH: `${fixture.binDir}:${process.env.PATH}`,
    SOURCE_DATE_EPOCH: "1700000000",
  };
  try {
    const result = await execFileAsync("bash", [
      macScript,
      "--version", version,
      "--repo", "hututuo/codex-token-bar",
      "--build-dir", fixture.buildDir,
      "--release-dir", fixture.releaseDir,
      "--key-path", fixture.key,
      "--signer", fixture.signer,
    ], { env });
    return { ...fixture, ...result, ok: true, buildSnapshot, outputSnapshot };
  } catch (error) {
    return { ...fixture, ...error, ok: false, buildSnapshot, outputSnapshot };
  }
}

test("Mac signing atomically publishes the complete seven-file release directory", async () => {
  const result = await runSignerFixture();
  assert.equal(result.ok, true, result.stderr);
  assert.deepEqual(await snapshotDirectory(result.buildDir), result.buildSnapshot);
  const names = (await readdir(result.releaseDir)).sort();
  const checksumName = `SHA256SUMS-v${version}-windows.txt`;
  assert.deepEqual(names, [
    ...installerNames,
    ...installerNames.map(name => `${name}.sig`),
    checksumName,
    "build-manifest.json",
    "latest-windows.json",
  ].sort());

  const latest = JSON.parse(await readFile(path.join(result.releaseDir, "latest-windows.json"), "utf8"));
  assert.deepEqual(Object.keys(latest.platforms), ["windows-aarch64", "windows-x86_64"]);
  for (const [platform, entry] of Object.entries(latest.platforms)) {
    const arch = platform === "windows-aarch64" ? "arm64" : "x64";
    assert.match(entry.url, new RegExp(`/CodexTokenBar-v0\\.7\\.2-windows-${arch}-setup\\.exe$`));
    assert.match(entry.signature, /^[A-Za-z0-9+/]+={0,2}$/);
  }

  const lines = (await readFile(path.join(result.releaseDir, checksumName), "utf8")).trim().split("\n");
  assert.equal(lines.length, 6);
  const checksumFiles = lines.map(line => line.split("  ")[1]);
  assert.deepEqual(checksumFiles, [...checksumFiles].sort());
  assert.deepEqual(checksumFiles, names.filter(name => name !== checksumName));
  for (const line of lines) {
    const [expected, filename] = line.split("  ");
    assert.equal(sha256(await readFile(path.join(result.releaseDir, filename))), expected);
  }

  const published = await Promise.all(names.map(name => readFile(path.join(result.releaseDir, name), "utf8")));
  assert.doesNotMatch(published.join("") + result.stdout + result.stderr, /TEST_PRIVATE_KEY_DO_NOT_LEAK/);
});

test("Mac signing refuses an existing output directory byte-for-byte", async () => {
  const result = await runSignerFixture({ outputExists: true });
  assert.equal(result.ok, false);
  assert.match(result.stderr, /Release output already exists/);
  assert.deepEqual(await snapshotDirectory(result.releaseDir), result.outputSnapshot);
  assert.deepEqual(await snapshotDirectory(result.buildDir), result.buildSnapshot);
});

for (const [name, options, expectedError] of [
  ["missing installer", { missingFile: true }, /Installer not found/],
  ["hash mismatch", { badHash: true }, /SHA-256 mismatch/],
  ["missing architecture", { missingArch: true }, /exactly x64 and arm64/],
  ["PE architecture mismatch", { badArch: true }, /PE architecture mismatch/],
  ["signer failure", { failSign: true }, /Signer failed/],
  ["single-byte signature corruption", { corruptSignature: true }, /Invalid Tauri signature envelope/],
  ["metadata generation failure", { failMetadata: true }, /Metadata generation failed/],
  ["checksum generation failure", { failChecksum: true }, /Checksum generation failed/],
]) {
  test(`Mac signing rejects ${name} without creating the output directory`, async () => {
    const result = await runSignerFixture(options);
    assert.equal(result.ok, false);
    assert.match(result.stderr, expectedError);
    await assert.rejects(access(result.releaseDir), { code: "ENOENT" });
    assert.equal((await readdir(result.root)).some(name => name.includes(".windows.staging.")), false);
    assert.deepEqual(await snapshotDirectory(result.buildDir), result.buildSnapshot);
  });
}
