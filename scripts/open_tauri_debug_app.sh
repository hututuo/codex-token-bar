#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAURI_DIR="$ROOT_DIR/tauri-app"
BUILT_APP_PATH="$TAURI_DIR/src-tauri/target/debug/bundle/macos/Codex Token Bar.app"
RUN_APP_PATH="$TAURI_DIR/src-tauri/target/debug/run-bundle/Codex Token Bar.app"
RUN_APP_BINARY="$RUN_APP_PATH/Contents/MacOS/codex-token-bar"
BUILT_APP_BINARY="$BUILT_APP_PATH/Contents/MacOS/codex-token-bar"
PROCESS_PATTERN="$RUN_APP_BINARY"
LEGACY_PROCESS_PATTERN="$BUILT_APP_BINARY"
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
  # Only stop this project's runnable debug copy, not installed release builds.
  /usr/bin/pkill -f "$PROCESS_PATTERN" >/dev/null 2>&1 || true
}

stop_legacy_built_app() {
  # Older versions opened Tauri's build output directly. Stop that instance
  # before rebuilding so the bundler never overwrites a live app bundle.
  /usr/bin/pkill -f "$LEGACY_PROCESS_PATTERN" >/dev/null 2>&1 || true
}

stage_runnable_app() {
  if [[ ! -x "$BUILT_APP_BINARY" ]]; then
    echo "Debug app is missing. Run with --build first: $BUILT_APP_PATH" >&2
    exit 1
  fi

  local run_parent
  local staged_path
  run_parent="$(dirname "$RUN_APP_PATH")"
  staged_path="$RUN_APP_PATH.next"
  /bin/mkdir -p "$run_parent"
  /bin/rm -rf "$staged_path"
  /usr/bin/ditto "$BUILT_APP_PATH" "$staged_path"

  stop_existing_debug_app
  /bin/rm -rf "$RUN_APP_PATH"
  /bin/mv "$staged_path" "$RUN_APP_PATH"
}

if [[ "$BUILD_FIRST" == "1" ]]; then
  stop_legacy_built_app
  (cd "$TAURI_DIR" && npm run tauri -- build --debug --bundles app)
  stage_runnable_app
elif [[ ! -x "$RUN_APP_BINARY" ]]; then
  stage_runnable_app
fi

if [[ ! -x "$RUN_APP_BINARY" ]]; then
  echo "Runnable debug app is missing: $RUN_APP_PATH" >&2
  exit 1
fi

stop_existing_debug_app

if ! /usr/bin/codesign --verify --deep --strict --verbose=2 "$RUN_APP_PATH" >/dev/null 2>&1; then
  echo "Debug app signature is not valid; repairing with ad-hoc signing." >&2
  /usr/bin/codesign --force --deep --sign - "$RUN_APP_PATH"
fi

/usr/bin/open -n "$RUN_APP_PATH"

opened_pid=""
for _ in $(seq 1 120); do
  pid="$(/usr/bin/pgrep -f "$PROCESS_PATTERN" | head -n 1 || true)"
  if [[ -n "$pid" ]]; then
    opened_pid="$pid"
    break
  fi
  /bin/sleep 0.1
done

if [[ -n "$opened_pid" ]]; then
  /bin/sleep 1
  if /bin/kill -0 "$opened_pid" >/dev/null 2>&1; then
    echo "Opened Codex Token Bar Tauri debug app."
    echo "App: $RUN_APP_PATH"
    echo "PID: $opened_pid"
    exit 0
  fi
  echo "Tauri debug app appeared and then exited quickly: $RUN_APP_PATH" >&2
  exit 1
fi

echo "Tauri debug app did not appear after opening: $RUN_APP_PATH" >&2
exit 1
