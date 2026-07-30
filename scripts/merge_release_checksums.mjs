#!/usr/bin/env node
// 统一 SHA256SUMS 合并器（发布资产完整性门禁）。
//
// 决策（decisions.md 2026-07-21）：GitHub Release 固定九项资产，第九项
// 统一 SHA256SUMS 覆盖前八项、不自包含：
//   mac DMG、版本 zip、兼容 zip、
//   Windows x64/ARM64 安装器及各自 .sig、latest-windows.json。
// mac / Windows 构建各自产出中间清单（SHA256SUMS-vX-macos.txt /
// SHA256SUMS-vX-windows.txt）；本脚本把两份中间清单按决策顺序合并成
// 统一 8 行清单，并对账集合与磁盘上的真实文件：
//   ① 两份中间清单的资产集合必须与期望完全一致（缺失/多余/重复都失败）；
//   ② 八项资产必须都在 release 目录里、是常规文件，重新哈希后与清单一致；
//   ③ 非 Release 资产（build-manifest.json、appcast.xml）不得进入统一清单；
//   ④ 已存在的统一清单视为不可变发布历史：内容一致幂等通过，不一致报错。
import { createHash, randomUUID } from "node:crypto";
import {
  closeSync,
  createReadStream,
  fsyncSync,
  linkSync,
  lstatSync,
  openSync,
  readFileSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import { pipeline } from "node:stream/promises";
import { fileURLToPath } from "node:url";

const USAGE = "Usage: merge_release_checksums.mjs --version VERSION --release-dir DIR";
const VERSION_PATTERN = /^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$/;
const CHECKSUM_LINE_PATTERN = /^([a-f0-9]{64})  ([^\s/\\]+)$/;
// Windows 中间清单必须列出但不属于九项 Release 资产的条目。
const WINDOWS_INTERMEDIATE_ONLY_NAMES = ["build-manifest.json"];

function fail(message) {
  throw new Error(message);
}

export function macChecksumName(version) {
  return `SHA256SUMS-v${version}-macos.txt`;
}

export function windowsChecksumName(version) {
  return `SHA256SUMS-v${version}-windows.txt`;
}

export function unifiedChecksumName(version) {
  return `SHA256SUMS-v${version}.txt`;
}

export function expectedMacAssetNames(version, archLabel) {
  return [
    `CodexTokenBar-v${version}-macos-${archLabel}.dmg`,
    `CodexTokenBar-v${version}-macos-${archLabel}.app.zip`,
    "CodexTokenBar.app.zip",
  ];
}

export function expectedWindowsReleaseAssetNames(version) {
  return [
    `CodexTokenBar-v${version}-windows-x64-setup.exe`,
    `CodexTokenBar-v${version}-windows-x64-setup.exe.sig`,
    `CodexTokenBar-v${version}-windows-arm64-setup.exe`,
    `CodexTokenBar-v${version}-windows-arm64-setup.exe.sig`,
    "latest-windows.json",
  ];
}

export function parseChecksumManifest(text, label) {
  if (typeof text !== "string" || text.length === 0) fail(`${label} is empty`);
  const body = text.endsWith("\n") ? text.slice(0, -1) : text;
  const entries = new Map();
  for (const line of body.split("\n")) {
    const match = CHECKSUM_LINE_PATTERN.exec(line);
    if (!match) fail(`${label} contains an unparsable checksum line: ${JSON.stringify(line)}`);
    const [, digest, name] = match;
    if (entries.has(name)) fail(`${label} lists a duplicate asset: ${name}`);
    entries.set(name, digest);
  }
  return entries;
}

function inferMacArchLabel(macEntries, version) {
  const prefix = `CodexTokenBar-v${version}-macos-`;
  const suffix = ".dmg";
  const dmgNames = [...macEntries.keys()].filter(
    (name) => name.startsWith(prefix) && name.endsWith(suffix),
  );
  if (dmgNames.length !== 1) {
    fail(`macOS checksum manifest must list exactly one ${prefix}<arch>${suffix} (found ${dmgNames.length})`);
  }
  const archLabel = dmgNames[0].slice(prefix.length, -suffix.length);
  if (!/^[a-z0-9_]+$/.test(archLabel)) fail(`Unexpected macOS arch label: ${JSON.stringify(archLabel)}`);
  return archLabel;
}

function assertNameSet(entries, expectedNames, label) {
  const actual = [...entries.keys()].sort();
  const expected = [...expectedNames].sort();
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    fail(
      `${label} asset set mismatch.\n  expected: ${expected.join(", ")}\n  actual:   ${actual.join(", ")}`,
    );
  }
}

// 纯函数：由两份中间清单文本产出统一清单的 8 行内容（决策顺序：
// DMG、版本 zip、兼容 zip、x64 安装器、x64 .sig、arm64 安装器、
// arm64 .sig、latest-windows.json）。
export function buildUnifiedChecksums({ version, macText, windowsText }) {
  if (!VERSION_PATTERN.test(version)) fail(`Invalid version: ${JSON.stringify(version)}`);
  const macEntries = parseChecksumManifest(macText, "macOS checksum manifest");
  const windowsEntries = parseChecksumManifest(windowsText, "Windows checksum manifest");
  const archLabel = inferMacArchLabel(macEntries, version);
  assertNameSet(macEntries, expectedMacAssetNames(version, archLabel), "macOS checksum manifest");
  assertNameSet(
    windowsEntries,
    [...expectedWindowsReleaseAssetNames(version), ...WINDOWS_INTERMEDIATE_ONLY_NAMES],
    "Windows checksum manifest",
  );
  const assetNames = [
    ...expectedMacAssetNames(version, archLabel),
    ...expectedWindowsReleaseAssetNames(version),
  ];
  const lines = assetNames.map((name) => {
    const digest = macEntries.get(name) ?? windowsEntries.get(name);
    return `${digest}  ${name}`;
  });
  return { archLabel, assetNames, lines };
}

async function sha256File(file) {
  const hash = createHash("sha256");
  await pipeline(createReadStream(file), hash);
  return hash.digest("hex");
}

function assertRegularFile(file, label) {
  let info;
  try {
    info = lstatSync(file);
  } catch {
    fail(`${label} not found: ${file}`);
  }
  if (info.isSymbolicLink() || !info.isFile()) fail(`${label} must be a regular file: ${file}`);
}

function fsyncParentDirectory(file) {
  if (process.platform === "win32") return;
  const descriptor = openSync(path.dirname(file), "r");
  try {
    fsyncSync(descriptor);
  } finally {
    closeSync(descriptor);
  }
}

export function publishImmutableFile(output, content) {
  const tmp = `${output}.tmp-${process.pid}-${randomUUID()}`;
  let temporaryExists = false;
  try {
    // Keep the exclusive-create descriptor through the write and durability
    // barrier. Windows FlushFileBuffers needs write access, while reopening
    // with r+ would fail on POSIX when a strict umask creates mode 0444.
    const descriptor = openSync(tmp, "wx+", 0o644);
    temporaryExists = true;
    try {
      writeFileSync(descriptor, content, { encoding: "utf8" });
      fsyncSync(descriptor);
    } finally {
      closeSync(descriptor);
    }
    try {
      // A same-directory hard link is an atomic no-replace publication:
      // EEXIST can never overwrite a manifest created after our earlier reads.
      linkSync(tmp, output);
      fsyncParentDirectory(output);
      return "written";
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
      assertRegularFile(output, "Existing unified checksum manifest");
      const existing = readFileSync(output, "utf8");
      if (existing === content) return "unchanged";
      fail(
        `Refusing to overwrite existing unified checksum manifest with different content: ${output}\n` +
          "Published checksum manifests are immutable history; delete the file manually if regenerating is intentional.",
      );
    }
  } finally {
    if (temporaryExists) {
      try {
        unlinkSync(tmp);
      } catch (error) {
        if (error.code !== "ENOENT") throw error;
      }
    }
  }
}

async function main(argv) {
  let version = "";
  let releaseDir = "";
  const rest = [...argv];
  while (rest.length > 0) {
    const flag = rest.shift();
    if (flag === "--version") version = rest.shift() ?? "";
    else if (flag === "--release-dir") releaseDir = rest.shift() ?? "";
    else fail(`Unknown argument: ${flag}\n${USAGE}`);
  }
  if (version === "" || releaseDir === "") fail(USAGE);
  if (!VERSION_PATTERN.test(version)) fail(`Invalid version: ${JSON.stringify(version)}`);

  const macPath = path.join(releaseDir, macChecksumName(version));
  const windowsPath = path.join(releaseDir, windowsChecksumName(version));
  assertRegularFile(macPath, "macOS checksum manifest");
  assertRegularFile(windowsPath, "Windows checksum manifest");
  const unified = buildUnifiedChecksums({
    version,
    macText: readFileSync(macPath, "utf8"),
    windowsText: readFileSync(windowsPath, "utf8"),
  });

  // ② 对账磁盘：八项资产必须在场且哈希一致，抓拷贝损坏与漏拷；
  // build-manifest.json 只是 Windows 中间产物，不要求出现在 release 目录。
  for (const line of unified.lines) {
    const digest = line.slice(0, 64);
    const name = line.slice(66);
    const file = path.join(releaseDir, name);
    assertRegularFile(file, `Release asset ${name}`);
    const actual = await sha256File(file);
    if (actual !== digest) {
      fail(`Checksum mismatch for ${name}: manifest says ${digest}, file on disk is ${actual}`);
    }
  }

  const output = path.join(releaseDir, unifiedChecksumName(version));
  const content = `${unified.lines.join("\n")}\n`;
  const publication = publishImmutableFile(output, content);
  if (publication === "unchanged") {
    process.stdout.write(`Unified checksum manifest already up to date: ${output}\n`);
  } else {
    process.stdout.write(
      `Unified checksum manifest written: ${output} (${unified.lines.length} assets, macOS arch ${unified.archLabel})\n`,
    );
  }
}

const invokedDirectly =
  process.argv[1] !== undefined && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (invokedDirectly) {
  main(process.argv.slice(2)).catch((error) => {
    process.stderr.write(`merge_release_checksums: ${error.message}\n`);
    process.exitCode = 1;
  });
}
