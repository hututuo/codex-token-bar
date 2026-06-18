#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAURI_DIR="$ROOT_DIR/tauri-app"
APP_PATH="$TAURI_DIR/src-tauri/target/debug/bundle/macos/Codex Token Bar.app"
APP_BINARY="$APP_PATH/Contents/MacOS/codex-token-bar"
PROCESS_PATTERN="$APP_BINARY"
BUILD_FIRST=0

usage() {
  cat <<'USAGE'
Usage: scripts/open_tauri_debug_app.sh [--build]

Builds and/or opens the local Tauri debug .app for visual testing.

Options:
  --build   Run `npm run tauri -- build --debug --bundles app` before opening.
USAGE
}

while (($# > 0)); do
  case "$1" in
    --build)
      BUILD_FIRST=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

stop_existing_debug_app() {
  # Only stop this project's debug bundle, not installed release builds.
  /usr/bin/pkill -f "$PROCESS_PATTERN" >/dev/null 2>&1 || true
}

if [[ "$BUILD_FIRST" == "1" ]]; then
  # Keep the previous app visible while the new bundle is being compiled. The
  # handoff happens after a successful build so visual testing does not look
  # like a slow gray startup or a window that briefly appears and gets killed.
  (cd "$TAURI_DIR" && npm run tauri -- build --debug --bundles app)
fi

if [[ ! -x "$APP_BINARY" ]]; then
  echo "Debug app is missing. Run with --build first: $APP_PATH" >&2
  exit 1
fi

stop_existing_debug_app

if ! /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH" >/dev/null 2>&1; then
  echo "Debug app signature is not valid; repairing with ad-hoc signing." >&2
  /usr/bin/codesign --force --deep --sign - "$APP_PATH"
fi

/usr/bin/open -n "$APP_PATH"

for _ in $(seq 1 120); do
  pid="$(/usr/bin/pgrep -f "$PROCESS_PATTERN" | head -n 1 || true)"
  if [[ -n "$pid" ]]; then
    echo "Opened Codex Token Bar Tauri debug app."
    echo "App: $APP_PATH"
    echo "PID: $pid"
    exit 0
  fi
  /bin/sleep 0.1
done

echo "Tauri debug app did not appear after opening: $APP_PATH" >&2
exit 1
