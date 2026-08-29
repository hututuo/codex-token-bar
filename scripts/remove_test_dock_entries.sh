#!/usr/bin/env bash
set -euo pipefail

# Local previews must not become persistent Dock applications.  Keep the
# installed /Applications release entry (if the user pinned it), and remove
# every other Codex Token Bar tile from the Dock's persistent-apps list.
#
# The Dock stores this list as opaque CFPreferences data, so export/import is
# used instead of trying to reconstruct nested bookmark records with `defaults
# write`.  The exported domain is changed only when one of our own app tiles
# is found; unrelated Dock applications and stacks remain byte-for-byte in
# the snapshot we import.

if [[ "$(uname -s)" != "Darwin" ]]; then
  exit 0
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-token-bar-dock.XXXXXX")"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

INPUT="$TMP_DIR/dock.plist"
OUTPUT="$TMP_DIR/dock-filtered.plist"

/usr/bin/defaults export com.apple.dock "$INPUT" >/dev/null

REMOVED_COUNT="$(/usr/bin/python3 - "$INPUT" "$OUTPUT" <<'PY'
import os
import plistlib
import sys
from urllib.parse import unquote, urlparse

input_path, output_path = sys.argv[1:]
with open(input_path, "rb") as handle:
    payload = plistlib.load(handle)

apps = payload.get("persistent-apps")
if not isinstance(apps, list):
    raise SystemExit("persistent-apps is not an array; refusing Dock rewrite")

owned_bundle_ids = {"local.codex.token-bar", "local.codex.token-bar.tauri"}
release_path = os.path.normpath("/Applications/Codex Token Bar.app")
kept = []
removed = []

for entry in apps:
    if not isinstance(entry, dict):
        raise SystemExit("persistent-apps contains a non-dictionary tile; refusing Dock rewrite")
    tile_data = entry.get("tile-data")
    if not isinstance(tile_data, dict):
        kept.append(entry)
        continue
    bundle_id = tile_data.get("bundle-identifier")
    if bundle_id not in owned_bundle_ids:
        kept.append(entry)
        continue
    file_data = tile_data.get("file-data")
    raw_url = file_data.get("_CFURLString") if isinstance(file_data, dict) else None
    if not isinstance(raw_url, str) or not raw_url.startswith("file:"):
        raise SystemExit("owned Dock tile has no stable file URL; refusing Dock rewrite")
    path = os.path.normpath(unquote(urlparse(raw_url).path))
    if path == release_path:
        kept.append(entry)
    else:
        removed.append(path)

if removed:
    payload["persistent-apps"] = kept
    with open(output_path, "wb") as handle:
        plistlib.dump(payload, handle, fmt=plistlib.FMT_BINARY, sort_keys=False)

for path in removed:
    print(path)
print(f"__REMOVED_COUNT__={len(removed)}")
PY
)"

COUNT="$(printf '%s\n' "$REMOVED_COUNT" | awk -F= '/^__REMOVED_COUNT__=/ {print $2; exit}')"
if [[ -z "$COUNT" ]]; then
  echo "Dock cleanup failed closed: no removal count" >&2
  exit 1
fi

if [[ "$COUNT" != "0" ]]; then
  /usr/bin/defaults import com.apple.dock "$OUTPUT"
  /usr/bin/killall Dock >/dev/null 2>&1 || true
  echo "Removed $COUNT test Codex Token Bar Dock entr$( [[ "$COUNT" == "1" ]] && printf 'y' || printf 'ies' )."
else
  echo "No test Codex Token Bar Dock entries found."
fi
