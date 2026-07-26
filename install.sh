#!/usr/bin/env bash
set -euo pipefail

REPO="hututuo/codex-token-bar"
APP_NAME="Codex Token Bar.app"
ASSET_NAME="CodexTokenBar.app.zip"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Codex Token Bar is a macOS app. This installer only supports macOS." >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# 先把 latest 解析成具体版本 tag：安装包与 checksum 清单必须取自同一个
# release，不能各自跟着 latest 漂移。
RELEASE_TAG_URL="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest")"
VERSION="${RELEASE_TAG_URL##*/tag/v}"
if [[ "$RELEASE_TAG_URL" != *"/tag/v"* || ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "Install failed: could not resolve the latest release version (got: $RELEASE_TAG_URL)." >&2
  exit 1
fi
DOWNLOAD_BASE="https://github.com/$REPO/releases/download/v$VERSION"
CHECKSUM_NAME="SHA256SUMS-v$VERSION.txt"

SKIP_VERIFY="${CODEX_TOKEN_BAR_SKIP_VERIFY:-0}"
if [[ "$SKIP_VERIFY" != "1" ]]; then
  echo "Downloading checksum manifest ($CHECKSUM_NAME)..."
  if ! curl -fsSL "$DOWNLOAD_BASE/$CHECKSUM_NAME" -o "$TMP_DIR/$CHECKSUM_NAME"; then
    echo "Install failed: checksum manifest $CHECKSUM_NAME is not available for v$VERSION." >&2
    echo "Refusing to install without integrity verification." >&2
    echo "If you accept an unverified download, rerun with CODEX_TOKEN_BAR_SKIP_VERIFY=1." >&2
    exit 1
  fi
fi

echo "Downloading Codex Token Bar v$VERSION..."
curl -fL --progress-bar "$DOWNLOAD_BASE/$ASSET_NAME" -o "$TMP_DIR/$ASSET_NAME"

if [[ "$SKIP_VERIFY" != "1" ]]; then
  EXPECTED_HASH="$(awk -v name="$ASSET_NAME" '$2 == name { print $1 }' "$TMP_DIR/$CHECKSUM_NAME")"
  if [[ ! "$EXPECTED_HASH" =~ ^[a-f0-9]{64}$ ]]; then
    echo "Install failed: $CHECKSUM_NAME does not contain exactly one entry for $ASSET_NAME." >&2
    exit 1
  fi
  ACTUAL_HASH="$(shasum -a 256 "$TMP_DIR/$ASSET_NAME" | awk '{ print $1 }')"
  if [[ "$ACTUAL_HASH" != "$EXPECTED_HASH" ]]; then
    echo "Install failed: SHA-256 mismatch for $ASSET_NAME." >&2
    echo "  expected: $EXPECTED_HASH" >&2
    echo "  actual:   $ACTUAL_HASH" >&2
    echo "The download is corrupted or is not the released asset; refusing to install." >&2
    exit 1
  fi
  echo "Checksum verified: $ACTUAL_HASH"
else
  echo "WARNING: CODEX_TOKEN_BAR_SKIP_VERIFY=1 is set — installing without checksum verification." >&2
fi

echo "Unpacking..."
ditto -x -k "$TMP_DIR/$ASSET_NAME" "$TMP_DIR"

APP_PATH="$TMP_DIR/$APP_NAME"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Install failed: $APP_NAME was not found in the downloaded archive." >&2
  exit 1
fi

if [[ -n "${CODEX_TOKEN_BAR_INSTALL_DIR:-}" ]]; then
  INSTALL_DIR="$CODEX_TOKEN_BAR_INSTALL_DIR"
  mkdir -p "$INSTALL_DIR"
elif [[ -n "${CODEX_TOKEN_DASHBOARD_INSTALL_DIR:-}" ]]; then
  INSTALL_DIR="$CODEX_TOKEN_DASHBOARD_INSTALL_DIR"
  mkdir -p "$INSTALL_DIR"
elif [[ -d "/Applications" && -w "/Applications" ]]; then
  INSTALL_DIR="/Applications"
else
  INSTALL_DIR="$HOME/Applications"
  mkdir -p "$INSTALL_DIR"
fi

TARGET="$INSTALL_DIR/$APP_NAME"

echo "Installing to $TARGET..."
rm -rf "$TARGET"
ditto "$APP_PATH" "$TARGET"

# Gatekeeper 隔离标记默认保留（这是 macOS 对下载内容的首启检查），
# 只有用户显式要求时才移除。
REMOVE_QUARANTINE="${CODEX_TOKEN_BAR_REMOVE_QUARANTINE:-0}"
if [[ "$REMOVE_QUARANTINE" == "1" ]] && command -v xattr >/dev/null 2>&1; then
  xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
fi

echo
echo "Installed: $TARGET"
NO_OPEN="${CODEX_TOKEN_BAR_NO_OPEN:-${CODEX_TOKEN_DASHBOARD_NO_OPEN:-0}}"
if [[ "$NO_OPEN" != "1" ]]; then
  echo "Opening Codex Token Bar..."
  open "$TARGET"
fi
echo
if [[ "$REMOVE_QUARANTINE" == "1" ]]; then
  echo "Note: the com.apple.quarantine flag was removed at your request (CODEX_TOKEN_BAR_REMOVE_QUARANTINE=1)."
  echo "It is still an unsigned app, so strict MDM, security tools, or macOS policy can still block it."
else
  echo "Note: this installer keeps macOS quarantine metadata (if present), so Gatekeeper may inspect the app on first launch."
  echo "The app is unsigned; if macOS blocks it, allow it in System Settings > Privacy & Security,"
  echo "or rerun this installer with CODEX_TOKEN_BAR_REMOVE_QUARANTINE=1 to remove the flag explicitly."
fi
