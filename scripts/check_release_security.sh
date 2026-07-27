#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Codex Token Bar"
APP_DIR="${APP_DIR:-$ROOT_DIR/dist/$APP_NAME.app}"
DMG_PATH="${1:-${DMG_PATH:-}}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-${CODESIGN_IDENTITY:--}}"
APPLE_NOTARY_PROFILE="${APPLE_NOTARY_PROFILE:-}"
APPLE_ID="${APPLE_ID:-}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"
APPLE_APP_SPECIFIC_PASSWORD="${APPLE_APP_SPECIFIC_PASSWORD:-}"
failures=0

status_line() {
  local state="$1"
  local text="$2"
  printf '%-8s %s\n' "[$state]" "$text"
  if [[ "$state" == "FAIL" ]]; then
    failures=$((failures + 1))
  fi
}

notary_configured() {
  if [[ -n "$APPLE_NOTARY_PROFILE" ]]; then
    return 0
  fi
  [[ -n "$APPLE_ID" && -n "$APPLE_TEAM_ID" && -n "$APPLE_APP_SPECIFIC_PASSWORD" ]]
}

cd "$ROOT_DIR"

echo "Codex Token Bar release security preflight"
echo "App: $APP_DIR"
if [[ -n "$DMG_PATH" ]]; then
  echo "DMG: $DMG_PATH"
fi
echo

if [[ "$CODE_SIGN_IDENTITY" == "-" ]]; then
  status_line "WARN" "CODE_SIGN_IDENTITY is ad-hoc (-); Gatekeeper will still show an unidentified developer flow."
else
  if security find-identity -v -p codesigning | grep -F -- "$CODE_SIGN_IDENTITY" >/dev/null; then
    status_line "OK" "Developer signing identity is available: $CODE_SIGN_IDENTITY"
  else
    status_line "FAIL" "Developer signing identity is missing or untrusted: $CODE_SIGN_IDENTITY"
  fi
fi

if [[ -d "$APP_DIR" ]]; then
  if codesign --verify --deep --strict --verbose=2 "$APP_DIR" >/dev/null 2>&1; then
    status_line "OK" "App code signature verifies."
  else
    status_line "FAIL" "App code signature verification failed."
  fi

  if codesign -dvv "$APP_DIR" 2>&1 | grep -F 'Runtime Version=' >/dev/null; then
    status_line "OK" "Hardened Runtime is enabled on the app signature."
  else
    status_line "WARN" "Hardened Runtime is not present. Use ENABLE_HARDENED_RUNTIME=1 with a Developer ID identity."
  fi

  if codesign -d --entitlements :- "$APP_DIR" 2>/dev/null | plutil -p - >/dev/null 2>&1; then
    status_line "OK" "Entitlements are readable."
  else
    status_line "WARN" "Entitlements could not be read from the app signature."
  fi
else
  status_line "WARN" "App bundle does not exist yet. Run scripts/package_app.sh or scripts/build_release.sh first."
fi

if notary_configured; then
  status_line "OK" "Apple notarization credentials are configured."
else
  status_line "WARN" "Apple notarization credentials are not configured."
fi

if [[ -n "$DMG_PATH" ]]; then
  if [[ -f "$DMG_PATH" ]]; then
    if xcrun stapler validate "$DMG_PATH" >/dev/null 2>&1; then
      status_line "OK" "DMG has a valid notarization staple."
    else
      status_line "WARN" "DMG has no valid notarization staple."
    fi
  else
    status_line "FAIL" "DMG file does not exist: $DMG_PATH"
  fi
fi

if (( failures > 0 )); then
  printf '\nRelease security preflight failed with %d blocking finding(s).\n' "$failures" >&2
  exit 1
fi
