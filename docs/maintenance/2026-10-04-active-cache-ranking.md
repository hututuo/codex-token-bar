# Cache ranking under Codex history compression

When `config.toml` explicitly enables `[features].local_thread_store_compression`, the cache ranking shows sessions with exact indexed token activity during the preceding seven days. This is session activity, not creation time: earlier turns in a recently active session remain eligible. A missing or disabled flag keeps the existing ranking scope.

Swift and Rust filter candidates in SQL before bounded ranking selection and before question/answer excerpt hydration. Automatic ranking in this mode skips compressed text sources, including older compressed shards of an eligible session. It does not decompress or promote their text proof just to populate excerpts. Ordinary source scan, first indexing, and explicit detail readers keep their existing safety requirements.

The scope is carried by the optional `rankingActiveSince` projection field. Old cached payloads remain decodable. A setting change invalidates both full and fast in-memory/persistent ranking cache reuse; normal refresh updates the rolling cutoff. Both ranking surfaces show:

> 已开启历史压缩，仅显示最近 7 天活跃会话。较早的历史会话可能已压缩。

An empty active ranking never falls back to the legacy all-history ranking. Lifetime totals, peak-thread usage, retained sources, ledger/checkpoints, schema 14 and history preservation are unchanged. There is no new persistent excerpt cache, load button, or size-budget subsystem.

Tests cover the real settings boolean, prompt/comment false positives, inline table settings, old payload decoding, fast cache toggles and restart persistence, filtering before selection limits, session activity rather than individual turn age, retained totals, skipping compressed text proof, setting toggles, and empty-ranking presentation.

Upstream setting definition: `openai/codex` at `a956835d020762cb2b570053af06f643a11c0ecc`, `codex-rs/features/src/lib.rs`, `LocalThreadStoreCompression`; its default is false. This reads the Home settings written by the desktop switch. It does not claim to resolve per-process CLI overrides or every managed/project configuration layer.
