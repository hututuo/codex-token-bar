# 压缩后计费、多客户端汇总与 API 模式排查

日期：2026-11-05。排查分支：`codex/legacy-debt-20261104`；产品源码基线：`333a5291690163527b1f9fa97cd8e4df648d74f0`。

后续修复已记录在 [API 模式额度与已知费用修复](2026-11-05-api-mode-and-known-cost-fix.md)。下文保留排查时的发现与验证边界。

本轮按“先排查报告”执行，只新增一项 Swift 回归测试和本报告，未修改产品逻辑。运行中的安装版只读核验为 **0.9.11 / build 992**；以下候选源码结论不能直接等同于安装版已生效，也没有验证真实历史账本已完成回补。

## 结论

| 用户关注点 | 已确认结果 | 尚需处理或验证 |
| --- | --- | --- |
| 压缩后的第一笔普通请求有没有费用 | 候选 Swift 源码经实际解析、聚合、价格公式验证，正常计入；已知压缩请求本身也计入 | 候选安装验收、真实旧账回补结果未验证 |
| 多客户端有没有汇总到一起 | 两端均有统一 Token、请求数、时间桶、模型及费用展示入口；本机显示范围已是 `all` | Tauri 会丢失混合已知/未知价格行中的已知费用小计；连接方式和账号维度尚不完整 |
| 第三方 API 为什么还查订阅额度 | Codex 自动刷新路径没有按 API/订阅能力分流，仍调用 `account/rateLimits/read`，失败可持续重试 | API 模式应停止订阅额度及相关重试，保留 Token 和费用统计 |

## 1. 压缩后的计费核实

新增 `CompactionUsageIntegrationTests.testFirstOrdinaryRequestAfterCompactionAndInheritedContextIsPriced`，输入经真实 `parseSessionIntoHistoryIndex` → `cacheUsage` → `APIPriceRates.costUSD`，没有用另写的计费模拟函数代替产品实现。

测试按顺序输入以下记录：

| 记录 | 输入事实 | 应如何处理 |
| --- | --- | --- |
| 有明确 usage 的压缩响应 | input 326,340；cache 323,968；output 7,768；total 334,108 | 计入一次 Token 与费用 |
| `compacted` 标记 | 指向上述 response ID | 关联压缩响应，不重复收费 |
| 继承上下文快照 | input/output 为 0；total 46,525；累计历史 17,032,149 | 用作继承基线，不把上下文大小或历史累计当成新增消费 |
| 第一笔普通请求 | input 100；cache 40；output 20；reasoning 7；total 120 | 正常计入一次；reasoning 属于 output，不另加一次 |

测试价格为每百万 Token：未缓存输入 $2、缓存输入 $0.1、输出 $10。压缩响应费用为 **$0.1148208**，第一笔普通请求为 **$0.000324**，合计 **$0.1151448**，请求数为 2。另一变体让第一笔普通请求的 usage 与压缩响应完全相同，结果仍分别计入一次，防止压缩镜像去重吞掉合法新请求。

相关源码：

- `Sources/CodexTokenBar/CodexUsageAnalyzer+SessionParsing.swift:415`：继承基线处理限制在零输入/输出快照。
- `Sources/CodexTokenBar/TokenUsageAccounting.swift:96`：有效普通 usage 的计数路径。
- `Sources/CodexTokenBar/CodexCompactionAccounting.swift:74`：压缩关联状态管理。
- `Sources/CodexTokenBar/CodexUsageAnalyzer+Aggregates.swift:73`、`QuotaConsumptionEstimator.swift:18`：聚合与三类 Token 的价格计算。
- `Tests/CodexTokenBarTests/CompactionUsageIntegrationTests.swift:97`：本轮新增回归。

该结论覆盖合成输入下的候选实现。如果“第一块”指的是零输入/输出的上下文快照，不能仅凭它的 total 推算一次费用；如果有独立请求的有效 usage，则应计入。缺失用量仅影响该条记录，不能把已有 Token 或费用整体变成未知。

这里的价格是按配置价表计算的参考费用，不能直接声称与第三方中转站实际账单相等。

## 2. 多客户端汇总现状

### 已有统一展示链路

Swift 的 `ClientDashboardProjection.snapshot` 将 Codex 与所选客户端的 Token、请求数、日期桶和模型明细组合给原有面板；`ClientModelCostPeriods.make` 提供累计、今日、近七天费用。Tauri 的 `DashboardPage.tsx:230` 同样调用 `projectOriginalDashboard` 和 `clientCostPeriods`，不是仅实现了未接入界面的辅助函数。

本机 `local.codex.token-bar` 设置中的 `multiClient.displayScope.v1` 已是 `all`。因此当前问题不能靠再次选择“全部客户端”解决。本轮没有逐一核对每个真实客户端的全部源日志与数据库总账，不能据此保证每种来源都无漏采或重复。

两个长期业务库是当前设计：`codex-ledger.sqlite` 保存 Codex 的 Exact、Quota、BodySpeed、ModelTrace 等模块；`multi-client-usage.sqlite` 保存外部客户端用量及活动记录。统一汇总在展示层完成，无须为了一个总数再强行合成一个物理库。设计依据为 `docs/maintenance/2026-10-28-business-ledger-and-shared-io.md`。

### 已复现缺陷：Tauri 隐藏部分已知费用

向实际 TypeScript 汇总函数输入同一 client/model 的一行：已有费用 **$0.37**，同时有 **1 笔价格未知请求**。

- `originalDashboardProjection.ts:41` 因 `unpricedRequests > 0` 将整行 `costUSD` 变成 `null`。
- `floating/floatingModelUsage.ts:280` 收不到这行原有的已知费用，已知小计也得到 `null`。
- Swift 对应的 `ClientDashboardProjection.swift:204` 保留了 `knownPartialCostUSD`，两端行为不一致。

正确结果应展示“已知费用至少 $0.37，另有 1 笔未定价”，同时保留全部已知 Token。这是展示投影中的费用信息丢失，不能据此称底层数据库丢了 Token。本轮只复现，未修复。

### 仍缺少统一的连接身份

`Sources/CodexTokenBar/MultiClientUsageModels.swift:18` 的 `ClientUsageEvent` 主要记录 client/session/event/model/usage，缺少统一的 provider、account、billingMode 维度。检测到 Codex 或 Claude Code，只能确定客户端来源，不能据此推定它在使用官方订阅，也不能确定它与某份缓存额度属于同一账号。

用量可以按选定范围相加；不同账号、不同套餐的剩余额度百分比不能相加。第三方实际价格或余额需要对应提供方的配置/观测，不能由官方订阅额度替代。

## 3. API 模式与额度读取

### Codex：持续读订阅额度的问题成立

Mac 当前主调用链：

`AccountQuotaStore.start` → 自动刷新/立即刷新 → `AccountQuotaReader` → `PersistentQuotaService` → Codex app-server 的 `account/rateLimits/read`。

- `AccountQuotaStore.swift:198` 启动时装定时器并立即刷新；刷新入口没有 API/订阅能力判断。
- `PersistentQuotaService.swift:67` 直接发送上述 RPC。配置和身份时间戳用于作用域变化检测，不等于已经识别“API 模式不适用”。
- `AccountQuotaStore.swift:415` 失败后安排重试；`:533` 到期再次刷新。
- `PersistentRefreshBackoff.swift:5` 的间隔为 1、3、5、10、30、60、120 秒，之后间隔保持在 120 秒。界面的“最长 2 分钟”指间隔上限，**不是两分钟后停止**。
- `DirectQuotaHTTPReader` 中存在拒绝普通 API key 的逻辑，但它不是这条自动轮询主链路，不能用它证明当前行为已被拦住。

Tauri 也存在同类能力缺口：`quotaAutoRefreshModel.ts:14` 只看页面和快照是否就绪、刷新间隔；`useDashboardData.ts:1113` 据此安装定时器；Rust `core/quota.rs:1210` 经 persistent 服务读取 rate limits。前端 `integratedClientModel.ts:83` 在没有订阅观测时仍创建“不可用”的 `codex:7d` 项。

直接调用实际 TS 函数已复现：没有任何 connectionMode 输入时，刷新计划仍为 `active: true`、间隔 60 秒；没有订阅观测时仍返回上述不可用额度项。

本轮未确认用户正在运行的客户端实例的真实第三方 endpoint，也未发起账号或额度网络请求。默认 Home 的配置分类不足以确定所有桌面实例的实际连接方式，不用于否定用户正在使用第三方 API 的情况。

### Claude Code：目前是本地缓存读取，应与 Codex 区分

`MultiClientUsageStore.swift:412` 被动读取 Claude Code statusLine 缓存和 Claude Desktop 的 `plan-usage-history.json`。当前链路没有向 Anthropic 发起额度请求，也没有为了读额度启动 CLI。

但本地缓存未绑定当前连接方式和账号，可能展示与当前 API 连接不对应的历史额度；本轮未证实真实数据发生串账。CLI 与 Desktop 的额度来源应继续独立，不应因同属 Claude 就合并百分比。

## 4. 建议的修复范围与验收

优先收束连接模式和费用展示两个具体问题：

1. 将 `subscription / api / unknown` 连接模式与客户端名称解耦，并关联选定 Home、provider 和账号身份。已确认 API 模式时，展示“API 接入 / 订阅额度不适用”，继续统计 Token 和费用，停止订阅额度、重试及 reset-credit 请求。
2. provider、认证状态或所选 Home 改变时重新判断。切回订阅应恢复对应账号的额度读取；切换账号不得继续沿用原账号额度。未知状态应提供明确状态与可用的确认入口，不能默认为永远重试。
3. 第三方 API 的费用以已配置价表或提供方账单为依据；仅有模型价表时标明参考费用。第三方余额作为独立能力接入。
4. Tauri 保留混合行中的已知费用小计及未定价数量，使其与 Swift 一致；未知局限到缺失部分。

最小验收场景：API 模式持续运行多个刷新周期仍无订阅 RPC/重试，而 Token 继续增加；API→订阅→另一账号切换后能力和额度归属正确；$0.37 已知费用加 1 笔未知请求仍显示 $0.37 已知小计；压缩响应、继承快照、首笔普通请求分别按上文口径计数。

这些改动不要求重写整个数据库或重新设计所有客户端采集器。正式接入前再验证安装版本与真实账本，避免把合成回归通过当作旧账已经修复。

## 5. 本轮验证与证据

| 验证 | 结果 | 范围 |
| --- | --- | --- |
| Swift 定向测试，包含新增回归 | 77 通过，0 失败 | compaction、accounting、多客户端投影/账本/额度发现；本轮实际编译并执行 |
| Rust 现有测试二进制定向执行 | 70 通过，0 失败，0 忽略 | compaction、accounting、多客户端相关用例；复用前轮构建，非本轮重新编译或 Windows 实机执行 |
| 前端 5 份测试文件 | 33 通过，0 失败，0 跳过 | 统一投影、模型、价表、额度自动刷新 |
| TS 独立复现 | 已确认上述费用和额度缺口 | 直接调用生产函数的合成输入；不是缺陷已修复的通过声明 |

Swift 新增测试前的 76 项执行记录另行保留，不与新增后的 77 项重复累计。所有命令、退出码和日志哈希在 `scratch/integrated-recovery/client-accounting-audit-20261105/`，`manifest.json` 汇总测试数量、源码/补丁和证据哈希；`projection-observation.mjs` 与 `.json` 保存独立复现输入与输出。

Rust 复用二进制的前轮构建记录为 `scratch/integrated-recovery/legacy-debt-20261104/performance-gap-20261105/rust-final-product.log`。这仅说明其构建来源；该旧日志的全量测试数量和耗时不作为本轮成绩。
