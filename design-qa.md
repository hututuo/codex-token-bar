# Design QA

latest result: blocked

## Current scope: floating content settings and Tauri header (2026-08-08)

- Implementation commit: `feature/floating-widget-metric-groups-20260807@7416360`.
- Reference designs:
  - `/Users/huyiyang/WorkBuddy/2026-08-08-08-01-54/codex-token-bar-floating-content-settings-redesign.html`
  - `/Users/huyiyang/WorkBuddy/2026-08-08-08-01-54/codex-token-bar-visual-polish-guide.html`
- Code-side gates passed: Swift compile plus 53 content/layout tests and 11 interface-scale tests; Tauri TypeScript typecheck, 60 targeted Node tests, and production frontend build; `git diff --check` clean.
- Interaction structure implemented in both clients: row reordering, page grouping/splitting, default page, hide/restore, reset confirmation, 3-second undo, and production-renderer preview selection.
- Blocker: the user explicitly owns complex visual inspection. No new Swift/Tauri app bundle was built or opened in this task, so viewport matching, real font rendering, clipping, density, hover affordances, and final polish remain pending user inspection.
- P0/P1 code defects found by automated checks: none. This is not visual acceptance.

## Prior completed scope: chart cards (2026-08-02)

prior result: passed

## Scope

- Swift current-point hover card: move upward by 20 pt without clipping its top edge.
- Tauri quota-estimate result card: place below the chart at the lower left, matching the Swift hierarchy.

## Visual sources

- User reference: `/var/folders/wm/8dy9mkcx4wv5tn4w4p0t48qc0000gn/T/codex-clipboard-a239f7e2-4ae6-4958-a575-ef3479fd83a2.png`
- Swift implementation capture: `/var/folders/wm/8dy9mkcx4wv5tn4w4p0t48qc0000gn/T/com.openai.sky.CUAService/Codex Token Bar Screenshot 2026-08-02 at 9.09.02 AM.jpeg`
- Tauri implementation capture: `/var/folders/wm/8dy9mkcx4wv5tn4w4p0t48qc0000gn/T/com.openai.sky.CUAService/Codex Token Bar Screenshot 2026-08-02 at 9.04.51 AM.jpeg`
- Side-by-side comparison inspected at `/private/tmp/codex-token-bar-chart-card-comparison.png`.

## Findings

- P0: none.
- P1: none.
- P2: none.
- Swift hover card is fully visible above the plot; its title and top border are not clipped. The card remains horizontally clamped inside the visible viewport while the selected guide stays aligned with the chart point.
- Tauri estimate card is no longer layered over the curve. It appears in normal flow immediately below the chart, left-aligned, with the ranking section pushed down.
- Both implementations preserve the existing typography, border, radius, spacing, data density, and interaction affordances.

## Interaction checks

- Swift: clicking a chart point creates the selection preview, keeps the hover card visible, and exposes the close action for the estimate card.
- Tauri: two chart clicks create a fixed range; the estimate card remains below the chart and exposes its close button.
- Existing floating-panel preference was restored after Swift main-window inspection.
