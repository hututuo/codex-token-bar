# Agent Speed — Network Specification

Agent Speed reads local logs and works fully offline. It makes exactly three kinds of automatic network requests, all
optional, all HTTPS `GET`, none of them carrying anything about the user: the update check (`spec/UPDATES.md`), the
daily price-table sync (section 3) and the daily exchange rates (section 4). A fourth kind exists only when the user
turns it on: live reporting (section 6, `spec/REPORTING.md`), the one feature that sends data about the user's
activity, to a service the user chose. Both platforms implement exactly this behaviour; anything not listed here is
never requested.

## 1. Common rules

- **Master switch** `networkEnabled` (Settings → About → `settings.network`), default on. Off: no request of any kind
  is made — automatic or manual (the manual buttons are disabled and show `settings.network.offHint`). Everything
  keeps working with the bundled or last good data. Turning it back on schedules each feature as after a launch.
- **What is sent** (sections 2–4; live reporting has its own rules, section 6): the request line and these headers
  only: `User-Agent: AgentSpeed/<version> (<macOS|Windows>)`,
  `Accept` as stated per feature, and `If-None-Match` with the `ETag` that the same URL returned before (when one is
  stored). No cookies, no credentials, no identifiers, no query parameters derived from the user's data or settings.
  Every request asks for the same resource for every user (the price table, the USD-based rate list), so a server
  learns nothing about the user's currency, models, sources or usage. Servers see the IP address and the time of the
  request, as with any connection.
- **Transport**: HTTPS only; redirects are followed only to `https` URLs on the feature's host list; the system proxy
  settings apply; the platform HTTP cache is bypassed (`URLRequest.CachePolicy.reloadIgnoringLocalCacheData`,
  `HttpClient` without a cache handler) because the app does its own `ETag` handling. Timeout 15 s per request.
- **Size**: bodies are read with a hard cap (per feature); exceeding it (by `Content-Length` or while streaming)
  aborts the request and counts as a failure.
- **Threads**: requests and parsing run off the UI thread; a validated result is applied in one step; the UI never
  waits for the network and never shows a spinner for it.
- **Failures** are silent (no dialog, no notification): logged with host, status code, bytes and the reason, never
  with personal data; the feature keeps its last good data and retries on its schedule.
- **Clock**: "days" below are 24-hour intervals measured from the last successful fetch (persisted), not calendar days.

| Feature | Hosts (in fallback order) | When | Cap |
| --- | --- | --- | --- |
| Update check (UPDATES) | `api.github.com`; downloads `github.com`, `objects.githubusercontent.com`, `release-assets.githubusercontent.com` | 30 s after launch, every 6 h, manual | 300 MiB (assets) |
| Price table (3) | `raw.githubusercontent.com`, `cdn.jsdelivr.net` | 60 s after launch, then daily, manual | 1 MiB |
| Exchange rates (4) | `open.er-api.com`, `cdn.jsdelivr.net`, `latest.currency-api.pages.dev`, `api.frankfurter.dev` | only while a non-USD currency is selected: 30 s after launch or on selection, then daily, manual | 256 KiB |
| Live reporting (6) | the service URL and the API host the user confirmed | only while the user has it on: every 5 s while agents work, a heartbeat while idle, nothing when quiet | 64 KiB discovery, 16 KiB API |

## 2. Update check

`spec/UPDATES.md`, subject to the master switch: with `networkEnabled` off, `autoCheckUpdates` has no effect and the
manual check is disabled.

## 3. Price table sync

The price table (`spec/assets/prices.json`, METRICS 9.1) is bundled with every build and also published by this
repository: whatever is committed on `main` reaches every running app within about a day, without a release.

- **URLs** (in order; the second is a mirror for networks where `raw.githubusercontent.com` is blocked):
  1. `https://raw.githubusercontent.com/zoefix/agent-speed/main/spec/assets/prices.json`
     (served as `text/plain`, `Cache-Control: max-age=300`, strong `ETag`; verified 2026-10-22)
  2. `https://cdn.jsdelivr.net/gh/zoefix/agent-speed@main/spec/assets/prices.json`
     (jsDelivr's GitHub mirror; its edge cache can lag `main` by up to 12 h, `s-maxage=43200`)
- **Setting** `syncPrices` (Settings → Cost, `prices.autoSync`), default on, under the master switch.
- **Schedule**: 60 s after launch, then whenever 24 h have passed since the last successful sync (checked hourly and
  on wake). A failed attempt (both URLs) retries once after 1 h, then follows the daily schedule. Manual
  `prices.check` always tries now and reports the outcome inline (`prices.upToDate`, `prices.updatedTo`,
  `prices.failed`).
- **Request**: `Accept: application/json`, `If-None-Match` when an `ETag` is stored for that URL. `304` → success
  without a change. Any other non-2xx status → try the next URL.
- **Validation** (all must pass; otherwise the download is discarded and the next URL is tried):
  1. UTF-8 JSON object, ≤ 1 MiB.
  2. `schema` equals the schema this build supports (1). A higher schema is not an error: it is ignored and logged
     (`prices.newerSchema` in the status line: this build needs an update to use newer tables).
  3. Every rule of `validate_table` in `spec/tools/prices.py`, implemented natively: field types, required prices,
     prices 0–10 000 USD per million tokens with at most 6 decimals, tiers strictly ascending with the same fields as
     the base prices, unique ids and aliases, unknown entries that shadow nothing, every id and alias resolving to its
     own entry, at most 2000 models, https source URLs.
  4. Every entry of the table's own `tests` resolves as expected with this build's matching (METRICS 9.2). A table
     whose tests fail is rejected, so a table that this build would match differently never becomes current.
  5. `version` is greater than the current version (equal: nothing to do; lower: ignored, never a downgrade), and
     `updated` is at most 2 days after the local date.
- **Storage**: `<app data>/prices/prices.json` (written to a temporary file and renamed), plus
  `<app data>/prices/sync.json` with `{version, updated, url, etag, lastSuccessMs, lastAttemptMs, lastError}`.
  `<app data>` is `~/Library/Application Support/AgentSpeed` on macOS and `%LOCALAPPDATA%\AgentSpeed` on Windows.
  On launch the stored copy is validated again; an invalid copy is deleted (logged) and the bundled table is used.
- **Current table** = the higher `version` of the bundled table and the stored copy, so a newer app build with a
  newer bundled table wins over an older download.
- **Effect**: known costs keep the table bound to their day (METRICS 9.7); new rates therefore apply to days not yet
  bound. A response the bound table could not price may use the newer table instead. Files with unpriced history
  are re-analysed when their local logs are still available, and retained live responses may acquire a known cost.
  This does not replay old reports or guarantee that previously omitted receiver costs can all be recovered.
  No notification; Settings shows the new status.
- **Maintenance** (repository): edit `spec/assets/prices.json`, increase `version` by one, set `updated` and every
  changed entry's `checked`, add a `tests` row for any new id form, run `python3 spec/tools/prices.py`, commit to
  `main`. Never decrease or reuse a version.
- **Trust**: the table is data only — no code, no URLs the app follows. The worst a mistaken or tampered table can do
  is show wrong costs, bounded by the validation limits. Integrity relies on HTTPS to GitHub and jsDelivr; the table is
  not signed (README says so).

## 4. Exchange rates

Costs are computed in USD (METRICS 9.8). Rates are needed only while the display currency is not USD.

- **Providers** (free, no key, no account; all verified on 2026-10-22 to return every currency of
  `spec/assets/currencies.json` unless noted):

  | # | URL | Response | Notes |
  | --- | --- | --- | --- |
  | 1 | `https://open.er-api.com/v6/latest/USD` | `{"result":"success","base_code":"USD","time_last_update_unix":…,"time_next_update_unix":…,"rates":{"CNY":6.689327,…}}` | ExchangeRate-API open access: 166 currencies, updated once a day (≈ 00:00 UTC), `Cache-Control: max-age=3600`; its terms ask for at most hourly requests (rate-limited IPs get HTTP 429 for 20 minutes), allow caching and commercial use, forbid redistributing the data (so it is never bundled or exported as a rate table) and require attribution: Settings shows `rates.attribution` linking to `https://www.exchangerate-api.com` whenever these rates are in use. |
  | 2a | `https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/usd.min.json` | `{"date":"2026-10-21","usd":{"cny":6.67870784,…}}` | fawazahmed0/exchange-api (CC0-1.0: the bundled `fallbackRates` come from it), 340 currencies (codes lower-case, includes crypto and metals: ignored), daily, no rate limit; jsDelivr's edge may serve the previous day. |
  | 2b | `https://latest.currency-api.pages.dev/v1/currencies/usd.min.json` | same as 2a | the project's own Cloudflare Pages mirror, used when jsDelivr fails. |
  | 3 | `https://api.frankfurter.dev/v1/latest?base=USD` | `{"amount":1.0,"base":"USD","date":"2026-10-21","rates":{"CNY":6.6761,…}}` | European Central Bank reference rates, 29 currencies, working days only. Missing on 2026-10-22: TWD, VND, MOP, AED, SAR, CLP, COP, ARS, RUB, UAH. Last resort, and only accepted when it has the selected currency. The old host `api.frankfurter.app` timed out on 2026-10-22 and is not used. |

  On 2026-10-22 providers 1 and 2 agreed within 1.03 % on all 38 currencies (largest gap MXN).
- **Schedule**: only while the selected currency is not USD and the master switch is on: 30 s after launch, at once
  when the user selects a non-USD currency and the stored rates are missing or older than 24 h, then whenever the
  stored rates are older than 24 h (checked hourly and on wake). A failed round (every provider) retries after 1 h,
  then hourly at most. Manual `rates.refresh` in Settings tries now. Selecting USD stops all rate requests.
- **Request**: always the complete USD-based list above (never the selected currency, so the server learns nothing),
  `Accept: application/json`, `If-None-Match` when stored. One round tries 1 → 2a → 2b → 3 and stops at the first
  response that passes validation.
- **Validation**:
  1. JSON object ≤ 256 KiB in the provider's shape; provider 1 needs `result == "success"` and `base_code == "USD"`;
     provider 3 needs `base == "USD"`.
  2. Rates are finite numbers > 0; codes are upper-cased; only the currencies of `currencies.json` are kept, USD = 1.
  3. The rate date (provider 1: `time_last_update_unix`; others: `date` at 00:00 UTC) is at most 2 days after now and
     not older than the stored rates' date (rates never go back in time).
  4. Sanity for the selected currency: the new rate is within ×0.5 … ×2 of the last accepted rate (the bundled
     `fallbackRates` when none). When the last accepted rate is older than 30 days the bound is skipped; instead two
     providers must agree within 3 % for the selected currency (the round then continues to the next provider to
     cross-check, and takes the first provider's rates). A provider that fails a check is rejected entirely.
  5. Provider 3 is accepted only if it has the selected currency; its missing currencies keep their previous rates.
- **Storage**: `<app data>/rates.json` (atomic): `{provider, url, date, fetchedMs, etags: {url: etag}, rates}` with
  the currencies of `currencies.json`.
- **Rate in use**: the last accepted rates, else the bundled `fallbackRates` of `currencies.json` (dated; status
  `rates.fallback`). A rate list older than 7 days shows `rates.stale` in the status line; conversion continues with
  it. Offline never blanks a value.
- **Test vectors**: `spec/fixtures/rates-cases.json` (parsing of the three response shapes and checks 3–5), checked
  by `python3 spec/tools/prices.py`.
- **Display**: Settings shows `rates.status` (e.g. `US$1 = NT$32.55 · 2026/10/22 · open.er-api.com`) and the
  attribution when provider 1 is the source. History and dashboard convert with this one rate (METRICS 9.8).

## 5. Privacy wording

The About pane shows `privacy.statement` (`spec/strings.json`, all four languages; it replaces
`settings.about.privacy` when the cost feature ships). The README privacy section is replaced by the text below when
the cost feature ships (until then the README describes the released app).

- English (`README.md`):
  > Read-only. Local-only. No telemetry, no accounts. Agent Speed makes only three kinds of network requests, and each
  > one sends nothing about you: the update check against GitHub Releases, a daily download of the public model price
  > table from this repository (GitHub, with jsDelivr as a mirror), and — only when you show costs in a currency other
  > than US dollars — a daily download of public exchange rates (open.er-api.com, with the fawazahmed0 currency API
  > and Frankfurter as fallbacks). Every user requests the same files, so no server learns your currency, models or
  > usage. One switch in Settings turns all network access off; costs then use the price table and rates shipped with
  > the app. Agent Speed never stores or displays conversation content — only token counts, model names and project
  > folder names. The usage history keeps only daily totals (including each day's API-equivalent cost), in a small
  > database on your computer (`~/Library/Application Support/AgentSpeed`, `%LOCALAPPDATA%\AgentSpeed`), and can be
  > cleared in Settings. Updates are verified against the release's SHA-256 checksums before they are installed; the
  > checksums are published with the release, so they catch corrupted or tampered downloads, not a compromised
  > repository. The price table is plain data checked against strict rules; it is not signed.
- 繁體中文（`README.zh-TW.md`）：
  > 唯讀、只在本機運作，沒有遙測、不需帳號。Agent Speed 只會發出三種網路請求，而且都不會傳送任何關於你的資料：向
  > GitHub Releases 檢查更新、每天從本專案下載公開的模型價格表（GitHub，以 jsDelivr 為備援），以及只有在你選擇以美元
  > 以外的貨幣顯示費用時，每天下載公開匯率（open.er-api.com，以 fawazahmed0 currency API 和 Frankfurter 為備援）。
  > 每位使用者下載的都是同一份檔案，所以伺服器無從得知你的貨幣、模型或用量。設定裡的一個開關就能關閉所有網路連線，
  > 此時費用改用 App 內建的價格表與匯率。Agent Speed 從不儲存或顯示對話內容，只使用 token 數量、模型名稱和專案資料夾
  > 名稱。用量歷史只保存每日總計（含每日的 API 等值費用），存在你電腦上的一個小型資料庫
  > （`~/Library/Application Support/AgentSpeed`、`%LOCALAPPDATA%\AgentSpeed`），可在設定中清除。更新在安裝前會
  > 以該版本發布的 SHA-256 校驗碼驗證；校驗碼與版本一起發布，因此能攔下損壞或遭竄改的下載檔，但無法防範儲存庫本身
  > 遭入侵。價格表是依嚴格規則檢查的純資料，沒有數位簽章。
- 简体中文（`README.zh-CN.md`）：
  > 只读、只在本机运行，没有遥测、无需账号。Agent Speed 只会发出三种网络请求，而且都不会发送任何关于你的数据：向
  > GitHub Releases 检查更新、每天从本项目下载公开的模型价格表（GitHub，以 jsDelivr 为备用），以及仅在你选择以美元
  > 以外的货币显示费用时，每天下载公开汇率（open.er-api.com，以 fawazahmed0 currency API 和 Frankfurter 为备用）。
  > 每位用户下载的都是同一份文件，因此服务器无从得知你的货币、模型或用量。设置里的一个开关即可关闭所有网络连接，
  > 此时费用改用应用内置的价格表和汇率。Agent Speed 从不保存或显示对话内容，只使用 token 数量、模型名称和项目文件夹
  > 名称。用量历史只保存每日汇总（含每日的 API 等值费用），存放在你电脑上的一个小型数据库
  > （`~/Library/Application Support/AgentSpeed`、`%LOCALAPPDATA%\AgentSpeed`），可在设置中清除。更新在安装前会
  > 用该版本发布的 SHA-256 校验和验证；校验和与版本一同发布，因此能拦截损坏或被篡改的下载文件，但无法防范仓库本身
  > 被入侵。价格表是按严格规则校验的纯数据，没有数字签名。
- 日本語（`README.ja.md`）：
  > 読み取り専用・ローカルのみで動作し、テレメトリもアカウントもありません。Agent Speed が行うネットワーク通信は
  > 次の 3 種類だけで、どれもあなたに関する情報を送りません：GitHub Releases でのアップデート確認、このリポジトリで
  > 公開しているモデル価格表の 1 日 1 回のダウンロード（GitHub、予備に jsDelivr）、そして米ドル以外の通貨で費用を
  > 表示するときだけ行う公開為替レートの 1 日 1 回のダウンロード（open.er-api.com、予備に fawazahmed0 currency API と
  > Frankfurter）。全員が同じファイルを取得するため、サーバーがあなたの通貨・モデル・使用量を知ることはありません。
  > 設定のスイッチ 1 つですべての通信をオフにでき、その場合はアプリ内蔵の価格表とレートで費用を計算します。Agent
  > Speed は会話の内容を保存・表示せず、使うのはトークン数・モデル名・プロジェクトフォルダー名だけです。使用履歴は
  > 日別の集計（各日の API 換算費用を含む）だけを、お使いのコンピューター上の小さなデータベース
  > （`~/Library/Application Support/AgentSpeed`、`%LOCALAPPDATA%\AgentSpeed`）に保存し、設定から消去できます。
  > アップデートはインストール前にリリースの SHA-256 チェックサムで検証します。チェックサムはリリースと一緒に公開
  > されるため、破損や改ざんされたダウンロードは検出できますが、リポジトリ自体の侵害は防げません。価格表は厳格な
  > ルールで検証される単なるデータで、署名はされていません。

## 6. Live reporting

Off by default and subject to the master switch: with `networkEnabled` off no report, registration or discovery
request is made and the pane shows `settings.network.offHint`. The protocol — discovery, device registration,
signed reports, what is and is never sent, error handling — is `spec/REPORTING.md`; the values and the scheduler are
METRICS 11; Settings, consent and storage of keys are DESIGN 11. Differences from the common rules above:

- It sends data about the user's live activity (REPORTING 1.3), with a username, a per-service device id and
  signature headers; and, when the user entered one, `Authorization: Bearer <api key>` — only to that service's API
  host.
- Hosts are not a fixed list: the service URL the user entered or picked (preset: `https://deng.codexradar.com`) and the
  `api` host of its discovery document, both shown in the consent sheet and pinned (REPORTING 3.3). HTTPS only, except
  `http` to `127.0.0.1`, `[::1]` and `localhost` for local testing.
- Methods `GET` (discovery), `POST`, `PATCH`, `PUT`, `DELETE`. API requests never follow redirects; discovery
  follows at most 3, `https` only. Timeouts 15 s (discovery) and 10 s (API).
- No `ETag`-based caching except for the discovery document; failures are not retried daily but handled by the
  report scheduler (METRICS 11.5) and shown in the pane's status line, never as dialogs or notifications.
- README and About wording for this feature: DESIGN 11 (prepared, applied when the feature ships).

### Optional profile and report extensions

`spec/REPORTING-EXTENSIONS.md` defines independently advertised model/Harness counts, execution-mode metadata,
avatars and approved one-time device pairing. Model breakdowns require the existing models sharing switch.
Profile requests use the same confirmed API host, signature, redirect policy and master network switch; they
are explicit actions available for an already registered device even when periodic reporting is paused.
Opening the profile surface may fetch the signed profile and current avatar. Pairing polls only while its
surface is open (at least 2 s between requests), and stops on close, expiry or network disable.
No image or pairing code is included in telemetry, persisted in settings or written to application logs.
Avatar input stays local until upload: PNG/JPEG up to 10 MiB is re-encoded without source metadata as one
256×256 PNG up to 512 KiB. Profile JSON responses are bounded to 64 KiB; these separate limits do not raise
the existing 16 KiB periodic report limit. Avatar URLs are website metadata; native clients download their
own avatar through the signed API endpoint rather than following an arbitrary external image URL.
