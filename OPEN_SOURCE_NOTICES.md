# Open Source Notices

## Codex Token Bar original code

The original Codex Token Bar code was made available under the MIT License:

- Copyright (c) 2026 hututuo
- Full preserved text: `LICENSES/CodexTokenBar-MIT.txt`

## Codex++ session enhancements

The session-enhancement implementation includes modified and adapted portions
of the following project:

- Project: Codex++ / CodexPlusPlus
- Upstream: https://github.com/BigPizzaV3/CodexPlusPlus
- Upstream version: v1.2.41
- Source commit: `3dafffcafb2566a1e8bce4b35671656d6adb3eda`
- Upstream license: GNU Affero General Public License version 3
- Primary upstream files studied or adapted:
  - `assets/inject/renderer-inject.js`
  - `crates/codex-plus-data/src/markdown.rs`
  - `crates/codex-plus-data/src/storage.rs`

Codex Token Bar modifies this work to use native local CDP bridges in both the
Swift and Tauri/Rust implementations, its existing official
`codex delete --force` deletion path, its own settings UI, local rollout
validation, atomic file replacement, and current Codex Desktop selectors.
The adapted capabilities cover Markdown export, project movement, plain-text
paste handling, thread-ID badges, centered conversation width, and per-thread
scroll restoration. The Rust implementation streams Markdown reads and uses a
SQLite transaction plus an atomic rollout replacement and rollback copy for
project movement.

The combined work on this branch is distributed under GNU AGPL version 3.
The complete corresponding source is the source tree containing this notice.
The root `LICENSE` contains the full AGPL-3.0 text.

## Wry Windows ARM64 WebView2 compatibility patch

The Tauri application vendors and modifies the published `wry` crate:

- Project: Wry
- Upstream: https://github.com/tauri-apps/wry
- Vendored version: 0.55.1
- Upstream license: Apache License 2.0 OR MIT License
- Vendored source: `tauri-app/src-tauri/vendor/wry`
- Modified file: `tauri-app/src-tauri/vendor/wry/src/webview2/mod.rs`

The modification replaces Wry's nested Windows message-pump wait with a
COM-dispatching completion wait only on Windows ARM64. The issue and initial
approach were documented in upstream issue `tauri-apps/wry#1665` and pull
request `tauri-apps/wry#1666`; that pull request targeted an older Wry version
and remains unmerged, so the project independently adapted and runtime-tested
the narrow change against 0.55.1. Wry's original `LICENSE-APACHE`,
`LICENSE-MIT`, and `LICENSE.spdx` files are preserved with the vendored source.

## Cockpit product-behavior reference

The Codex instance-management and conversation-visibility work was informed by
publicly documented product behavior in:

- Project: Cockpit Tools
- Upstream: https://github.com/jlcodes99/cockpit-tools
- Source revision reviewed: `9946e985e9491c8c2c6c0d1b4ac7d0f987802bdd`
- Upstream license declaration: CC BY-NC-SA 4.0
- Relevant public releases: v0.24.10 and v0.26.0

No Cockpit source code, tests, comments, or UI copy is included in Codex Token
Bar. Cockpit's non-commercial ShareAlike license is not treated as compatible
with this AGPL-3.0-only software distribution. The implementation here was
written independently from observed behavior and uses a different registry,
process-identity gate, stopped-instance gate, transaction journal, conflict
policy, and official Codex app-server visibility rebuild. This attribution is
provided as product-design provenance and does not relicense any part of Codex
Token Bar under CC BY-NC-SA 4.0.
