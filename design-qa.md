# Design QA

final result: passed

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
