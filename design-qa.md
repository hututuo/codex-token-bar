# Design QA — 状态栏额度、模型榜与跨平台弹窗

## Current visual truth and implementation evidence

- Evidence root: `runs/20260731-234300_status-ui-qa/` (ignored local QA material, not a release asset).
- Source visual truth: `runs/20260731-234300_status-ui-qa/source-swift.png` (`780 × 880` Retina capture, `390 × 440` logical pixels, dark appearance, pending/empty-data state).
- Tauri implementation: `runs/20260731-234300_status-ui-qa/implementation-tauri.png` (`390 × 440`, dark appearance, the same pending/empty-data state).
- Full-view comparison: `runs/20260731-234300_status-ui-qa/comparison-full.png` (`780 × 440`; Swift on the left, Tauri on the right).
- Focused comparison: `runs/20260731-234300_status-ui-qa/comparison-focused.png` (`780 × 320`; header, overview, usage, and quota regions at the same scale and state).
- Compact status renderer: `runs/20260731-234300_status-ui-qa/implementation-tauri-compact.png` (`420 × 40` crop) verifies vertically stacked `5/H`, `7/D`, and two model-ranking rows. Swift stacking is additionally covered by attributed-string baseline tests.
- Capture boundary: the Tauri content was captured from the production React/CSS status surface with only its native-window lifecycle stubbed for localhost rendering; the temporary stub and compact-threshold override were removed before tests and commit.

## Findings and fixes

No actionable P0, P1, or P2 visual difference remains.

- Geometry: both expanded surfaces use the same `390 × 440` frame, `14px` outer padding, `16px` shell radius, single-column cards, and fixed three-button footer.
- Hierarchy: both retain the same title/subtitle/“按设置编排” header, key overview, Token usage, stacked quota, scrolling summaries, and bottom actions. Tauri intentionally exposes three supported usage values rather than inventing Swift-only model-generation data.
- Quota presentation: the first Tauri iteration reused centered floating-panel pills. The focused comparison showed that they did not match Swift, so the popup now uses a left label, central track, and right remaining-value column; unavailable windows show a true dash.
- Height containment: the first `390 × 440` browser render let the card expand to about `669px`, clipping the footer. Adding a zero minimum height and hidden outer overflow now keeps the card at exactly `440px`, gives the summary region a bounded scroll area, and leaves the footer fully visible.
- Color, border, and elevation: Tauri reuses the product's existing dark panel, border, muted-text, and accent tokens. Broad shadows, duplicate close controls, and opaque startup paint are absent.
- Accessibility: the scrolling summary has a named keyboard focus target; the Windows compact button exposes the complete live tooltip as its accessible name while its visual stacking subtree is hidden from duplicate announcement.
- Compact layout: the `5/H` and `7/D` markers are true two-row elements, not superscript text. The model ranking is two rows (`1 …`, `2 …`) with score removed and effort compacted.

## Primary interactions and checks

- Expanded popup frame and scrolling region measured at `390 × 440`; footer bottom remained inside the frame.
- Full and focused Swift/Tauri comparisons inspected together at identical scale and state.
- Compact indicator click, Enter, Space, Escape behavior and accessible name covered by DOM tests.
- Main interface, settings, collapse, focus-loss dismissal, transparent first paint, and settings preview paths covered by source and integration tests.
- Current limitation: Windows native shadow/WebView2 first-frame behavior cannot be physically observed on this Mac; the transparent document class is applied before React render and the native surface remains covered by Rust tests.

final result: passed

---

# Archived Design QA — 双端总体设置重构

## Visual truth and implementation evidence

- Evidence root: canonical project `runs/20260716-013504_settings-redesign/design/` (ignored local QA material, not a release asset).
- Source visual truth: `runs/20260716-013504_settings-redesign/design/settings-sidebar-reference.png` (`1487 × 1058`, dark appearance, “监控与额度” selected).
- Source-use boundary: `runs/20260716-013504_settings-redesign/design/settings-sidebar-reference.md`; the source is a layout and hierarchy reference, not a functional specification. Its “删除本地数据” action is intentionally excluded.
- Swift implementation:
  - `runs/20260716-013504_settings-redesign/design/settings-qa/swift-general.jpeg` (`920 × 650`).
  - `runs/20260716-013504_settings-redesign/design/settings-qa/swift-monitoring.jpeg` (`920 × 650`, dark appearance, “监控与额度” selected).
  - `runs/20260716-013504_settings-redesign/design/settings-qa/swift-floating.jpeg`, `swift-content.jpeg`, and `swift-data.jpeg` for secondary states.
- Tauri implementation:
  - `runs/20260716-013504_settings-redesign/design/settings-qa/tauri-general.jpeg` (`1054 × 768` app capture; settings surface targets `900 × 650` logical CSS pixels).
  - `runs/20260716-013504_settings-redesign/design/settings-qa/tauri-monitoring.jpeg` (`1054 × 768`, dark appearance, “监控与额度” selected).
  - `runs/20260716-013504_settings-redesign/design/settings-qa/tauri-floating.jpeg` and `tauri-data.jpeg` for secondary states.
- Full-view comparisons:
  - `runs/20260716-013504_settings-redesign/design/settings-qa/comparison-swift-full.jpg`.
  - `runs/20260716-013504_settings-redesign/design/settings-qa/comparison-tauri-full.jpg`.
- Focused comparisons:
  - `runs/20260716-013504_settings-redesign/design/settings-qa/comparison-swift-focused.jpg`.
  - `runs/20260716-013504_settings-redesign/design/settings-qa/comparison-tauri-focused.jpg`.
  - `runs/20260716-013504_settings-redesign/design/settings-qa/comparison-cross-platform-monitoring.jpg`.

The focused comparisons normalize the source dialog and implementation surfaces to the same height. The full Tauri capture includes the native window and dimmed dashboard behind the dialog; this shell difference is excluded from content-region judgment.

## Findings

No actionable P0, P1, or P2 differences remain.

- Fonts and typography: both implementations use their existing system-font stacks, preserve a clear sidebar/page/section hierarchy, keep small text at usable optical weights, and show complete labels without truncation or ellipses. Swift is slightly denser; Tauri uses one extra description line where the cross-platform behavior needs explanation.
- Spacing and layout rhythm: both use the same left category rail, right page header, selected accent rail, flat bordered setting groups, and high-density row rhythm. The `920 × 650` Swift sheet and `900 × 650` Tauri target retain the same major-region proportions as the source.
- Colors and visual tokens: both reuse the product’s dark panel, border, muted text, and blue selected-state tokens. Broad modal shadows and backdrop blur were removed; semantic green/amber states remain reserved for real status rows.
- Image quality and asset fidelity: the settings surface contains no product imagery or decorative raster assets. Swift uses real SF Symbols. Tauri keeps a text-led rail because this frontend has no established icon dependency; it does not substitute emoji, text glyph icons, custom SVG, or CSS illustration art.
- Copy and content: the seven category names are identical across both implementations. Platform-only capabilities are explained instead of faked. The mock’s destructive local-data action is absent, the preview no longer invents a missing 5h window, and main-screen high-frequency shortcuts remain visible.
- Accessibility and interaction: Tauri exposes `tablist`/`tab`/`tabpanel`, selected state, Arrow keys, Home/End, a focus trap, Escape, backdrop close, and focus restoration. Swift exposes unique category buttons with selected values and help text, native controls, and Escape close. Both real latest builds were opened and inspected through their accessibility trees.

## Comparison history

### Iteration 1 — blocked

- [P2] Cross-platform frame mismatch: the first Tauri render added a full-width dialog header while the source and Swift surface put the settings identity in the sidebar and the page title/close action in the content header.
- [P2] Excess elevation and truncation risk: the first Tauri CSS added a broad modal shadow, backdrop blur, and ellipsis rules that did not match the product’s flat, complete-label style.
- [P2] State/copy drift: the first Tauri preview showed a fabricated `5h` value even though the current official runtime only exposes `7d`; sorting actions also used bare arrow glyphs.

Fixes made:

- Moved the Tauri “总体设置 / Codex Token Bar” identity into the sidebar and the close action into the selected page header.
- Removed broad shadow/blur and sidebar truncation rules.
- Changed the preview to `7d 61% · 均速正常` and replaced glyph-only sorting controls with explicit “上移 / 下移” labels.
- Removed the Swift preview shadow in favor of the existing border token.

Post-fix evidence:

- `runs/20260716-013504_settings-redesign/design/settings-qa/comparison-tauri-focused.jpg`.
- `runs/20260716-013504_settings-redesign/design/settings-qa/comparison-cross-platform-monitoring.jpg`.

### Iteration 2 — passed

- Final source/Swift and source/Tauri focused comparisons show matching information hierarchy, category geometry, selected-state treatment, row density, and page boundaries.
- Secondary-state captures show complete floating appearance, content ordering, reminders/update, and data/maintenance pages without clipped persistent controls.
- No remaining P0/P1/P2 issue was found.

## Primary interactions tested

- Open settings from the real Swift and Tauri main windows.
- Select category pages without changing stored preferences.
- Tauri: click navigation plus Arrow keys and Home/End; verified Home selects “常规” and End selects “数据与维护”.
- Both: Escape closes the settings surface.
- Read-only review of data directory, Provider repair, update, and thread-delete states; no repair, update installation, directory change, Codex restart, or deletion action was triggered.
- Tauri startup trace reached `frontend dashboard summary ui ready`; both staged binaries matched their just-built bundles and passed deep code-sign verification.

## Open questions and follow-up polish

- [P3] A future shared Tauri icon dependency could add real sidebar icons to match Swift more closely. It is not introduced in this pass because the current Tauri design system has no icon package and fake glyph/SVG substitutes are not acceptable.
- [P3] The `<= 680px` Tauri breakpoint is implemented as a horizontally scrollable tab rail and covered by CSS/code review, but this native macOS handoff did not preserve a separate narrow-window screenshot.

## Implementation checklist

- [x] Seven shared categories and selected-state navigation.
- [x] Platform-specific capabilities represented honestly.
- [x] Token-rate full scale, floating appearance preview, ordering, updates, and maintenance grouped into settings.
- [x] No local-data deletion action.
- [x] Full and focused visual comparisons after fixes.
- [x] Real latest Swift and Tauri builds inspected.

archived result: passed
