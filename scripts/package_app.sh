#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Codex Token Bar"
PRODUCT_NAME="CodexTokenBar"
CONFIGURATION="${1:-debug}"
APP_VERSION="${APP_VERSION:-0.7.0}"
APP_BUILD="${APP_BUILD:-700}"
BUNDLE_ID="local.codex.token-bar"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://raw.githubusercontent.com/hututuo/codex-token-bar/main/appcast.xml}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-gzOiRKuKM4MkXj1OaYuL40U39RvfEWavuB8PaOdMDq0=}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-${CODESIGN_IDENTITY:--}}"
ENABLE_HARDENED_RUNTIME="${ENABLE_HARDENED_RUNTIME:-auto}"
ENABLE_APP_SANDBOX="${ENABLE_APP_SANDBOX:-0}"

write_info_plist() {
  local output_path="$1"
  cat > "$output_path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleExecutable</key>
  <string>CodexTokenBar</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Codex Token Bar</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>zh_CN</string>
    <string>zh_TW</string>
    <string>zh_HK</string>
    <string>en</string>
  </array>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSAccessibilityUsageDescription</key>
  <string>用于在你开启悬浮窗锁定时读取目标窗口的位置，让悬浮窗跟随你选择的窗口。</string>
  <key>NSScreenCaptureUsageDescription</key>
  <string>用于识别屏幕上的窗口位置和名称，以支持悬浮窗锁定与跟随；不会截取或上传屏幕内容。</string>
  <key>SUEnableAutomaticChecks</key>
  <true/>
  <key>SUScheduledCheckInterval</key>
  <integer>14400</integer>
  <key>SUEnableInstallerLauncherService</key>
  <true/>
  <key>SUFeedURL</key>
  <string>$SPARKLE_FEED_URL</string>
  <key>SUPublicEDKey</key>
  <string>$SPARKLE_PUBLIC_ED_KEY</string>
</dict>
</plist>
PLIST
}

if [[ "$CONFIGURATION" == "--write-info-plist" ]]; then
  if [[ $# -ne 2 ]]; then
    echo "usage: $0 --write-info-plist OUTPUT_PATH" >&2
    exit 64
  fi
  write_info_plist "$2"
  exit 0
fi

cd "$ROOT_DIR"
"$ROOT_DIR/scripts/prepare_tiktoken_lfs.sh"
swift build ${CONFIGURATION:+-c "$CONFIGURATION"}

BUILD_DIR="$ROOT_DIR/.build/$CONFIGURATION"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
SPARKLE_FRAMEWORK_SRC="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
ENTITLEMENTS_FILE="$ROOT_DIR/Resources/CodexTokenBar.entitlements"
SANDBOX_ENTITLEMENTS_FILE="$ROOT_DIR/Resources/CodexTokenBar.sandbox.entitlements"

if [[ "$ENABLE_APP_SANDBOX" == "1" ]]; then
  ENTITLEMENTS_FILE="$SANDBOX_ENTITLEMENTS_FILE"
fi

HARDENED_RUNTIME=0
if [[ "$ENABLE_HARDENED_RUNTIME" == "1" || ( "$ENABLE_HARDENED_RUNTIME" == "auto" && "$CODE_SIGN_IDENTITY" != "-" ) ]]; then
  HARDENED_RUNTIME=1
fi

sign_target() {
  local target="$1"
  local role="${2:-}"
  local -a args=(--force --sign "$CODE_SIGN_IDENTITY")
  if [[ "$CODE_SIGN_IDENTITY" == "-" ]]; then
    args+=(--timestamp=none)
  fi
  if [[ "$HARDENED_RUNTIME" == "1" ]]; then
    args+=(--options runtime --entitlements "$ENTITLEMENTS_FILE")
  fi
  if [[ "$role" == "app" ]]; then
    args+=(--requirements "=designated => identifier \"$BUNDLE_ID\"")
  fi
  codesign "${args[@]}" "$target" >/dev/null
}

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR"

cp "$BUILD_DIR/$PRODUCT_NAME" "$MACOS_DIR/$PRODUCT_NAME"
chmod +x "$MACOS_DIR/$PRODUCT_NAME"

if [[ -f "$ROOT_DIR/Resources/AppIcon.icns" ]]; then
  cp "$ROOT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

if [[ -f "$ROOT_DIR/Assets/ResetCreditIcon.png" ]]; then
  cp "$ROOT_DIR/Assets/ResetCreditIcon.png" "$RESOURCES_DIR/ResetCreditIcon.png"
fi

if [[ -d "$SPARKLE_FRAMEWORK_SRC" ]]; then
  ditto "$SPARKLE_FRAMEWORK_SRC" "$FRAMEWORKS_DIR/Sparkle.framework"
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/$PRODUCT_NAME" >/dev/null 2>&1 || true
fi

write_info_plist "$CONTENTS_DIR/Info.plist"

if [[ -d "$FRAMEWORKS_DIR/Sparkle.framework" ]]; then
  sign_target "$FRAMEWORKS_DIR/Sparkle.framework/Versions/B/Autoupdate"
  sign_target "$FRAMEWORKS_DIR/Sparkle.framework/Versions/B/Updater.app"
  sign_target "$FRAMEWORKS_DIR/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"
  sign_target "$FRAMEWORKS_DIR/Sparkle.framework/Versions/B/XPCServices/Installer.xpc"
  sign_target "$FRAMEWORKS_DIR/Sparkle.framework"
fi

sign_target "$APP_DIR" app
codesign --verify --deep --strict --verbose=2 "$APP_DIR" >/dev/null

echo "$APP_DIR"

if [[ "$CONFIGURATION" == "debug" && "${CODEX_TOKEN_BAR_NO_OPEN:-0}" != "1" ]]; then
  /usr/bin/osascript -e 'tell application id "local.codex.token-bar" to quit' >/dev/null 2>&1 || true
  /usr/bin/pkill -x "$PRODUCT_NAME" >/dev/null 2>&1 || true
  /usr/bin/pkill -x "CodexTokenDashboard" >/dev/null 2>&1 || true

  for _ in {1..20}; do
    if ! /usr/bin/pgrep -x "$PRODUCT_NAME" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done

  /usr/bin/open "$APP_DIR"
  echo "Opened $APP_DIR"
fi
