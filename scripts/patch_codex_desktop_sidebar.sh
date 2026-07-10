#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${CODEX_APP_PATH:-}"
BACKUP_ROOT="${CODEX_SIDEBAR_PATCH_BACKUP_ROOT:-$HOME/Library/Application Support/CodexTokenBar/codex-desktop-sidebar-patch/backups}"
ACTION="${1:-install}"

if [[ $# -gt 0 ]]; then
  shift
fi

OPEN_AFTER=1
QUIT_CODEX=1
DRY_RUN=0
ROLLBACK_BACKUP=""

usage() {
  cat <<'EOF'
Codex Desktop sidebar history patch

Usage:
  patch_codex_desktop_sidebar.sh install [options]
  patch_codex_desktop_sidebar.sh status [options]
  patch_codex_desktop_sidebar.sh rollback [options]

Options:
  --app PATH          Codex app path. Default: auto-detect by bundle identifier.
  --backup-root DIR  Backup root. Default: ~/Library/Application Support/CodexTokenBar/codex-desktop-sidebar-patch/backups
  --backup DIR       Roll back from a specific backup directory.
  --dry-run          Build and verify the patched ASAR without installing it.
  --no-quit          Do not ask the running Codex app to quit before install/rollback.
  --no-open          Do not reopen Codex after install/rollback.
  -h, --help         Show this help.

One-line install:
  curl -fsSL https://raw.githubusercontent.com/hututuo/codex-token-bar/main/scripts/patch_codex_desktop_sidebar.sh | bash -s -- install

One-line rollback:
  curl -fsSL https://raw.githubusercontent.com/hututuo/codex-token-bar/main/scripts/patch_codex_desktop_sidebar.sh | bash -s -- rollback
EOF
}

log() {
  printf '%s\n' "$*"
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      [[ $# -ge 2 ]] || fail "--app requires a path"
      APP_PATH="$2"
      shift 2
      ;;
    --backup-root)
      [[ $# -ge 2 ]] || fail "--backup-root requires a path"
      BACKUP_ROOT="$2"
      shift 2
      ;;
    --backup)
      [[ $# -ge 2 ]] || fail "--backup requires a path"
      ROLLBACK_BACKUP="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --no-quit)
      QUIT_CODEX=0
      shift
      ;;
    --no-open)
      OPEN_AFTER=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

case "$ACTION" in
  install|status|rollback|resolve-app) ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    fail "unknown action: $ACTION"
    ;;
esac

command -v python3 >/dev/null 2>&1 || fail "python3 is required"
command -v shasum >/dev/null 2>&1 || fail "shasum is required"
command -v plutil >/dev/null 2>&1 || fail "plutil is required"

validate_codex_app() {
  local candidate="$1" bundle_id
  [[ -d "$candidate" ]] || return 1
  [[ -f "$candidate/Contents/Info.plist" ]] || return 1
  [[ -f "$candidate/Contents/Resources/app.asar" ]] || return 1
  bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$candidate/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$bundle_id" == "com.openai.codex" ]]
}

discover_codex_app() {
  local candidate root

  if [[ "${CODEX_APP_MDFIND_DISABLE:-0}" != "1" ]] && command -v mdfind >/dev/null 2>&1; then
    while IFS= read -r candidate; do
      if validate_codex_app "$candidate"; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done < <(mdfind 'kMDItemCFBundleIdentifier == "com.openai.codex"' 2>/dev/null || true)
  fi

  if [[ -n "${CODEX_APP_DISCOVERY_ROOTS:-}" ]]; then
    while IFS= read -r root; do
      [[ -n "$root" ]] || continue
      while IFS= read -r candidate; do
        if validate_codex_app "$candidate"; then
          printf '%s\n' "$candidate"
          return 0
        fi
      done < <(find "$root" -mindepth 1 -maxdepth 1 -name '*.app' -print 2>/dev/null | LC_ALL=C sort)
    done < <(printf '%s\n' "$CODEX_APP_DISCOVERY_ROOTS" | tr ':' '\n')
  else
    for root in /Applications "$HOME/Applications"; do
      while IFS= read -r candidate; do
        if validate_codex_app "$candidate"; then
          printf '%s\n' "$candidate"
          return 0
        fi
      done < <(find "$root" -mindepth 1 -maxdepth 1 -name '*.app' -print 2>/dev/null | LC_ALL=C sort)
    done
  fi

  return 1
}

if [[ -n "$APP_PATH" ]]; then
  validate_codex_app "$APP_PATH" || fail "Codex app is invalid or missing required resources: $APP_PATH"
else
  APP_PATH="$(discover_codex_app)" || fail "Codex app was not found by bundle identifier in LaunchServices or the standard Applications folders. Use --app PATH or CODEX_APP_PATH."
fi

if [[ "$ACTION" == "resolve-app" ]]; then
  printf '%s\n' "$APP_PATH"
  exit 0
fi

ASAR_PATH="$APP_PATH/Contents/Resources/app.asar"
SIGNATURE_PATH="$APP_PATH/Contents/_CodeSignature"

[[ -d "$APP_PATH" ]] || fail "Codex app not found: $APP_PATH"
[[ -f "$ASAR_PATH" ]] || fail "app.asar not found: $ASAR_PATH"

quit_codex_if_needed() {
  local executable_name
  [[ "$QUIT_CODEX" == "1" ]] || return 0
  executable_name="$(plutil -extract CFBundleExecutable raw -o - "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
  if [[ -n "$executable_name" ]] && pgrep -x "$executable_name" >/dev/null 2>&1; then
    log "Quitting the Codex app so the patched renderer can be loaded cleanly..."
    osascript -e 'tell application id "com.openai.codex" to quit' >/dev/null 2>&1 || true
    sleep 2
  fi
}

open_codex_if_needed() {
  [[ "$OPEN_AFTER" == "1" ]] || return 0
  open -a "$APP_PATH" >/dev/null 2>&1 || open "$APP_PATH" >/dev/null 2>&1 || true
}

needs_sudo() {
  [[ -w "$ASAR_PATH" && -w "$APP_PATH/Contents" ]]
}

restore_backup_files() {
  local backup_dir="$1"
  if needs_sudo; then
    cp -p "$backup_dir/app.asar.before" "$ASAR_PATH"
    if [[ -d "$backup_dir/_CodeSignature.before" ]]; then
      rm -rf "$SIGNATURE_PATH"
      ditto "$backup_dir/_CodeSignature.before" "$SIGNATURE_PATH"
    fi
  else
    sudo cp -p "$backup_dir/app.asar.before" "$ASAR_PATH"
    if [[ -d "$backup_dir/_CodeSignature.before" ]]; then
      sudo rm -rf "$SIGNATURE_PATH"
      sudo ditto "$backup_dir/_CodeSignature.before" "$SIGNATURE_PATH"
    fi
  fi
}

make_backup_dir() {
  mkdir -p "$BACKUP_ROOT"
  local ts base candidate i
  ts="$(date +%Y%m%d-%H%M%S)"
  base="$BACKUP_ROOT/$ts"
  candidate="$base"
  i=2
  while [[ -e "$candidate" ]]; do
    candidate="${base}-${i}"
    i=$((i + 1))
  done
  mkdir -p "$candidate"
  printf '%s\n' "$candidate"
}

latest_backup_dir() {
  if [[ -n "$ROLLBACK_BACKUP" ]]; then
    printf '%s\n' "$ROLLBACK_BACKUP"
    return 0
  fi
  [[ -d "$BACKUP_ROOT" ]] || fail "backup root not found: $BACKUP_ROOT"
  local latest
  latest="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '*-*' -print | sort | tail -n 1)"
  [[ -n "$latest" ]] || fail "no backup found under $BACKUP_ROOT"
  printf '%s\n' "$latest"
}

asar_status_or_patch() {
  local mode="$1"
  local input="$2"
  local output="${3:-}"
  local manifest="${4:-}"
  python3 - "$mode" "$input" "$output" "$manifest" <<'PY'
import hashlib
import json
import os
import struct
import sys
from collections import OrderedDict

MODE, INPUT, OUTPUT, MANIFEST = sys.argv[1:5]

OLD_REFRESH = b"let t=await this.listRecentThreads({limit:50*this.recentConversationPageCount,cursor:null})"
NEW_REFRESH = b"let t={data:await this.listAllThreads({modelProviders:null,archived:!1}),nextCursor:null}"
OLD_MORE = b"let e=await this.listRecentThreads({limit:50,cursor:this.nextRecentConversationCursor})"
NEW_MORE = b"let e=await this.listRecentThreads({limit:500,cursor:this.nextRecentConversationCursor})"

def read_pickle_uint32(buf):
    if len(buf) < 8:
        raise ValueError("pickle is too short")
    payload_size = struct.unpack("<I", buf[0:4])[0]
    if payload_size < 4:
        raise ValueError("pickle payload is too small")
    return struct.unpack("<I", buf[4:8])[0]

def make_uint32_pickle(value):
    return struct.pack("<II", 4, value)

def align4(n):
    return (n + 3) & ~3

def make_string_pickle(text):
    raw = text.encode("utf-8")
    payload_len = align4(4 + len(raw))
    payload = bytearray(payload_len)
    struct.pack_into("<i", payload, 0, len(raw))
    payload[4:4 + len(raw)] = raw
    return struct.pack("<I", payload_len) + bytes(payload)

def read_asar(path):
    data = open(path, "rb").read()
    header_size = read_pickle_uint32(data[:8])
    header_pickle = data[8:8 + header_size]
    if len(header_pickle) != header_size:
        raise ValueError("truncated ASAR header")
    payload_size = struct.unpack("<I", header_pickle[0:4])[0]
    string_len = struct.unpack("<i", header_pickle[4:8])[0]
    if string_len < 0 or string_len > payload_size:
        raise ValueError("invalid ASAR header string length")
    header_text = header_pickle[8:8 + string_len].decode("utf-8")
    header = json.loads(header_text, object_pairs_hook=OrderedDict)
    return data, header, 8 + header_size

def iter_file_entries(node, prefix=""):
    for name, entry in node.get("files", OrderedDict()).items():
        path = f"{prefix}/{name}" if prefix else name
        if "files" in entry:
            yield from iter_file_entries(entry, path)
        elif "size" in entry and not entry.get("unpacked"):
            yield path, entry

def read_entry(data, data_start, entry):
    offset = int(entry.get("offset", "0"))
    size = int(entry.get("size", 0))
    start = data_start + offset
    end = start + size
    if start < 0 or end > len(data):
        raise ValueError("file entry points outside ASAR data")
    return data[start:end]

def update_integrity(entry, content):
    integrity = entry.get("integrity")
    if not isinstance(integrity, dict):
        return
    block_size = int(integrity.get("blockSize") or 4194304)
    blocks = []
    for i in range(0, len(content), block_size):
        blocks.append(hashlib.sha256(content[i:i + block_size]).hexdigest())
    if not blocks:
        blocks.append(hashlib.sha256(b"").hexdigest())
    integrity["algorithm"] = "SHA256"
    integrity["hash"] = hashlib.sha256(content).hexdigest()
    integrity["blockSize"] = block_size
    integrity["blocks"] = blocks

def inspect(data, header, data_start):
    old_paths = []
    new_paths = []
    old_more_paths = []
    new_more_paths = []
    for path, entry in iter_file_entries(header):
        if not path.endswith(".js"):
            continue
        content = read_entry(data, data_start, entry)
        if OLD_REFRESH in content:
            old_paths.append(path)
        if NEW_REFRESH in content:
            new_paths.append(path)
        if OLD_MORE in content:
            old_more_paths.append(path)
        if NEW_MORE in content:
            new_more_paths.append(path)
    if len(old_paths) == 1:
        state = "unpatched"
        target = old_paths[0]
    elif len(old_paths) == 0 and len(new_paths) >= 1:
        state = "patched"
        target = new_paths[0]
    else:
        state = "unknown"
        target = old_paths[0] if old_paths else (new_paths[0] if new_paths else "")
    return {
        "state": state,
        "target": target,
        "oldRefreshMatches": old_paths,
        "newRefreshMatches": new_paths,
        "oldLoadMoreMatches": old_more_paths,
        "newLoadMoreMatches": new_more_paths,
    }

def patch(data, header, data_start, info):
    target = info["target"]
    if not target:
        raise RuntimeError("could not find target JS bundle")
    replacements = {}
    for path, entry in iter_file_entries(header):
        if path != target:
            continue
        content = read_entry(data, data_start, entry)
        if content.count(OLD_REFRESH) != 1 or content.count(OLD_MORE) != 1:
            raise RuntimeError("target JS does not contain the expected patch points exactly once")
        content = content.replace(OLD_REFRESH, NEW_REFRESH).replace(OLD_MORE, NEW_MORE)
        replacements[path] = content
        break
    if target not in replacements:
        raise RuntimeError("target JS entry not found while patching")

    chunks = []
    cursor = 0
    for path, entry in iter_file_entries(header):
        content = replacements.get(path)
        if content is None:
            content = read_entry(data, data_start, entry)
        entry["size"] = len(content)
        entry["offset"] = str(cursor)
        update_integrity(entry, content)
        chunks.append(content)
        cursor += len(content)

    header_text = json.dumps(header, ensure_ascii=False, separators=(",", ":"))
    header_pickle = make_string_pickle(header_text)
    size_pickle = make_uint32_pickle(len(header_pickle))
    return size_pickle + header_pickle + b"".join(chunks)

data, header, data_start = read_asar(INPUT)
info = inspect(data, header, data_start)
info["input"] = INPUT
info["inputSha256"] = hashlib.sha256(data).hexdigest()

if MODE == "status":
    print(json.dumps(info, ensure_ascii=False, indent=2))
    if MANIFEST:
        with open(MANIFEST, "w", encoding="utf-8") as f:
            json.dump(info, f, ensure_ascii=False, indent=2)
    sys.exit(0)

if MODE != "patch":
    raise RuntimeError(f"unknown mode: {MODE}")

if info["state"] == "patched":
    info["message"] = "already patched"
    print(json.dumps(info, ensure_ascii=False, indent=2))
    if MANIFEST:
        with open(MANIFEST, "w", encoding="utf-8") as f:
            json.dump(info, f, ensure_ascii=False, indent=2)
    sys.exit(0)

if info["state"] != "unpatched":
    raise RuntimeError("ASAR does not look like a supported Codex Desktop bundle")

patched = patch(data, header, data_start, info)
info["state"] = "patched-output-created"
info["output"] = OUTPUT
info["outputSha256"] = hashlib.sha256(patched).hexdigest()
info["outputSize"] = len(patched)

if not OUTPUT:
    raise RuntimeError("patch output path is required")
with open(OUTPUT, "wb") as f:
    f.write(patched)
if MANIFEST:
    with open(MANIFEST, "w", encoding="utf-8") as f:
        json.dump(info, f, ensure_ascii=False, indent=2)
print(json.dumps(info, ensure_ascii=False, indent=2))
PY
}

case "$ACTION" in
  status)
    asar_status_or_patch status "$ASAR_PATH" "" ""
    ;;

  install)
    workdir="$(mktemp -d "${TMPDIR:-/tmp}/codex-sidebar-patch.XXXXXX")"
    patched_asar="$workdir/app.asar.patched"
    patch_manifest="$workdir/patch-manifest.json"

    log "Inspecting $ASAR_PATH..."
    patch_output="$(asar_status_or_patch patch "$ASAR_PATH" "$patched_asar" "$patch_manifest")"
    printf '%s\n' "$patch_output"

    if grep -q '"state": "patched"' "$patch_manifest" 2>/dev/null; then
      log "Codex Desktop already appears to be patched. Nothing to install."
      rm -rf "$workdir"
      exit 0
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
      log "Dry run complete. Patched ASAR was built at: $patched_asar"
      log "No files were changed."
      exit 0
    fi

    backup_dir="$(make_backup_dir)"
    log "Creating backup: $backup_dir"
    cp -p "$ASAR_PATH" "$backup_dir/app.asar.before"
    if [[ -d "$SIGNATURE_PATH" ]]; then
      ditto "$SIGNATURE_PATH" "$backup_dir/_CodeSignature.before"
    fi
    /usr/libexec/PlistBuddy -c 'Print' "$APP_PATH/Contents/Info.plist" > "$backup_dir/Info.plist.before.txt" 2>/dev/null || true
    shasum -a 256 "$ASAR_PATH" "$patched_asar" > "$backup_dir/checksums.before-after.txt"
    cp "$patch_manifest" "$backup_dir/patch-manifest.json"

    cat > "$backup_dir/README.md" <<EOF
# Codex Desktop Sidebar Patch Backup

App: $APP_PATH
Created: $(date '+%Y-%m-%d %H:%M:%S %z')

This backup was created before replacing:

\`$ASAR_PATH\`

Rollback:

\`\`\`bash
curl -fsSL https://raw.githubusercontent.com/hututuo/codex-token-bar/main/scripts/patch_codex_desktop_sidebar.sh | bash -s -- rollback --backup "$backup_dir"
\`\`\`

Manual rollback:

\`\`\`bash
osascript -e 'tell application id "com.openai.codex" to quit'
sleep 2
cp -p "$backup_dir/app.asar.before" "$ASAR_PATH"
rm -rf "$SIGNATURE_PATH"
ditto "$backup_dir/_CodeSignature.before" "$SIGNATURE_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
open -a "$APP_PATH"
\`\`\`
EOF

    quit_codex_if_needed

    set +e
    if needs_sudo; then
      cp -p "$patched_asar" "$ASAR_PATH"
      copy_status=$?
      if [[ "$copy_status" -eq 0 ]]; then
        codesign --force --sign - "$APP_PATH" > "$backup_dir/codesign.resign.txt" 2>&1
        sign_status=$?
      else
        sign_status=1
      fi
    else
      log "Writing to $APP_PATH requires administrator privileges."
      sudo cp -p "$patched_asar" "$ASAR_PATH"
      copy_status=$?
      if [[ "$copy_status" -eq 0 ]]; then
        sudo codesign --force --sign - "$APP_PATH" > "$backup_dir/codesign.resign.txt" 2>&1
        sign_status=$?
      else
        sign_status=1
      fi
    fi
    set -e

    if [[ "$copy_status" -ne 0 || "$sign_status" -ne 0 ]]; then
      log "Install failed; restoring the backup created for this run..."
      restore_backup_files "$backup_dir" || true
      fail "failed to install or re-sign the Codex app. Backup: $backup_dir"
    fi

    codesign --verify --deep --strict --verbose=2 "$APP_PATH" > "$backup_dir/codesign.verify.after.txt" 2>&1
    shasum -a 256 "$ASAR_PATH" > "$backup_dir/checksum.installed.txt"
    log "Patch installed."
    log "Backup: $backup_dir"
    log "Codex must be restarted to load the patched renderer."
    open_codex_if_needed
    ;;

  rollback)
    backup_dir="$(latest_backup_dir)"
    [[ -f "$backup_dir/app.asar.before" ]] || fail "backup is missing app.asar.before: $backup_dir"
    log "Rolling back from: $backup_dir"

    if [[ "$DRY_RUN" == "1" ]]; then
      log "Dry run only. No files were changed."
      exit 0
    fi

    quit_codex_if_needed

    if [[ -d "$backup_dir/_CodeSignature.before" ]]; then
      restore_backup_files "$backup_dir"
    elif needs_sudo; then
      cp -p "$backup_dir/app.asar.before" "$ASAR_PATH"
      codesign --force --sign - "$APP_PATH"
    else
      log "Writing to $APP_PATH requires administrator privileges."
      sudo cp -p "$backup_dir/app.asar.before" "$ASAR_PATH"
      sudo codesign --force --sign - "$APP_PATH"
    fi

    codesign --verify --deep --strict --verbose=2 "$APP_PATH"
    log "Rollback complete."
    open_codex_if_needed
    ;;
esac
