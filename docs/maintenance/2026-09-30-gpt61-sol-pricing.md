# GPT-6.1 Sol model support

Verified against the OpenAI model page and API changelog on 2026-09-30:

- Model: `gpt-6.1-sol`; released 2026-09-29.
- Standard short-context rates per million tokens: input $2, cached input $0.10, cache writes $2.50, output $10.
- Above 272K input tokens, the published standard rates are $4 / $0.20 / $5 / $15.
- Sources: https://developers.openai.com/api/docs/models/gpt-6.1-sol and https://developers.openai.com/api/docs/changelog

Token Bar adds a separate `gpt61Sol` card, exact model-name aliases, model labels/colors, settings choices and recommendation ordering in Swift and the shared Tauri frontend. Existing `gpt-6-sol` rows keep their own $0.20 cached-input price. Unknown suffixes and bare `gpt-6.1` remain unpriced.

Historical estimates use the existing UTC-midnight convention, beginning 2026-09-29. Swift price partitions and SQL grouping include this boundary; Rust already preserves the raw model identity and UTC event-day timestamps, and does not hold a separate dollar-price table. Windows uses the shared TypeScript prices.

The estimate continues to use standard short-context input, cached-input and output rates. Cache-write token counts and per-request long-context/service-tier information are outside the existing estimator; the published extended rates above are recorded as source evidence, not newly applied to aggregate usage.

Regression checks cover exact aliases, unknown variants, the release-date boundary, mixed cached/uncached costs, stored settings, separate model presentation, and preservation of previous Sol prices.
