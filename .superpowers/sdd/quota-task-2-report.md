# Quota Task 2 Red/Green Report

## Scope

- Tauri quota freshness, in-flight coalescing, canonical Home/account identity, explicit unavailable quota, and quota UI/compact projections only.
- No Swift implementation, Provider implementation, `platform/settings.rs`, release metadata, network, real auth, real app-server, or reset-card consume/redeem/use request.

## RED

1. `node --test src/components/quota/quotaStripSsr.test.mjs src/surfaces/compactPanelLabels.test.mjs`
   - Failed because unavailable `null` percentages rendered as `剩 0%` with `width:0%`.
   - Failed because compact quota had no availability-aware projection.
2. Focused Rust quota compile after adding behavior tests
   - Missing `QuotaAvailability`, nullable percentages, cadence freshness policy, stable account key, and canonical cache scope.
3. Isolated focused Rust test `identity_change_during_read_does_not_reuse_previous_success`
   - Failed because an auth subject change during a forced read still reused account A's successful quota as stale data for account B.

## GREEN

- Rust availability shape: `QuotaLimit { availability: measured | unavailable, remaining_percent: Option<f64>, used_percent: Option<f64>, ... }`; serde emits camel-case nullable fields and snake-case discriminator values.
- TypeScript availability shape: `availability: "measured" | "unavailable"`, `remainingPercent: number | null`, and `usedPercent: number | null`.
- Automatic success freshness: sanitize persisted cadence to `30s/1m/3m/5m/10m`, then use `min(30s, cadence / 2)` (`15s/30s/30s/30s/30s`).
- The backend reads the persisted shared cadence through `read_app_settings` behind an injectable policy/loader seam.
- Manual refresh bypasses an already-completed cache entry. Concurrent callers for the same canonical Home join the in-flight read, including forced and independently phased automatic callers.
- Successful/stale reuse requires the same canonical Home and the same established local ID-token `sub`/account key. Missing, changed, or mid-read-changing identity cannot reuse prior success.
- Unavailable failures never load or attach global history. Same-identity stale success preserves its trusted history; full stable-identity history schema migration remains Task 3.
- Main and compact/floating accessibility render unavailable quota as pending/failure status with no `0%`, empty measured bar, or `aria-valuenow=0`; a real measured zero remains `0%`.

## Verification

- Isolated clean-HEAD Rust quota filter after applying only Task 2 diff: `86 passed`; follow-up identity-transition RED failed on stale reuse, then GREEN passed.
- Target-worktree Rust quota filter: `87 passed`.
- Target-worktree expanded Node/SSR/compact/cadence quota filter: `32 passed`.
- Target-worktree frontend build (`tsc --noEmit && vite build`): passed.
