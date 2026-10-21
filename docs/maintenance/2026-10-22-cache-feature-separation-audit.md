# 缓存命中功能剥离调查 · 2026-10-22

结论：建议剥离缓存命中的提醒和续问建议整条专用链路；排行/命中率展示可继续单独裁减。保留输入、缓存输入、输出三项基础计数及费用计算。当前仅只读调查，没有删除代码、库、设置或历史。

这里的“缓存命中”指模型输入复用，不包含软件自身的SQLite索引、读取缓存或历史压缩功能。

| 层次 | 内容 | 可独立剥离程度 | 停用后的收益 |
|---|---|---|---|
| 实时提醒 | 最近请求命中率、低命中判断、主页/悬浮/侧栏提醒、提醒开关 | 与TPS输出曲线共享实时reader，但tracker与呈现可拆 | 少量增量解析和短期状态；共享reader仍服务活动曲线，不应整段删除 |
| 续问建议 | 主页横条、推荐/最晚续问线、间隔图、筛选、样本、刷新任务 | 独立scanner、分析器、SQLite侧库，边界较清晰 | 可停止专用文件发现/增量解析、样本写库、曲线分析；只删横条无法获得这些收益 |
| 历史分析 | 会话/单轮缓存排行、今日命中率、24h/7d/30d命中率线、缓存构成 | 展示可拆；专用排名SQL与候选投影须随调用链停止 | 减少查询/投影与渲染；只拆前两层时这部分仍运行 |
| 基础账本 | cached_input_tokens及模型、轮次、事件归属、去重和计费 | 保留 | 维持历史与费用口径；不应为了移除分析UI删除字段 |

## 关键调用链与证据

### 低命中提醒

- Swift `CacheUsageAdvice.swift:145`：输入至少20,000且命中低于30%的提醒判定。
- Swift `LiveRateMonitor+Rollout.swift:247` / Rust `core/live_rate/rollout.rs:393`：随实时rollout读取解析缓存样本。
- Swift `LiveRateView.swift:24`、`QuotaSidebarViews.swift`，React `CacheUsageNotice.tsx:11`、`QuotaSidebarApp.tsx`：提醒展示和侧栏交互。

只隐藏UI，reader里的提醒采样与tracker还会运行。应解除提醒消费者、移除专用tracker及设置，保留共享reader和TPS处理。

### 续问建议与间隔图

- Swift `DashboardRuntime.swift:522`：启动绑定并刷新，用量更新时间变化后继续刷新 `cacheRetentionStore`。
- Swift `CacheRetentionEngine.swift:22`：独立文件发现、会话类别读取、逐文件同步。
- Swift `CacheRetentionEngine.swift:14`：独立库 `Application Support/CodexTokenBarSwift/cache-retention-v1/<源哈希>.sqlite`。
- Swift专用模块：`CacheRetentionStore/Engine/Parser/Analysis/Database/ChartView/Models.swift`；入口 `DashboardView.swift:1168`。
- Tauri `CacheRetentionSection.tsx:54`：进入时读取并刷新；页面可见时每180秒刷新。
- Tauri `core/usage/token_count_jsonl/cache_retention.rs:41`：独立侧库；递归发现session文件，未变更文件跳过解析，变更文件验证前缀并增量扫描；有独立存储预算。预算不代表本机实际占用。
- Tauri `DashboardPage.tsx:261`：provider与主页入口；专用 `CacheRetentionProvider`、客户端、读写命令、解析器和分析器需要一起解除。

因此停用整条专用链路比仅移除横条更有意义。旧侧库不会因移除界面自行消失。

### 历史排行与命中率

- Swift `DashboardView.swift:1213` 读取 `cacheUsage.sessions/turns`。
- Tauri `exact_usage_index.rs:4147`、`:4769`：快照里的排行SQL、候选读取，并有 `cache_ranking_ms/cache_usage_ms` 埋点。
- Swift `Models.swift:99`、React `cacheHitRanking/model.ts:79`：命中率为缓存输入除以输入。
- React `RecentUsageChart.tsx:583`：命中率曲线入口；侧栏概览和构成图也引用基础缓存计数。

若这些入口也移除，应追踪到专用候选查询/派生投影，不能只删组件。通用用量桶仍供Token/调用/费用曲线使用。

### 基础费用

- Swift `QuotaConsumptionEstimator.swift:22`：费用 = 未缓存输入×普通输入价 + 缓存输入×缓存价 + 输出×输出价。
- React `settings/quotaPriceModel.ts:220` 的费用入口也传入缓存输入。
- Rust `exact_usage_index/ledger.rs:8` 的账本字段包含 `cached_input_tokens`。

即使命中率很高，也需要保留实测缓存数量用于费用计算，不能硬编码100%或去掉缓存字段。

## 建议实施顺序（尚未实施）

1. 保存当前完整功能到独立分支/检查点，先解除低命中提醒及续问建议的运行入口、定时刷新与写库。并行移除双端相关UI、设置、桥接命令和专用测试；保留共享reader/TPS/用量功能。
2. 旧续问侧库封存，不自动删除，不回写账本，不重建用量索引；仍可由保留分支查看旧结果。
3. 如决定同时去掉排行/命中率展示，再独立裁掉专用查询与派生投影。首轮保持基础schema与字段，避免不必要的破坏性迁移。
4. 以相同输入核对总输入/缓存输入/输出、模型费用、主会话/fork/归档删除保留、TPS样本与窗口；运行时验证专用刷新与写库确已停止。

当前证据是源码和埋点定义，没有做关闭前后CPU/耗时/磁盘A/B，也没有测量真实侧库大小，不能承诺具体性能收益。当前运行版本仍保留全部缓存命中功能。
