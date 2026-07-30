#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TIKTOKEN_CHECKOUT="$ROOT_DIR/.build/checkouts/TiktokenSwift"

command -v git-lfs >/dev/null 2>&1 || {
  echo "error: git-lfs is required to build TiktokenSwift. Install with: brew install git-lfs && git lfs install" >&2
  exit 1
}

cd "$ROOT_DIR"
GIT_LFS_SKIP_SMUDGE=1 swift package resolve

if [[ ! -d "$TIKTOKEN_CHECKOUT" ]]; then
  exit 0
fi

if grep -Fq 'path: "Sources/TiktokenFFI/TiktokenFFI.xcframework"' "$TIKTOKEN_CHECKOUT/Package.swift"; then
  TIKTOKEN_XCFRAMEWORK_PATH="Sources/TiktokenFFI/TiktokenFFI.xcframework"
elif grep -Fq 'path: "TiktokenFFI.xcframework"' "$TIKTOKEN_CHECKOUT/Package.swift"; then
  TIKTOKEN_XCFRAMEWORK_PATH="TiktokenFFI.xcframework"
else
  echo "error: unable to identify the active TiktokenFFI binary target path" >&2
  exit 1
fi

TIKTOKEN_LFS_PATH="$TIKTOKEN_XCFRAMEWORK_PATH/macos-arm64_x86_64/TiktokenFFI.framework/TiktokenFFI"
TIKTOKEN_LFS_INCLUDE="$TIKTOKEN_XCFRAMEWORK_PATH/macos-arm64_x86_64/**"
TIKTOKEN_FRAMEWORK_BINARY="$TIKTOKEN_CHECKOUT/$TIKTOKEN_LFS_PATH"

if [[ -f "$TIKTOKEN_FRAMEWORK_BINARY" ]] \
  && grep -q "git-lfs.github.com/spec" "$TIKTOKEN_FRAMEWORK_BINARY"; then
  git -C "$TIKTOKEN_CHECKOUT" lfs fetch https://github.com/narner/TiktokenSwift.git --include="$TIKTOKEN_LFS_INCLUDE" --exclude=""
  git -C "$TIKTOKEN_CHECKOUT" lfs checkout "$TIKTOKEN_LFS_PATH"
fi
