#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TIKTOKEN_CHECKOUT="$ROOT_DIR/.build/checkouts/TiktokenSwift"
TIKTOKEN_LFS_INCLUDE="Sources/TiktokenFFI/TiktokenFFI.xcframework/macos-arm64_x86_64/**,TiktokenFFI.xcframework/macos-arm64_x86_64/**"
TIKTOKEN_MACOS_FRAMEWORKS=(
  "$TIKTOKEN_CHECKOUT/Sources/TiktokenFFI/TiktokenFFI.xcframework/macos-arm64_x86_64/TiktokenFFI.framework/TiktokenFFI"
  "$TIKTOKEN_CHECKOUT/TiktokenFFI.xcframework/macos-arm64_x86_64/TiktokenFFI.framework/TiktokenFFI"
)

command -v git-lfs >/dev/null 2>&1 || {
  echo "error: git-lfs is required to build TiktokenSwift. Install with: brew install git-lfs && git lfs install" >&2
  exit 1
}

cd "$ROOT_DIR"
GIT_LFS_SKIP_SMUDGE=1 swift package resolve

if [[ ! -d "$TIKTOKEN_CHECKOUT" ]]; then
  exit 0
fi

needs_lfs=0
for framework_binary in "${TIKTOKEN_MACOS_FRAMEWORKS[@]}"; do
  if [[ -f "$framework_binary" ]] && grep -q "git-lfs.github.com/spec" "$framework_binary"; then
    needs_lfs=1
  fi
done

if [[ "$needs_lfs" == "1" ]]; then
  git -C "$TIKTOKEN_CHECKOUT" lfs fetch https://github.com/narner/TiktokenSwift.git --include="$TIKTOKEN_LFS_INCLUDE" --exclude=""
  git -C "$TIKTOKEN_CHECKOUT" lfs checkout \
    "Sources/TiktokenFFI/TiktokenFFI.xcframework/macos-arm64_x86_64/TiktokenFFI.framework/TiktokenFFI" \
    "TiktokenFFI.xcframework/macos-arm64_x86_64/TiktokenFFI.framework/TiktokenFFI"
fi
