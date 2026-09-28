# Direct HTTP quota and independent account selection

Status: included in the v0.9.3 release candidate. Implementation began on codex/cpa-reserve-display from be27b084. Hosted checks, build, signing and publication evidence are recorded separately in the release locator.

## Product contract

- Quota reads use GET https://chatgpt.com/backend-api/wham/usage with a ChatGPT OAuth access token and Chatgpt-Account-Id. Reset-credit reads use the same captured identity and official origin. They do not launch Codex app-server.
- Ordinary API keys and provider/base_url settings are not quota identities. No ChatGPT credential is sent to a configured relay/provider.
- Stable identity is a domain-separated SHA-256 of ChatGPT user ID and account/workspace ID. Token rotation keeps the same identity; matching email is not enough to merge accounts. Missing identity and conflicting claims fail closed. JWT decoding extracts metadata; the server validates authentication.
- The quota toolbar and expanded sidebar offer following the current login or selecting a saved account. Add/update current login, import a Codex/CPA OAuth JSON file, and remove a saved account are available. Swift uses a native file picker; Tauri currently accepts the full file path in its main-window manager.
- Account changes clear previous quota, Reserve, reset cards and quota history; revision guards reject late A-to-B-to-A responses. Changes synchronize among Tauri windows. Other-client registry changes reconcile on focus/15-second polling; current-login credential changes are recognized at quota refresh.
- Local token/cost/session totals remain the existing local ledger. Selecting a quota account does not rewrite Codex login/provider or assign all local usage to that account. Pinned independent accounts suppress shared-account attribution and local quota-cycle breakdowns; local account labels are retained.
- Automatic resume reads the current local login separately, never the display-selected account. This changes quota observation, not inference execution.
- Reserve remains passive: no supportsLunaReserve, opt-in header, spending or model switching. Reserve windows remain separate from ordinary 5h/7d windows.

## Credential lifecycle and storage

- Current login can come from auth.json or Codex keyring/auto storage. Import supports Codex nested tokens and CPA flat credentials. Saved-account metadata contains opaque ID, label, source link, revision and selection only.
- Saved access tokens use macOS Keychain. Windows uses current-user DPAPI encrypted files because OAuth JWTs can exceed Credential Manager's blob limit. Original Codex keyring reads retain Codex's service and home-hash lookup.
- Fresh matching credentials are reread from the linked original file or current login. The newest expiry among matching candidates wins; a file rewritten for another account never replaces the saved identity. Removal and vault refresh share a registry lock.
- This version does not own an OAuth login/refresh-token flow. Refresh tokens are not copied or rotated. If an account's original source no longer refreshes and its saved access token expires, quota access requires login in the original client and add/update/import again. Saved accounts are not a promise of indefinite unattended access.
- Redirects are refused; origin is fixed; request time and response size are bounded. Credential contents never enter the frontend, registry metadata, diagnostics or test logs.

## Verification

Evidence: runs/quota-accounts-verification/verification.json and the runs/quota-accounts-*.log files.

Tests use synthetic credentials and include cross-language identity agreement, token rotation, same-email different identities, malformed/API-key rejection, fixed official read-only request headers, WHAM percent/reset normalization, Reserve separation, A-to-B-to-A request rejection and preservation of local counts/history ownership.

The Windows check harness compiles the actual accounts.rs module for x86_64-pc-windows-msvc, including DPAPI calls. It is not a complete Windows application build or runtime test. The browser preview uses synthetic data; DOM geometry was checked, while screenshot capture timed out. Real accounts, secure-store runtime prompts, installed native UI and release acceptance remain unverified.
