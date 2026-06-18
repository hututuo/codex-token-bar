# Codex Token Bar Tauri App

This directory is the next-generation cross-platform app candidate.

Current scope:

- Tauri v2 desktop shell.
- React + TypeScript dashboard UI.
- Rust command boundary matching the migration plan.
- Mock dashboard, quota, live-rate, floating-panel, and provider-repair data.

The SwiftUI app in the repository root remains the release baseline during migration.
Do not remove or rewrite the SwiftUI app until the Tauri version has passed the
feature, data, visual, and performance comparison gates in the migration plan.

Useful commands:

```bash
npm install
npm run build
cd src-tauri && cargo check
```
