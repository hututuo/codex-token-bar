# Codex Token Bar v0.7.2 Swift 独立盲审

## 结论摘要

- **审计基线：** release tag `v0.7.2`，commit `e48930a626679230d5d52267c830812f254fdd26`。
- **工作树 HEAD：** `e4d42d2d7e99f20b16d34551895262e8eaf705f7`。`Package.swift`、`Package.resolved`、`Sources/`、`Tests/`、`Resources/` 和发布脚本相对 `v0.7.2` 无差异，因此本报告的 Swift 产品与测试结论对应 `v0.7.2`。
- **确认问题：** P0 0，P1 3，P2 10，P3 3，共 16 条。
- **最高风险：** 数据源切换没有传递给实时速率；切换失败时旧目录的用量/额度/历史仍可出现在新目录上下文中；Provider 修复与回滚在 Codex 运行时仍允许写入其活动数据库和会话文件。
- **执行限制：** 按审计约定未构建、未运行 App、未运行测试、未调用 reset-card consume API、未执行 Provider 写入，也未使用 SwiftLint、Periphery、JSCpd、mutation 等扫描器。

## 方法与实际范围

本次为从架构入口向下的人工盲审。先从 `Package.swift`、`@main`、`DashboardView` 和对象所有权关系发现模块，再用源码阅读、`rg` 调用追踪和现有测试反查完整业务流；未从预设文件清单或既有审计结论出发。

### 精确统计

| 范围 | 文件 | 行数/数量 |
|---|---:|---:|
| `Sources/CodexTokenBar/*.swift` | 112 | 28,682 行 |
| `Tests/CodexTokenBarTests/*.swift` | 34 | 9,871 行 |
| Swift 合计 | 146 | 38,553 行 |
| `func test...` | - | 322 个 |
| 直接读取生产源码文本的测试 | - | 54 处 `String(contentsOf:)` |

### 已探索生产模块

- **应用与生命周期：** `CodexTokenBarApp`、`DashboardView`、启动展示、登录项、Sparkle 更新设置、菜单栏入口、显示模式迁移、通知与刷新计划。
- **数据源与权限：** `CodexDataSource`、自动/用户目录解析、安全作用域书签、Codex 二进制定位。
- **用量统计：** `CodexUsageStore`、`CodexUsageAnalyzer` 全部扩展、state SQLite、session JSONL、增量/持久缓存、聚合、缓存命中排行、热图与近期图表。
- **额度与历史：** `AccountQuotaReader/Store/Models/Diagnostics/ResetCredit`、刷新节奏、单调归一化、`QuotaHistoryStore` SQLite 持久化、额度消耗估计与展示。
- **实时速率：** `LiveRateMonitor` 全部扩展、`logs_2.sqlite` 持久连接、rollout 增量读取、流事件解析、去重、token 估算、`RateAccumulator`、轮询计划与视图。
- **未读与任务完成：** Codex 全局未读状态、SQLite/JSONL 可见性过滤、fallback scanner、读取基线、通知与未读计数状态机。
- **Codex Radar：** summary/detail/feed readers、授权、诊断、缓存回退、详情定时刷新、展示状态与视图。
- **Provider 同步：** 扫描、备份、session provider 重写、SQLite provider/时间戳修复、索引和全局状态协调、验证、回滚、Store 并发门禁和完整 UI。
- **展示表面：** Dashboard、悬浮窗、状态栏 popover、窗口跟随/辅助功能命中、位置持久化、外观/内容配置、未读 ripple/shimmer 帧缓存、界面缩放。
- **其他：** CSV/PNG 导出、SQLite 驱动、刷新性能探针、格式化与共享展示模型。

### 已探索测试模块

全部 34 个测试文件均已阅读：AccountQuota 的 diagnostics/binary locator/cadence/reset credit/store；Codex Radar 的 models/schedule/presentation/store/view placement；Unread reader；Usage analyzer/store/cache ranking；Dashboard refresh；Display migration；Floating visibility/effects；Interface scale；Live rate；Provider engine/store；Quota estimator/history/normalizer；Rate accumulator；Performance probe；SQLite driver；Startup；Status bar；Task monitor/baseline/scanner；Usage cadence recovery。

## 架构与所有权

`CodexTokenBarApp` 持有登录项、更新器、悬浮窗控制器和状态栏控制器。`DashboardView` 是业务对象组合根，持有 `CodexUsageStore`、`AccountQuotaStore`、`QuotaHistoryStore`、`CodexRadarStore`、`ProviderSyncStore`、`TaskCompletionMonitor` 和 `LiveRateMonitor`。Dashboard、悬浮窗与状态栏共享这些 Store/Monitor 实例；Provider 界面通过 Dashboard 当前数据源发起独立操作。

关键状态边界：

```text
CodexDataSourceResolver
  -> CodexUsageStore.currentDataSource + dataSourceLabel
  -> Dashboard onChange(dataSourceLabel)
       -> TaskCompletionMonitor.start(new source)
       -> AccountQuotaStore.setDataSource(new source) + refresh
       -X LiveRateMonitor.setDataSource(new source)  [P1-01]
       -X QuotaHistoryStore source/account transition [P1-02]
```

Store 的代际发布保护总体采用 `Task` + generation/source ID；持久数据分别落在 usage cache、quota-history SQLite、Codex 自身 SQLite/JSONL 和 Provider backup 目录。

## 完整业务流图

### 1. 数据源选择与切换

```text
security-scoped bookmark / default ~/.codex / discovered home
  -> CodexDataSourceResolver.resolve()
  -> Usage refresh captures source ID
  -> Dashboard observes usage label change
  -> quota + task monitor switch
  -> shared Dashboard/floating/status surfaces publish state
```

切换代际能阻止旧异步任务覆盖新任务，但没有统一的 source-scoped snapshot 容器，造成“旧值保留”和“实时监控未切换”两类不同问题。

### 2. 用量、缓存与聚合

```text
state_5.sqlite fast metadata
  + sessions/**/*.jsonl token_count / prompt / response parsing
  -> per-session incremental cache (plaintext excerpts excluded)
  -> daily/recent/hourly/plugin/cache aggregates
  -> CodexUsageStore generation-guarded publication
  -> Dashboard / floating / status bar / CSV-PNG export
```

session 文件追加、截断、删除和无换行尾部都有相应缓存分支；持久缓存以摘要替代原始 prompt/response。

### 3. 额度、重置卡与历史

```text
CodexBinaryLocator
  -> codex app-server --listen stdio:// (CODEX_HOME scoped)
  -> initialize -> account/rateLimits/read
  -> parse 5h/7d cards + local account identity
  -> GET /backend-api/wham/rate-limit-reset-credits
  -> AccountQuotaStore -> memory/history monotonic normalization
  -> QuotaHistoryStore SQLite record/reload/interpolation
  -> Dashboard / floating / status bar
```

重置卡路径只读取可用卡片，没有消费写调用。额度读取最多重试 3 次，每次进程等待窗口 12 秒。

### 4. 实时速率

```text
logs_2.sqlite stream rows (SSE/websocket/bridged log)
  + rollout JSONL append tail
  -> attribution + cross-source dedupe
  -> selected/all-session RateAccumulator
  -> 0.25s active / 1s idle adaptive poll
  -> Dashboard / floating / status bar
```

日志目录由 DispatchSource 观察；SQLite reader 为按路径缓存的持久连接；rollout reader 只提交完整换行记录。

### 5. 未读与任务完成

```text
.codex-global-state.json unread-thread-ids-by-host-v1
  -> SQLite/session visibility filter
  -> available unread set

unavailable native unread state
  -> sessions JSONL incremental fallback scanner
  -> task_started/user_message/task_complete state machine
  -> baseline + completed thread map
  -> notification + unread count
```

### 6. Codex Radar

```text
public current.json
  -> summary snapshot + server-provided RSS URL
  -> feed reader

authenticated /api/v1/current
  -> detail snapshot
  -> scheduled refresh slots

success/failure diagnostics + stale snapshot/feed fallback
  -> Dashboard/floating detail surfaces
```

### 7. Provider 同步与回滚

```text
scan sessions + state SQLite + index + global state
  -> detect target provider / timestamp collisions / workspace issues
  -> backup config + SQLite VACUUM INTO + index/global state + session tar
  -> atomic session first-line rewrites
  -> SQLite provider/timestamp transaction
  -> reconcile session index + workspace order
  -> post-write verification
  -> selected/latest backup rollback
```

Store 对并行 destructive operations 有串行门禁，但没有把 Codex 运行状态作为写入门禁。

## 确认问题

### P1-01 数据源切换未传递给 LiveRateMonitor

- **文件/行：** `Sources/CodexTokenBar/DashboardView.swift:297-301`；`Sources/CodexTokenBar/LiveRateMonitor.swift:24-26,321-334`；`Sources/CodexTokenBar/LiveRateMonitor+LogSource.swift:6-18`。
- **影响：** 用量、额度和未读已经切到目录 B 时，实时速率仍读取目录 A 的 `logs_2.sqlite` 与 rollout；同一悬浮窗/状态栏会混合两个目录的数据，并可能暴露旧目录正在输出的内容/速率。
- **触发：** Live monitor 首次轮询已解析目录 A，随后用户选择目录 B。
- **置信度：** 高。`poll()` 使用 `dataSource ?? resolver.resolve()`；一旦 `dataSource` 非空便不再解析新书签，而 Dashboard 切换回调没有调用已有的 `setDataSource`。
- **静态复现：** 让 monitor 在 A 上完成首次 `setDataSource`，再让 Usage Store 解析到 B；执行 Dashboard 的 `dataSourceLabel` 变化路径，检查 monitor 的 cached DB/rollout 路径仍为 A。
- **缺失测试：** 现有 `LiveRateMonitorTests.swift:515-623` 只直接调用 `setDataSource` 验证内部清理；缺少 Dashboard 数据源切换到 live monitor 的组合测试。

### P1-02 新数据源刷新失败时继续展示旧源用量、额度与历史

- **文件/行：** `Sources/CodexTokenBar/CodexUsageStore.swift:57-75,90-108,183-193`；`Sources/CodexTokenBar/AccountQuotaStore.swift:95-108,169-171,187-211,215-240`；`Sources/CodexTokenBar/DashboardView.swift:297-301`；`Sources/CodexTokenBar/QuotaHistoryStore.swift:628-695`。
- **影响：** 标题/目录标签已变为 B，但 B 的读取失败后仍显示 A 的 token、额度、账号和历史曲线。额度成功路径还会先把 B 与 A 的旧 snapshot 做单调归一化；当身份字段相同或都为空时，A 的值可影响 B 的首次显示。历史表没有 Codex Home 身份，reload 默认从全局最新账号开始。
- **触发：** A 已有成功 snapshot；切到 B；B 的 fast/precise usage 或 quota read 失败、超时或权限不足。
- **置信度：** 高。两个 Store 都在更换 source 后保留旧 snapshot；失败分支明确保留“已有可显示数据”，但 snapshot 不带 source ID。
- **静态复现：** 先向 Store 返回 A 的成功结果，再更改 resolver/currentDataSource 到 B 并返回失败；检查 `dataSourceLabel/currentDataSource` 为 B，而 snapshot 仍含 A 的统计/账号。随后 reload history，仍由全局 latest row 选账号。
- **缺失测试：** `CodexUsageStoreTests.swift:285-360` 和 `AccountQuotaStoreTests.swift:203-267` 覆盖同源 stale retention 与旧任务不能覆盖新任务，但没有“切源后新源失败”及 snapshot provenance 测试，也没有 history source/account transition 测试。

### P1-03 Codex 运行时仍允许 Provider 修复和回滚写入活动数据

- **文件/行：** `Sources/CodexTokenBar/ProviderSyncEngine.swift:107-151,168-182,231,259-262`；`Sources/CodexTokenBar/ProviderSyncView.swift:121-155`；`Sources/CodexTokenBar/ProviderSyncEngine+Sessions.swift:85-106`；`Sources/CodexTokenBar/ProviderSyncEngine+Backups.swift:139-190`。
- **影响：** 与 Codex 同时改写 session JSONL、state SQLite、session index 和全局状态，或删除 WAL/SHM 并替换主库，可能丢失并发写入、产生跨文件不一致、破坏当前会话或让回滚得到混合状态。
- **触发：** `codexRunning == true` 时点击“修复历史”或任一备份回滚按钮。
- **置信度：** 高。运行检测只附加“建议退出”文案；按钮 disabled 条件不含 `codexRunning`，engine 也没有 hard guard。
- **静态复现：** 构造 scan snapshot 的 `codexRunning=true`，检查修复/回滚按钮仍可用；跟踪到 `rewriteSessionMetaProvider`、SQLite 更新及 `restoreBackup` 的 remove/copy/tar 写路径。
- **缺失测试：** 没有“Codex 正在运行时 destructive operation 必须拒绝”的 Store/UI/Engine 测试，也没有并发写入故障测试。

### P2-01 Provider 写后验证失败不在自动回滚边界内

- **文件/行：** `Sources/CodexTokenBar/ProviderSyncEngine.swift:118-151`；`Sources/CodexTokenBar/ProviderSyncStore.swift:202-224`。
- **影响：** session/SQLite/index/global state 已修改，但第二次 `makeReport` 抛错时不会执行 catch 中的 rollback；UI只显示失败并保留旧 snapshot，新建 backup 路径也未通过结果暴露。用户会看到“失败”，实际写入却已提交。
- **触发：** 所有 mutation 成功后，post-write report 因权限变化、I/O、SQLite 打开/完整性检查等异常失败。
- **置信度：** 高（控制流），触发概率中等偏低。
- **静态复现：** 在 `reconcileWorkspaceOrder` 返回后、`makeReport` 入口注入错误；确认 catch 范围在第 148 行结束，backup 不回滚且 Store failure 分支只改 status。
- **缺失测试：** Engine 没有可注入的文件/报告阶段故障点；缺少 mutation 后验证失败、rollback 失败和 backup 可恢复性测试。

### P2-02 发布二进制内含可确定性还原的共享 Bearer 凭据

- **文件/行：** `Sources/CodexTokenBar/CodexRadarStore.swift:73-81,94-114`；`Tests/CodexTokenBarTests/CodexRadarModelsTests.swift:147-169`。
- **影响：** 任意获得 App 二进制或源码的人都可还原 token，并在 App 外调用 detail API。实际可造成的配额滥用、数据访问或封禁范围取决于服务端赋予该 token 的权限。
- **触发：** 分发含该字节数组和固定 XOR 逻辑的 App。
- **置信度：** 高（可提取性）；凭据权限与服务端限流影响未知。本审计未解码、记录或使用该 token。
- **静态复现：** 按 `token()` 的公开确定性算法对固定 cipher/mask 运行一次即可得到 Authorization 值；测试还要求请求包含非空 Bearer。
- **缺失测试：** 客户端测试不能让静态共享秘密变安全；缺少服务端短期签发、设备绑定、轮换/撤销和最小权限的契约验证。

### P2-03 fallback 任务扫描器永久跳过未写完整的 JSONL 尾记录

- **文件/行：** `Sources/CodexTokenBar/TaskCompletionScanner.swift:136-173,224-225`；`Sources/CodexTokenBar/TaskCompletionMonitor.swift:120-135`。
- **影响：** `task_complete` 正在分段写入时，第一次扫描解析失败却把 offset 推到整个文件末尾；后续追加剩余字节会从记录中间读取，该完成事件永久丢失，未读计数和通知漏报。
- **触发：** native unread state 不可用且轮询恰好落在 JSONL 一行的两次 write 之间。
- **置信度：** 高。
- **静态复现：** 写 session meta 和半条 `task_complete`，scan；追加剩余 JSON 与换行，再用前次 state scan；第二次从旧 EOF 开始，无法重组完整 JSON。
- **缺失测试：** `TaskCompletionScannerTests.swift:88-90` 的 fixture 始终一次性写入完整、换行结尾文件；缺少 partial-tail append 测试。

### P2-04 取消额度刷新不会终止旧 app-server 进程、重试或后续网络读取

- **文件/行：** `Sources/CodexTokenBar/AccountQuotaStore.swift:95-106,148-152,174-184`；`Sources/CodexTokenBar/AccountQuotaReader.swift:10-50,79-192,282-329`。
- **影响：** 切源后 A 的结果不会发布，但旧任务可继续启动/等待最多 3 次 app-server（每次 12 秒窗口），并可能继续用 A 的 access token 请求 reset-credit GET；浪费进程、CPU、I/O 和网络，并延长退出/切源后的后台活动。
- **触发：** quota read 卡在 process/JSON line wait 时切换目录或启动下一刷新。
- **置信度：** 高。同步 `readOnce` 循环没有 cancellation check，重试 sleep 用 `try?` 吞掉 CancellationError。
- **静态复现：** 使用不响应 rate-limit read 的 Codex binary，开始 A 刷新后切 B；取消只改变 generation，A 的 reader 仍走 deadline/retry，最后才由 Store 的 post-read cancellation guard 丢弃。
- **缺失测试：** Store 测试只用可控 async fake 验证发布代际；没有真实 reader 的 process termination/cancellation 测试。

### P2-05 stream delta 与 rollout agent_message 的常见组合可重复计数

- **文件/行：** `Sources/CodexTokenBar/LiveRateMonitor+StreamParsing.swift:47-66`；`Sources/CodexTokenBar/LiveRateMonitor+Rollout.swift:85-109,131-140`；`Sources/CodexTokenBar/LiveRateMonitor.swift:364-379,500-577`。
- **影响：** 同一助手回复先按多个 SSE delta 累加，随后又按 rollout 的完整 `agent_message` 全量计数，实时 token 和速率被放大。
- **触发：** rollout 中 `agent_message` 先于对应 `response_item`（现有测试已覆盖这种顺序），同时 logs DB 含该回复的 chunked output deltas。
- **置信度：** 高（当前键规则）；上游事件格式若改变则触发率变化。
- **静态复现：** 向一个 poll batch 提供 item ID 为 `msg-1` 的多个 delta，再提供相同全文的 rollout `agent_message`；rollout key 为 `agent:timestamp:hash`，文本为全文，无法匹配 stream 的 `msg-1 + 单个 delta 文本` fingerprint。
- **缺失测试：** `LiveRateMonitorTests.swift:484-511` 只验证“相同 item key + 完全相同文本”；`680-704` 只验证 rollout 内部去重，未组合 chunked stream 与 agent fallback。

### P2-06 同路径替换 logs_2.sqlite 后 monitor 不会重开数据库或重置 row ID

- **文件/行：** `Sources/CodexTokenBar/LiveRateLogDatabaseReader.swift:3-16`；`Sources/CodexTokenBar/SQLiteDatabaseDriver.swift:165-223`；`Sources/CodexTokenBar/LiveRateMonitor+LogSource.swift:21-57`；`Sources/CodexTokenBar/LiveRateMonitor.swift:47-48,196-208,364-410`。
- **影响：** 日志轮换、迁移或重建后，持久 SQLite handle 继续指向已 unlink 的旧 inode；即使重开，新库 ID 从较小值开始也会被 `id > lastGlobalLogID` 跳过。实时速率可永久停在旧库或漏掉新库前段。
- **触发：** Codex 在 monitor 运行期间 rename/delete 并重建同路径 `logs_2.sqlite`。
- **置信度：** 高（SQLite/Unix 文件语义）。目录 watcher 只安排 poll；`lastLogsSignature` 被赋值但从未比较。
- **静态复现：** monitor 打开 DB 后将文件换名并创建 ID 从 1 开始的新 DB；reader path 未变所以被复用，`lastGlobalLogID` 也未清零。
- **缺失测试：** 没有同路径 DB replacement、inode change、ID reset 或 watcher rename/delete 测试。

### P2-07 额度历史在最后已知 reset 之后无期限生成 100% 数据点

- **文件/行：** `Sources/CodexTokenBar/QuotaHistoryStore.swift:450-535`。
- **影响：** App 睡眠、离线或读取失败跨过 reset 后，图表把所有后续桶画成 100%，看起来像测量到“未消费”，而实际状态未知；`maxCarryGap` 只在 reset 缺失时生效。
- **触发：** 最后一条 row 有未来 reset 时间，之后没有新样本，图表时间已越过该 reset。
- **置信度：** 高。
- **静态复现：** 数据库只放一条 reset 在过去的 row，生成 recent buckets；第 505-506 行对所有 reset 后日期返回 100，不检查距 row/reset 的新鲜度。
- **缺失测试：** 现有 history 测试覆盖同周期插值和异常尖峰，不覆盖“跨 reset 且无后续样本应变 unknown”的边界。

### P2-08 未读动画在主线程同步预渲染最多 48 MB 的整段帧

- **文件/行：** `Sources/CodexTokenBar/FloatingUnreadRippleEffect.swift:109-183`；`Sources/CodexTokenBar/FloatingUnreadShimmerEffect.swift:101-180`；`Sources/CodexTokenBar/FloatingUnreadFrameCache.swift:4-42,121-158`。
- **影响：** 第一次出现未读、切换效果/颜色/尺寸或 cache miss 时，主线程绘制约 97 个 ripple 帧或 63 个 shimmer 帧；单序列预算允许 48 MB、全局 cache 96 MB，可能造成悬浮窗和 App UI 明显卡顿。
- **触发：** `cachedFrames.isEmpty` 或 resize debounce 后的 render request。
- **置信度：** 高（执行线程与工作量）；具体停顿时长取决于硬件。
- **静态复现：** 首次 attach 对应 NSView；ripple 直接 `workItem.perform()`，shimmer 直接调用 `renderFrames`；非首次 work item 也由 `DispatchQueue.main.asyncAfter` 执行。
- **缺失测试：** `FloatingUnreadEffectsTests` 只验证内存预算/降采样和源码形状，没有主线程、首帧 latency、取消或峰值内存测试。

### P2-09 界面缩放只放大悬浮窗外壳，内部内容仍用原始 panel scale

- **文件/行：** `Sources/CodexTokenBar/DashboardView.swift:554-569,631-640`；`Sources/CodexTokenBar/FloatingTokenPanel.swift:158-179,206-236,281-311,371-400,413-422`。
- **影响：** interface scale 不为 1 时，NSPanel/content controller 按 `floatingPanelScale * interfaceScale` 调大，但 `FloatingTokenPanelView` 重新从 `@AppStorage("floatingPanelScale")` 计算内容尺寸、字体、padding 和最终 frame。结果是窗口与 SwiftUI 根视图尺寸不一致，产生空白、对齐/命中区域异常，界面缩放也没有真正作用于内容。
- **触发：** 自动大屏缩放或手动界面缩放不为 100%，同时启用悬浮窗。
- **置信度：** 高。
- **静态复现：** 设 panel scale 1.0、interface scale 1.3；controller 创建约 1.3 倍 panel，但 root view 第 309-310 行仍得到 1.0 倍 size，并在第 400 行固定为该尺寸。
- **缺失测试：** `InterfaceScaleSettingsTests` 与 `FloatingPanelContentVisibilityTests` 分别验证纯计算，没有 controller effective scale 到 root content frame 的组合测试。

### P2-10 悬浮窗关闭时仍常驻全局鼠标与辅助功能命中检查

- **文件/行：** `Sources/CodexTokenBar/CodexTokenBarApp.swift:6-9`；`Sources/CodexTokenBar/FloatingTokenPanel.swift:57-87`；`Sources/CodexTokenBar/FloatingTokenPanel+WindowFollow.swift:8-38`；`Sources/CodexTokenBar/FloatingTokenPanel+WindowTargeting.swift:303-319`。
- **影响：** 只要 App 存活，每次全局左键按下都会记录位置/窗口 PID，并在已授权时做 system-wide AX hit-test，再强制刷新窗口列表；即使用户关闭悬浮窗或从未锁定窗口也执行。带来不必要的每次点击开销和超出功能启用期的本地行为采集。
- **触发：** App 启动后任意外部左键点击；与 `floatingPanelEnabled` 无关。
- **置信度：** 高。Controller 是 App 级 StateObject，monitor 仅在 deinit 移除。
- **静态复现：** 关闭悬浮窗，controller 仍存活；全局 monitor 回调进入 `recordExternalMouseClick`，没有 `panel != nil/lockedAnchor != nil` 前置 guard 就调用 AX 与 window list。
- **缺失测试：** 没有 enable/disable 生命周期、全局 monitor 安装次数、未锁定 fast-path 或每次点击成本测试。未发现数据外传，影响限定为本地采集与运行成本。

### P3-01 状态栏每 0.5 秒重建 popover 根视图，即使 popover 隐藏

- **文件/行：** `Sources/CodexTokenBar/StatusBarTokenPanel.swift:64-70,100-129`。
- **影响：** 状态栏启用期间主线程每秒两次创建完整 `StatusBarTokenPopoverView` 并赋给 hosting controller；标题虽然有 presentation 去重，但 root view 重建发生在 guard 之前，造成持续无效分配与 SwiftUI 更新。
- **触发：** 状态栏模式启用，无论 popover 是否显示、数据是否变化。
- **置信度：** 高。
- **静态复现：** 观察 timer 调用 `updateStatusItem`；第 102-111 行先替换 root，再在第 122 行判断 presentation 是否变化。
- **缺失测试：** `StatusBarTokenPanelTests` 只验证 presentation 值；没有隐藏 popover、无变化 tick 或更新次数测试。

### P3-02 Provider Engine 可在存在无效 session 文件时返回“验证通过”

- **文件/行：** `Sources/CodexTokenBar/ProviderSyncEngine.swift:93-104,151-160,185-195`；`Sources/CodexTokenBar/ProviderSyncView.swift:203-214,242-247`。
- **影响：** Engine 的成功条件没有 `invalidSessionFiles == 0`；当所有 session 都无效时，`sessionProviders.keys.allSatisfy` 还会空集合为 true。UI 另行把 invalid 数计入问题数，因此可同时出现 Engine “验证通过”和步骤卡“仍有问题”的矛盾状态。
- **触发：** 一个或多个 session 首行无法解析，但其他 SQLite/index/integrity 条件通过。
- **置信度：** 高。
- **静态复现：** fixture 放入无效 session JSONL 且保持其余状态一致，调用 `verify`；成功表达式不读取 `invalidSessionFiles`。
- **缺失测试：** Provider engine tests 只有健康 fixture 的 sync/verify/rollback，没有 invalid-only 或 mixed-validity verification。

### P3-03 CSV/PNG 导出静默吞掉渲染与写入失败

- **文件/行：** `Sources/CodexTokenBar/Exporter.swift:5-20,23-45`。
- **影响：** 无写权限、磁盘满、PNG 渲染失败等情况下没有错误提示；保存面板完成后用户可能认为文件已成功导出。
- **触发：** 目标写失败，或 ImageRenderer/TIFF/PNG conversion 返回 nil。
- **置信度：** 高。
- **静态复现：** 选择不可写目标或注入失败 writer；CSV/PNG 使用 `try?`，PNG guard 直接 return。
- **缺失测试：** 没有可注入 exporter、成功/失败反馈或目标写安全测试。

## 疑似问题（未计入严重度）

1. **Provider 时间戳碰撞修复可能改坏合法并发记录。** `ProviderSyncEngine+SQLiteRepair.swift:125-170` 把“同一秒 >=4 个 thread”直接判为异常，并改成该秒、前一秒、再前一秒，同时调整文件 mtime；没有证据证明合法导入/并发不能产生这种分布。因缺少产品数据不变量和真实异常样本，保留为 suspected。
2. **Radar 的服务端 RSS 链接缺少 scheme/host allowlist。** `CodexRadarStore.swift:302-304,454-467` 会请求 `current.json` 提供的任意可解析 URL；若源服务被入侵，可让 App 请求 localhost/内网。该请求不携带 detail Bearer，且需要上游服务先失陷，因此未升为确认问题。
3. **全局未读 key 缺失被解释为“可用且为空”。** `CodexUnreadThreadReader.swift:6-16` 在 JSON 可解析但 key 缺失时返回 `.available([])`，从而禁用 fallback scanner。若 Codex schema 迁移/部分写入会暂时缺 key，可能清空未读并漏报；缺少上游 schema 契约证据。
4. **重启后的持久 usage cache 丢失可展示 prompt/answer 摘要。** `CodexUsageAnalyzerModels.swift:553-578` 只持久化 digest，rehydrate 时文本为空；cache hit 的排行可能在文件未变化时长期显示占位。此行为同时明确降低隐私风险，是否属于可接受设计取舍需产品确认。

## 已排除的误报

1. **没有自动消费 reset card。** `AccountQuotaReader.swift:298-329` 对固定 HTTPS endpoint 仅发 `GET` 读取卡片；Swift 生产源码中未发现 consume/redeem 的 POST/PUT/DELETE 路径。
2. **旧异步任务不会直接覆盖新源成功结果。** Usage、Quota、Radar、Quota History、Provider Store 均有 generation/source ID publication guard；P1-02 是旧 snapshot 被主动保留且缺 source provenance，不是代际 guard 缺失。
3. **Usage JSONL 的 partial tail 不会像 Task scanner 那样被提交。** Usage parser 在非换行尾部放弃 append fast path并回到完整解析；Live rollout reader也只推进到最后一个完整换行。P2-03 仅适用于 fallback `TaskCompletionScanner`。
4. **未发现 thread/provider 查询的直接 SQL 注入。** 动态身份值走 SQLite binding；实时日志的 `afterID`/timestamp 来自内部整数，不是用户字符串。
5. **Provider 具备若干有效写安全措施。** 回滚先核对 manifest 的 Codex Home；SQLite backup 使用 `VACUUM INTO`；session 单文件重写使用 atomic write；Store 会阻止两个 destructive operation 并行。P1-03/P2-01 是这些措施未覆盖的边界。
6. **Radar 的两个 `URL(...)!` 是静态编译期字面量。** 它们不是用户输入导致的崩溃面。
7. **持久 usage cache 未泄露 prompt/response 明文。** 只保存 digest；疑似项关注重启后 UX，而不是隐私泄露。

## 测试质量评估

### 做得好的部分

- Usage/Quota/Radar/History/Provider Store 对 late result 和 generation race 有针对性测试。
- Usage analyzer 覆盖 cache append、截断、删除、版本迁移、token_count 与 metadata fallback。
- SQLite driver、绑定、事务、quota normalization、history 插值和异常尖峰均有较细的单元测试。
- Live rate 覆盖 stream/rollout 解析、同 key 去重、source-local reset、显示降噪和 RateAccumulator。
- Provider fixture 验证了健康路径的 backup、限定文件变更、sync、verify 和 selected rollback。
- 未读过滤覆盖 archived/subagent/visibility 与 baseline；动画测试覆盖内存预算和降采样。

### 主要缺口

- 组件级方法测试多，组合根 wiring 测试少；P1-01 正是“内部 `setDataSource` 测试通过，但 Dashboard 从未调用”的例子。
- 54 处测试直接读取生产源码文本并断言字符串/布局形状。这类测试能固定文案或源结构，但不能证明状态传播、实际 AppKit/SwiftUI 布局、线程、定时器和取消语义。
- 缺少切源失败后的 provenance、历史账号切换、真实 app-server cancellation、SQLite replacement、partial JSONL append、stream chunk + agent fallback、Provider fault injection/在线写门禁、动画首帧延迟、悬浮窗组合缩放、全局 monitor 生命周期和 exporter failure 测试。
- 没有运行测试；因此本报告只评价测试源码的意图与覆盖面，不声称测试在当前环境通过。

## 未覆盖区域与限制

- **Swift 文件级未覆盖：无。** `Sources/CodexTokenBar` 的 112 个生产 Swift 文件和 `Tests/CodexTokenBarTests` 的 34 个测试文件均纳入人工阅读。
- **未做运行时验证：** AppKit/SwiftUI 实际渲染、AX 权限提示和窗口命中、timer 实际唤醒频率、动画帧延迟/内存峰值、SQLite 被运行中 Codex 替换或并发写入的行为。
- **未验证外部系统：** Codex app-server 与日志 schema 的真实版本兼容性、CodexRadar 服务端 token 权限/轮换/限流和 RSS 信任边界、Sparkle feed/签名/发布基础设施。
- **非 Swift 发布面：** 未构建、签名、公证、安装、启动或验证 DMG/App bundle；未把脚本审阅等同于实际发布验证。

## 严重度计数

| 严重度 | 数量 |
|---|---:|
| P0 | 0 |
| P1 | 3 |
| P2 | 10 |
| P3 | 3 |
| **合计** | **16** |
