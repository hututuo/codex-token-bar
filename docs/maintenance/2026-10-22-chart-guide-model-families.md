# Chart guidance, five-minute speed presentation and model families

The body TPS chart now defaults to 24 hours and removes the one-hour option on both platforms. Each daily point remains the existing five-minute weighted mean (qualified output Tokens divided by measured duration), with gaps for absent samples. Seven- and thirty-day rollups remain compatible. This is presentation work; measurement, retention and SQLite schemas are unchanged.

Dashboard model costs are grouped by generation: all GPT-6/6.0/6.1/future 6.x names, then GPT-5.6, then other models. Unknown model prices remain unknown. Family assignment does not change pricing or infer an identity. Auto Review retains its separate identity under other models. Unused fixed four-model placeholders and their old grouping helpers were removed. The unassigned/boundary usage subtotal, per-model sentence and explanation are hidden; underlying records and conservative confirmed totals are retained.

A larger, initially expanded guide above the usage chart demonstrates hover readouts, first-click start, moving interval, second-click end, result display and restarting a selection. It can collapse and reopen. Its numeric values are explicitly illustrative. Tauri uses CSS animation paused when offscreen/hidden, and unmounts it when collapsed. Native SwiftUI uses an isolated PhaseAnimator. Reduced-motion settings show a static example. No sampler, data query or recurring dashboard timer was added.

The collapsed sidebar's meter fills now change actual dimensions rather than scaling an already rounded shape. This keeps low readings' end caps round on both platforms and preserves the measured fraction and existing interpolation timing.

Validation: 196 native selected tests (193 passed, 3 opt-in local audit/render tests skipped), 180 frontend tests and the production frontend build passed. The real cache toggle still removes/restores plotted observations; its test now uses the actual host height instead of a fixed 640pt coordinate. Browser checks verified guide collapse/reopen and two real chart clicks producing an interval readout. Family tests preserve Tokens, costs and unknown-price handling. Prior sidebar-storage Rust tests remain 45 passed. Windows source is synchronized; Windows installation, full build and physical multi-monitor acceptance were not performed in this task.

Local installation/rollback records are in `runs/20261022-chart-guide-model-families/` outside the release tree. Build937 was superseded before installation; build938 was installed and verified before the final animation polish in build939. No public release is authorized by this maintenance change.

Native animation polish: separate movement and click-hold phases, animate the marker position with the cursor, and switch readout/caption text without crossfade ghosting. The 20 production chart interaction tests passed again.
