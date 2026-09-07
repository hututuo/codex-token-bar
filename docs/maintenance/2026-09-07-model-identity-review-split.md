# Model identity, unknown prices, and Auto Review presentation

## Behavior

- Swift and Tauri preserve explicit unknown model names. A future `gpt-5.6-*` name no longer falls through to Sol.
- Known aliases still have friendly labels. Model names come from usage records; this change does not fetch an official model catalog or live prices.
- Explicit unknown models retain tokens and call counts, but have no inferred price. Monetary surfaces identify the known-price subtotal and unknown coverage. Savings and quota attribution do not present an incomplete estimate as a complete result.
- Existing missing-model legacy fallback remains distinct from explicit unknown models.
- Floating model rows merge Auto Review into the underlying model. Main dashboard and activity detail surfaces distinguish ordinary model usage from Auto Review usage, including dated historical review mappings.
- No parser, raw-history, or database schema change.

## Verification

- PASS: 192 focused Swift tests, zero failures.
- PASS: Tauri production build and `git diff --check`.
- FAIL (pre-existing): complete Node suite has 1,014 passing tests and two floating structure editor drag failures out of 1,016. Both failures were separately reproduced from clean baseline `8cd9e449`.
- PASS: actual historical cohort retains 74,567,567,319 tokens and API estimate USD 38,541.9403714 after the change. Floating and main model group totals agree.
- PASS: server-rendered dashboard fixture covers ordinary usage, Auto Review, unknown source names, and the known-price subtotal.
- NOT_RUN: installed-app restart/update and visual runtime acceptance. Browser preview of the local fixture was blocked by URL policy.

Local verification logs and the historical comparison fixture are under `/tmp/token-accounting-review-20260907/`. The concurrent commit `91ff7fcf` changes only the unrelated Swift floating drag test's pixel-alignment assertions.
