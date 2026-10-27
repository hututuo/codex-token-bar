# Open Source Notices

## ModelTrace model fingerprints

Model fingerprint scoring and the bundled reference bank are adapted from
[ModelTrace](https://github.com/xqy2006/ModelTrace), revision
`d4131b30243dfa05e70180b5eedde742103f1d73`, by xqy2006 (MIT).
The initial Tauri scorer/probe implementation was contributed in
[PR #3](https://github.com/hututuo/codex-token-bar/pull/3), then adapted for
three parallel probes and opt-in scheduling. The native app runs the pinned
upstream JavaScript scorer locally; Tauri's Rust port is checked against the
same fixtures. Full MIT text: `LICENSES/ModelTrace-MIT.txt`, bundled as
`OpenSourceLicenses/ModelTrace-MIT.txt`.

## Codex Token Bar original code

The original Codex Token Bar code was made available under the MIT License:

- Copyright (c) 2026 hututuo
- Full preserved text: `LICENSES/CodexTokenBar-MIT.txt`

## Zstandard compressed-history decoder

The Swift application statically includes the official Zstandard 1.5.7 decoder.
The Rust application uses the `zstd` 0.13.3 wrapper and its `zstd-sys` 1.5.7
native decoder dependency.

- Upstream: https://github.com/facebook/zstd
- Zstandard license selected: BSD 3-Clause
- Full text bundled with the apps: `OpenSourceLicenses/Zstandard-BSD-3-Clause.txt`
- Vendored Swift source and provenance: `Sources/CZstd/` and
  `LICENSES/Zstandard-1.5.7-provenance.md`
- Rust wrapper upstream: https://github.com/gyscos/zstd-rs
- Rust wrapper license selected: MIT
- Full wrapper license bundled with Tauri: `OpenSourceLicenses/Zstd-rs-MIT.txt`

No external zstd executable or system shared library is required for history
reading.

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

## Google Material Design Icons paging-guide asset

The Tauri floating-panel paging guide includes one unmodified raster icon:

- Project: Google Material Design Icons
- Upstream: https://github.com/google/material-design-icons
- Asset: `action/touch_app`, round 48dp 2x
- Bundled file: `tauri-app/public/floating-paging-touch.png`
- Upstream license: Apache License 2.0

The icon is used only as the animated pointer/touch affordance in the one-time
floating-panel paging guide.

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

## Tauri updater Windows launch patch

The Tauri application includes tauri-plugin-updater 2.10.1, with a narrow local
patch checking Windows installer launch errors before cleaning up and exiting.
Download and signature verification remain upstream implementations.

- Upstream: https://github.com/tauri-apps/plugins-workspace/tree/updater-v2.10.1/plugins/updater
- License selected: MIT
- Full text: OpenSourceLicenses/Tauri-updater-MIT.txt
- Source and patch provenance: tauri-app/src-tauri/vendor/tauri-plugin-updater/TOKENBAR_PATCH.md

## Local body-speed tokenizer

Completed-body speed uses the bundled OpenAI `o200k_base.tiktoken` vocabulary
and the o200k regex via TiktokenSwift. No runtime vocabulary download is required.

- Vocabulary: https://openaipublic.blob.core.windows.net/encodings/o200k_base.tiktoken
- SHA256: `446a9538cb6c348e3516120d7c08b09f57c36495e2acfffe59a5bf8b0cfb1a2d`
- Upstream: https://github.com/openai/tiktoken
- License: MIT, preserved in `LICENSES/Tiktoken-MIT.txt` and bundled in the macOS app.
- Rust/Windows uses `tiktoken-rs` 0.12.1 with an embedded vocabulary, without runtime downloads.
- Rust wrapper: https://github.com/zurawiki/tiktoken-rs, MIT; preserved in `LICENSES/Tiktoken-rs-MIT.txt` and bundled by Tauri.
- Local token counts describe visible body text, not server billing usage.
