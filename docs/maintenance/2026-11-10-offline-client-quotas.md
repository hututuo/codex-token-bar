# Claude / Antigravity 离线额度来源与统一投影

日期：2026-11-10，Asia/Shanghai。基线 HEAD：`c295a3e59dbcbeea26be3d908634c12b60308e76`。
本批为源码修改；尚未构建、打包、安装或实机 GUI 验收。用户要求不发送网络请求，因此没有推送、查询或触发云端工作流。

## 定位：Claude 持续运行，旧文件却不再更新

“过期”是 Token Bar 对本地观察采用的 20 分钟新鲜度判定，不代表订阅失效、额度耗尽或 Desktop 已关闭。

只读核验发现两条不同的本地来源：

| 来源 | 实测采样时间（北京时间） | 数据 | 结论 |
| --- | --- | --- | --- |
| `Claude/plan-usage-history.json` | 11 月 9 日 09:55:53 | 5h 已用 0%，7d 已用 59% | 旧入口读到了陈旧文件 |
| `Claude/Cache/Cache_Data/*_0`，官方 `/usage` 响应 | 11 月 10 日 19:31:40 | 5h 已用 30%，7d 已用 90% | 有更新的离线来源，旧实现漏读 |
| 同一 HTTP 缓存再次核验 | 11 月 10 日 20:16:08、20:21:58 | 20:21 记录为 5h 已用 33%，7d 已用 90% | 缓存由 Claude 自身持续更新；不能归因于用户未打开应用 |

最后一次只读核验在 20:23:24：Simple Cache 两段 CRC32 和 key SHA256 一致，zstd 响应可解码。5h 重置时间为 11 月 10 日 21:39:59，7d 为 11 月 11 日 18:59:59。数值只是该采样时点的记录，不承诺持续不变。未保存响应原文、组织 ID、认证字段或 Cookie。

Claude CLI 的 app-owned statusline 和 `.claude-monitor/statusline/latest.json` 均不存在；CLI 本机 API 配置与 Desktop 订阅来源保持分离。

Antigravity 已定位两种缓存：

- IDE `User/globalStorage/state.vscdb` 的 `antigravityUnifiedStateSync.userStatus`，是两层 base64/protobuf 封装。只查询这一项并解析模型额度字段。该格式没有可信采样时间，不能用 SQLite 文件/WAL 修改时间冒充额度更新时间；本机记录的重置时间已过期。
- `.antigravity_tools/accounts.json` 的 `current_account_id` 指向当前 Tools 记录，其 `quota.last_updated` 为 **2026-06-09 19:48:04**，含 16 个模型额度。它不是当前 Antigravity 余额的证据。只选择索引指定账号，不遍历其他账号，不回退 `.bak`。
- 没有在新版 Antigravity 已检查的本地文件中找到当前有效额度采样；未调用 localhost RPC、额度 API、CLI 刷新或 GUI 来制造新采样。

## 扫描与收束

| 职责 | Swift | Rust / Tauri |
| --- | --- | --- |
| 有界文件读取 | `LocalQuotaCacheFile` | `local_quota_cache` |
| Claude HTTP 缓存 | `ClaudeDesktopHTTPCache` | `claude_desktop_http_cache` |
| Claude 来源选择 | `ClaudeLocalQuota.readDesktop / desktopObservation` | `read_claude_desktop_quota / select` |
| Antigravity 本地缓存 | `AntigravityLocalQuota` | `antigravity_local_quota` |
| 统一后台刷新 | `MultiClientUsageStore.refreshLocalQuotaCaches` | `read_local_client_quotas` 与现有一分钟缓存 |
| 统一 UI 投影 | `ClientQuotaProjection.items(localReadings:)` | `quotaItems(localReadings)` / `useClientQuotaItems` |
| 消费端 | 主页面、侧栏二级/三级、额度设置、客户端设置 | 同等消费端及账本刷新失败时的独立 IPC 回退 |

不再在 UI 投影中写死“只接受 Claude CLI/Desktop”或只遍历 5h/7d。Antigravity 模型使用来源 ID 保持身份，展示名变化不改变选择项；保留真实 0%，不合计模型余额。

Claude HTTP 解析只接受本地 Chromium Simple Cache v5 中指定官方 HTTPS `/usage` key，校验 footer、两段 CRC32 与 key SHA256。支持 identity 和 zstd；其他编码明确不可用，不联网补取。单条最大 2 MiB、解码结果 64 KiB、zstd window 1 MiB、目录最多 20,000 项；只读目录首层，并拒绝文件符号链接。新格式需要对应的明确适配。

两个 Claude 来源比较真正的采样/响应时间后**整份选择**，不从旧账号、旧来源补齐新记录缺失的 5h 或 7d。HTTP 来源保留响应中的重置时间；旧历史来源继续不编造重置时间。新缓存已失效或结构无效时，不借较旧记录伪装有效。

Antigravity 优先读取存在的 Tools 当前所选账号缓存；没有 Tools 索引时才读 IDE 状态库。选中的 Tools 文件缺失、损坏或账号不匹配时不跳到其他账号来源。账号文件虽与认证字段共存，生产投影只取额度、来源与采样时间，不使用认证字段、访问 Keychain 或输出原始文件。该 Tools 账号未与运行中的 Antigravity 账号绑定，界面明确说明。

状态边界：有效且未越过已知 reset 的采样才显示当前余额；过期或没有采样时间的 Antigravity 数据只显示一个缓存状态项，不画成满额圆环。客户端设置可展开“历史缓存（非当前余额）”查看旧模型值。移除了以“应用可能暂停”解释历史文件不更新的推断提示。

存储职责 A–D、原始 Token/计价账本、迁移、认证配置、网络设置均未改动；没有写入 provider 缓存或用户业务数据库。

## 检查与未执行边界

- 新增共享 `fixtures/local-quota-caches.json`：20 个合成案例，涵盖 zstd/identity、完整性损坏、错误来源、真实 0、20 分钟边界、未来时间、无效/缺失字段、已过 reset、账号不匹配、禁用、禁止访问、protobuf 默认零值及未知采样时间。包含假凭据标记以检查投影不泄漏；不含真实用户记录。
- 新增 Swift `OfflineClientQuotaTests`、Rust `offline_quota_cache_tests`、Tauri `offlineQuotaProjection.test.mjs`；更新原消费者、独立刷新失败与 API 模式回归，覆盖 Antigravity 接线。上述完整测试套件 **NOT_RUN**。
- **PASS**：用 Node 内置 TypeScript 类型擦除执行实际生产投影的定向断言，验证客户端隔离、两种客户端额度、0% 与 NaN、显示选择、过期状态、HTTP 重置时间、API 模式与来源标识；没有安装依赖或构建前端。
- **PASS**：修改的 Swift 生产代码/测试 `swiftc -frontend -parse`；Rust 新模块和接线文件用 rustfmt 进行语法解析；修改的 JS 测试 `node --check`。这些是语法检查，**不等同于类型检查、编译或运行原生测试**。
- **PASS**：`git diff --check`；受保护文件 `AGENTS.md`、`HANDOFF.md`、`2026-10-03-windows-incomplete-scan-report.md` 的 SHA256 与接手基线一致；原有其他 dirty/untracked 材料保留。
- **NOT_RUN**：原生构建/测试、完整前端测试、云端门禁、候选包、安装、GUI 验收。遵循本轮不联网和项目云端构建规则，没有在本机替代重编译；也没有使用旧测试二进制证明新代码。

后续需在允许 CI 联网后完成编译与三大云端门禁；实机替换或 GUI 验收前仍按用户在场规则安排。当前 `/Applications/Codex Token Bar.app` 未因本批修改而替换。
