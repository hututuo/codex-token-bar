#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Codex Token Bar"
PRODUCT_NAME="CodexTokenBar"
CONFIGURATION="${1:-debug}"
APP_VERSION="${APP_VERSION:-0.5.1}"
APP_BUILD="${APP_BUILD:-501}"
BUNDLE_ID="local.codex.token-bar"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://raw.githubusercontent.com/hututuo/codex-token-bar/main/appcast.xml}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-gzOiRKuKM4MkXj1OaYuL40U39RvfEWavuB8PaOdMDq0=}"

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

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
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
  <key>SUEnableInstallerLauncherService</key>
  <true/>
  <key>SUFeedURL</key>
  <string>$SPARKLE_FEED_URL</string>
  <key>SUPublicEDKey</key>
  <string>$SPARKLE_PUBLIC_ED_KEY</string>
</dict>
</plist>
PLIST

if [[ -d "$FRAMEWORKS_DIR/Sparkle.framework" ]]; then
  codesign --force --sign - --timestamp=none "$FRAMEWORKS_DIR/Sparkle.framework/Versions/B/Autoupdate" >/dev/null
  codesign --force --sign - --timestamp=none "$FRAMEWORKS_DIR/Sparkle.framework/Versions/B/Updater.app" >/dev/null
  codesign --force --sign - --timestamp=none "$FRAMEWORKS_DIR/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc" >/dev/null
  codesign --force --sign - --timestamp=none "$FRAMEWORKS_DIR/Sparkle.framework/Versions/B/XPCServices/Installer.xpc" >/dev/null
  codesign --force --sign - --timestamp=none "$FRAMEWORKS_DIR/Sparkle.framework" >/dev/null
fi

codesign --force --sign - --timestamp=none \
  --requirements "=designated => identifier \"$BUNDLE_ID\"" \
  "$APP_DIR" >/dev/null
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
