# v0.7.2 Tauri / Windows 全项目上下文人工审查

## 1. 审查身份与源码边界

- 审查类型：完整发布产品人工源码审查，不是 recent-diff review，也不是自动扫描。
- Worktree：`/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2`
- 审查分支：`audit/v0.7.2-full-project`
- 审查分支 HEAD：`c7050b0537ea64a55dfcd04ceabf2f353a63bc9a`
- 发布源码边界：tag `v0.7.2`，commit `e48930a626679230d5d52267c830812f254fdd26`
- 基准核验：`git diff e48930a..HEAD -- tauri-app scripts` 无差异；审计分支在发布 tag 之后只包含正式发布记录和审计材料。因此本文的产品源码判断对应已发布 v0.7.2。
- 初始状态：`## audit/v0.7.2-full-project...origin/main [ahead 4]`，产品树干净；`audits/v0.7.2/reports/` 中已有另一审查者未跟踪的 `commander-core-review.md`，本文未读取、未修改它。
- 最终状态见文末。本文是本轮唯一新增文件；没有修改产品、测试、脚本或发布元数据。

## 2. 实际覆盖范围与充分性

本轮人工重读并串联了以下范围：

- React/TypeScript 入口、主界面、悬浮窗、状态面板、托盘、设置与首次引导。
- dashboard fast/precise load、刷新计划、wake、quota cadence、live-rate feed、merge/warning 模型。
- Codex Home 保存、事件同步、compact snapshot、quota surface、unread acknowledgement。
- Rust IPC 注册、window allowlist、capability JSON、CSP、窗口创建与 Windows single-instance。
- JSONL/state SQLite 用量统计、fork replay、active rollout、token shard/aggregate cache、排行和缓存生命周期。
- quota app-server 子进程、CLI 自动发现、rate-limit/reset-credit 解析、stale-success、quota history。
- live-rate logs/rollout 双路径、monitor/refcount、selected/all-session、未读读取。
- Radar public/full-detail、错误/陈旧状态、08:00/18:00 调度、Rust full-detail command。
- ProviderRepair 扫描、备份、同步、验证、回滚、前端 operation controller 和 panel copy。
- Tauri updater、Windows capability/CSP、Windows release PowerShell、debug handoff 和 Codex Desktop sidebar patch 脚本。
- 现有 Rust/Node 测试入口、source-shape assertions、提交历史和关键行 `git blame`。

覆盖规模参考：179 个 TS/TSX 文件、70 个 Rust 文件、10 个 scripts、54 个 test/spec 文件。未运行 Knip、Biome、JSCpd、Clippy、Machete、mutants 或其他自动扫描；未运行构建/测试，符合 brief 的人工只读边界。

充分性判断：对核心读取、统计、实时速率、额度、Provider 写入、三 surface 同步、IPC 和发布脚本已经形成端到端调用图，足以确认下列问题。Windows 原生运行、真实 Codex WAL 时序、真实 updater 安装和视觉/辅助功能仍需要后续运行态覆盖，因此对应项没有被包装成“已确认”。

## 3. 核心流图与必须维持的不变量

### 3.1 启动、source 与 surface

```text
Tauri run
  -> setup_desktop_surfaces
  -> main / floating / status webview
  -> App surface router
  -> read_app_settings
  -> selected Codex Home (settings.codex_home or platform default)
  -> dashboard / quota / live-rate / compact readers

main settings changes
  -> Rust read-modify-write settings.json
  -> optional frontend event
  -> floating/status local React state
```

不变量：

1. Codex Home 切换后，旧 source 的总量、今日、请求、额度、未读和 live-rate 都不能继续标成新 source 数据。
2. surface command 失败/timeout 不能伪装成已确认的用户设置。
3. floating/status 只应拥有轻量读取和自身窗口能力；主界面敏感命令保持 main-only。

### 3.2 用量总量链

```text
sessions/**/*.jsonl + active state_5.sqlite.rollout_path
  -> session parser (fork/subagent/replay policy)
  -> per-session token-event shard cache v8
  -> dashboard aggregate cache v10
  -> DashboardSnapshot / TokenUsageSummary
  -> dashboard + compact/floating/status labels
```

不变量：

1. `总/今/次` 只能来自可信 precise event aggregate，不能来自 `tokens_used` 或 live-rate totals。
2. cache scope 必须包含 Codex Home、本地日期、UTC offset、文件签名和语义版本。
3. fork replay 的 2 秒退出 grace 不能被机械删除；它保护真实 multi-session-meta replay 文件不被重复计数。
4. same-source aggregate 暂时失配时可保留上一份可信摘要并后台更新；跨 source/date/offset 不复用。

### 3.3 额度与历史链

```text
selected Codex Home/auth.json
  -> discovered Codex CLI
  -> app-server JSON-RPC account/rateLimits/read
  -> rate-limit + plan parser
  -> reset-credit HTTP read
  -> per-home quota cache/stale-success
  -> quota-history.sqlite
  -> dashboard merge + compact surfaces
```

不变量：

1. app-server deadline 的主分类仍是 timeout；stderr 噪声只作为 raw cause。
2. 新读取失败时保留同 source 上一次真实额度，并明确 stale。
3. reset-credit 失败不能清空成功的主额度；unknown/past expiry 不能制造 countdown。
4. quota history 必须属于真实账户身份，不能因为昵称或计划相同而跨账户混合。

### 3.4 实时速率与未读链

```text
logs_2.sqlite(+WAL), otherwise recent rollout JSONL
  -> event attribution/dedupe
  -> LiveRateMonitorService
  -> shared stream registry/refcount
  -> global live-rate-snapshot event
  -> dashboard/floating/status

.codex-global-state.json + state_5.sqlite/session meta
  -> visible unread thread filter
  -> per-Codex-Home acknowledgement
```

不变量：

1. `live_rate_summary` 是准备态；只有 `live_rate_stream` 是失败/重试态。
2. all-session 与 selected-session 不得相互覆盖；多 surface subscriber 不能互相停止。
3. live-rate tick 不得扫描完整 usage tree；总量仍取 O(1) 同源可信摘要。
4. unread acknowledgement 只能写应用自己的 baseline，不能修改 Codex unread state。

### 3.5 Radar、ProviderRepair 与 updater

```text
Radar public current.json -> dashboard/floating basic view
Radar full Rust command -> authenticated detail overlay, main-only

ProviderRepair panel -> scan -> backup -> sync/verify/rollback
                   frontend operation controller
                   Rust direct filesystem/SQLite mutations

Tauri updater -> latest-windows.json -> signed NSIS download/install -> relaunch
```

不变量：

1. Radar public failure保留上一份 public 数据；full-detail 失败不能拖垮 basic surface。
2. Provider destructive operation 必须后端串行化、可恢复且使用当前 source 的一致性备份。
3. Windows updater metadata/signature 与 installer 架构必须一致；私钥不得进入 Windows 构建机或 Git。

## 4. 确认问题（按严重度）

### High-1：Codex Home 切换不会通知已打开的 compact surfaces，旧 source 总量/额度可显示在新 source 下

**证据**

- `tauri-app/src/state/useDashboardActions.ts:124-136` 的 `updateCodexHome` / `restoreAutoCodexHome` 只保存 source 并重载主界面，没有发布 `app-settings-changed`。
- `tauri-app/src/floating/FloatingWindowApp.tsx:110-138` 与 `tauri-app/src/status/StatusPanelApp.tsx:68-98` 只在首次读取或收到该 event 时更新 `codexHomeKey`。
- `tauri-app/src/surfaces/useCompactPanelSnapshot.ts:61-71,84-98` 依靠 `sourceKey` 清旧摘要；summary 暂不可用时会刻意保留旧摘要。
- `tauri-app/src/surfaces/useCompactPanelSnapshot.test.mjs:131-137` 只测试纯 helper，且明确把“manual path -> null(auto)”判成不重置，不能覆盖真实跨组件 wiring。
- `tauri-app/src/surfaces/useCompactPanelData.ts:42-52` 没有把 `sourceKey` 传给 `useCompactPanelQuota`；`tauri-app/src/surfaces/useCompactPanelQuota.ts:15-63` 也没有 source 概念，旧额度会一直保留到下一次 timer 成功。

**影响**：用户在主界面切换 Codex Home 后，悬浮窗/状态面板可继续显示上一个目录/账户的 `总/今/次` 和额度。若新 source 正在首次建 aggregate，旧 precise summary 会被保留到构建完成；额度最长可滞留用户配置的 10 分钟 cadence。属于跨账户数据正确性问题。

**触发条件**：floating/status 已打开；主界面设置新 Codex Home 或恢复 auto；新 source 没有立即可用的 summary/quota。

**置信度**：高，调用链完整且缺少任何 source-change event 发布。

**建议复现**：两个 fixture Codex Home 写入明显不同的 usage；挂载 main + floating/status harness，切 A -> B 和 manual -> auto，令 B 首次 summary 返回 null，断言 surface 立即清除 A 且不会保留 A quota。

**缺失测试**：真实 `set/reset Codex Home -> settings event -> compact source reset` 行为测试；`useCompactPanelQuota` source transition 测试。

### High-2：ProviderRepair 的 destructive operation 只有前端 gate；timeout 后 Rust 写操作仍可与下一次操作重叠

**证据**

- `tauri-app/src/api/providerRepairClient.ts:17-30` 给 backup/sync/rollback 设置 60 秒前端 timeout。
- `tauri-app/src/platform/runtime.ts:5-17` 只 `Promise.race`，不会取消 Rust command。
- `tauri-app/src/components/ProviderRepairCard.tsx:105-133` timeout/rejection 后结束 controller operation 并清 busy。
- `tauri-app/src/components/providerRepair/operationController.ts:26-68` 的互斥只存在于单个 React card 内存。
- `tauri-app/src-tauri/src/commands/provider_repair.rs:27-63` 和 `core/provider_repair.rs:32-92` 没有 Rust in-flight gate、generation token 或 cancellation。

**影响**：较大的 session tree 使 sync/backup 超过 60 秒时，界面重新允许操作；第二次 sync/rollback 可与仍运行的第一次 Rust 写入并发，竞争 JSONL、SQLite、session_index 和备份目录，造成部分写入或回滚结果不确定。

**触发条件**：Provider operation 超过前端 timeout；或另一 invoke/未来另一窗口绕过同一 card controller。

**置信度**：高；前端 timeout 与后端非取消命令语义明确。

**建议复现**：给 Rust Provider command 注入可控阻塞 seam；启动 sync A，模拟前端 60 秒 timeout，再启动 rollback B，断言后端 gate 拒绝 B 且 A 仍处于 uncertain/busy。

**缺失测试**：backend operation serialization；frontend timeout 后 uncertain state；真实 command 超时生命周期。

### High-3：Provider SQLite 备份/回滚不是一致性快照，可能丢弃 WAL 中已提交数据

**证据**

- `tauri-app/src-tauri/src/core/provider_repair/backups.rs:37-48` 分别复制 `state_5.sqlite`、WAL、SHM，WAL/SHM copy 错误被忽略；复制期间没有 SQLite online backup、事务或停止写入保证。
- `backups.rs:117-137` 回滚只恢复 `state_5.sqlite.before`，随后删除当前 WAL/SHM；已经备份的 `state_5.sqlite-wal.before` 从未恢复。
- `tauri-app/src/pages/dashboard/ProviderRepairPanel.tsx:55-57` 仅“建议”退出 Codex，未把正在运行的 Codex 作为写操作 hard gate。
- `tauri-app/src-tauri/src/core/provider_repair_tests.rs` 没有 WAL-mode/uncheckpointed-row 备份恢复测试。

**影响**：若 Codex 正在 WAL 模式写 `state_5.sqlite`，主库副本可能依赖 WAL 才包含最近已提交行；回滚恢复旧主库并删 WAL，会永久丢掉这些行。分文件复制还可能生成彼此不一致的主库/WAL 组合。

**触发条件**：创建备份或回滚时 Codex 有未 checkpoint 的 WAL 提交。

**置信度**：高，恢复代码明确不读取已保存 WAL。

**建议复现**：WAL-mode fixture 中提交但不 checkpoint 一行，创建 Provider backup，再修改并 rollback；重新打开数据库后验证该行与 `PRAGMA integrity_check`。同时模拟 WAL copy 失败，备份必须失败而非宣称完整。

**缺失测试**：SQLite online backup/consistent snapshot、WAL restore、copy failure、运行中 Codex gate。

### Medium-1：Provider UI 承诺“每次同步先创建完整备份”，实际只复用任意已有备份

**证据**

- `tauri-app/src/pages/dashboard/ProviderRepairPanel.tsx:55-57` 明确显示“所有同步都会先创建完整备份”。
- `tauri-app/src/components/ProviderRepairCard.tsx:88-95` 从现有 backup 列表选一个 ID 后直接 sync。
- `tauri-app/src-tauri/src/core/provider_repair.rs:42-67` 只加载并校验该旧 backup；同步开始前没有调用 `create_provider_backup_files`。

**影响**：用户可能把数天前的 backup 当作本次同步的安全回滚点。同步前新增的有效会话不在旧 backup 中，回滚会退得过远。安全文案与真实保障不一致。

**触发条件**：已有任意 backup 后，Codex 数据继续变化，再点击同步。

**置信度**：高。

**建议复现**：创建 backup A，追加 session B，执行 sync；断言 sync 自动生成时间更晚的 backup C 并返回 C，而非 A。

**缺失测试**：sync preflight backup freshness、backup count/timestamp、失败时不得进入写入。

### Medium-2：共享 settings.json 是无锁 read-modify-write 且非原子覆盖，多个 surface 可丢字段或读到半写 JSON

**证据**

- `tauri-app/src-tauri/src/platform/settings.rs:16-63` 每个 setter 都独立读取整个 settings、修改一个字段、再覆盖整个文件。
- `settings.rs:84-92` 使用直接 `std::fs::write`，没有 process mutex、unique temp + rename 或 compare-and-merge。
- `tauri-app/src/floating/useFloatingWindowPlacement.ts:24-30` 移动事件异步保存 position；主界面同时可保存 floating style、display surfaces、quota cadence、昵称、setup state 或 Codex Home。
- 保存调用多处 `.catch(() => {})`，丢更新没有用户可见诊断。

**影响**：两个近同时 setter 都基于旧 snapshot 时，后写者会覆盖前者的字段；崩溃/读取与覆盖写交错还可能让三 surface 暂时把设置当无效 JSON。表现为悬浮位置、开关、刷新频率或 Codex Home“自己变回去”。

**触发条件**：拖动 floating window 的同时在主界面改设置，或多个快速设置保存重叠。

**置信度**：高，典型 lost-update 时序在当前实现中成立。

**建议复现**：给 storage 注入 barrier，让 `save_floating_position` 和 `save_display_surfaces` 在相同旧 snapshot 后并发写；最终文件必须同时保留两项并始终可解析。

**缺失测试**：concurrent field updates、atomic write/crash safety、save error surfacing。

### Medium-3：quota history 以显示名 + plan 识别账户，两个真实账户同名同计划时会混合历史

**证据**

- `tauri-app/src-tauri/src/core/quota/auth.rs:21-33` 只从 JWT `name/nickname/preferred_username/email` 选择显示名，不读取稳定 `sub/account_id`。
- `tauri-app/src-tauri/src/core/quota_history.rs:186-210,325-340` history key 是 `account_name|plan_type|codex`，不含稳定账户 ID 或 Codex Home。
- `tauri-app/src-tauri/src/core/quota_history/database.rs:81-170` compatibility query 按 `account_name`、plan、limit 匹配。
- `database.rs:234-264` history bundle 先从整个数据库选最新 row，再以该可碰撞 identity 读取。

**影响**：两个 Codex Home 使用相同昵称/姓名与计划时，主界面 24h/7d/30d 额度历史可合并或选错账户；当前实时额度仍按 source 读取，但历史 overlay 不可靠。

**触发条件**：切换到另一个同显示名、同 plan 的账户并产生 history rows。

**置信度**：高。

**建议复现**：写入两个不同 JWT `sub`、相同 `name` 与 `Plus` 的 bundle，历史查询必须隔离；验证旧 fake-Pro rows 只按明确迁移策略兼容。

**缺失测试**：same-display-name multi-account isolation、stable subject migration。

### Medium-4：Radar full-detail bearer credential 可由发布二进制确定性还原

**证据**

- `tauri-app/src-tauri/src/commands/codex_radar.rs:9-17` 把 cipher 和 mask 一起嵌入客户端。
- `codex_radar.rs:59-74` 在本地用公开算法还原 key 并拼入 Authorization header。

**影响**：任何获得开源代码或发布二进制的人都能重建共享 bearer credential，绕过应用调用 full endpoint；可能消耗配额、触发封禁/轮换，并让所有客户端 detail 功能同时失效。它没有进入 TS bundle，但“Rust-only obfuscation”不构成 secret storage。

**触发条件**：读取源码或静态分析二进制。

**置信度**：高；可逆性是设计本身。API key 权限/计费范围未在仓库中证明，因此业务损失上限需服务端确认。

**建议复现**：无需打印 key；测试一个外部 extractor 只能确认重建字节的 hash 与运行时 header hash 相同。产品目标应改为服务端代理、用户自带 key、或限域/可轮换短期 token。

**缺失测试**：服务端 scope/rate-limit/rotation contract；仓库只能做 raw-key leak guard，不能证明 credential 安全。

### Medium-5：官方 Windows release 脚本要求把 updater 私钥放到 Windows，与 v0.7.2 实际安全流程冲突

**证据**

- `scripts/build_tauri_windows_release.ps1:86-121` 强制 Windows 端存在 `TAURI_SIGNING_PRIVATE_KEY(_PATH)`，并把私钥内容放入环境后由 Tauri build 生成 `.sig`。
- `README.md:181-187,358-364` 把该脚本作为标准本地打包入口，没有说明 Mac-side signing split。
- `release-ledger/v0.7.2-tauri-prep.md:26-33` 与 `release-ledger/v0.7.2.md:49-56` 记录的真实安全流程正相反：私钥未离开 Mac；Windows 临时关闭 updater artifacts，拉回 installer 后在 Mac 签名。

**影响**：下一次维护者按 README 运行会被阻塞，或为了让脚本通过而把长期私钥复制到 Windows，破坏已接受的 key-custody 边界。当前 release 无法用仓库脚本按记录流程复现。

**触发条件**：下一次 x64/ARM64 Windows release。

**置信度**：高。

**建议复现**：在无私钥 Windows fixture 运行 preflight，应生成 unsigned installers + manifest，而非失败；Mac-side signer 再消费 manifest/installer 并生成 `.sig`/metadata。

**缺失测试**：两阶段 release pipeline、private-key absence success path、installer/hash/signature handoff contract。

### Low-1：`useCompactPanelQuota` 的 mounted ref 在 React StrictMode effect replay 后永久为 false

**证据**

- `tauri-app/src/main.tsx:56-61` 全应用包在 `React.StrictMode`。
- `tauri-app/src/surfaces/useCompactPanelQuota.ts:21-29` ref 初值 true，effect cleanup 设 false，但 effect setup 不重新设 true。
- `useCompactPanelQuota.ts:38-40` 只有 ref 为 true 才发布 quota。

**影响**：在启用 Strict Effects 的开发/harness 环境中，首次 setup-cleanup-setup 后 quota 结果永远被丢弃，造成 debug 与 production 行为不一致并降低测试可信度。Vite production bundle通常不执行开发期 double-effect，因此不按发布阻塞评估。

**触发条件**：React development StrictMode effect replay。

**置信度**：高。

**建议复现**：StrictMode render hook，resolve fake quota 后断言更新；setup 时设 true 或改用 request generation/cancelled closure。

**缺失测试**：`useCompactPanelQuota` 没有直接 hook/lifecycle 测试。

### Low-2：关键跨组件 wiring 仍由 source-string assertions 兜底，存在“字符串都在但行为断裂”的假阳性

**证据**

- `tauri-app/src/app/surfaceState.test.mjs:19-37` 只证明 cadence 相关文件里出现 `publishAppSettings`/listener 字符串；它没有验证 Codex Home 保存会发布 event。High-1 正好通过了这些 source checks。
- `surfaceState.test.mjs:366-402` 只检查 updater 配置/脚本字符串，无法发现 Medium-5 的两阶段 key-custody 冲突。
- `status/statusPanelActions.test.mjs`、`floating/floatingEffects.test.mjs` 等仍有大量源码/CSS 正则；后者主要保护视觉实现细节而非 runtime lifecycle。

**影响**：重构时噪声高，真正的数据流断路却可保持全绿；审查者容易把“wiring smoke”误当行为覆盖。

**触发条件**：跨 hook/event/IPC 行为改变但保留相同标识符。

**置信度**：高。

**建议复现**：把 Codex Home event 发布替换为 no-op，现有 source test仍通过；改用注入式 desktop event bus + hook harness/SSR model 测试。

**缺失测试**：main/floating/status 联合 fixture、timer/listener cleanup、window lifecycle、updater two-stage preflight。

## 5. 需要复现或产品决策的问题

### S-1：live-rate recent rollout thread cache 没有把 `state_5.sqlite-wal` 纳入 invalidation

- `tauri-app/src-tauri/src/core/live_rate/rollout.rs:105-133` 只以主 `state_5.sqlite` size/mtime 缓存 recent rollout thread 列表。
- `tauri-app/src-tauri/src/core/live_rate/monitor.rs:202-221` monitor signature包含 `logs_2.sqlite-wal`，但 state 仍只有主库。
- 若 Codex 以 WAL 模式新增 active thread/rollout_path 且尚未 checkpoint 主库，同时 logs source 为空，fallback 可能继续监听旧 20 个文件。
- 尚未在本轮证明当前 Codex `state_5.sqlite` 的 journal mode/commit 时序，故不列确认缺陷。下一步应做 WAL fixture：主库 mtime 不变、WAL 新增 thread，断言 thread cache刷新。

### S-2：`--autostart` 参数被注册但没有控制 dashboard 可见性

- `tauri-app/src-tauri/src/lib.rs:15-18` autostart 注册 `--autostart`。
- 源码没有其他 `--autostart` 读取；`platform/surfaces.rs:391-417` 页面加载完成后总是 show + focus 主窗口。
- `platform/capabilities.rs` 的 capability note 已承认“登录后隐藏主界面仍需按平台验收”。
- 若产品目标是“登录时后台常驻”，这是确认 bug；若目标就是登录即打开 dashboard，则只是缺少明确文案/测试。需要 commander/product 决定后做 Windows login-start integration。

### S-3：custom-command allowlist 是文档/测试映射，不是所有 handler 的运行时 guard

- `commands/window_auth.rs` 列出 main-only/surface-safe commands。
- main-only handlers普遍接收 `WebviewWindow` 并调用 guard；多数 surface-safe handler不接收 window，也不会执行该 allowlist。
- 当前只创建固定 `main/floating/status` 三个 local webview，CSP 与 capability split 降低外部触发面，因此未证明可利用的越权路径。
- 下一步应明确 custom command 是否受 Tauri v2 capability ACL 约束；若否，给所有 handler统一 guard，并做真实 invoke integration，而不是仅测试常量映射。

### S-4：Provider whole-operation 不是跨文件事务

- JSONL 单文件用 temp + rename，但 sync 顺序是多 JSONL -> SQLite -> session_index；中途失败会留下部分修复。
- 只要 High-3 的 backup 真正可靠，部分写入可通过 rollback 处理；当前两者叠加才构成高风险。
- 目标设计需要决定：operation journal/rollback-on-error，还是强制 fresh consistent backup + 明确“失败后回滚”。不建议直接做大事务重写。

### S-5：Radar RSS URL 被 CSP 固定为 `/feed.xml`

- public payload 提供 `links.rss`，client会 fetch 该值；CSP只允许 `https://codexradar.com/feed.xml`。
- 当前服务返回值若稳定则无问题；未来改路径/domain会表现为 RSS partial failure。应由 API contract 或 allowlisted URL normalization 决定，不应放宽整个 domain。

## 6. 已否定或已过时的历史担忧

1. **fork replay 应删除 2 秒 grace**：否定。当前 parser/cache version 与真实 multi-session-meta replay语义需要 grace，已有回归；机械改成首个 user_message 退出会重引入巨额重复计数。
2. **compact `总/今/次` 会回退 live-rate totals**：当前已否定。`compactPanelSnapshotModel` 只用 trusted usage summary；null 时 `待读取`/保留同源旧 trusted summary，Rust floating也读 scope-checked cached aggregate。
3. **live-rate 每 tick 扫完整 session tree**：当前已否定。live-rate summary走 O(1) in-memory same-home/date/offset cache；文件签名检查由 usage refresh负责。
4. **quota noisy stderr 会把 protocol timeout误报 parse/app-server failure**：已修。deadline始终构造 timeout primary，stderr保留 raw detail；stdout忽略非目标日志对象。
5. **quota失败会清掉上一份真实额度**：已修。同 Codex Home previous success保留并附 `stale_cached_data`。
6. **account plan 硬编码 Pro**：当前主 quota parser与新 history rows会读真实 plan；placeholder不再伪造 Pro。本文 Medium-3 是 identity 碰撞，不是 hardcoded-Pro 回归。
7. **Codex CLI 只认 `Codex.app`/`ChatGPT.app`**：已修。显式 override优先，macOS按 bundle id + 标准 Applications 有界扫描，验证 executable/symlink；Windows保留受限目录/PATH发现。
8. **Tauri `csp: null` / 三窗口共用 updater权限**：已修。CSP已收紧；main/floating/status capability分离；updater/restart只给 main。
9. **reset-credit unknown/past expiry 被排除计数或制造 countdown**：当前 helper/parser区分 counted availability 与 future-expiry；compact unknown/past为 count-only，used/expired不制造详情。
10. **Radar根失败清空 stale snapshot、RSS失败静默**：已修。public client保留上一份 snapshot/feed并标 root/feed stale；full-detail失败回退 public。
11. **Provider auto-scan失败循环**：已修。autoScan controller每个 panel mount只尝试一次；关闭重开才允许新尝试。
12. **cache-hit “最新”只在低命中裁剪集排序**：已修。Rust候选同时保留 low-hit 与 latest，TS再按 tab排序/截断。

## 7. 未覆盖区域与下一步闭环

### 尚未做运行态覆盖

- Windows x64/ARM64：autostart隐藏/显示、single-instance激活、tray click/status panel、floating window drag/placement。
- 真实 ProviderRepair：未对用户 Codex Home执行任何 scan/write；WAL风险只基于源码和 SQLite语义确认。
- 真实 updater：未下载/安装/relaunch；仅审查配置、脚本和发布 ledger。
- 真实网络：Radar public/full、reset-credit、Codex app-server未调用。
- 视觉/可访问性：未启动 App，不验证 keyboard focus trap、dialog focus restore、窄屏拥挤、ripple/callout clipping。
- 长时间 lifecycle：未观察 sleep/wake、日期/UTC offset跨界、连续 source switch、多个 surface同时订阅数小时。

### 建议覆盖顺序

1. **Provider safety batch（实现）**：Rust per-home operation gate；fresh pre-sync backup；SQLite online backup或明确停止 Codex hard gate；WAL fixture和 timeout integration。
2. **source propagation batch（实现）**：保存/reset Codex Home后发布带 resolved canonical home 的 source event；compact usage/quota统一 source generation；A/B/manual-auto hook fixture。
3. **settings durability batch（小重构）**：单一 Rust settings mutex + atomic temp/rename；所有 setter在锁内读改写；并发字段测试。
4. **quota history identity batch（需迁移设计）**：稳定 JWT subject/account ID + source scope，保留明确 legacy兼容窗口。
5. **Windows acceptance（运行态）**：autostart、single-instance、tray/surface、signed updater安装与重启。
6. **testability batch（测试）**：优先替换 source-change、Provider timeout、settings concurrency、release two-stage flow的 source-string assertions；纯视觉 CSS smoke可保留但标明性质。
7. **credential architecture（产品/服务端）**：确认 Radar full API key scope与轮换；不要继续把可逆客户端 obfuscation当 secret boundary。

## 8. 本轮变更声明

- 未修改任何 `tauri-app/` 产品文件、Rust/TS测试、scripts、README、release notes、ledger、appcast 或 updater metadata。
- 未运行产品构建、测试、自动扫描、App、进程管理、Provider写操作、reset-card动作、网络发布或 updater。
- 未触碰 Swift worktree/runtime。
- 唯一新增内容是 brief 指定的本审查报告。

## 9. 最终 Git 状态

报告写入后应显示：

```text
## audit/v0.7.2-full-project...origin/main [ahead 4]
?? audits/v0.7.2/reports/commander-core-review.md
?? audits/v0.7.2/reports/tauri-context-review.md
```

其中 `commander-core-review.md` 在本轮开始前已由其他审查者创建；本轮未读取或修改。
