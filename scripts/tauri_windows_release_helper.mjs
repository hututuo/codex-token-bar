#!/usr/bin/env node
import { createHash } from "node:crypto";
import { lstatSync, mkdirSync, readFileSync, readdirSync, renameSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";

function fail(message) {
  throw new Error(message);
}

function hashFile(file) {
  return createHash("sha256").update(readFileSync(file)).digest("hex");
}

function readJson(file) {
  return JSON.parse(readFileSync(file, "utf8"));
}

function canonicalBase64(value, label) {
  if (typeof value !== "string" || value.length === 0 || value.length % 4 !== 0 ||
      !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)) {
    fail(`Invalid ${label} base64`);
  }
  const decoded = Buffer.from(value, "base64");
  if (decoded.toString("base64") !== value) fail(`Non-canonical ${label} base64`);
  return decoded;
}

function validateSignatureEnvelope(envelope, filename) {
  try {
    if (envelope.length < 200 || envelope.length > 2048) fail("envelope length");
    const decoded = canonicalBase64(envelope, "signature envelope");
    if (decoded.length < 180 || decoded.length > 1536) fail("decoded envelope length");
    const text = decoded.toString("utf8");
    if (!Buffer.from(text, "utf8").equals(decoded)) fail("envelope UTF-8");
    const lines = text.endsWith("\n") ? text.slice(0, -1).split("\n") : text.split("\n");
    if (lines.length !== 4) fail("minisign line count");
    if (lines[0] !== "untrusted comment: signature from tauri secret key") fail("untrusted comment");
    const fileSignature = canonicalBase64(lines[1], "minisign file signature");
    if (fileSignature.length !== 74 || fileSignature.subarray(0, 2).toString("ascii") !== "Ed") fail("file signature shape");
    const trustedPrefix = "trusted comment: timestamp:";
    const trustedSuffix = `\tfile:${filename}`;
    if (!lines[2].startsWith(trustedPrefix) || !lines[2].endsWith(trustedSuffix)) fail("trusted comment");
    const timestamp = lines[2].slice(trustedPrefix.length, -trustedSuffix.length);
    if (!/^[0-9]{1,20}$/.test(timestamp)) fail("trusted timestamp");
    if (canonicalBase64(lines[3], "minisign trusted signature").length !== 64) fail("trusted signature shape");
  } catch (error) {
    fail(`Invalid Tauri signature envelope for ${filename}: ${error.message}`);
  }
}

function loadAssets(assetList) {
  const assets = readJson(assetList);
  if (!Array.isArray(assets) || assets.length !== 2) fail("Asset list is invalid");
  return assets;
}

function assertRegularFile(file, label) {
  let info;
  try { info = lstatSync(file); } catch { fail(`${label} not found`); }
  if (info.isSymbolicLink() || !info.isFile()) fail(`${label} must be a regular file, not a symbolic link`);
  return info;
}

function assertExactDirectory(directory, expectedNames, label) {
  const actual = readdirSync(directory).sort();
  const expected = [...expectedNames].sort();
  if (JSON.stringify(actual) !== JSON.stringify(expected)) fail(`${label} must contain exactly two installers and build-manifest.json`);
  for (const name of actual) assertRegularFile(path.join(directory, name), `${label} entry ${name}`);
}

function validateBuild([manifestPath, buildDir, version, assetList]) {
  assertRegularFile(manifestPath, "Build manifest");
  const manifest = readJson(manifestPath);
  if (manifest.version !== version || !Array.isArray(manifest.assets)) fail("Build manifest version or assets are invalid");
  const expected = new Map([
    ["windows-aarch64", { arch: "arm64", filename: `CodexTokenBar-v${version}-windows-arm64-setup.exe` }],
    ["windows-x86_64", { arch: "x64", filename: `CodexTokenBar-v${version}-windows-x64-setup.exe` }],
  ]);
  if (manifest.assets.length !== expected.size) fail("Build manifest must contain exactly x64 and arm64 installers");
  const assets = [];
  const expectedNames = ["build-manifest.json"];
  for (const asset of [...manifest.assets].sort((a, b) => a.platform.localeCompare(b.platform))) {
    const wanted = expected.get(asset.platform);
    if (!wanted || asset.version !== version || asset.arch !== wanted.arch || asset.filename !== wanted.filename ||
        path.basename(asset.filename) !== asset.filename || !Number.isSafeInteger(asset.bytes) || asset.bytes <= 0 ||
        !/^[a-f0-9]{64}$/.test(asset.sha256)) {
      fail(`Unexpected manifest asset: ${asset.platform || "unknown"}`);
    }
    expected.delete(asset.platform);
    const file = path.join(buildDir, asset.filename);
    const info = assertRegularFile(file, `Installer ${asset.filename}`);
    if (info.size !== asset.bytes) fail(`Size mismatch: ${asset.filename}`);
    if (hashFile(file) !== asset.sha256) fail(`SHA-256 mismatch: ${asset.filename}`);
    assets.push(asset);
    expectedNames.push(asset.filename);
  }
  if (expected.size) fail("Build manifest must contain exactly x64 and arm64 installers");
  assertExactDirectory(buildDir, expectedNames, "Unsigned build directory");
  writeFileSync(assetList, `${JSON.stringify(assets, null, 2)}\n`);
}

function validateStagedBuild([assetList, staging, version]) {
  const assets = loadAssets(assetList);
  const stagedManifest = readJson(path.join(staging, "build-manifest.json"));
  const stagedAssets = Array.isArray(stagedManifest.assets)
    ? [...stagedManifest.assets].sort((a, b) => a.platform.localeCompare(b.platform))
    : null;
  if (stagedManifest.version !== version || JSON.stringify(stagedAssets) !== JSON.stringify(assets)) {
    fail("Staged build manifest does not match the validated manifest");
  }
  const expectedNames = [path.basename(assetList), "build-manifest.json", ...assets.map(asset => asset.filename)];
  for (const asset of assets) {
    const file = path.join(staging, asset.filename);
    const info = assertRegularFile(file, `Staged installer ${asset.filename}`);
    if (info.size !== asset.bytes) fail(`Staged size mismatch: ${asset.filename}`);
    if (hashFile(file) !== asset.sha256) fail(`Staged SHA-256 mismatch: ${asset.filename}`);
  }
  assertExactDirectory(staging, expectedNames, "Staged unsigned build directory");
}

function publishNoReplace([staging, destination, ...expectedNames]) {
  if (!expectedNames.length) fail("Expected publication set is missing");
  const lock = `${destination}.publish.lock`;
  let locked = false;
  try {
    mkdirSync(lock);
    locked = true;
    try { lstatSync(destination); fail(`Publication destination already exists: ${destination}`); } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    const actual = readdirSync(staging).sort();
    const expected = [...expectedNames].sort();
    if (JSON.stringify(actual) !== JSON.stringify(expected)) fail("Publication staging set is incomplete or unexpected");
    for (const name of actual) assertRegularFile(path.join(staging, name), `Publication entry ${name}`);
    renameSync(staging, destination);
    const published = readdirSync(destination).sort();
    if (JSON.stringify(published) !== JSON.stringify(expected)) fail("Published directory set is incomplete or unexpected");
  } catch (error) {
    if (error.code === "EEXIST") fail(`Publication lock or destination already exists: ${destination}`);
    throw error;
  } finally {
    if (locked) rmSync(lock, { recursive: true, force: true });
  }
}

function printAssets([assetList]) {
  for (const asset of loadAssets(assetList)) {
    process.stdout.write(`${asset.platform}\t${asset.arch}\t${asset.filename}\t${asset.sha256}\n`);
  }
}

function validateSignatures([assetList, staging]) {
  for (const asset of loadAssets(assetList)) {
    const signature = readFileSync(path.join(staging, `${asset.filename}.sig`), "utf8").trim();
    validateSignatureEnvelope(signature, asset.filename);
  }
}

function writeMetadata([assetList, staging, version, repo, pubDate]) {
  const platforms = {};
  for (const asset of loadAssets(assetList)) {
    const signature = readFileSync(path.join(staging, `${asset.filename}.sig`), "utf8").trim();
    platforms[asset.platform] = {
      signature,
      url: `https://github.com/${repo}/releases/download/v${version}/${asset.filename}`,
    };
  }
  const metadata = { version, notes: `Codex Token Bar Windows v${version}`, pub_date: pubDate, platforms };
  writeFileSync(path.join(staging, "latest-windows.json"), `${JSON.stringify(metadata, null, 2)}\n`);
}

function releasePayloadNames(assets) {
  return [
    ...assets.flatMap(asset => [asset.filename, `${asset.filename}.sig`]),
    "build-manifest.json",
    "latest-windows.json",
  ].sort();
}

function writeChecksums([assetList, staging, version]) {
  const names = releasePayloadNames(loadAssets(assetList));
  const lines = names.map(name => `${hashFile(path.join(staging, name))}  ${name}`);
  writeFileSync(path.join(staging, `SHA256SUMS-v${version}-windows.txt`), `${lines.join("\n")}\n`);
}

function validateRelease([assetList, staging, version]) {
  const assets = loadAssets(assetList);
  const checksumName = `SHA256SUMS-v${version}-windows.txt`;
  const payloadNames = releasePayloadNames(assets);
  const actualNames = readdirSync(staging).filter(name => name !== path.basename(assetList)).sort();
  const expectedNames = [...payloadNames, checksumName].sort();
  if (JSON.stringify(actualNames) !== JSON.stringify(expectedNames)) fail("Signed release staging contains unexpected files");
  const lines = readFileSync(path.join(staging, checksumName), "utf8").trim().split("\n");
  if (lines.length !== 6) fail("Checksum manifest must contain exactly six payloads");
  const names = [];
  for (const line of lines) {
    const match = /^([a-f0-9]{64})  ([^/\\]+)$/.exec(line);
    if (!match) fail("Checksum line is malformed");
    const [, expectedHash, name] = match;
    names.push(name);
    if (hashFile(path.join(staging, name)) !== expectedHash) fail(`Checksum mismatch: ${name}`);
  }
  if (JSON.stringify(names) !== JSON.stringify(payloadNames)) fail("Checksum payload set or order is invalid");
  const metadata = readJson(path.join(staging, "latest-windows.json"));
  for (const asset of assets) {
    const signature = readFileSync(path.join(staging, `${asset.filename}.sig`), "utf8").trim();
    if (metadata.platforms?.[asset.platform]?.signature !== signature) fail(`Metadata signature mismatch: ${asset.platform}`);
  }
}

const [command, ...args] = process.argv.slice(2);
const commands = {
  "validate-build": validateBuild,
  "validate-staged-build": validateStagedBuild,
  "publish-no-replace": publishNoReplace,
  "print-assets": printAssets,
  "validate-signatures": validateSignatures,
  "write-metadata": writeMetadata,
  "write-checksums": writeChecksums,
  "validate-release": validateRelease,
};
if (!commands[command]) fail(`Unknown helper command: ${command || "missing"}`);
commands[command](args);
