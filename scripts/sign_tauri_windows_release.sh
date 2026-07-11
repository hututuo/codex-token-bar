#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 --version VERSION --repo OWNER/REPO --build-dir DIR --release-dir DIR --key-path FILE [--signer FILE]" >&2
}

VERSION=""
REPO=""
BUILD_DIR=""
RELEASE_DIR=""
KEY_PATH=""
SIGNER=""

while (($#)); do
  case "$1" in
    --version) VERSION=${2-}; shift 2 ;;
    --repo) REPO=${2-}; shift 2 ;;
    --build-dir) BUILD_DIR=${2-}; shift 2 ;;
    --release-dir) RELEASE_DIR=${2-}; shift 2 ;;
    --key-path) KEY_PATH=${2-}; shift 2 ;;
    --signer) SIGNER=${2-}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

if [[ -z "$VERSION" || -z "$REPO" || -z "$BUILD_DIR" || -z "$RELEASE_DIR" || -z "$KEY_PATH" ]]; then
  usage
  exit 2
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || { echo "Invalid version" >&2; exit 1; }
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "Invalid repository" >&2; exit 1; }
[[ -d "$BUILD_DIR" ]] || { echo "Unsigned build directory not found: $BUILD_DIR" >&2; exit 1; }
if [[ -e "$RELEASE_DIR" || -L "$RELEASE_DIR" ]]; then
  echo "Release output already exists: $RELEASE_DIR" >&2
  exit 1
fi
[[ -f "$KEY_PATH" ]] || { echo "Signing key file not found" >&2; exit 1; }
command -v node >/dev/null || { echo "Missing required command: node" >&2; exit 1; }
command -v file >/dev/null || { echo "Missing required command: file" >&2; exit 1; }
command -v cc >/dev/null || { echo "Missing required command: cc (install Xcode Command Line Tools)" >&2; exit 1; }
[[ "$(uname -s)" == "Darwin" ]] || { echo "Darwin is required for atomic RENAME_EXCL publication" >&2; exit 1; }

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
HELPER="$SCRIPT_DIR/tauri_windows_release_helper.mjs"
RENAME_HELPER_SOURCE="$SCRIPT_DIR/rename_no_replace_darwin.c"
[[ -f "$RENAME_HELPER_SOURCE" ]] || { echo "Darwin RENAME_EXCL helper source not found" >&2; exit 1; }
BUILD_DIR=$(cd "$BUILD_DIR" && pwd)
RELEASE_PARENT=$(dirname "$RELEASE_DIR")
RELEASE_NAME=$(basename "$RELEASE_DIR")
[[ -d "$RELEASE_PARENT" ]] || { echo "Release parent directory not found: $RELEASE_PARENT" >&2; exit 1; }
RELEASE_PARENT=$(cd "$RELEASE_PARENT" && pwd)
RELEASE_DIR="$RELEASE_PARENT/$RELEASE_NAME"
[[ "$BUILD_DIR" != "$RELEASE_DIR" ]] || { echo "Build and release directories must differ" >&2; exit 1; }
case "$RELEASE_DIR/" in
  "$BUILD_DIR/"*) echo "Release directory must not be inside the unsigned build directory" >&2; exit 1 ;;
esac

MANIFEST="$BUILD_DIR/build-manifest.json"
[[ -f "$MANIFEST" ]] || { echo "Build manifest not found" >&2; exit 1; }
STAGING=$(mktemp -d "$RELEASE_PARENT/.${RELEASE_NAME}.staging.XXXXXX")
RENAME_HELPER=$(mktemp "$RELEASE_PARENT/.rename-excl.XXXXXX")
ASSET_LIST="$STAGING/.assets.json"
cleanup() {
  if [[ -n "${STAGING:-}" && -d "$STAGING" ]]; then rm -rf "$STAGING"; fi
  if [[ -n "${RENAME_HELPER:-}" ]]; then rm -f "$RENAME_HELPER"; fi
}
trap cleanup EXIT INT TERM

cc -std=c11 -Wall -Wextra -Werror "$RENAME_HELPER_SOURCE" -o "$RENAME_HELPER"

node "$HELPER" validate-build "$MANIFEST" "$BUILD_DIR" "$VERSION" "$ASSET_LIST"
cp "$MANIFEST" "$STAGING/build-manifest.json"

while IFS=$'\t' read -r platform arch filename sha256; do
  description=$(file -b "$BUILD_DIR/$filename")
  normalized_description=$(printf '%s' "$description" | tr '[:upper:]' '[:lower:]')
  case "$arch:$normalized_description" in
    x64:*x86-64*|x64:*x86_64*|x64:*amd64*) ;;
    arm64:*arm64*|arm64:*aarch64*) ;;
    *) echo "PE architecture mismatch for $filename: $description" >&2; exit 1 ;;
  esac
  cp "$BUILD_DIR/$filename" "$STAGING/$filename"
done < <(node "$HELPER" print-assets "$ASSET_LIST")

node "$HELPER" validate-staged-build "$ASSET_LIST" "$STAGING" "$VERSION"

while IFS=$'\t' read -r platform arch filename sha256; do
  if [[ -n "$SIGNER" ]]; then
    if ! "$SIGNER" -f "$KEY_PATH" "$STAGING/$filename"; then
      echo "Signer failed for $filename" >&2
      exit 1
    fi
  elif ! (cd "$ROOT_DIR/tauri-app" && npm run tauri -- signer sign -f "$KEY_PATH" "$STAGING/$filename"); then
    echo "Signer failed for $filename" >&2
    exit 1
  fi
  [[ -s "$STAGING/$filename.sig" ]] || { echo "Signer failed to create a signature for $filename" >&2; exit 1; }
done < <(node "$HELPER" print-assets "$ASSET_LIST")

node "$HELPER" validate-signatures "$ASSET_LIST" "$STAGING"
PUB_DATE=${SOURCE_DATE_EPOCH:+$(date -u -r "$SOURCE_DATE_EPOCH" +%Y-%m-%dT%H:%M:%SZ)}
PUB_DATE=${PUB_DATE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
if ! node "$HELPER" write-metadata "$ASSET_LIST" "$STAGING" "$VERSION" "$REPO" "$PUB_DATE"; then
  echo "Metadata generation failed" >&2
  exit 1
fi
if ! node "$HELPER" write-checksums "$ASSET_LIST" "$STAGING" "$VERSION"; then
  echo "Checksum generation failed" >&2
  exit 1
fi
node "$HELPER" validate-release "$ASSET_LIST" "$STAGING" "$VERSION"
rm -f "$ASSET_LIST"

if [[ -e "$RELEASE_DIR" || -L "$RELEASE_DIR" ]]; then
  echo "Release output appeared during signing: $RELEASE_DIR" >&2
  exit 1
fi
"$RENAME_HELPER" "$STAGING" "$RELEASE_DIR"
STAGING=""

echo "Signed Windows updater assets: $RELEASE_DIR"
echo "Updater metadata: $RELEASE_DIR/latest-windows.json"
echo "Checksums: $RELEASE_DIR/SHA256SUMS-v$VERSION-windows.txt"
