# Token accounting and historical standard API pricing

Implementation date: 2026-09-06. Branch: `codex/token-accounting-standard-api-20260906`. Starting HEAD: `c17b57121832873fb2ae6ac6c892f0eb285d2920`. Public compatibility baseline: v0.9.1 (`f5989bf1e1199063d75c90dabe39242317d64ce8`, Swift schema 6 / Tauri schema 9); existing unpublished schema 11 is retained as an upgrade source.

## Accounting contract

Input includes cached input; output includes reasoning. Counted tokens are `input + output`; standard API equivalent is `((input-cached)*inputRate + cached*cachedRate + output*outputRate)/1e6`. No independent cache-write field is invented. Full valid last usage has priority. Cumulative fallback uses component deltas and a persisted source checkpoint; last-only amounts not yet reflected in a cumulative snapshot are subtracted to avoid counting them twice. A legacy checkpoint without component state cannot be treated as zero.

Missing input/output, invalid numeric values, impossible cache/reasoning bounds and unexplained scalar totals remain diagnostic rows. They contribute neither tokens nor calls. Original reported totals are separate from derived tokens. Old stored tokens are retained in `legacy_tokens`, never relabeled as a raw reported total.

The durable complete-snapshot fingerprint and fork replay boundary remain unchanged. Partial snapshots carry a SHA-256 identity over field-presence signatures and the original timestamp. Their durable identity uses the existing eleven-value fingerprint codec with the reserved `hasLast=false, lastTokens=1` combination; a numeric full snapshot without last always has five trailing zeros, so the domains cannot collide. Swift and Rust share an exact digest/codec vector test. A cumulative decrease alone is not permission to bypass durable replay protection.

## Existing-database migration

The existing schema-11 candidate/manifest flow first validates its original structural facts. Accounting conversion then runs transactionally in the original DB and publishes schema 12. Source checkpoint and event columns are added to existing tables; Rust published/pending compatibility views and triggers carry them. No new accounting database or patch ledger is introduced.

A structural receipt in existing metadata lets an already-switched manifest resume after semantic conversion. Integrity checks still run, and original managed rollback cleanup remains at its established successful-refresh point. New and known old staging formats import through the same path; old artifacts are read without rewriting them, normalizing only supported components and preserving their prior token values. Unknown formats fail closed.

Aggregate and attribution rebuilds exclude diagnostics, including lineages whose last legacy events become non-counted. Model/reasoning enrichment receipts are retained across the accounting parser revision so an accounting change does not silently schedule a cold scan.

Old parser omissions cannot be reconstructed from event rows or chunk hashes alone. Every nonempty legacy index retains `legacy-source-audit-required`; fresh indexes with diagnostics retain unresolved coverage. Swift exposes this as 已确认小计 with a tooltip; Rust emits a coverage warning. This is not a claim that all raw historical events were recovered.

## Dated standard API estimate

Rates are USD per million input / cached input / output:

| Model | Before cutover | From cutover |
|---|---|---|
| Sol | 5 / 0.5 / 30 | 4 / 0.4 / 20 from 2026-08-21 |
| Terra | 2.5 / 0.25 / 15 | 2 / 0.2 / 12 from 2026-07-30 |
| Luna | 1 / 0.1 / 6 | 0.2 / 0.02 / 1.2 from 2026-07-30 |
| GPT-5.5 | 5 / 0.5 / 30 | unchanged |

UTC midnight is an explicit day-level estimation convention, not a verified billing second. Sol does not automatically revert on an assumed promotion end date. Extra 50% promotions, Batch/Flex, credits discounts, provider multipliers, long-context surcharges and tool fees are outside this standard short-context estimate. Radar comparison cards are separate.

Model and event-price periods survive aggregation until pricing. The old settings key for GPT-5.5 still migrates to the existing Sol preference, while real GPT-5.5 usage retains its model identity. Numeric cache revisions advance (Swift payload 5, Tauri 23); known older projections are last-good/stale only.

Sources verified for this task: [official API prices](https://developers.openai.com/api/docs/pricing), [July 30 announcement](https://openai.com/index/advancing-the-price-performance-frontier-with-gpt-5-6/), [Sol announcement](https://community.openai.com/t/20-price-reduction-for-gpt-5-6-sol-api-codex-credits-and-chatgpt-work/1391726), [reasoning usage](https://developers.openai.com/api/docs/guides/reasoning). CC Switch comparison baseline: `farion1231/cc-switch@5a04034816e63e034d5ba9031eb10cec2190e8d1`; its proxy/session time-window merge is not copied into this local-source parser.

## Verification and outstanding gates

Final gates on the reviewed source worktree:

| Gate | Result |
|---|---|
| Swift complete suite | PASS: 1423 executed, 4 skipped, 0 failures |
| Rust token_count_jsonl complete suite | PASS: 209 passed, 1 ignored, 0 failures |
| Node complete suite | 960 passed / 962; 2 existing floating editor drag failures |
| TypeScript type check | PASS |
| Frontend production build | PASS; existing bundle-size/dynamic-import warnings remain |
| Two independent Luna Max reviews | PASS after root fixes and closure review |
| Whitespace/diff check | PASS |

The two Node drag failures (`row dragging commits an optimistic order...` and `page dragging shows an item-sized...`) were reproduced on the untouched starting HEAD in a temporary exported tree with the same installed dependencies. They are not attributed to accounting. A separate Radar title assertion was updated to match the concurrent UI wording and passed; that UI-coupled assertion stays outside the accounting commit.

Review findings fixed by root: Swift source replacement now deletes diagnostics too; Rust's temporary published-events view filters diagnostics; Swift direct and streaming aggregation filter them; missing-total replay uses durable timestamp/presence-aware fingerprints; integer lexical handling agrees across Swift/Rust, including decimal/exponent forms and negative zero. Regression tests cover same-offset replacement, A/B/A replay across reopen/append, independent timestamp-distinct requests, diagnostic calls/components, shared fingerprint bytes, schema conversion, rollback, and legacy stage reuse without reparse.

Reproduction commands:

```sh
swift test
cargo test --manifest-path tauri-app/src-tauri/Cargo.toml --lib core::usage::token_count_jsonl:: -- --test-threads=1
# From tauri-app:
node --test $(rg --files src -g '*.test.mjs')
npm run build
```

Final logs: `/tmp/accounting-swift-final-gate.log`, `/tmp/accounting-rust-final-gate.log`, `/tmp/accounting-node-all-verified.log`, `/tmp/accounting-node-baseline.log`, `/tmp/accounting-web-build.log`.

Tests use temporary fixtures. Accounting and price changes are staged separately from concurrent Radar/chart UI edits. The source gates ran on the shared worktree; live acceptance remains separate. No running app was replaced, no active index or JSONL was modified, and no push, release or publication was performed. Real bundle/database migration and full raw-history coverage audit remain NOT_RUN.
