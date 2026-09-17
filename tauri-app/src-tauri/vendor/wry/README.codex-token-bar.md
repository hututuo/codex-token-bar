# Codex Token Bar Wry patch

This directory vendors the exact published `wry 0.55.1` crate used by Tauri.
The original source remains licensed under Apache-2.0 OR MIT; both upstream
license files are retained in this directory.

Codex Token Bar carries narrowly scoped Windows patches in
`src/webview2/mod.rs`:

- On `aarch64-pc-windows-msvc`, WebView2 environment, controller, and cookie
  completion waits use `CoWaitForMultipleHandles` with
  `COWAIT_DISPATCH_CALLS | COWAIT_DISPATCH_WINDOW_MESSAGES`.
- x86/x64 retain Wry 0.55.1's original `mpsc` plus `wait_with_pump` behavior.
- The event handle is owned by an RAII guard so early errors do not leak it.

The desktop floating dock also carries a per-window WebView2 resize gate:

- While Codex Token Bar clips its floating outer HWND to an edge handle, the
  app sets the `CodexTokenBar::PinnedWebViewViewport` HWND property.
- Wry's parent `WM_SIZE` hook skips its automatic `SetBounds`/child resize only
  while that property is present. This prevents the otherwise unavoidable
  full-width -> 12px -> full-width browser reflow during dock collapse/reveal.
- The property is scoped to the floating HWND and is removed again at the full
  expanded frame; every other Wry window keeps the upstream resize path.

The root cause and initial approach were reported in upstream Wry issue
`tauri-apps/wry#1665` and pull request `tauri-apps/wry#1666` (commit
`efbd29926b1b52f84cac629c6a3deca18a480508`). That pull request targeted Wry
0.54.1 and remains unmerged, so its code was not copied wholesale. This patch
was independently adapted to 0.55.1, limited to ARM64, and is gated by this
project's own dual-architecture compile and Windows runtime tests.

Remove the `[patch.crates-io]` entry from the application's `Cargo.toml` when an
upstream Wry release contains an equivalent verified fix.
