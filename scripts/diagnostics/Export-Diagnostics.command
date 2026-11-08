#!/bin/bash
# This shipped helper needs neither the main UI nor a developer toolchain.
set -u
DIAGNOSTIC_DIR="$(cd "$(dirname "$0")" && pwd)"
for helper in "$DIAGNOSTIC_DIR/TokenBarDiagnostics" \
  "$DIAGNOSTIC_DIR/../MacOS/TokenBarDiagnostics" \
  "/Applications/Codex Token Bar.app/Contents/MacOS/TokenBarDiagnostics" \
  "$HOME/Applications/Codex Token Bar.app/Contents/MacOS/TokenBarDiagnostics"; do
  if [[ -x "$helper" ]]; then
    exec "$helper" --export-diagnostics "$@"
  fi
done
printf '%s\n' '未找到诊断工具。请从官方安装包复制 TokenBarDiagnostics 到此脚本旁，再次打开。' \
  'Diagnostic helper missing. Copy TokenBarDiagnostics from the official installer beside this script.'
exit 1
