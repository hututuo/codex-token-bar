#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAURI_DIR="$ROOT_DIR/tauri-app"
BUILT_APP_PATH="$TAURI_DIR/src-tauri/target/debug/bundle/macos/Codex Token Bar.app"
RUN_ROOT="$TAURI_DIR/src-tauri/target/debug/run-bundle"
RUN_APP_NAME="Codex Token Bar.app"
LATEST_RUN_LINK="$RUN_ROOT/latest"
LEGACY_RUN_APP_PATH="$RUN_ROOT/$RUN_APP_NAME"
BUILT_APP_BINARY="$BUILT_APP_PATH/Contents/MacOS/codex-token-bar"
LEGACY_PROCESS_PATTERN="$BUILT_APP_BINARY"
TRACE_LOG="$HOME/Library/Application Support/CodexTokenBarTauri/startup-trace.log"
BUILD_FIRST=0

usage() {
  cat <<'USAGE'
Usage: scripts/open_tauri_debug_app.sh [--build]

Builds and/or opens the local Tauri debug .app for visual testing.

Options:
  --build   Build the debug app without release updater artifacts, then open it.
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

debug_app_pids() {
  /usr/bin/pgrep -f "$TAURI_DIR/src-tauri/target/debug/.*/Codex Token Bar.app/Contents/MacOS/codex-token-bar" 2>/dev/null || true
}

stop_other_debug_apps() {
  local keep_pid="${1:-}"
  local pid
  for pid in $(debug_app_pids); do
    if [[ -n "$keep_pid" && "$pid" == "$keep_pid" ]]; then
      continue
    fi
    /bin/kill "$pid" >/dev/null 2>&1 || true
  done
}

wait_for_debug_apps_to_stop() {
  local remaining
  local i
  for i in $(seq 1 50); do
    remaining="$(debug_app_pids)"
    if [[ -z "$remaining" ]]; then
      return 0
    fi
    /bin/sleep 0.1
  done

  remaining="$(debug_app_pids)"
  if [[ -n "$remaining" ]]; then
    echo "Warning: stale Tauri debug app processes are still exiting: $remaining" >&2
  fi
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

  local staged_path
  local launch_dir
  launch_dir="$RUN_ROOT/launch-$(/bin/date +%Y%m%d-%H%M%S)-$$"
  staged_path="$launch_dir.next"
  /bin/mkdir -p "$RUN_ROOT"
  /bin/rm -rf "$staged_path"
  /bin/mkdir -p "$staged_path"
  /usr/bin/ditto "$BUILT_APP_PATH" "$staged_path/$RUN_APP_NAME"
  /bin/mv "$staged_path" "$launch_dir"
  /bin/ln -sfn "$launch_dir" "$LATEST_RUN_LINK"

  echo "$launch_dir/$RUN_APP_NAME"
}

latest_runnable_app() {
  if [[ -x "$LATEST_RUN_LINK/$RUN_APP_NAME/Contents/MacOS/codex-token-bar" ]]; then
    local latest_dir
    latest_dir="$(cd "$LATEST_RUN_LINK" && /bin/pwd -P)"
    echo "$latest_dir/$RUN_APP_NAME"
    return 0
  fi

  local newest
  newest="$(/bin/ls -td "$RUN_ROOT"/launch-*/"$RUN_APP_NAME" 2>/dev/null | head -n 1 || true)"
  if [[ -n "$newest" && -x "$newest/Contents/MacOS/codex-token-bar" ]]; then
    /bin/ln -sfn "$(dirname "$newest")" "$LATEST_RUN_LINK"
    echo "$newest"
    return 0
  fi

  if [[ -x "$LEGACY_RUN_APP_PATH/Contents/MacOS/codex-token-bar" ]]; then
    echo "$LEGACY_RUN_APP_PATH"
    return 0
  fi

  return 1
}

fresh_or_latest_runnable_app() {
  if [[ -x "$BUILT_APP_BINARY" ]]; then
    stage_runnable_app
    return 0
  fi

  latest_runnable_app
}

pid_list_contains() {
  local needle="$1"
  local haystack="$2"
  local pid
  for pid in $haystack; do
    if [[ "$pid" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

wait_for_dashboard_visible() {
  local pid="$1"
  local visible=0
  local i
  for i in $(seq 1 80); do
    if ! /bin/kill -0 "$pid" >/dev/null 2>&1; then
      return 1
    fi
    if [[ -f "$TRACE_LOG" ]] && /usr/bin/grep -q "frontend dashboard summary ui ready" "$TRACE_LOG"; then
      visible=1
      break
    fi
    /bin/sleep 0.1
  done

  [[ "$visible" == "1" ]]
}

cleanup_old_run_bundles() {
  local active_dir
  active_dir="$(cd "$(dirname "$RUN_APP_PATH")" && pwd -P)"
  /bin/ls -td "$RUN_ROOT"/launch-* 2>/dev/null | while IFS= read -r dir; do
    if [[ "$(cd "$dir" && pwd -P)" == "$active_dir" ]]; then
      continue
    fi
    /bin/rm -rf "$dir"
  done
  if [[ -d "$LEGACY_RUN_APP_PATH" ]]; then
    /bin/rm -rf "$LEGACY_RUN_APP_PATH"
  fi
}

if [[ "$BUILD_FIRST" == "1" ]]; then
  stop_other_debug_apps
  wait_for_debug_apps_to_stop
  stop_legacy_built_app
  (cd "$TAURI_DIR" && npm run tauri -- build --debug --bundles app \
    --config '{"bundle":{"createUpdaterArtifacts":false}}')
  RUN_APP_PATH="$(stage_runnable_app)"
else
  stop_other_debug_apps
  wait_for_debug_apps_to_stop
  if ! RUN_APP_PATH="$(fresh_or_latest_runnable_app)"; then
    RUN_APP_PATH="$(stage_runnable_app)"
  fi
fi

if [[ -z "${RUN_APP_PATH:-}" ]]; then
  RUN_APP_PATH="$(stage_runnable_app)"
fi

RUN_APP_BINARY="$RUN_APP_PATH/Contents/MacOS/codex-token-bar"

if [[ ! -x "$RUN_APP_BINARY" ]]; then
  echo "Runnable debug app is missing: $RUN_APP_PATH" >&2
  exit 1
fi

if ! /usr/bin/codesign --verify --deep --strict --verbose=2 "$RUN_APP_PATH" >/dev/null 2>&1; then
  echo "Debug app signature is not valid; repairing with ad-hoc signing." >&2
  /usr/bin/codesign --force --deep --sign - "$RUN_APP_PATH"
fi

existing_pids="$(/usr/bin/pgrep -f "$RUN_APP_BINARY" 2>/dev/null || true)"
/bin/rm -f "$TRACE_LOG"
/usr/bin/env -u CODEX_HOME -u CODEX_SQLITE_HOME /usr/bin/open -n "$RUN_APP_PATH"

opened_pid=""
for _ in $(seq 1 120); do
  for pid in $(/usr/bin/pgrep -f "$RUN_APP_BINARY" 2>/dev/null || true); do
    if ! pid_list_contains "$pid" "$existing_pids"; then
      opened_pid="$pid"
      break 2
    fi
  done
  /bin/sleep 0.1
done

if [[ -n "$opened_pid" ]]; then
  if wait_for_dashboard_visible "$opened_pid"; then
    stop_other_debug_apps "$opened_pid"
    cleanup_old_run_bundles
    echo "Opened Codex Token Bar Tauri debug app."
    echo "App: $RUN_APP_PATH"
    echo "PID: $opened_pid"
    exit 0
  fi
  echo "Tauri debug app did not reach the dashboard-visible checkpoint: $RUN_APP_PATH" >&2
  exit 1
fi

echo "Tauri debug app did not appear after opening: $RUN_APP_PATH" >&2
exit 1
