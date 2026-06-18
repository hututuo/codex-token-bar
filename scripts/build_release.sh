#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Codex Token Bar"
PRODUCT_NAME="CodexTokenBar"
REPO="hututuo/codex-token-bar"
VERSION="${1:-${APP_VERSION:-0.5.2}}"
VERSION="${VERSION#v}"
BUILD="${APP_BUILD:-}"
ARCH_LABEL="${ARCH_LABEL:-arm64}"
SPARKLE_KEY_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-local.codex.token-bar}"
SPARKLE_KEY_SOURCE="${SPARKLE_KEY_SOURCE:-auto}"
PRIVATE_KEY_FILE="${SPARKLE_PRIVATE_KEY_FILE:-$HOME/.config/codex-token-bar/sparkle-ed25519-private.key}"
RELEASE_NOTES_FILE="${RELEASE_NOTES_FILE:-$ROOT_DIR/release-notes/v$VERSION.md}"
NOTARIZE_RELEASE="${NOTARIZE_RELEASE:-auto}"
RELEASE_SECURITY_STRICT="${RELEASE_SECURITY_STRICT:-1}"
ENABLE_HARDENED_RUNTIME_WAS_SET=0
ENABLE_APP_SANDBOX_WAS_SET=0
if [[ -n "${ENABLE_HARDENED_RUNTIME+x}" ]]; then
  ENABLE_HARDENED_RUNTIME_WAS_SET=1
fi
if [[ -n "${ENABLE_APP_SANDBOX+x}" ]]; then
  ENABLE_APP_SANDBOX_WAS_SET=1
fi
ENABLE_HARDENED_RUNTIME="${ENABLE_HARDENED_RUNTIME:-auto}"
ENABLE_APP_SANDBOX="${ENABLE_APP_SANDBOX:-0}"
APPLE_NOTARY_PROFILE="${APPLE_NOTARY_PROFILE:-}"
APPLE_ID="${APPLE_ID:-}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"
APPLE_APP_SPECIFIC_PASSWORD="${APPLE_APP_SPECIFIC_PASSWORD:-}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-${CODESIGN_IDENTITY:--}}"

if [[ -z "$BUILD" ]]; then
  BUILD="$(python3 - "$VERSION" <<'PY'
import sys
parts = [int(p) for p in sys.argv[1].split(".")]
while len(parts) < 3:
    parts.append(0)
print(parts[0] * 10000 + parts[1] * 100 + parts[2])
PY
)"
fi

case "$SPARKLE_KEY_SOURCE" in
  keychain)
    SPARKLE_SIGN_ARGS=(--account "$SPARKLE_KEY_ACCOUNT")
    ;;
  file)
    if [[ ! -f "$PRIVATE_KEY_FILE" ]]; then
      echo "Missing Sparkle private key file: $PRIVATE_KEY_FILE" >&2
      exit 1
    fi
    SPARKLE_SIGN_ARGS=(--ed-key-file "$PRIVATE_KEY_FILE")
    ;;
  auto)
    if [[ -f "$PRIVATE_KEY_FILE" ]]; then
      SPARKLE_SIGN_ARGS=(--ed-key-file "$PRIVATE_KEY_FILE")
    else
      SPARKLE_SIGN_ARGS=(--account "$SPARKLE_KEY_ACCOUNT")
    fi
    ;;
  *)
    echo "Unknown SPARKLE_KEY_SOURCE: $SPARKLE_KEY_SOURCE (expected auto, file, or keychain)" >&2
    exit 1
    ;;
esac

if [[ ! -f "$RELEASE_NOTES_FILE" ]]; then
  echo "Missing release notes: $RELEASE_NOTES_FILE" >&2
  exit 1
fi

cd "$ROOT_DIR"

if [[ "$RELEASE_SECURITY_STRICT" == "1" ]]; then
  if [[ "$ENABLE_HARDENED_RUNTIME_WAS_SET" == "0" ]]; then
    ENABLE_HARDENED_RUNTIME="1"
  fi
  if [[ "$ENABLE_APP_SANDBOX_WAS_SET" == "0" ]]; then
    ENABLE_APP_SANDBOX="1"
  fi
fi

notary_available() {
  if [[ "$NOTARIZE_RELEASE" == "0" ]]; then
    return 1
  fi
  if [[ -n "$APPLE_NOTARY_PROFILE" ]]; then
    return 0
  fi
  [[ -n "$APPLE_ID" && -n "$APPLE_TEAM_ID" && -n "$APPLE_APP_SPECIFIC_PASSWORD" ]]
}

release_security_preflight() {
  if [[ "$NOTARIZE_RELEASE" == "1" ]] && ! notary_available; then
    echo "NOTARIZE_RELEASE=1 requires Apple notarization credentials." >&2
    echo "Set APPLE_NOTARY_PROFILE, or APPLE_ID + APPLE_TEAM_ID + APPLE_APP_SPECIFIC_PASSWORD." >&2
    exit 1
  fi

  if [[ "$RELEASE_SECURITY_STRICT" != "1" ]]; then
    return 0
  fi

  if [[ "$CODE_SIGN_IDENTITY" == "-" ]]; then
    echo "RELEASE_SECURITY_STRICT=1 requires CODE_SIGN_IDENTITY or CODESIGN_IDENTITY." >&2
    exit 1
  fi

  if ! security find-identity -v -p codesigning | grep -F -- "$CODE_SIGN_IDENTITY" >/dev/null; then
    echo "Code signing identity not found or not trusted: $CODE_SIGN_IDENTITY" >&2
    exit 1
  fi

  if ! notary_available; then
    echo "RELEASE_SECURITY_STRICT=1 requires Apple notarization credentials." >&2
    echo "Set APPLE_NOTARY_PROFILE, or APPLE_ID + APPLE_TEAM_ID + APPLE_APP_SPECIFIC_PASSWORD." >&2
    exit 1
  fi

  if [[ "$ENABLE_HARDENED_RUNTIME" == "0" ]]; then
    echo "RELEASE_SECURITY_STRICT=1 requires ENABLE_HARDENED_RUNTIME=1." >&2
    exit 1
  fi

  if [[ "$ENABLE_APP_SANDBOX" != "1" ]]; then
    echo "RELEASE_SECURITY_STRICT=1 requires ENABLE_APP_SANDBOX=1." >&2
    exit 1
  fi
}

notarize_artifact() {
  local artifact="$1"
  local -a args=(notarytool submit "$artifact" --wait)
  if [[ -n "$APPLE_NOTARY_PROFILE" ]]; then
    args+=(--keychain-profile "$APPLE_NOTARY_PROFILE")
  else
    args+=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD")
  fi
  xcrun "${args[@]}"
  xcrun stapler staple "$artifact" >/dev/null
  xcrun stapler validate "$artifact" >/dev/null
}

release_security_preflight

APP_VERSION="$VERSION" APP_BUILD="$BUILD" CODEX_TOKEN_BAR_NO_OPEN=1 \
  ENABLE_HARDENED_RUNTIME="$ENABLE_HARDENED_RUNTIME" ENABLE_APP_SANDBOX="$ENABLE_APP_SANDBOX" \
  "$ROOT_DIR/scripts/package_app.sh" release >/dev/null

APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
RELEASE_DIR="$ROOT_DIR/dist/release/v$VERSION"
APPCAST_SOURCE_DIR="$RELEASE_DIR/appcast-source"
VERSIONED_ZIP="CodexTokenBar-v$VERSION-macos-$ARCH_LABEL.app.zip"
LEGACY_ZIP="CodexTokenBar.app.zip"
DMG_NAME="CodexTokenBar-v$VERSION-macos-$ARCH_LABEL.dmg"
CHECKSUM_FILE="SHA256SUMS-v$VERSION.txt"

rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR" "$APPCAST_SOURCE_DIR"

ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$RELEASE_DIR/$VERSIONED_ZIP"
cp "$RELEASE_DIR/$VERSIONED_ZIP" "$RELEASE_DIR/$LEGACY_ZIP"

DMG_STAGING="$(mktemp -d "$RELEASE_DIR/dmg-staging.XXXXXX")"
DMG_DEVICE=""
DMG_MOUNT=""
cleanup() {
  if [[ -n "$DMG_MOUNT" ]]; then
    hdiutil detach "$DMG_MOUNT" >/dev/null 2>&1 || true
  elif [[ -n "$DMG_DEVICE" ]]; then
    hdiutil detach "$DMG_DEVICE" >/dev/null 2>&1 || true
  fi
  rm -rf "$DMG_STAGING"
}
trap cleanup EXIT

detach_existing_volume() {
  local volume_name="$1"
  hdiutil info | awk -v exact="/Volumes/$volume_name" '
    /^\/dev\// { device=$1 }
    index($0, exact) {
      print device
    }
  ' | while read -r device; do
    [[ -n "$device" ]] && hdiutil detach "$device" >/dev/null 2>&1 || true
  done
}

ditto "$APP_DIR" "$DMG_STAGING/$APP_NAME.app"
ln -s /Applications "$DMG_STAGING/Applications"
mkdir -p "$DMG_STAGING/.background"

/usr/bin/swift - "$DMG_STAGING/.background/dmg-background.png" "$APP_NAME" <<'SWIFT'
import AppKit
import Foundation

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let appName = CommandLine.arguments[2]
let size = NSSize(width: 760, height: 500)
let image = NSImage(size: size)

image.lockFocus()

let bounds = NSRect(origin: .zero, size: size)
let background = NSGradient(colors: [
    NSColor(calibratedRed: 0.93, green: 0.96, blue: 1.0, alpha: 1.0),
    NSColor(calibratedRed: 0.99, green: 0.99, blue: 1.0, alpha: 1.0)
])!
background.draw(in: bounds, angle: 25)

func roundedPanel(_ rect: NSRect, alpha: CGFloat) {
    let path = NSBezierPath(roundedRect: rect, xRadius: 24, yRadius: 24)
    NSColor(calibratedWhite: 1.0, alpha: alpha).setFill()
    path.fill()
    NSColor(calibratedWhite: 1.0, alpha: 0.65).setStroke()
    path.lineWidth = 1
    path.stroke()
}

roundedPanel(NSRect(x: 80, y: 170, width: 170, height: 170), alpha: 0.52)
roundedPanel(NSRect(x: 510, y: 170, width: 170, height: 170), alpha: 0.52)
roundedPanel(NSRect(x: 74, y: 42, width: 612, height: 102), alpha: 0.48)

let arrowPath = NSBezierPath()
arrowPath.move(to: NSPoint(x: 306, y: 255))
arrowPath.line(to: NSPoint(x: 448, y: 255))
arrowPath.move(to: NSPoint(x: 418, y: 284))
arrowPath.line(to: NSPoint(x: 450, y: 255))
arrowPath.line(to: NSPoint(x: 418, y: 226))
NSColor(calibratedRed: 0.03, green: 0.50, blue: 0.95, alpha: 0.80).setStroke()
arrowPath.lineWidth = 8
arrowPath.lineCapStyle = .round
arrowPath.lineJoinStyle = .round
arrowPath.stroke()

let titleStyle: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 24, weight: .semibold),
    .foregroundColor: NSColor(calibratedWhite: 0.11, alpha: 0.88)
]
let bodyStyle: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 15, weight: .regular),
    .foregroundColor: NSColor(calibratedWhite: 0.15, alpha: 0.72)
]
let smallStyle: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 13, weight: .regular),
    .foregroundColor: NSColor(calibratedWhite: 0.18, alpha: 0.68)
]
let warningStyle: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
    .foregroundColor: NSColor(calibratedRed: 0.04, green: 0.23, blue: 0.55, alpha: 0.86)
]

let title = "安装 \(appName)"
title.draw(
    in: NSRect(x: 0, y: 410, width: size.width, height: 34),
    withAttributes: titleStyle.merging([.paragraphStyle: centeredParagraph()]) { $1 }
)

"拖动左侧 App 到右侧 Applications 文件夹".draw(
    in: NSRect(x: 0, y: 378, width: size.width, height: 24),
    withAttributes: bodyStyle.merging([.paragraphStyle: centeredParagraph()]) { $1 }
)

"提示“未知开发者”时不要删除 App".draw(
    in: NSRect(x: 98, y: 110, width: 564, height: 22),
    withAttributes: warningStyle.merging([.paragraphStyle: centeredParagraph()]) { $1 }
)
"系统设置 -> 隐私与安全 -> 滑到最底下找到 \(appName)".draw(
    in: NSRect(x: 96, y: 82, width: 568, height: 22),
    withAttributes: smallStyle.merging([.paragraphStyle: centeredParagraph()]) { $1 }
)
"点“仍要打开”，再确认“打开”".draw(
    in: NSRect(x: 96, y: 58, width: 568, height: 22),
    withAttributes: smallStyle.merging([.paragraphStyle: centeredParagraph()]) { $1 }
)

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiff),
    let png = bitmap.representation(using: .png, properties: [:])
else {
    fatalError("Failed to render DMG background PNG")
}
try png.write(to: outputURL)

func centeredParagraph() -> NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    return style
}
SWIFT

RW_DMG="$RELEASE_DIR/${DMG_NAME%.dmg}.rw.dmg"
rm -f "$RW_DMG" "$RELEASE_DIR/$DMG_NAME"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGING" \
  -fs HFS+ \
  -format UDRW \
  -ov "$RW_DMG" >/dev/null

detach_existing_volume "$APP_NAME"

ATTACH_OUTPUT="$(hdiutil attach \
  -readwrite \
  -noverify \
  -noautoopen \
  "$RW_DMG")"
DMG_DEVICE="$(printf '%s\n' "$ATTACH_OUTPUT" | awk -F '\t' '$3 ~ /^\/Volumes\// {print $1; exit}')"
DMG_MOUNT="$(printf '%s\n' "$ATTACH_OUTPUT" | awk -F '\t' '$3 ~ /^\/Volumes\// {print $3; exit}')"

if [[ -z "$DMG_DEVICE" || -z "$DMG_MOUNT" ]]; then
  echo "Failed to attach writable DMG at a Finder-visible /Volumes mount." >&2
  echo "$ATTACH_OUTPUT" >&2
  exit 1
fi

/usr/bin/osascript <<APPLESCRIPT >/dev/null
set bgFile to POSIX file "$DMG_MOUNT/.background/dmg-background.png" as alias
set dmgFolder to POSIX file "$DMG_MOUNT" as alias
tell application "Finder"
  open dmgFolder
  delay 0.5
  set dmgWindow to container window of dmgFolder
  set current view of dmgWindow to icon view
  try
    set toolbar visible of dmgWindow to false
  end try
  try
    set statusbar visible of dmgWindow to false
  end try
  set bounds of dmgWindow to {120, 120, 920, 680}
  set viewOptions to icon view options of dmgWindow
  set arrangement of viewOptions to not arranged
  set icon size of viewOptions to 96
  set background picture of viewOptions to bgFile
  set position of item "$APP_NAME.app" of dmgFolder to {165, 255}
  set position of item "Applications" of dmgFolder to {595, 255}
  update dmgFolder without registering applications
  delay 2
  try
    close dmgWindow
  end try
end tell
APPLESCRIPT

sync
if [[ ! -f "$DMG_MOUNT/.DS_Store" ]]; then
  echo "Finder DMG styling did not create .DS_Store; refusing to ship an unstyled DMG." >&2
  exit 1
fi
if ! strings -a "$DMG_MOUNT/.DS_Store" | grep -q "backgroundImageAlias"; then
  echo "Finder DMG styling did not persist a background image; refusing to ship an unstyled DMG." >&2
  exit 1
fi
rm -rf "$DMG_MOUNT/.fseventsd" "$DMG_MOUNT/.Trashes" "$DMG_MOUNT/.TemporaryItems"
hdiutil detach "$DMG_MOUNT" >/dev/null
DMG_DEVICE=""
DMG_MOUNT=""

hdiutil convert \
  "$RW_DMG" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$RELEASE_DIR/$DMG_NAME" >/dev/null
rm -f "$RW_DMG"

hdiutil verify "$RELEASE_DIR/$DMG_NAME" >/dev/null

if notary_available; then
  notarize_artifact "$RELEASE_DIR/$DMG_NAME"
fi

cp "$RELEASE_DIR/$VERSIONED_ZIP" "$APPCAST_SOURCE_DIR/$VERSIONED_ZIP"
cp "$RELEASE_NOTES_FILE" "$APPCAST_SOURCE_DIR/${VERSIONED_ZIP%.zip}.md"

EXISTING_APPCAST="$RELEASE_DIR/appcast-existing.xml"
GENERATED_APPCAST="$RELEASE_DIR/appcast-generated.xml"
if [[ -f "$ROOT_DIR/appcast.xml" ]]; then
  cp "$ROOT_DIR/appcast.xml" "$EXISTING_APPCAST"
fi

"$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_appcast" \
  "${SPARKLE_SIGN_ARGS[@]}" \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  --embed-release-notes \
  --maximum-versions 5 \
  -o "$GENERATED_APPCAST" \
  "$APPCAST_SOURCE_DIR" >/dev/null

python3 - "$VERSION" "$GENERATED_APPCAST" "$EXISTING_APPCAST" "$ROOT_DIR/appcast.xml" <<'PY'
import re
import sys
from pathlib import Path

version, generated_path, existing_path, output_path = sys.argv[1:5]
generated = Path(generated_path).read_text(encoding="utf-8")
existing = Path(existing_path).read_text(encoding="utf-8") if Path(existing_path).exists() else ""

item_pattern = re.compile(r"\n        <item>.*?\n        </item>", re.S)
version_pattern = re.compile(r"<sparkle:shortVersionString>(.*?)</sparkle:shortVersionString>")

def item_version(item):
    match = version_pattern.search(item)
    return match.group(1) if match else None

generated_items = item_pattern.findall(generated)
current_items = [item for item in generated_items if item_version(item) == version]
if not current_items:
    raise SystemExit(f"generated appcast missing current version {version}")

existing_items = [
    item
    for item in item_pattern.findall(existing)
    if item_version(item) != version
]
merged_items = (current_items + existing_items)[:5]

first_match = item_pattern.search(generated)
if not first_match:
    raise SystemExit("generated appcast has no item block")

last_match = None
for match in item_pattern.finditer(generated):
    last_match = match
if last_match is None:
    raise SystemExit("generated appcast has no item block")

merged = generated[:first_match.start()] + "".join(merged_items) + generated[last_match.end():]
Path(output_path).write_text(merged, encoding="utf-8")
PY

cp "$ROOT_DIR/appcast.xml" "$RELEASE_DIR/appcast.xml"

UPDATE_SIGNATURE="$(python3 - "$ROOT_DIR/appcast.xml" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
match = re.search(r'sparkle:edSignature="([^"]+)"', text)
if not match:
    raise SystemExit("missing sparkle:edSignature in appcast")
print(match.group(1))
PY
)"
"$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin/sign_update" \
  --verify \
  "${SPARKLE_SIGN_ARGS[@]}" \
  "$RELEASE_DIR/$VERSIONED_ZIP" \
  "$UPDATE_SIGNATURE"

(
  cd "$RELEASE_DIR"
  shasum -a 256 "$DMG_NAME" "$VERSIONED_ZIP" "$LEGACY_ZIP" appcast.xml > "$CHECKSUM_FILE"
)

codesign --verify --deep --strict --verbose=2 "$APP_DIR" >/dev/null
spctl --assess --type execute -vv "$APP_DIR" >/dev/null 2>&1 || true

cat <<REPORT
Release build complete.
Version: $VERSION
Build: $BUILD
App: $APP_DIR
DMG: $RELEASE_DIR/$DMG_NAME
Zip: $RELEASE_DIR/$VERSIONED_ZIP
Compat zip: $RELEASE_DIR/$LEGACY_ZIP
Checksums: $RELEASE_DIR/$CHECKSUM_FILE
Appcast: $ROOT_DIR/appcast.xml
REPORT
