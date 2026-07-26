import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtemp, readFile, rm, symlink, unlink, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import {
  buildUnifiedChecksums,
  expectedMacAssetNames,
  expectedWindowsReleaseAssetNames,
  macChecksumName,
  parseChecksumManifest,
  unifiedChecksumName,
  windowsChecksumName,
} from "./merge_release_checksums.mjs";

const execFileAsync = promisify(execFile);
const mergeScript = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  "merge_release_checksums.mjs",
);
const version = "0.9.0";

function sha256(data) {
  return createHash("sha256").update(data).digest("hex");
}

// 纯函数测试用的占位摘要：内容无关，只要形状合法。
function fakeDigest(seed) {
  return sha256(`digest:${seed}`);
}

function manifestText(entries) {
  return `${entries.map(([digest, name]) => `${digest}  ${name}`).join("\n")}\n`;
}

function macManifest(archLabel = "arm64", overrides = {}) {
  const entries = expectedMacAssetNames(version, archLabel).map((name) => [fakeDigest(name), name]);
  return manifestText(applyOverrides(entries, overrides));
}

function windowsManifest(overrides = {}) {
  const names = [...expectedWindowsReleaseAssetNames(version), "build-manifest.json"];
  const entries = names.map((name) => [fakeDigest(name), name]);
  return manifestText(applyOverrides(entries, overrides));
}

function applyOverrides(entries, { drop = [], add = [] }) {
  return [...entries.filter(([, name]) => !drop.includes(name)), ...add];
}

test("buildUnifiedChecksums emits the eight decision-ordered release assets", () => {
  const unified = buildUnifiedChecksums({
    version,
    macText: macManifest(),
    windowsText: windowsManifest(),
  });

  assert.equal(unified.archLabel, "arm64");
  assert.deepEqual(unified.assetNames, [
    `CodexTokenBar-v${version}-macos-arm64.dmg`,
    `CodexTokenBar-v${version}-macos-arm64.app.zip`,
    "CodexTokenBar.app.zip",
    `CodexTokenBar-v${version}-windows-x64-setup.exe`,
    `CodexTokenBar-v${version}-windows-x64-setup.exe.sig`,
    `CodexTokenBar-v${version}-windows-arm64-setup.exe`,
    `CodexTokenBar-v${version}-windows-arm64-setup.exe.sig`,
    "latest-windows.json",
  ]);
  assert.equal(unified.lines.length, 8);
  assert.deepEqual(unified.lines, unified.assetNames.map((name) => `${fakeDigest(name)}  ${name}`));
  assert.ok(!unified.lines.some((line) => line.includes("build-manifest.json")));
  assert.ok(!unified.lines.some((line) => line.includes("appcast.xml")));
});

test("buildUnifiedChecksums accepts an x86_64 macOS build", () => {
  const unified = buildUnifiedChecksums({
    version,
    macText: macManifest("x86_64"),
    windowsText: windowsManifest(),
  });
  assert.equal(unified.archLabel, "x86_64");
  assert.equal(unified.lines.length, 8);
  assert.match(unified.lines[0], /CodexTokenBar-v0\.9\.0-macos-x86_64\.dmg$/);
});

test("buildUnifiedChecksums rejects the legacy four-line mac manifest containing appcast.xml", () => {
  const legacy = macManifest("arm64", { add: [[fakeDigest("appcast"), "appcast.xml"]] });
  assert.throws(
    () => buildUnifiedChecksums({ version, macText: legacy, windowsText: windowsManifest() }),
    /macOS checksum manifest asset set mismatch/,
  );
});

test("buildUnifiedChecksums rejects manifests with missing or extra assets", () => {
  assert.throws(
    () =>
      buildUnifiedChecksums({
        version,
        macText: macManifest("arm64", { drop: ["CodexTokenBar.app.zip"] }),
        windowsText: windowsManifest(),
      }),
    /macOS checksum manifest asset set mismatch/,
  );
  assert.throws(
    () =>
      buildUnifiedChecksums({
        version,
        macText: macManifest(),
        windowsText: windowsManifest({
          drop: [`CodexTokenBar-v${version}-windows-arm64-setup.exe.sig`],
        }),
      }),
    /Windows checksum manifest asset set mismatch/,
  );
  assert.throws(
    () =>
      buildUnifiedChecksums({
        version,
        macText: macManifest(),
        windowsText: windowsManifest({ add: [[fakeDigest("extra"), "debug-symbols.zip"]] }),
      }),
    /Windows checksum manifest asset set mismatch/,
  );
});

test("buildUnifiedChecksums rejects a mac manifest whose assets belong to another version", () => {
  const otherVersion = "0.8.0";
  const otherEntries = expectedMacAssetNames(otherVersion, "arm64").map((name) => [
    fakeDigest(name),
    name,
  ]);
  assert.throws(
    () =>
      buildUnifiedChecksums({
        version,
        macText: manifestText(otherEntries),
        windowsText: windowsManifest(),
      }),
    /must list exactly one CodexTokenBar-v0\.9\.0-macos-<arch>\.dmg/,
  );
});

test("parseChecksumManifest rejects malformed, duplicate, and path-escaping lines", () => {
  assert.throws(() => parseChecksumManifest("", "manifest"), /manifest is empty/);
  assert.throws(
    () => parseChecksumManifest(`${fakeDigest("a").toUpperCase()}  a.zip\n`, "manifest"),
    /unparsable checksum line/,
  );
  assert.throws(
    () => parseChecksumManifest(`${fakeDigest("a")} a.zip\n`, "manifest"),
    /unparsable checksum line/,
  );
  assert.throws(
    () => parseChecksumManifest(`${fakeDigest("a")}  ../escape.zip\n`, "manifest"),
    /unparsable checksum line/,
  );
  assert.throws(
    () =>
      parseChecksumManifest(
        `${fakeDigest("a")}  a.zip\n${fakeDigest("b")}  a.zip\n`,
        "manifest",
      ),
    /duplicate asset/,
  );
});

async function makeReleaseFixture() {
  const releaseDir = await mkdtemp(path.join(os.tmpdir(), "merge-sha256sums-"));
  const macNames = expectedMacAssetNames(version, "arm64");
  const windowsNames = expectedWindowsReleaseAssetNames(version);
  const contents = new Map();
  for (const name of [...macNames, ...windowsNames]) {
    const data = Buffer.from(`asset payload for ${name}`);
    contents.set(name, data);
    await writeFile(path.join(releaseDir, name), data);
  }
  const line = (name) => [sha256(contents.get(name)), name];
  await writeFile(
    path.join(releaseDir, macChecksumName(version)),
    manifestText(macNames.map(line)),
  );
  // Windows 中间清单包含 build-manifest.json（Windows 侧真实产物如此），
  // 但 release 目录里不需要该文件——统一清单不覆盖它。
  await writeFile(
    path.join(releaseDir, windowsChecksumName(version)),
    manifestText([...windowsNames.map(line), [fakeDigest("build-manifest"), "build-manifest.json"]]),
  );
  return { releaseDir };
}

async function runMerge(releaseDir) {
  return execFileAsync(process.execPath, [
    mergeScript,
    "--version",
    version,
    "--release-dir",
    releaseDir,
  ]);
}

async function assertMergeFails(releaseDir, pattern) {
  await assert.rejects(runMerge(releaseDir), (error) => {
    assert.equal(error.code, 1);
    assert.match(error.stderr, pattern);
    return true;
  });
}

test("CLI writes the unified eight-line manifest and is idempotent", async () => {
  const { releaseDir } = await makeReleaseFixture();
  try {
    const first = await runMerge(releaseDir);
    assert.match(first.stdout, /Unified checksum manifest written: .*SHA256SUMS-v0\.9\.0\.txt \(8 assets, macOS arch arm64\)/);

    const unifiedPath = path.join(releaseDir, unifiedChecksumName(version));
    const content = await readFile(unifiedPath, "utf8");
    const lines = content.trimEnd().split("\n");
    assert.equal(lines.length, 8);
    assert.match(lines[0], new RegExp(`^[a-f0-9]{64}  CodexTokenBar-v${version.replaceAll(".", "\\.")}-macos-arm64\\.dmg$`));
    assert.equal(lines.at(-1).endsWith("  latest-windows.json"), true);
    assert.ok(!content.includes("build-manifest.json"));
    assert.ok(!content.includes("appcast.xml"));

    const second = await runMerge(releaseDir);
    assert.match(second.stdout, /already up to date/);
  } finally {
    await rm(releaseDir, { recursive: true, force: true });
  }
});

test("CLI refuses to run when the Windows manifest is still pending", async () => {
  const { releaseDir } = await makeReleaseFixture();
  try {
    await unlink(path.join(releaseDir, windowsChecksumName(version)));
    await assertMergeFails(releaseDir, /Windows checksum manifest not found/);
  } finally {
    await rm(releaseDir, { recursive: true, force: true });
  }
});

test("CLI fails on a missing, tampered, or symlinked release asset", async () => {
  const { releaseDir } = await makeReleaseFixture();
  try {
    const targetName = `CodexTokenBar-v${version}-windows-x64-setup.exe`;
    const target = path.join(releaseDir, targetName);
    await writeFile(target, Buffer.from("tampered payload"));
    await assertMergeFails(releaseDir, /Checksum mismatch for CodexTokenBar-v0\.9\.0-windows-x64-setup\.exe/);
    await writeFile(target, Buffer.from(`asset payload for ${targetName}`));

    await unlink(path.join(releaseDir, "latest-windows.json"));
    await assertMergeFails(releaseDir, /Release asset latest-windows\.json not found/);

    await symlink(target, path.join(releaseDir, "latest-windows.json"));
    await assertMergeFails(releaseDir, /Release asset latest-windows\.json must be a regular file/);
  } finally {
    await rm(releaseDir, { recursive: true, force: true });
  }
});

test("CLI treats an existing different unified manifest as immutable history", async () => {
  const { releaseDir } = await makeReleaseFixture();
  try {
    await writeFile(
      path.join(releaseDir, unifiedChecksumName(version)),
      `${fakeDigest("stale")}  stale.zip\n`,
    );
    await assertMergeFails(releaseDir, /Refusing to overwrite existing unified checksum manifest/);
  } finally {
    await rm(releaseDir, { recursive: true, force: true });
  }
});

test("CLI validates its arguments", async () => {
  await assert.rejects(
    execFileAsync(process.execPath, [mergeScript, "--version", version]),
    (error) => {
      assert.equal(error.code, 1);
      assert.match(error.stderr, /Usage: merge_release_checksums\.mjs/);
      return true;
    },
  );
  await assert.rejects(
    execFileAsync(process.execPath, [mergeScript, "--version", "v0.9", "--release-dir", os.tmpdir()]),
    (error) => {
      assert.equal(error.code, 1);
      assert.match(error.stderr, /Invalid version/);
      return true;
    },
  );
});
