#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 --version VERSION --repo OWNER/REPO --release-dir DIR --key-path FILE [--signer FILE]" >&2
}

VERSION=""
REPO=""
RELEASE_DIR=""
KEY_PATH=""
SIGNER=""

while (($#)); do
  case "$1" in
    --version) VERSION=${2-}; shift 2 ;;
    --repo) REPO=${2-}; shift 2 ;;
    --release-dir) RELEASE_DIR=${2-}; shift 2 ;;
    --key-path) KEY_PATH=${2-}; shift 2 ;;
    --signer) SIGNER=${2-}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

if [[ -z "$VERSION" || -z "$REPO" || -z "$RELEASE_DIR" || -z "$KEY_PATH" ]]; then
  usage
  exit 2
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || { echo "Invalid version" >&2; exit 1; }
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "Invalid repository" >&2; exit 1; }
[[ -d "$RELEASE_DIR" ]] || { echo "Release directory not found: $RELEASE_DIR" >&2; exit 1; }
[[ -f "$KEY_PATH" ]] || { echo "Signing key file not found" >&2; exit 1; }
command -v node >/dev/null || { echo "Missing required command: node" >&2; exit 1; }
command -v shasum >/dev/null || { echo "Missing required command: shasum" >&2; exit 1; }

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
MANIFEST="$RELEASE_DIR/build-manifest.json"
[[ -f "$MANIFEST" ]] || { echo "Build manifest not found" >&2; exit 1; }

STAGING=$(mktemp -d "$RELEASE_DIR/.windows-signing.XXXXXX")
cleanup() { rm -rf "$STAGING"; }
trap cleanup EXIT INT TERM

ASSET_LIST="$STAGING/assets.tsv"
node - "$MANIFEST" "$RELEASE_DIR" "$VERSION" > "$ASSET_LIST" <<'NODE'
const [manifestPath, releaseDir, version] = process.argv.slice(2);
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
if (manifest.version !== version || !Array.isArray(manifest.assets)) throw new Error("Build manifest version or assets are invalid");
const expected = new Map([
  ["windows-aarch64", { arch: "arm64", filename: `CodexTokenBar-v${version}-windows-arm64-setup.exe` }],
  ["windows-x86_64", { arch: "x64", filename: `CodexTokenBar-v${version}-windows-x64-setup.exe` }],
]);
if (manifest.assets.length !== expected.size) throw new Error("Build manifest must contain exactly x64 and arm64 installers");
for (const asset of [...manifest.assets].sort((a, b) => a.platform.localeCompare(b.platform))) {
  const wanted = expected.get(asset.platform);
  if (!wanted || asset.version !== version || asset.arch !== wanted.arch || asset.filename !== wanted.filename) {
    throw new Error(`Unexpected manifest asset: ${asset.platform || "unknown"}`);
  }
  expected.delete(asset.platform);
  const file = path.join(releaseDir, asset.filename);
  const info = fs.statSync(file);
  const hash = crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
  if (info.size !== asset.bytes) throw new Error(`Size mismatch: ${asset.filename}`);
  if (hash !== asset.sha256) throw new Error(`SHA-256 mismatch: ${asset.filename}`);
  process.stdout.write(`${asset.platform}\t${asset.arch}\t${asset.filename}\t${asset.sha256}\n`);
}
if (expected.size) throw new Error("Required Windows architecture missing");
NODE

command -v file >/dev/null || { echo "Missing required command for PE architecture validation: file" >&2; exit 1; }
while IFS=$'\t' read -r platform arch filename sha256; do
  description=$(file -b "$RELEASE_DIR/$filename")
  normalized_description=$(printf '%s' "$description" | tr '[:upper:]' '[:lower:]')
  case "$arch:$normalized_description" in
    x64:*x86-64*|x64:*x86_64*|x64:*amd64*) ;;
    arm64:*arm64*|arm64:*aarch64*) ;;
    *) echo "PE architecture mismatch for $filename: $description" >&2; exit 1 ;;
  esac
done < "$ASSET_LIST"

while IFS=$'\t' read -r platform arch filename sha256; do
  cp "$RELEASE_DIR/$filename" "$STAGING/$filename"
  if [[ -n "$SIGNER" ]]; then
    "$SIGNER" -f "$KEY_PATH" "$STAGING/$filename"
  else
    (cd "$ROOT_DIR/tauri-app" && npm run tauri -- signer sign -f "$KEY_PATH" "$STAGING/$filename")
  fi
  [[ -s "$STAGING/$filename.sig" ]] || { echo "Signer did not create a signature for $filename" >&2; exit 1; }
done < "$ASSET_LIST"

PUB_DATE=${SOURCE_DATE_EPOCH:+$(date -u -r "$SOURCE_DATE_EPOCH" +%Y-%m-%dT%H:%M:%SZ)}
PUB_DATE=${PUB_DATE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
node - "$ASSET_LIST" "$STAGING" "$VERSION" "$REPO" "$PUB_DATE" <<'NODE'
const [listPath, staging, version, repo, pubDate] = process.argv.slice(2);
const fs = require("node:fs");
const path = require("node:path");
const rows = fs.readFileSync(listPath, "utf8").trim().split("\n").map(line => line.split("\t"));
const platforms = {};
for (const [platform, , filename] of rows) {
  platforms[platform] = {
    signature: fs.readFileSync(path.join(staging, `${filename}.sig`), "utf8").trim(),
    url: `https://github.com/${repo}/releases/download/v${version}/${filename}`,
  };
}
const metadata = { version, notes: `Codex Token Bar Windows v${version}`, pub_date: pubDate, platforms };
fs.writeFileSync(path.join(staging, "latest-windows.json"), `${JSON.stringify(metadata, null, 2)}\n`);
NODE

CHECKSUM_NAME="SHA256SUMS-v$VERSION-windows.txt"
while IFS=$'\t' read -r platform arch filename sha256; do
  printf '%s  %s\n' "$sha256" "$filename"
  signature_hash=$(shasum -a 256 "$STAGING/$filename.sig" | awk '{print $1}')
  printf '%s  %s.sig\n' "$signature_hash" "$filename"
done < "$ASSET_LIST" | LC_ALL=C sort -k2 > "$STAGING/$CHECKSUM_NAME"

while IFS=$'\t' read -r platform arch filename sha256; do
  mv -f "$STAGING/$filename.sig" "$RELEASE_DIR/$filename.sig.tmp"
  mv -f "$RELEASE_DIR/$filename.sig.tmp" "$RELEASE_DIR/$filename.sig"
done < "$ASSET_LIST"
for output in latest-windows.json "$CHECKSUM_NAME"; do
  mv -f "$STAGING/$output" "$RELEASE_DIR/$output.tmp"
  mv -f "$RELEASE_DIR/$output.tmp" "$RELEASE_DIR/$output"
done

echo "Signed Windows updater assets: $RELEASE_DIR"
echo "Updater metadata: $RELEASE_DIR/latest-windows.json"
echo "Checksums: $RELEASE_DIR/$CHECKSUM_NAME"
