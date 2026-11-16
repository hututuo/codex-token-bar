# 多客户端接入核对与主页 Antigravity 四栏布局

本次按“读取器 → 账本 → 展示投影 → 页面组件 → 入口”核对 macOS Swift 和 Windows Rust/React 路径。基线是本机 build 1020，任务分支 `codex/production-rail-20261116`。本次没有把“解析器存在”当作“所有页面均已接入”，也没有把云端 Windows 测试当作用户 Windows 实机验证。

## 结论

**目前不是所有功能都完整多客户端化。** 基础用量、24小时/7天/30天曲线、曲线中的模型与金额、主页费用、Token 热力图和缓存排行已进入共同展示路径；热力图的模型、费用、额度仍有真实缺口。

“同一个接口”应分两层理解：

- 各客户端文件格式、额度提供者不同，底层保留各自读取器；Claude、Antigravity 等规范化成同一个事件/额度结构后，进入共同账本与投影。
- Codex 继续用原有精确账本和账户额度服务，在展示边界与其他客户端一起投影到原有页面接口。它没有被迁移进多客户端账本，这是保护历史、计价和来源身份的既有结构。

## 客户端范围

| 客户端 | 本地用量读取 | 主页独立/汇总入口 | 当前额度/额度历史 |
| --- | --- | --- | --- |
| Codex | 原精确索引与账本 | 有 | 原账户额度与历史服务 |
| Claude CLI | 本地会话记录 | 有 | statusLine/本地捕获缓存；API 接入不生成订阅额度 |
| Claude Desktop | 本地 Desktop 会话分类与记录 | 有 | 本地用量历史、HTTP 缓存，保留原采样时间 |
| Antigravity | 本地会话/数据库 | 有 | 本机语言服务/已有缓存；Gemini、第三方模型两个池，各有5小时和7天 |
| Gemini CLI | 本地会话记录 | 有 | 暂无本地额度提供者 |
| DeepSeek CLI | 本地会话记录 | 有 | 暂无本地额度提供者 |
| OpenCode | SQLite/旧版消息记录 | 有 | 暂无本地额度提供者 |

入口按启用状态、记录和本地额度发现情况出现。macOS 顶部优先展示两个外部客户端，其余进入“更多”；“汇总”始终是独立选项。不是所有检测到的软件都会自动开始读取其全部历史。

## 功能接入矩阵

| 区域 | 共用接口与样式 | 独立/汇总入口 | 核对结果 |
| --- | --- | --- | --- |
| 总 Token、今日、近7天、累计模型费用 | `ClientDashboardProjection` / `projectOriginalDashboard` 与原 `StatStrip` / `StatsStrip` | 跟随主页 | 已接；费用保留账本的逐请求计价，未知金额不算成0 |
| 24小时、7天、30天折线图 | `DashboardRecentUsageChart` / `DashboardAnalyticsSection` → 原 `RecentUsageChart` | 有图表专属的“跟随主页 / 汇总 / 各客户端” | 已接 |
| 曲线 hover、选区模型明细、已知金额、缓存率 | `RecentChartPreparedSnapshot.usageBuckets` / `usageSnapshot.ts` | 随图表客户端 | 已接；每个模型保留客户端身份，缺字段维持未知 |
| 曲线额度叠加 | `ClientQuotaChartSource` / `clientQuotaHistory.ts` → 原曲线接口 | 额度来源下拉，Antigravity 两池独立 | Codex、Claude CLI/Desktop、Antigravity 已接；不同池百分比不可求和 |
| 方块热力图：每日/每周/累计 Token | `ClientActivityProjection.days` / `projectClientDays` → 原 `TokenHeatmap` / `TokenActivitySection` | 跟随主页的单客户端/汇总 | 已接；365个本地日历日期，空日期保留 |
| 方块热力图：缓存命中率 | 日汇总已有输入/命中字段 | 外部客户端单独查看时模式被隐藏 | **未完整接入**：`tokensOnly` 隐藏了非 Codex 的全部特殊模式，尽管部分缓存数据已存在 |
| 方块热力图：模型/费用 | 日桶目前按 client+day 汇总 | 汇总页可见模式，数据不完整 | **未完整接入**：外部日桶缺 model 和已计价金额。Swift 对混合日期撤下不完整 Codex 模型投影；React 添加“模型明细未提供”占位。不能把现有模式按钮当作已支持 |
| 方块热力图：额度 | `quotaDaily` / `activityDays` 目前仅保留 Codex | 没有本地额度来源下拉 | **未接其他客户端**：已有外部额度历史尚未适配到日额度桶 |
| 主页当前额度 | `ClientQuotaItem` / `QuotaItem` → 原 `AccountQuotaSegment` / `QuotaBar` | 跟随主页；汇总页逐客户端展示 | 已接支持的提供者；本次将 Antigravity 从3+1改为4等宽 |
| 缓存排行 | 聚合排行投影 → 原排行组件 | 跟随主页，可打开各客户端会话 | 已接，按缓存字段可用性保留未知 |
| 侧栏用量/额度 | 共用选择、额度投影与组件 | 侧栏范围独立于主页 | 已接；macOS 的 A 式紧凑小图标双条是原生布局实现，不能据此声称 Windows 一级布局完全相同 |
| 实时速度 | 外部客户端使用 Agent Speed / 本地测速适配 | 随客户端范围 | 不是全部等价：Codex 正文 TPS 与外部活动速度来源和语义不同，不能冒充同一采样精度 |
| 重置卡、共享账号额度反推、Codex 雷达 | 原 Codex 专属接口 | Codex 被选中时 | 这是服务能力边界，不应把外部用量塞进 Codex 额度反推 |

## 源码定位

- 读取与规范化：`Sources/CodexTokenBar/MultiClientUsageModels.swift`、`MultiClientUsageDiscovery.swift`、`MultiClientUsageParsers.swift`、`AntigravityUsageSource.swift`；Windows 为 `tauri-app/src-tauri/src/core/multi_client_usage.rs`、`antigravity_usage.rs`。
- 统一用量投影：`ClientDashboardProjection.swift`、`MultiClientUsageLedger.swift`；React 为 `multiClient/originalDashboardProjection.ts`。30天趋势桶已含模型、逐请求计价金额、缓存完整性；365天日桶目前没有模型与价格维度。
- 入口：`IntegratedClientViews.swift` 的 `ClientScopePicker`、`DashboardRecentUsageChart.swift`；React 为 `ClientScopeControls.tsx`、`recentChartClientScope.ts`。
- 24小时曲线：`DashboardRecentUsageChart.swift`、`RecentChartPreparationStore.swift`、`RecentChartUsageSnapshot.swift`；React 为 `pages/dashboard/DashboardAnalyticsSection.tsx`、`components/recentUsageChart/usageSnapshot.ts`。
- 热力图缺口：`DashboardView.swift` 的 `ActivitySection(...)`、`TokenActivitySection.swift` 的 `tokensOnly`、`ClientDashboardProjection.swift` 的 `codexDailyModels`；React 为 `DashboardAnalyticsSection.tsx`、`TokenActivitySection.tsx`、`integratedClientModel.ts` 的 `projectClientDays`。
- 额度能力：`MultiClientUsageStore.quotaReading`、`ClientQuotaHistory.swift`；Rust 为 `multi_client_product.rs`、`client_quota_history.rs`。Windows 本机 RPC 进程/端口发现已有 `antigravity_local_rpc/windows.rs` 和 `windows_metadata.ps1`，不是缺少 Windows 读取入口。

## 本次修改与后续收束边界

本次明确的布局修改使用原额度组件：Antigravity 固定最多4列等宽，顺序继续来自原始池/周期投影（Gemini 5h、Gemini 7d、第三方5h、第三方7d）；标题与重置时间分层，保留完整小数与自然换行。Windows 同样使用四等宽列、等宽进度轨道。

新增每个已注册客户端及汇总的用量守恒检查，复用原有24小时/7天/30天和365日热力图数据接口。原有模型明细与价格回归继续覆盖跨客户端选择。原生组件渲染增加840/980pt四栏、汇总页场景。

本次排查列出的热力图缺口尚未改成“已完成”。收束它们应沿现有路径补齐日桶的模型/已计价金额和完整性字段，再接同一热力图；额度历史按客户端、源、池投影为日采样并提供来源选择。只去掉 `tokensOnly` 会把数据缺口变成空白/误导的页面，不能作为完整修复。

候选 build 1021 的云端与本机验证结果在完成后补记。没有更改账本 schema、历史记录、读取范围、刷新周期或网络读取策略。
