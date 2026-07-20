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

Codex Token Bar modifies this work to use a Swift-native local CDP bridge,
its existing official `codex delete --force` deletion path, its own settings
UI, local rollout validation, atomic file replacement, and current Codex
Desktop selectors. The adapted capabilities cover Markdown export, project
movement, plain-text paste handling, thread-ID badges, centered conversation
width, and per-thread scroll restoration.

The combined work on this branch is distributed under GNU AGPL version 3.
The complete corresponding source is the source tree containing this notice.
The root `LICENSE` contains the full AGPL-3.0 text.
