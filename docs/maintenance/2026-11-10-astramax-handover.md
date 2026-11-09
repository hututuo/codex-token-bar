# Astra Max 接手：功能区统一入口、模型速度条与多客户端图表

编写日期：2026-11-10（Asia/Shanghai）。面向新开启的 `astra max` 线程；Argon负责主控、范围协调、独立复核和实机测试安排。

本次交接只新增本文档，不修改业务代码、不启动构建、不安装或操作GUI。接手者执行后续开发。本文以 `b45f9495` 工作树的实读源码和已保存证据为依据；代码行号是定位提示，修改后请以符号搜索为准。

## 0. 先读结论与优先级

1. 当前可回退的已安装基线是 **0.9.11 / build1007，产品源码 `dcf9184a`**。完整CI、双端安装包、Public097及本机启动已通过；并不代表所有界面口径问题已解决。
2. 先做两个完整功能批次：**L1 速率二级/三级同源投影及模型速度条**；**L2 趋势图分桶、顶部指标、hover/框选模型与金额同源**。两批各自有完整合同、回归及所有消费点清单，不再只给一个界面补一条旁路。
3. 本轮源码调查已发现L2的直接证据：Swift `fineCoversHistory` 与TS `useFine` 会让7d改用5分钟序列；外部趋势桶没有模型维度；框选使用 `quotaData`，该数据刻意只保留Codex。**聚合曲线金额已接入，不等于选区模型明细已接入。**
4. 后续按L3–L7覆盖费用/命名、运行态、来源与刷新、诊断升级、剩余服务。按功能区闭环，不能用“搬走几百行”作为完成标准。
5. **禁止本机构建/测试套件；必须走云端。安装或GUI验收前先由Argon询问用户是否在场。** 新规覆盖此前“直接替换”的操作习惯；详见第9节。

## 1. 仓库、源码、产物与设备基线

| 项目 | 已核对事实 |
| --- | --- |
| Worktree | `/Users/huyiyang/.codex/worktrees/f97f/codex-token-dashboard` |
| 分支 | `codex/storage-responsibility-split-20261106` |
| Remote | `https://github.com/hututuo/codex-token-bar.git` |
| 产品/云端基线SHA | `dcf9184ad7bfa282ef364b2a9f72f142251054e6` |
| 上轮验收文档SHA | `b45f94953a78c470a82a4ec71607ea196ebe39b8`，本文提交前本地HEAD与remote分支一致 |
| 安装位置 | `/Applications/Codex Token Bar.app` |
| 已安装版本 | `0.9.11 / build1007`，本文编写时重新读取Info.plist确认 |
| 已安装可执行文件SHA256 | `22dd9f96b4b22bda281c63774a68041181420aab673737572f6549d57972da2f` |
| macOS app.zip SHA256 | `8036f02925fe8875c7d48bcd804fb3cd71872e1bd6419bad69045826a80bea5b` |
| CI | [42648172101](https://github.com/hututuo/codex-token-bar/actions/runs/42648172101)，全部成功 |
| Public097 | [42648172070](https://github.com/hututuo/codex-token-bar/actions/runs/42648172070)，双平台成功 |
| Installers | [42648209361](https://github.com/hututuo/codex-token-bar/actions/runs/42648209361)，macOS ARM64、Windows x64/ARM64成功 |
| 签名/发布属性 | macOS候选为ad-hoc签名，未公证；manifest `update_signed=false`、`public_release=false`；没有新tag、公开Release或appcast发布 |

本文提交后HEAD自然会多一个文档提交，**已安装二进制仍对应dcf9184a**，不要把文档SHA写成已打包源码SHA。

旧版build1006回滚备份（已经校验，不得覆盖或当缓存清理）：

```text
/Users/huyiyang/.codex/worktrees/f97f/codex-token-dashboard/scratch/chart-aggregation-20261109/local-install-1007-ehc55rda/rollback-build1006/Codex Token Bar.app
```

证据主目录：`scratch/chart-aggregation-20261109/`。具体入口：

- `dcf9184a/final-validation.json`：安装前最终源码/测试/构件门禁，`installed=false`是其采集阶段，不代表后来未安装。
- `dcf9184a/app-validation.json`、`package-macos/candidate-manifest.json`、`package-windows/candidate-manifest.json`：应用与两个lane的身份、大小、hash。
- `local-install-1007-ehc55rda/installation.json`：新旧build、二进制hash、备份、安装attempt。
- 同目录 `runtime-validation.json`：`PASS_INSTALLED_RUNTIME`，首次刷新4376文件完成、pending0、schema14、generation27212；后端完成、UI收到完成、安装确认是三个独立时间。
- `build1007-ui-validation.json`与`build1007-{today,sevenDay,lifetime}.png`：模型表三周期。
- `build1007-chart-validation.json`、`build1007-chart-manual-review.json`、`build1007-chart-contact-sheet.png`：4个来源×3周期的截图及人工复核。
- `counts-1794237594.json`、`counts-1794241727.json`、`counts-1794243340.json`：只读rollout生命周期与内核FD计数快照。

当前工作树并非全净：`docs/maintenance/2026-10-03-windows-incomplete-scan-report.md`有用户既有修改，SHA256为 `63801116c53adee10cb0692cdad6553e6187906f7659ae0aea67b69d4f24ecef`。还有未跟踪的 `AGENTS.md`、`HANDOFF.md`、清理审计、历史维护/交接报告等。**不要 `git add .`，不要reset/clean，不要把它们并入本任务提交。** 新线程先重新执行 `git status --short`，以实时状态为准。

### 1.1 已通过的门禁和未证明的事项

最终dcf9184a：XCTest2438通过/38原有跳过，Swift Testing676通过；Rust macOS1828、Windows1771通过，各14原有ignore；前端1457、云端脚本18、发布脚本112通过（发布脚本1原有跳过）。两个平台各16个生产场景、备份cleanup负控、物理A替换负控通过。Public097包含Swift升级8项及支持105项、Rust升级3项、4个生产阶段、19个manifest恢复场景。

这些数字是基线，新增测试后可以增加；不能删测、放宽断言或只跑局部测试后宣称“全绿”。源码发生变化后需要在新候选上重新完成门禁。

上轮已证明：曲线非空、来源切换、可见窗口定位和缩放、逐桶Token/调用/已知价格守恒测试，以及Argon/Antigravity费用分组。**上轮没有完成“7d固定标准粒度”和“多客户端框选模型列表”的验收**，本轮用户反馈有效，不应以旧报告驳回。完整滚动/交互性能A/B也尚未闭合；不能宣称全软件所有卡顿已消除。

## 2. 不可破坏的约束

- 遵循本worktree的 `AGENTS.md`。不在本机运行 `cargo`（含check/test/build）、`swift build/test`、Xcode编译、npm/Vite前端构建或全量测试。允许源码/JSON检查、diff、下载校验、脱敏只读诊断；运行现有保留二进制必须有明确诊断范围，不能暗中重建。
- 禁止为了显示更干净修改原始Token、丢请求、删除历史、清空pending、绕过完整性检查或降低价格未知的真实边界。未知模型参考费用与真实已核算费用分开标注。
- 展示别名归并不等于计价别名归并；不同客户端/来源的同名模型不能因短名相同失去账本身份。
- 只读诊断不得通过可能恢复/导入/注册namespace的业务open入口。不要修改Codex的 `state_5.sqlite`、rollout、thread-writer-locks或用户认证文件。
- 不启用Agent Speed网络上报来解决本地显示；本地监控、排行、上报是不同权限/生命周期。
- 不改四列30pt费用芯片、稀疏四槽位、未知末尾单卡等已确认布局。新增速度条应紧凑，不能顺手重做整页样式。
- 不把多客户端费用全部套上Codex配额/回退模型。Codex配额反推、共享账号归因、周期边界需要保留独立的provider语义。
- 不再开启无边界“反向审查”。Argon按本轮合同和可复现反例复核；发现无关问题记入backlog，不无休止扩大当前批次。

## 3. 架构总图：事实、投影与界面

```text
Codex rollout / state DB          其他客户端本地记录与只读观察
          │                                  │
 Exact索引、账本、checkpoint         discovery / parsers / client_usage_events
          │                                  │
 A: codex-ledger.sqlite              B: multi-client-usage.sqlite
 namespace / route / admission       逐请求价格、客户端/模型汇总、时间桶
          │                                  │
 Codex DashboardSnapshot        MultiClientUsageStore / Rust snapshot → IPC
          └─────────────────┬────────────────┘
                  客户端scope与展示投影
                ┌──────────┼──────────┐
           主页费用表     趋势图       侧栏费用/汇总
                          │
                   当前待收束断点：
                 图线/顶部 ↔ 框选/模型

实时速率与运行态是另一条观察链，不从费用图反推：
LiveRateMonitor / ClaudeLocalRuntime / AgentSpeed本地snapshot
          ├─ 模型速率贡献 → 圆圈/竖条 → 待补同源三级速度条
          └─ 生命周期 + 活跃证据 → 主/子任务summary → 主页/侧栏
```

### 3.1 存储与启动边界

| 职责 | Swift macOS | Rust / Tauri |
| --- | --- | --- |
| App/启动准入 | `CodexTokenBarApp.swift`、`ApplicationStartupCoordinator.swift` | `src-tauri/src/lib.rs`，startup/commands及business bootstrap |
| A容器与逻辑路由 | `CodexBusinessDatabase.swift`中的`BusinessSQLiteStore`/`BusinessSQLiteRoutes`，`BusinessDatabaseMigration.swift`、`BusinessDatabaseMaintenance.swift`、SQLite driver | `core/business_store_container.rs`及子模块、`business_store_route.rs`、`business_store_connection.rs`、`business_store_recovery.rs` |
| Exact根编排 | `CodexUsageHistoryIndex`相关文件、`CodexUsageStore`相关refresh/projection | `core/usage/token_count_jsonl/exact_usage_index.rs`：`open_at`、`sync_with_scan_plan_mode_once`、`finalize_generation`、facade |
| Exact模块 | 不应照搬Rust文件拆分改变Swift合同 | `connection.rs`/`contracts.rs`；`read_model.rs`/`projections.rs`/`ledger.rs`；`ingest.rs`/`sources.rs`；`migration.rs`/`migration/proof.rs`；`stage_pool.rs`及其目录；`cycle_range.rs`/`dashboard_buckets.rs`等 |
| Route模块 | 激活、物理身份和namespace同样受保护 | `business_store_route/admission.rs`、`path_identity.rs`、`import_coordinator.rs`、`exact_namespace.rs` |
| B路径 | `ClientUsageDataLocation.databaseURL` | `core/app_paths.rs::multi_client_usage_database_path` |

**数据库名字校正**：当前生产路由明确使用A `codex-ledger.sqlite`与独立B `multi-client-usage.sqlite`。Swift默认B位于 `~/Library/Application Support/CodexTokenBar/multi-client-usage.sqlite`，preview有隔离路径；Windows须通过app_paths和配置解析，不能套macOS路径。用户提到的 `usage_snapshots.sqlite` 在本次 `Sources/` 与 `tauri-app/src-tauri/src/` 搜索中没有对应生产文件名定义，不能据此虚构第三个主库或新建一个。若设备发现该名字，先查创建者/实际路由/表结构，归类为来源或历史工件再处理。

已经完成的A–D拆分不能被UI收束推翻：

- `ManagedIndexConnection`的字段、Drop、per-path gate、完整性收据、真实`StoreConnection`绑定保持；读模型的TEMP表/视图和所有查询共用同一连接/DEFERRED快照。
- `ensure_dashboard_aggregates`的独立修复事务不能塞进读取快照；`i64`溢出必须报错。
- stage builder/validator/importer使用同一不可变artifact；pending关联先落账，根`finalize_generation`提交后才回收；两个EventSink绑定不同，不合并。
- append自有IMMEDIATE事务、代次变化才复制checkpoint、早退依赖Drop回滚保持；缺失源只标unavailable，不清pending175。
- schema11 Prepared→Copied→Migrated→Validated→Switching→Switched→Retained持久化点、生产clone/replace/seal与test文件改名分支保持。
- `validate_pending_snapshot`可能重建frozen backup，`open_read_only_index`可能恢复/旧库导入，不能按名字放进纯工具层；route事务内recheck与marker提交点不能分散。

详读 `docs/design/2026-11-07-storage-global-decomposition-master-plan.md` 及A/B/C/D维护报告。后续除非功能修复确实需要，先在展示合同层收束，避免触碰存储迁移状态机。

### 3.2 多客户端账本与聚合地图

下述Swift路径均相对 `Sources/CodexTokenBar/`；Rust路径相对 `tauri-app/src-tauri/src/`。

| 层 | Swift入口 | Rust/React入口 | 合同/注意点 |
| --- | --- | --- | --- |
| 来源发现/读取 | `MultiClientUsageDiscovery.swift`、`MultiClientUsageParsers.swift`、`MultiClientCompressedUsageReader.swift`、Antigravity相关reader | `core/multi_client_usage.rs`、`core/antigravity_usage.rs`、共享本地reader | 只读来源，保留session/request/source身份、压缩边界、错误状态 |
| 持久账本 | `MultiClientUsageLedger.swift` | `core/multi_client_usage.rs` | B的`client_usage_events`；保留原始模型和payload语义，不由UI写回 |
| 逐请求计价 | `forEachPricedEvent`约583、`apiCostMicroUSD`约608；`StandardAPIPriceSchedule.swift` | `api_cost_micro_usd_at`约3973，价格汇总约4170/4300 | cache read/write TTL、日期、生效价格、长上下文按事件保留；不能先合Token再盲目重价 |
| 5分钟趋势 | `trendBuckets(now:)`约431；同一个readTransaction读取Token与逐请求价格 | `read_trend_buckets`约4491；`aggregate`事务/cache约4350–4460 | 当前GROUP BY client与300秒，没有model；`apiCostMicroUSD`可nil，`unpricedRequests`不能省略 |
| 日/月范围 | `dailyBuckets`、summaries；`MultiClientUsageStore.swift`的聚合缓存与发布 | `read_daily_buckets`、snapshot/aggregate缓存；`commands/multi_client_usage.rs` | 本地日历天与UTC定长桶不同，DST/午夜不能互换 |
| IPC/Store | `MultiClientUsageModels.swift`、`MultiClientProduct.swift::ClientTrendBucket`；`MultiClientUsageStore` | Rust `MultiClientUsageTrendBucket`约340；`tauri-app/src/multiClient/MultiClientUsage.tsx` | 增字段须双端/旧字段缺省兼容，来源切换时防旧异步回复污染新scope |
| 展示投影 | `ClientDashboardProjection.snapshot`、`ClientDashboardProjectionCache`、`ClientModelCostPeriods`/Cache | `multiClient/originalDashboardProjection.ts::projectOriginalDashboard/clientCostPeriods/clientModelCostItems` | 这里是适配层，不能变成第二套账本；scope和revision必须进入缓存键 |

Codex精确历史与多客户端B账本并非相同原始格式，底层reader保留各自语义；统一应发生在有完整来源、时间、质量和计价信息的合同上。

### 3.3 主页趋势图、缩放、hover与框选地图

| 阶段 | Swift入口/符号 | Tauri入口/符号 |
| --- | --- | --- |
| scope选择/接线 | `DashboardRecentUsageChart.swift`：`RecentChartClientScope`、`DashboardRecentUsageChart.body`约44–85 | `pages/dashboard/DashboardAnalyticsSection.tsx`约30–80；`multiClient/recentChartClientScope.ts` |
| 来源适配 | `ClientDashboardProjection.snapshot`：`bins(300/3600)`、`cacheBins` | `multiClient/originalDashboardProjection.ts::points`约108、返回三种序列约137 |
| Range合同 | `RecentUsageChart.swift::RecentChartRange`约4–49：24h300s、7d3600s、30d21600s | `components/recentUsageChart/model.ts::RANGE_CONFIG`约277 |
| 准备/归桶 | `RecentUsageChartData.swift::prepare`约4、`usageBins`约102、`aggregateUsage`、`cacheBreakdowns`、`modelBreakdowns` | `model.ts::prepareRecentChartData`约428、`pointsForRange`约1088 |
| 后台准备/缓存 | `RecentChartPreparationStore.swift::RecentChartPreparedSnapshot.build`、`prepare`；三range有界缓存/请求ID fence | `RecentUsageChart.tsx::preparedDataForRange`约151；useMemo三range缓存/来源key |
| 已知价格 | `RecentChartPreparedSnapshot.build`约66开始合externalCostBuckets；`recordedCostText`约1518 | `recentUsageChart/recordedCosts.ts::recordedChartCosts`；组件约211–225的金额与窗口 |
| 可见窗口/坐标 | `RecentChartScrollMetrics`、`RecentChartScrollOffsetObserver`、`RecentChartViewportGeometry`、`visibleWindowSummary`、`RecentChartPlotData` | `model.ts::recentChartScrollLayout/recentChartVisibleWindowSummary/plotChartPoints`；组件ResizeObserver和scroll处理 |
| 自动缩放/曲线 | `RecentChartScaleMap.swift`；`RecentUsageChartDrawing.swift`单调平滑/命中测试；组件`chartPlotCanvas` | `recentUsageChart/scale.ts`；`model.ts::smoothPath/scaledCostPoints`；组件SVG绘制 |
| hover/scrub气泡 | `RecentUsageChart.swift::chartHoverBubbleOverlay`约2138；`RecentUsageChartComponents.swift::ChartHoverBubble` | `RecentUsageChart.tsx`约940后hover bubble，activePoint来自data |
| 框选状态/锚点 | `RecentChartConsumptionSelectionState`在`QuotaConsumptionEstimator.swift`约894；`RecentChartSelectionTimeAnchor`、点击/恢复/清除函数在图表根文件 | `recentUsageChart/selectionAnchors.ts`；`model.ts::clickQuotaSelection/quotaConsumptionSelection` |
| 框选摘要/模型/金额 | `QuotaConsumptionEstimator.swift::selection(displayedData:quotaData:)`约929；`ChartSelectionSummaryBubble`；`consumptionSelectionSummary`约2271 | `RecentUsageChart.tsx::consumptionSelection`约298、`SelectionSummaryBubble`约1003，`ModelUsageInline`约1037 |
| Codex额度反推 | `QuotaConsumptionEstimator.swift`、`QuotaSelectionAttribution.swift` | `model.ts::quotaConsumptionEstimate/quotaSelectionAttribution`；sharedAccountAttribution |

来源选择独立于主页scope，切换会重建图表身份以清掉旧selection。要保持这个行为和最新位置初始化修复（等待完整document宽度，不覆盖用户已开始的手动翻阅）。**不要再写另一套Antigravity图。**

### 3.4 速率二级圆圈、三级详情和颜色/名称

| 职责 | Swift | Tauri |
| --- | --- | --- |
| 原始Codex实时观察 | `LiveRateMonitor`/`LiveRateSnapshot`及相关文件 | `core/live_rate.rs`及`live_rate/{monitor,stream,state,observed,completed_body,...}.rs` |
| 多客户端实时选择 | `ClientLocalRuntimePresentation.rates`；`ClaudeLocalRuntime`；`ActivitySpeedPresentation.swift::AgentSpeedDisplayRuntime` | `multiClient/ClaudeLocalRuntime.tsx`、`activitySpeedMode.tsx::selectedActivityRates`；Rust/C#本地AgentSpeed桥 |
| 速度模式 | `ActivitySpeedDisplayMode`、`SpeedDisplayPreferences.swift`；Bar/AgentSpeed | `activitySpeedMode.tsx`、`components/liveRate/speedDisplay.ts`、`SpeedDisplayControls.tsx` |
| 二级圆圈 | `QuotaSidebarViews.swift`约185–203的`liveRates/barRates/liveRate`；`rateRing`约603；`SidebarValueRing` | `QuotaSidebarApp.tsx::SidebarRailContent`约356，`rates/totalRate/barRates`、`Ring`与`speed`入口约432 |
| 模型切片/颜色 | `ModelRatePresentation.swift::slices/stops`；`ModelUsagePresentation.key/label/color`；`SpeedColorOverrides` | `components/liveRate/modelRatePresentation.ts::modelRateSlices/modelRateGradient`；`components/modelUsagePresentation.ts`、`useSpeedPalette.ts` |
| 短名/规范身份 | `ModelDisplayNames.swift`、`ModelPresentationIdentity.swift` | `domain/modelDisplayNames.ts`、`domain/modelPresentationIdentity.ts`，Rust `core/model_presentation.rs` |
| 三级打开/生命周期 | `QuotaSidebarController.select(.speeds)`约308、`enter/dismiss`、面板挂载/卸载；`QuotaSidebarViews`约737的speeds分支 | `quota-sidebar/nativeCoordinator.ts`、`model.ts`/`presence.ts`；`QuotaSidebarApp`约520，`quota + speeds/activity-speed`分支 |
| 现有正文TPS详情 | `ObservedSpeedView.swift::ObservedSpeedSidebarView`约91；`BodySpeedTrendView`、最近10条样本 | `components/liveRate/ObservedSpeedDetails.tsx`、`BodySpeedTrend.tsx`、`bodySpeedPresentation.ts` |
| 现有近3分钟活动图 | `ClaudeLocalSpeedView.swift::ActivitySpeedSummaryView`；`ActivitySpeedHistoryController`与`ActivitySpeedChartProjection` | `multiClient/ClaudeLocalRuntime.tsx::ClientActivitySpeedPanel`约122；`ActivitySpeedLivePlot.tsx`、`activitySpeedChart.ts` |

当前三级speeds首先是Codex正文TPS历史，再显示近3分钟活动图；**没有圆圈实时模型切片的独立“颜色+短名+条+数值”图例列表**。二级`barRates`还是视图内计算，三级不能独立再抄一份。

口径必须分开：实时output activity/估算速率、完成正文的实测TPS、时间窗口均速/分位数、账本Token与金额是不同量。统一选择和呈现入口，不能把这些数值揉成一个“速度”。保留Bar/AgentSpeed选择、按模型/客户端配色、自定义色、停用/不可用/stale、零速率、未知模型残差和source identity。

### 3.5 费用表、三级价格和运行态

| 功能 | Swift入口 | Tauri/Rust入口 |
| --- | --- | --- |
| 今日/近7天/累计费用 | `ClientDashboardProjection.swift::ClientModelCostPeriods.make`、`ClientModelCostPeriodsCache` | `originalDashboardProjection.ts::clientModelCostItems/clientCostPeriods/clientCostGroups` |
| 主页排序/布局 | `DashboardModelCostOrder.swift::groupID/groups`；`DashboardHeaderView.swift::DashboardModelCostChip` | `domain/modelCostOrder.ts::costModelGroup/orderedCostGroups`；`styles/global.css`费用芯片 |
| 三级今日模型金额 | `QuotaSidebarViews.swift::overview`约830、`modelCostCache`约689 | `QuotaSidebarApp.tsx::QuotaDetails`约540，`clientModelCostItems`后展示已知金额 |
| 通用费用展示 | `FloatingTodayModelUsagePresentation`、`ModelUsagePresentation`、`StandardAPIPriceSchedule` | `floating/floatingModelUsage.ts`、`components/modelUsagePresentation.ts`、`settings/standardAPIPriceSchedule.ts`、`multiClient/clientReferencePrice.ts` |
| Codex运行扫描 | `RunningThreadScanner.swift::scan`约130、`summary`约1165、`latestLifecycle`约813 | `core/thread_activity.rs`，`commands/thread_activity.rs`，`models/thread_activity.rs` |
| 运行存活 | `RunningThreadLiveness.swift::snapshot/writeHandles`；scanner的`activeFileLease=5min` | `core/thread_activity/liveness.rs`、`thread_activity.rs`内生命周期/新鲜度投影 |
| 发布/合并 | `TaskCompletionMonitor.swift`后台scan；`RunningThreadModels`；`ClientLocalRuntimePresentation.running` | `state/useRunningThreadSummary.ts`，`quota-sidebar/runningTaskPresentation.ts::combinedRunningTasks`消费`multiClient/ClaudeLocalRuntime.tsx`，Tauri运行态API |
| 主页/侧栏任务 | `TokenDisplaySurface`、`QuotaSidebarViews.taskContent/taskGroup/childTask`、`FloatingRunningThreadModelDetails` | `quota-sidebar/RunningTaskDetails.tsx`/`runningTaskPresentation.ts`、`floating/FloatingRunningThreadModelDetails.tsx` |

当前共享排序策略 `Sources/CodexTokenBar/Resources/model-cost-order.json`：

- 第一组最新主力：Argon4、Fable5.1、原生Opus5.5/Sonnet5.5/Haiku5.5、Astra6、Sol6.1、Terra6.1、Luna6；只显示实际有记录的模型，Sol6不回第一组。
- 第二组“Gemini · Antigravity”：Flash3.8及按来源规则进入的Claude模型。Antigravity所有模型默认进第二组，Argon4是明确例外；非原生Claude5.5也有sourceGroups规则，不要仅按短名猜组。
- 之后GPT其他、Claude其他、其他、未知模型。未知跨来源末尾单卡，保留sourceModels悬浮详情和参考费用标识。
- 多客户端Opus的旧记录缺少cache-write TTL拆分时，默认5m已由用户批准并在build1002落地；合法1h拆分必须保留，不退回“全部nil”旧逻辑。

运行态合同：24h是发现窗口；最后生命周期为running、文件近5min有推进可保留，静默更久须有真实rollout写句柄。terminal优先于持锁/持句柄；writer-lock文件存在不代表活跃；读取失败保留stale/unavailable，不发布fresh0。子代理由rollout/DB source明确身份判定，普通fork或side chat不因parentID变为子代理。主标题name→title→preview→first_user_message→首条用户正文，子代理还用nickname/path/role；不要破坏已补的有界读取缓存。

### 3.6 共享资源是合同，不是第三套业务实现

`Sources/CodexTokenBar/Resources/`内已有 `model-presentation-policy.json`、`model-presentation-cases.json`、`model-display-names.json`、`model-cost-order.json`、`standard-api-price-history.json`。Swift加载，TS直接import或适配，Rust通过相应资源/实现对齐。`Vendor/AgentSpeed/UPSTREAM.json`约束vendor版本和本地补丁hash。

一个语言里的统一入口无法直接消灭跨语言实现；应共享规范、schema、fixtures与结果比较，平台适配保留。不要把SwiftUI、React、Rust硬塞到一个泛用service，更不要把真实parser和账本换成共同的低精度表示。

### 3.7 其余功能区的扫描起点

这些是L5–L7需要纳入owner矩阵的外围入口，尚不构成“已证明重复、必须重写”的结论：

| 功能区 | 入口与应追踪的边界 |
| --- | --- |
| 页面与设置 | Swift `CodexTokenBarApp.swift`、`TokenDisplaySurface.swift`、各Store；React `App.tsx`、`pages/dashboard/`、`settings/`、`state/`；Rust `commands/`、`models/settings.rs`。追踪同一设置在主窗/浮窗/侧栏的存储key、事件和晚到回复 |
| 额度/API模式 | Swift `AccountQuotaStore`、客户端quota providers、`QuotaSelectionAttribution`；Rust `core/quota/connection_mode.rs`、`models/quota.rs`与前端quota消费者。真实账户额度与本地API等值费用必须分开 |
| 活动速度历史/实测正文 | Swift `ActivitySpeedHistoryController`/`ActivitySpeedStore`与`BodySpeedHistory`/`BodySpeedTrendStore`；Rust `activity_speed_store*.rs`与`live_rate/speed_trend*`。内存3分钟活动、持久历史、正文TPS具有不同采样意义 |
| ModelTrace/排行榜/上报 | Swift `ModelTraceController.swift`、`ModelTraceProbe.swift`、`AgentSpeedReportingController.swift`；Rust `commands/modeltrace.rs`、`commands/agent_speed_reporting.rs`、`core/modeltrace/`；React相应页面及Vendor桥。手动探测、本地显示、网络上报的权限和生命周期不能相互触发 |
| 诊断/恢复日志 | Swift `DiagnosticsExport.swift`、`RecoveryDiagnostics.swift`、`UpdaterDiagnostics.swift`；Rust `core/diagnostics/{collect,journal,privacy,files}.rs`、`core/recovery_diagnostics.rs`；`commands/diagnostics.rs`与`bin/tokenbar-diagnostics.rs`。采集不能走会迁移的业务open |
| 安装/更新 | Swift `AppUpdater.swift`/Sparkle；`install.sh`、Windows release/NSIS脚本；`scripts/diagnostics/Export-Diagnostics.command/.ps1/.cmd`。逐阶段receipt、失败留存、首次健康确认与用户回滚分开 |

跨区排查要记录真正的owner与数据合同，而不是仅把这些路径列为“待拆文件”。

## 4. 必做任务一：三级菜单模型速度条

目标：点击二级“速率”圆圈后，在三级首屏看到每种颜色代表的模型及其当下速度。每行 **色点/色条 + 规范短模型名 + 速度条 + 数值（tok/s）**；同一采样时点，行贡献之和与圆圈总速率一致。

建议实现合同（名字是建议，不表示当前已有）：`SidebarLiveRateSnapshot`/`LiveRatePresentation`，至少包含source key、observedAt、mode、grouping、availability、total、每项canonical model/client、label、color、rate、share。二级圆圈、收起竖条、三级速度条共享这个投影；视图仅布局。

实施要求：

1. 先列清所有rate consumers及Bar/AgentSpeed来源，检查Swift视图局部`liveRates/barRates`与TS`selectedActivityRates`是否同口径，保留未知残差守恒。
2. 提取已有计算到功能投影，避免三级新开timer、扫描器、数据库或网络调用。带source/mode/revision或采样时间的快照，晚到回复不能串源。
3. 模型行按确定顺序，短名与颜色走现有identity/palette；原始名放help/title。条的量纲写清：若用相对最大值仅作为长度比例，不冒充份额；份额与圆圈切片则按同一total。
4. 按客户端配色模式仍需可解释每个模型与客户端关系，不出现圆圈颜色与模型图例错配；不要用模型费用表排序直接替代速度排序。
5. 零/未知/不支持/过期有明确展示，不保留虚假的旧速度；现有正文TPS图和近3分钟活动图继续存在，标题明确不同口径。
6. 隐藏三级后取消其专属UI订阅/绘制工作；共享监控者由已有lease管理，不能关闭其他窗口需要的monitor。

验收/回归：双端覆盖两模式×模型/客户端配色、单/多客户端、同名跨客户端、未知残差、NaN/负数/零、数据源切换、停用/过期、palette立即更新、隐藏/重新展开。真实GUI比较同一时点的圆圈总量和列表合计，不能拿不同秒的截图判守恒。正文TPS不进入实时圆圈合计。没有实机数据的客户端用明确fixture，不伪造实机结果。

## 5. 必做任务二：趋势分桶与框选气泡一次闭环

### 5.1 已确认代码机制与仍需实测的差异

**粒度**：Swift `RecentUsageChartData.prepare`约21根据`fineCoversHistory`令7d的`dataRange=.twentyFourHours`；TS `model.ts`约435以`useFine`作同样处理，实际bucket300s。原注释目的是保留小时内部配额低点，不是偶然混入桶。不同来源历史覆盖长度会触发不同分支；上轮本机汇总/Codex/Antigravity/Claude Desktop的7d截图都可能显示细粒度，故不能未经复现就断言“仅汇总有bug”。确定事实是**当前7d合同随输入覆盖情况改变**，与用户要求的统一标准精度冲突。

**模型**：`ClientTrendBucket`/Rust对应结构没有model字段，SQL只按client与300秒归并。Swift `modelBreakdowns`只从Codex attributionEvents生成；TS投影只复制Codex points的modelBreakdowns，外部trend仅加总数。到了框选，Swift `(quotaData ?? displayedData).quotaConsumptionSelection(...)`、TS `quotaConsumptionSelection(quotaData, ...)`又把provider数据作为选区基础。外部价格目前通过`recordedCostText`旁路显示，因此可能出现**价格是汇总、模型/其他选区数值仍Codex**。本次必须连选区Token、调用、命中率一起排查，不能只补模型文字。

### 5.2 终局合同

以一个 `ChartScopeRequest → ChartSnapshot` 功能入口收束（实际命名由Astra确定），至少统一：

- 请求：allowed client IDs、Codex home/source token、窗口range、asOf/settledThrough、账本revision/生成代次、时区或calendar、价格版本/回退模型（仅适用处）。
- 时间：24h用5m、7d用1h、30d用6h作为现有Range标准；点的 `[start,end)`、closed/open状态、保留历史长度与可见窗口分开。若实际要改标准必须先给Argon明确理由，不能隐藏在coverage分支。
- 每桶：input/cache-read/cache-write/output/reasoning、calls、总Token、已知费用microUSD、unpriced数量、缓存/模型/价格完整性、按client+canonical model的贡献；保留必要raw IDs追溯。
- 消费：图线、顶部可见窗口指标、单点hover、拖动scrub、点击两端固定选区、选区模型列表、选区金额只读同一snapshot；不得各自重查DB或另行估价。
- Codex配额是明确附属provider子快照：配额低点、reset cycle、分钟模型证明、共享账号归因、compaction/unknown保护继续专用，**不把外部用量算入Codex额度反推**。

### 5.3 分桶与模型来源实现路线

1. 先写同一事件集合在每个scope/range下的期望桶、模型与金额，再接代码；覆盖“细序列覆盖/不覆盖小时序列”两个输入，结果粒度必须一致。
2. 在账本侧提供有model/client的有界时间桶或有界range明细；已有 `forEachPricedEvent`/`api_cost_micro_usd_at`用于逐请求价格，复用同一read transaction。不要把全部原始payload/对话搬到UI，也不要每次鼠标移动执行SQL。
3. 保存事件级计价结果后再合桶；未知/缺少cache统计不默认为0完整；保留溢出错误。若更新IPC，处理旧字段缺省并测试跨端序列化。
4. 统一时间key/步长/末端截断/补零策略，防止同一事件同时从fine和hourly进入两次。缓存命中率用总cached/总input，不平均各客户端百分比。
5. 把显示数据与配额数据分开为明确类型，框选的usage summary用display，quota estimate用provider；不能再让一个`QuotaConsumptionSelection`结构隐式兼任两套统计。
6. 保留原成熟绘制、局部可见窗口裁剪、滚动初始定位、时间锚点和自定义颜色。删除或收缩已迁移的重复价格/模型分支，防止旧入口继续被另一种气泡调用。
7. 当前细桶用于保留quota低点，修7d不能直接丢掉这些观测；可以图形按1h显示，但provider的分钟/5m证据保持独立、按时间关联。回归必须证明配额窗口与跨reset选择没有退化。

### 5.4 必须新增的端到端反例

- 两客户端在同一5m内用不同模型，选“汇总”24h框选：模型集合是二者并集，列表Token/调用/费用与范围合计一致；切单客户端只剩其贡献。
- Antigravity Opus与Claude原生Opus短名相同，选区仍保留client身份；不能互相吞账或重复计价。
- 5m/1h/6h边界、反向选区、单桶、午夜/DST、空洞、最新未闭合桶、不同开始时间的客户端、只含外部来源。
- 相同原始事件，7d总计等于规范1h桶总和；切换scope不能改变bucketSeconds。30d6h与24h5m同理，覆盖长/短旧缓存。
- 价格未知、不同cache-write TTL、生效日期、长上下文阈值：先逐请求计价再汇总；不凭均价凑相等。
- 图表顶部/hover/固定选区/下方summary分别断言source IDs、模型集合、数值和completeness，而不只测试某个纯函数。
- 原Codex quota cycle、低点、reset边界、shared account与compaction负控继续通过。鼠标高频移动不触发新的全表扫描，跨scope旧selection应清除或按既有规则重定位。

优先扩展 `RecentChartClientScopeTests.swift`、`RecentChartPreparationStoreTests.swift`、`RecentChartSelectionInteractionTests.swift`、`RecentChartLastBucketPricingTests.swift`、`MultiClientUsageLedgerTests.swift`；TS `recentUsageChart/{model,recordedCosts,selectionAnchors,recentUsageChartDom}.test.mjs`及多客户端projection测试；Rust `multi_client_usage.rs`中的真实只读transaction/逐请求计价回归。**必须有旧代码失败、新代码通过的生产接线反例，不能只给新的helper自证。**

## 6. 全仓“功能区统一入口收束 Loop”

用户要求原意：全面扫描各写各的逻辑，按功能或界面逐步完成“确定定位→全面扫描→收束→全面检查”，真正提高可维护性，避免一边修好另一边仍坏；由Argon监督。不是文件越少越好，也不是把全部服务合成一个大类。

### 6.1 每轮固定交付

1. **确定定位**：写出现象、期望、可复现输入、基线SHA，区分直接代码证据/实机证据/待证假设；圈定本轮完整功能。
2. **全面扫描**：从每个UI入口往下到reader、账本、IPC、cache、计价、设置，再反向枚举所有consumers；记录source identity、锁/事务、生命周期和副作用。扫描不能只搜函数名。
3. **收束**：先定输入/输出/不变量，复用已成熟实现，移走真正重复的业务决策；全部consumers接新入口，旧分支删除或成为薄适配器。平台原生绘制与必要的不同统计口径保留。
4. **全面检查**：语义差异清单、双端同fixture、负控、完整CI/生产验证、候选包；按第9节取得实机测试安排后验收。报告区分PASS/FAIL/NOT_RUN和残留边界。
5. 每轮一个高内聚提交系列和维护记录，附 `入口→权威计算→消费者` 矩阵以及旧重复决策被移除的证据。Argon审核本轮合同、差异和未覆盖边界，再进入下一轮；同一数据正确性问题不延后到“下一次优化”。

完成标准：每项关键决策只剩一个语言内权威入口；跨语言实现共用版本化规范/fixture；所有消费界面已接线；新增一个客户端/模型不需改多份相同分支；账目/生命周期/安全合同不变；实际回归反例被门禁拦住。没有这些收益的机械移动不立项。

### 6.2 预调查路线图与优先级

| Loop | 完整功能边界 | 当前分叉/风险证据 | 收束成果与停止线 |
| --- | --- | --- | --- |
| L1 首批 | 二级圆圈/收起条/三级实时模型速度条，配色/名称/单位/模式 | Swift视图内liveRates/barRates；TS选速helper与详情活动图分开；三级缺模型图例 | 一个实时速率投影供全部speed surfaces；不把正文TPS历史或上报合并进去 |
| L2 首批 | 主图24h/7d/30d、顶部指标、hover、框选与模型/金额 | 已确认coverage改粒度、外部桶无model、selection用quotaData、金额旁路 | 一个带scope/revision的chart snapshot和range summary；配额另有provider子合同 |
| L3 | 主页/侧栏/浮窗/日历浏览的模型身份、分组、价格 | 已有共享JSON与ClientModelCostPeriods，但ModelUsagePresentation、参考价格、Codex quota估算各有适配；需审是否绕过 | 明确展示identity、billing identity、source identity三者；权威费用投影，已知费用不重价；保留参考值标签 |
| L4 | 主/子运行态、标题、主页/侧栏/浮窗计数 | Codex scanner、Claude runtime、AG activity各自判定；聚合有fresh/stale优先与enabled过滤 | 统一observed summary/quality/source合同及aggregate入口；来源专属liveness adapter保留，terminal永远优先 |
| L5 | client scope、来源发现/切换、IPC/cache、刷新/进度、设置同步 | page/chart/sidebar允许各自scope，多个Store/hook和source token；易发生旧回复/重复订阅/快照不同步 | 共用scope解析和快照版本规则，显式override；UI不另开扫描器；卡顿以同条件数据测，不重开UI猜测 |
| L6 | 诊断导出、升级回执、启动迁移进度、错误恢复 | 独立Swift/Rust诊断与脚本；已知6000事件上限遗漏当前启动会话；需查事件排序/轮转 | 一个事件schema/采集allowlist/安装确认合同；最近失败与本次证据可定位，纯只读/脱敏/超时负控；安装器启动≠成功 |
| L7 有证据再做 | 剩余设置/额度/API模式、排行榜/ModelTrace、存储/备份入口 | 存在多surface和平台适配，尚未逐条证明重复有害；不能仅凭文件大判坏 | 全仓owner矩阵和风险排序；仅对真实重复/交叉职责安排完整批次，存储A–D边界与vendor独立上报保留 |

贯穿所有Loop的共享配置/fixture工作：不仅同步两边常量，还要检查资源是否真正进入打包、schema版本/缺省行为、客户端名称与事件字段、颜色override、时区/币种/价格版本、顺序稳定性、Rust/Swift/TS结果等价。用相同输入验证，不复制三份不同期望值。

### 6.3 规模提示：先看职责，不以行数为KPI

本文时点实测（含内嵌测试，不能等同生产复杂度）：Swift `RecentUsageChart.swift`2723行、`QuotaSidebarViews.swift`1163、Controller979、Ledger669、Store559、ClientDashboardProjection365、RunningThreadScanner1405；TS图表1430、chart/model1628、QuotaSidebarApp655；Rust multi_client_usage7548、thread_activity1980、business_store_route1195、Exact根2900。

L1/L2要读整个功能区的输入、输出和所有消费者，不能因文件大只抽走100行helper；也不能为“统一”改掉上轮已经通过字节等价审计的存储事务。

### 6.4 Argon与Astra职责/交接记录

- Astra Max负责架构落地、双端关键生产代码、接线、测试和候选包；Argon保留范围协调、独立复核与用户沟通。不能将主要前端/视觉实现甩给低阶worker。
- 有价值的有界证据调查可遵守当前AGENTS授权委派；不要为拆任务而委派。此前GPT-6 Luna一次启动不可用，不要反复失败或偷偷换不获授权模型。
- 原生subagent向parent报告用collaboration mailbox；单独用户线程只有用户明确指定后才用线程消息。不要靠记忆ID寻找Argon；主控线程ID由发起者明确传入。本文不新建线程、不发送跨线程消息。
- 每轮给Argon：基线/新SHA、改动职责、消费者矩阵、旧入口清理、测试和负控结果、剩余问题、下一步；不得只报“全绿”。GUI前另发第9节通知。

## 7. 保护此前修复：重点不变量检查表

| 区域 | 必保合同 |
| --- | --- |
| 数据准确性 | Token/calls按来源守恒；unknown/不完整不得假0；缓存命中加权；单位/币种/日期明确；溢出报错 |
| 历史接续 | v0.9.4冷历史/压缩边界；空源/全删除历史保留及墓碑；0.9.7–0.9.11迁移回退、ledger/pending175、stage pool恢复 |
| 索引/SQL | 单快照、绑定StoreConnection、Drop/gate/锁顺序、物理A替换保护、checkpoint及发布回执时点；候选索引/稳态刷新优化不回退 |
| 客户端 | Windows客户端选择同步/路径身份；Orca/Antigravity roots；ModelTrace手动检测；API模式不伪装订阅额度 |
| 模型/费用 | 已确认Flash路由alias；Opus legacy5m写缓存；原生与AG同名保留来源；未知单卡参考价；标题变化不使数值缓存无故失效 |
| 图表交互 | 部分document宽度初始化修复；手动滚动不被抢回；selection时间锚点；第二次点击和关闭按钮命中；不让overlay挡交互 |
| 侧栏 | 四列30pt费用芯片；细轨道圆点内收/首尾caps；动画反向/生命周期/hidden订阅；正文TPS设置定位框不能消失 |
| 运行态 | 完成信号优先；孤立exec不活跃24h；5min宽限与长静默真writer；不把普通fork当child；title fallback与紧凑任务卡 |
| 安装诊断 | 备份不覆盖；包hash/版本/sourceSHA一致；launch/refresh/install-confirmed分别证明；纯只读/强脱敏/锁超时 |

PR历史与存储全分支审核详见 `docs/maintenance/2026-11-08-storage-full-branch-compatibility-review.md`（当前为未跟踪本地资料，保留，不随本文提交）及A–D报告。涉及存储合同的Loop需追加四版本formed矩阵，不用Public097代替。

## 8. 云端构建、门禁与构件收拢操作手册

以下是**接手者完成代码后**的操作说明，本次仅写文档。普通新代码push会自动触发CI和符合paths条件的Public097，先查已有run，避免重复dispatch。纯docs提交不会触发完整CI。

### 8.1 完整CI / Public097 / Installers

在repo内用专用变量固定精确40位SHA；先提交推送，再dispatch。下一build须核查没有并行占用，若仍以1007为最新才选1008，不把示例数字当永久事实。

```sh
candidate_sha=$(git rev-parse HEAD)
candidate_branch=codex/storage-responsibility-split-20261106
candidate_build=1008
gh run list --repo hututuo/codex-token-bar --branch "$candidate_branch" --limit 12
```

若新SHA没有自动run，触发完整模式（不要开启reader_only/usage_only/formed_only/scale_only来冒充完整CI）：

```sh
gh workflow run ci.yml --repo hututuo/codex-token-bar --ref "$candidate_branch" -f source_sha="$candidate_sha"
gh workflow run release-upgrade-compatibility.yml --repo hututuo/codex-token-bar --ref "$candidate_branch" -f source_sha="$candidate_sha"
```

打包工作流 `.github/workflows/prepare-release.yml` 的inputs是 `source_sha`、`app_build`、可选 `reviewed_upstream_pin` 与 `reason`：

```sh
gh workflow run prepare-release.yml --repo hututuo/codex-token-bar --ref "$candidate_branch" -f source_sha="$candidate_sha" -f app_build="$candidate_build"
```

Agent Speed默认远端HEAD严格核对。本文基线 `Vendor/AgentSpeed/UPSTREAM.json` 的 `commit` 字段为 `a94a67fcc78e5d8eea5f82d8d5e737bccf994e2c`，它是**上游commit，不是文件hash也不是本仓SHA**。若上游发生漂移，只在已审阅当前vendor pin/patch合同、确认本批不更新上游后，按既有工作流提交明确理由：

```sh
reviewed_pin=$(jq -r '.commit' Vendor/AgentSpeed/UPSTREAM.json)
gh workflow run prepare-release.yml --repo hututuo/codex-token-bar --ref "$candidate_branch" -f source_sha="$candidate_sha" -f app_build="$candidate_build" -f reviewed_upstream_pin="$reviewed_pin" -f reason='Reviewed the pinned vendor and local patch manifest for this candidate; retain that version for this scoped UI and projection change.'
```

不能无脑复制理由跳过真实核对，不能直接改UPSTREAM.json使门禁假绿。若改变Vendor必须遵循 `scripts/agent_speed_vendor.py` 同步/补丁证明流程。打包本身不发布更新。

### 8.2 npm镜像故障修复必须保留

`dcf9184a`解决npmmirror500/502，使用npm原生下载地址替换：

```sh
npm ci --registry=https://registry.npmjs.org --replace-registry-host=registry.npmmirror.com
```

**此命令只在云端job执行，不在本机执行。** Swift job中的脚本测试使用同参数加 `--prefix tauri-app`；CI frontend/native依赖、Public097 Windows和 `scripts/build_tauri_windows_release.ps1`也已采用。只设registry不足以替换lockfile中完整tarball URL。不要修改lockfile版本/integrity来规避下载问题，不禁用TLS/完整性。上轮ws/undici-types官方字节与锁定integrity已核对相同。

### 8.3 门禁脚本分别证明什么

| 入口 | 用法/范围 | 必查输出 |
| --- | --- | --- |
| `scripts/check_test_execution.py` | **云端** `--kind swift\|rust --log <log> --source-sha <SHA> --require <test> ... -- <真实测试命令>`；解析真实测试结果并绑定源码 | execution JSON、日志hash、实际测试名、失败/跳过、dirty状态；仅exit0不够 |
| `scripts/cloud/node-execution-reporter.mjs` | CI前端/脚本测试现有reporter，不另绕过 | 前端1457等基线与新测试必须真实执行；node execution JSON |
| `scripts/cloud/run-business-store-fixture.py` | **云端** `python scripts/cloud/run-business-store-fixture.py tauri-app/src-tauri/target/debug/examples/business-store-fixture`；binary由同SHA生产feature构建 | `runtime-recovery-production.json`、validation/log；16场景、生产cfg、精确字段/并发probe。程序内`validate_production_report`为权威校验 |
| `scripts/check_backup_cleanup_gate.py` | **云端**无参数；正常→禁用cleanup→恢复 | 0/101/0，指定负例失败，不能把任意构建失败算负控有效 |
| `scripts/check_route_identity_gate.py` | **云端**无参数；有效物理A替换，临时禁身份保护再恢复 | 0/1/0，6入口，原/替换文件保留、marker不变；真实非cfg(test)访问 |
| `scripts/cloud/check_ci_evidence.py` | CI `--needs "$JOB_OUTCOMES" --source-sha "$SOURCE_SHA" --run-id "$GITHUB_RUN_ID" --formed-requested false --scale-requested false` | `ci-execution.json`与`checked-source.json`；要求source/frontend/swift/native/windows-updater成功，按需矩阵不得跳过 |
| Public097工作流 | 构造真实tag `v0.9.7` producer并跑当前生产恢复；旧tagcommit固定`0219554ce444b0013987da7b82e3c2e891f4afdb` | producer/fixtures/restart/manifest与支持测试证据；不能拿纯mock代替 |
| `scripts/cloud/manifest.py verify` | 本机可只读校验已下载构件，见下 | lane/sourceSHA/runID、清单大小/hash、无额外文件、candidate属性 |

标准CI的evidence job不能用伪造needs JSON本地补签；只有真实云端结果可证明通过。若改了风险相关测试，核对原测试仍存在/执行，新增语义变化用明确successor说明，不重设阈值掩盖回归。

涉及存储/迁移/账本合同再用完整CIinputs `formed_release=all`、`formed_platform=all`追加0.9.8–0.9.11历史矩阵；如设置`formed_only=true`，那次仅是矩阵，仍需另一份完整CI。性能大改按需要追加`scale=true`，不能把合成scale当实机滚动FPS。

### 8.4 状态、下载与核验

```sh
gh run view <CI_RUN> --repo hututuo/codex-token-bar --json status,conclusion,headSha,jobs,url
gh run view <PUBLIC097_RUN> --repo hututuo/codex-token-bar --json status,conclusion,headSha,jobs,url
gh run view <PACKAGE_RUN> --repo hututuo/codex-token-bar --json status,conclusion,headSha,jobs,url
```

有`source_sha`输入时工作流run的headSha可能是dispatch ref，不要只比headSha；同时检查source job解析值、实际checkout、execution JSON和candidate manifest最终指向同一候选。失败立即读失败job日志，区分编译、回归、镜像/网络和证据收集；修源码后新SHA重新完成所需门禁。

下载到**新的独立目录**，三个run的artifact不要平铺混在一起。设置 `candidate_evidence`、`package_run`为新候选的明确路径/ID后：

```sh
gh run download "$package_run" --repo hututuo/codex-token-bar --name "candidate-macos-$candidate_sha" --dir "$candidate_evidence/package-macos"
gh run download "$package_run" --repo hututuo/codex-token-bar --name "candidate-windows-$candidate_sha" --dir "$candidate_evidence/package-windows"
python3 scripts/cloud/manifest.py verify "$candidate_evidence/package-macos" --source-sha "$candidate_sha" --run-id "$package_run" --lane macos-arm64
python3 scripts/cloud/manifest.py verify "$candidate_evidence/package-windows" --source-sha "$candidate_sha" --run-id "$package_run" --lane windows
```

下载器若保留原artifact ZIP，还需核对GitHub artifact digest、zip路径安全、解压目标未覆盖。应用解压到候选暂存目录后核对Info.plist build、可执行hash、`codesign --verify --deep --strict`、资源/诊断helper、manifest和版本。ad-hoc候选不等于公证或自动更新签名成功。两个Windows架构均要收齐；不能macOS先绿就安装。

现有本地恢复工具：`scratch/chart-aggregation-20261109/cloud.mjs`导出`status()`、`artifacts()`、`downloadJob(id)`，读取同目录`runs.json`；`evidence.py`包含unpack/validate/stage/install等模式。这些是**上轮证据脚本，跨多个旧scratch目录复用且含旧SHA/测试数/路径假设**，不是通用安装器。不要改旧runs.json冒充新基线；先读完整依赖链，复制到新批次并明确调整合同，或优先使用上述正式workflow/manifest入口。新实机规则前严禁执行install模式。不要输出或保存 `gh auth token`。

## 9. 新实机测试前询问机制（优先于旧习惯）

用户新规：**“以后实机测试前先问问用户在不在，用户没回答再自己测，用户说了就由用户来测。”**

这不是重新请求已授权的代码修改/云端构建，而是保护用户正在使用的设备。必须执行：

1. Astra完成源码、远端CI/Public097/双端包及下载校验，准备好候选SHA/build、备份方案、验收步骤和截图清单；此时可以整理文档，**停在安装/设备操作之前**。
2. 通知主控Argon：“候选X的门禁已完成，准备安装/实机验收，请先询问用户是否在场并希望亲自测试。” Argon实际向用户发问；没有发问不能把沉默当回复。
3. 给用户合理回复窗口（简单在场询问至少60秒，Argon约定更长则按约定），期间继续不占设备的证据整理，不抢鼠标、焦点、窗口。
4. 用户回复在场/愿意亲测：由用户操作GUI；Astra提供简洁步骤和预期结果，配合读取用户提供的结果。安装动作由Argon与用户安排，不能借既有安装授权抢先重启。
5. 询问已送达且窗口结束仍无回复：按用户明示允许自行测试，记录询问/等待事实再开始；用户后来回应就停止抢占，交回控制。不要重复问同一已回答的问题。
6. 范围包括CUA、capture_ui.py、JXA/AppleScript/CGEvent、任何会移动鼠标/切换窗口/取焦点的测试，也包括shell替换App、quit/restart。不能换工具绕过询问。

安装流程沿用安全做法：唯一新备份目录→核验旧App备份→替换已核验候选→启动→核对进程路径/build/hash→首次刷新和安装确认→功能验收。**禁止覆盖build1006/1007既有回滚备份，禁止清理整个scratch。** 没有必要给接手者一段可在询问前直接粘贴执行的替换命令。

实机功能验收至少：

- L1二级颜色/总速率与三级同一时点逐模型条及合计，两个模式/配色切换、展开收起、空/过期状态。
- L2“汇总”和各有记录客户端的24h/7d/30d；读出实际bucketSeconds；对同一区间比较顶部/气泡/模型列表/金额；明确Codex quota只是其provider。
- 费用表三周期四列30pt与Argon/AG分组；主/子计数同时间、同client scope核对；不人为创建假任务凑截图。
- 用户愿意进行滚动性能复测时才执行同口径sample/xctrace，记录CPU、主线程、帧/hitch、数据规模和窗口条件；不把首刷耗时当滚动性能。

旧capture脚本有硬编码PID/build、屏幕坐标和窗口号，只能参考，不能原样跑。侧栏是非激活浮窗，主窗口截图不一定包含它；按当前窗口几何与AX identifier定位，等待动画稳定，避免旧坐标点到测速/任务错误页。截图包含会话/路径，留本机；仓库报告只提交脱敏数字和证据索引。

## 10. 已知未闭合项与应避免的重复劳动

- 新反馈的7d粒度、框选模型明细与三级速度条尚未修改；本文是已定位的接手方案，不是完成声明。
- 诊断export6000事件上限漏当前启动会话：上轮以持久化脱敏journal直接核验，不伪称ZIP完整；纳入L6。
- 主线程旧安全库读取约123ms等前序性能问题和全页滚动A/B需查 `2026-11-09-installed-performance-hotspots.md`、`2026-11-09-scroll-models-performance.md`，区分已修、已采样和未后测，不能凭历史摘要重写。
- 用户当时“12个主Agent”的全部构成没有精确重建。已证实6条长期停写孤立exec误计；新规则保留5分钟宽限，不能承诺从文件推知所有远端等待/网络重试状态。
- 本机没有Antigravity Sonnet记录；双端fixture证明分组，实机只证明实际存在的Opus5.5。Windows当前是云端验证/包核验，未实体GUI验收。
- 本worktree没有CodeGraph索引；本次查询已确认，不反复调用或擅自建索引，用rg直接读源码。
- 云端7/14天artifact会过期，现存本地fixtures、compatibility binaries、回滚App和报告不能当临时缓存删除。若缺依赖脚本应补工具链可移植性，不能篡改门禁结果。

## 11. 必读材料与首轮执行清单

按顺序：

1. `AGENTS.md`和本文，确认本次只接业务后续，不重做build1007安装。
2. `docs/maintenance/2026-11-09-chart-aggregation-channel-models.md`：最新已交付边界与云端/实机证据。
3. `docs/maintenance/2026-11-09-chart-clients-sidebar-costs-scroll.md`、`2026-11-09-model-order-full-row.md`、`2026-11-09-model-costs-compact-tasks.md`、`2026-11-09-model-cost-chip-30pt.md`：不回退既有用户决定。
4. `docs/design/2026-11-07-storage-global-decomposition-master-plan.md`及 `2026-11-07-exact-foundation-batch-a.md`、`2026-11-08-exact-read-projection-batch-b.md`、`2026-11-08-exact-ingest-batch-c.md`、`2026-11-08-exact-migration-route-batch-d.md`（后四篇在maintenance）。
5. 性能两篇、`docs/design/2026-11-08-diagnostic-bundle.md`与维护 `2026-11-09-diagnostic-bundle-build997.md`，只读需要的部分，不扩大首批范围。

新线程首轮可直接执行的无设备占用工作：

```sh
cd /Users/huyiyang/.codex/worktrees/f97f/codex-token-dashboard
git status --short
git log -6 --oneline
git branch --show-current
rg -n 'fineCoversHistory|dataRange' Sources/CodexTokenBar/RecentUsageChartData.swift
rg -n 'useFine|quotaConsumptionSelection\(quotaData|modelBreakdowns' tauri-app/src/components/recentUsageChart/model.ts tauri-app/src/components/RecentUsageChart.tsx tauri-app/src/multiClient/originalDashboardProjection.ts
rg -n 'liveRates|barRates|rateRing|interaction.detail == .speeds' Sources/CodexTokenBar/QuotaSidebarViews.swift
rg -n 'selectedActivityRates|modelRateSlices|ClientActivitySpeedPanel' tauri-app/src/quota-sidebar tauri-app/src/multiClient tauri-app/src/components/liveRate
```

向Argon提交L1/L2的消费者矩阵和明确合同，之后按批准功能范围实现。每完成一轮，追加维护记录和真实门禁；下一轮开始前将发现但未实施的事项标NOT_RUN/待定位。收官报告必须列源码SHA、云端run、已安装build、实机验证范围和未完成边界，不能只写“已统一”。
