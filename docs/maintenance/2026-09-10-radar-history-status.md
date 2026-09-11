# Localize reminder-history refresh status

Performance trace confirms one RSS read timed out after 18013ms while the live Radar JSON succeeded. The next scheduled round fetched the RSS successfully in 118–185ms. A direct check returned HTTP 200 in 0.437s. Retaining historical reminders did not mean the live window state was old, but the global `RSS 旧数据` banner conflated their states.

The live Radar status and diagnostic banner now ignore reminder-history-only failures. Root-data failures still display their existing failure/staleness warning. The reminder history section itself explains a failed refresh and whether previously read history is retained. The optional full-detail response preserves the independently fetched history and its diagnostics, so loading full details cannot discard that section's state.

Tests verify that a feed-only failure leaves the fresh live status intact, root failures remain visible, and full-detail composition preserves feed history/status. Model and component tests: 25 PASS. SSR regression verifies the feed-only global banner is absent. Evidence: runs/20260910-radar-history-status/.

SSR: 8 PASS. Final release build and deep signature verification PASS. Preview Tauri.app replaced; executable SHA256 08b41f66311019210bb6f27353c9edcb78529e716e7225895668a9fb9c06c463. Previous app retained. Full native visual acceptance of the failure case NOT_RUN; rendered component regression PASS.
