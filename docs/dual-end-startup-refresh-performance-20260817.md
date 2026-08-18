# 双端启动与刷新性能审计（2026-08-17）

## 结论

当前最重的不是“首次建立索引”这一件事，而是后续额度/归因变化把完整仪表盘重新聚合了一遍。索引同步本身已经有增量判断，但完整统计仍会重新读取已发布事件，导致一次刷新重复做 11–42 秒的历史聚合。

本轮先完成三项低风险收敛：

1. Tauri 的 `quota`、`attribution`、`catch-up` 请求改走已有的 summary owner；保留上一次完整画布，完整画布只由首次精确读取、普通 cadence、源切换或手动刷新更新。
2. 双端归因边界统一按索引实际使用的 5 分钟桶计算，同一桶内的额度轮询不再被当作新的完整归因任务。
3. Swift 在当前 5 分钟桶已经有精确覆盖时，归因回调只标记待更新，不重复启动完整历史聚合；跨桶、连续性丢失和手动刷新仍走精确路径。

没有修改原始 JSONL、`events` 表结构、generation 发布边界，也没有触发真实用户索引重建。

## 现场身份

- 仓库：`/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard`
- 分支：`codex/ui-paging-arrow-cues`
- 审计时 HEAD：`e73c07da49a6b06f0d7517a49f9b071d83193b81`
- Swift 运行实例：PID `71030`，版本 `0.8.3`，来自 `dist/Codex Token Bar.app`
- Tauri 运行实例：PID `74123`，版本 `0.8.3`，来自 `tauri-app/src-tauri/target/debug/run-bundle/...`
- 本轮只构建了 Swift debug 源码和 Tauri 前端；没有替换或重启这两个运行实例。

## Swift 原生版

### 首次启动

启动顺序为：

1. `CodexUsageStore.init` 解析 Codex Home、启动会话变更监视器。
2. 立即读取 fast snapshot：优先读已持久化的精确数值快照，否则读 `state_5.sqlite` 的轻量统计。
3. 2.5 秒后启动第一次精确 owner，避免首屏和精确索引同时抢资源。
4. 枚举 JSONL、计算文件签名和会话签名。
5. 打开 `CodexUsageHistoryIndex`，执行 schema/replay/catalog/attribution ledger 检查。
6. 对未变化文件只做 metadata 校验，对 append 文件读尾部，对重写文件做定向重建；迁移/发布在 SQLite 事务内提交。
7. 生成完整数值统计：当前实现会遍历已发布事件，构建日、小时、5 分钟序列、模型分布、缓存命中排行和归因数据。
8. 原子写入 numeric snapshot；随后在索引锁外补齐会话/turn 摘录。

现场同规模（约 2,106 个 JSONL、336,037 个事件）的代表性时间：

- fast snapshot：约 `0.8–2.9 s`；
- 精确索引和聚合 cache hit：约 `0.35–0.5 s`；
- 索引有变化或聚合 cache miss：通常 `6–10 s`；
- 观测到的异常长尾：约 `29–31 s`，另有一次约 `72 s`。长尾不是 SQLite 最终提交造成的，而是索引锁/事件聚合链路的等待或重复工作。

当前精确 SQLite 约 `613 MB`，包含约 `336,037` 个 events、`2,106` 个 sources、`26,528` 个 attribution buckets 和 `1,440` 个 session catalog entries。

### 后续启动

后续启动仍然先走 fast snapshot，再按签名决定是否启动精确 owner：

- 签名和已持久化精确快照一致：很快返回上次可信数值；
- 活跃 JSONL 有 append：同步增量索引，但当前完整聚合仍会重新遍历已发布事件；
- provenance/schema/replay/integrity 变化：只应进入相应迁移或归因 ledger 修复，不应因为小问题重扫全部 JSONL。

因此“后续启动”并不是每次都慢，但只要发生活跃文件变化，就可能重新付出完整聚合成本。

### 后续刷新

- 普通 Swift timer 默认约 `300 s`；
- 仅状态栏/悬浮窗可见时，已有 compact summary：增量同步 + 三条 SUM SQL，不构建时间序列、排行和摘录；
- 展开主仪表盘时走完整精确统计；
- 之前 `refreshPreciseTimeSeriesForAttribution()` 无条件 `forceFullTimeSeries`，额度归因回调会绕过 compact 优化。本轮已增加 5 分钟桶门控：当前桶已有精确覆盖时，不再重复启动完整历史聚合。

当前 Swift 进程现场资源样本：RSS 约 `130 MB`，物理 footprint 约 `252 MB`，峰值约 `434 MB`；采样时 CPU 约 `39%`。这包含应用本身，不等于单次扫描的磁盘写入量。

## Tauri 跨平台版

### 首次启动（已有索引的真实现场）

Tauri 启动先读取持久化 dashboard snapshot，再启动精确 owner：

1. 读取持久化快照：现场约 `145 ms`，先把旧的可信画布展示出来。
2. 精确 owner 打开索引、等待锁、执行 integrity/watcher/schema 检查。
3. 预扫描只用于估算进度，本次发现约 `2,106` 个候选文件。
4. `sync_with_scan_plan` 做 metadata/append/full-rebuild 判断并发布 generation。
5. summary owner 读取轻量汇总。
6. 完整 owner 调 `dashboard_data`，重新构建活动日、stats、24h/7d/30d 五分钟序列、排行、模型/归因详情。
7. 写入持久化 numeric cache 并向前端发布。

现场第一轮已有索引的精确请求：

| 阶段 | 时间 |
| --- | ---: |
| open/index preparation | `32,747 ms` |
| sync | `9,536 ms` |
| dashboard_data | `11,369 ms` |
| store publish | `251 ms` |
| full total | `11,623 ms`（完整阶段） |
| request total | `54,519 ms` |

这里的 `open` 包含精确索引打开/锁等待/初始化边界，不能把它误报成“重新扫描了 32 秒”。现场当时完整性收据记录的是 generation `59`，数据库已经是 generation `60`，因此这一次会执行一次 SQLite `quick_check(1)`；收据在本轮关闭时已更新到 generation `60`，后续同样状态的打开可以跳过这次检查。本轮没有在真实 Home 上强制删除索引来测冷建，因此不能伪造首次冷建秒数。

### 后续启动与刷新

- 可见 dashboard cadence：约 `3 min`；
- 后台 cadence：约 `5 min`；
- quota cadence：设置默认约 `60 s`，可选 `30 s`；
- source watcher/catch-up 可能另外触发精确请求。

完整 owner 的现场长尾：

- 常见 `15–29 s`；
- 观测到 `35.9 s`、`52.5 s`；
- 一次 `dashboard_data` 达到 `42.3 s`；
- summary-only owner 约 `5.3–6.0 s`，明显低于完整 owner。

Tauri 当前 exact DB 约 `2.12 GB`，约 `358,560` 个 events、`2,108` 个 files、`12,932` 个 file chunks。进程现场 RSS 约 `89 MB`，物理 footprint 约 `110 MB`，峰值约 `300 MB`；活动期间 CPU 样本约 `20–72%`。

一次全系统 `iostat` 观察到磁盘吞吐约 `169–554 MB/s`，因为 Swift 与 Tauri 同时运行，不能把这个数字冒充成某一个进程的独占写入量。

### 已确认的重复链路

原先的触发链是：

```text
quota poll / attribution callback
  -> read_precise_dashboard_snapshot
  -> native full owner
  -> dashboard_data（重新聚合全部历史）
  -> quota/catch-up 再次检查 coverage
  -> 同一 5 分钟桶内再次发起 full owner
```

当前 Tauri native 已经有 `read_usage_summary_snapshot` 和 Summary/Full 两类 owner，但前端归因请求一直调用完整 dashboard command；此外前端的 attribution boundary 之前按 Unix 秒去重，而索引实际按 300 秒分桶。

## 本轮修改

### Tauri

- `tauri-app/src/state/attributionBoundary.ts`：归因 key 改为 Unix 时间的 5 分钟桶起点。
- `tauri-app/src/state/usePreciseDashboardLoad.ts`：`quota`、`attribution`、`catch-up` 只调用 summary owner，不清空当前完整画布，不触发 30 天 dashboard 聚合；普通 cadence、source-change、manual、retry 仍走完整 owner。
- `tauri-app/src/data/dashboardDataSource.ts`、`useDeferredDashboardLoads.ts`：接入轻量 summary 读取能力。
- 相应单测已更新为五分钟语义。

### Swift

- `Sources/CodexTokenBar/CodexUsageStore.swift`：在同一 5 分钟桶已有精确覆盖、没有连续性丢失时，归因回调不再启动完整历史聚合；跨桶或安全恢复仍走完整路径。
- `Sources/CodexTokenBar/DashboardHeaderView.swift`：`StatStrip` 增加轻量等价边界；同一历史快照不再因实时速率每秒发布而重新构建 7d 模型归因。一个 body 内的 7d 数据、储蓄估算和模型费用行也改为每次事务只计算一次。
- `Sources/CodexTokenBar/DashboardView.swift`：在 `StatStrip` 外加 `.equatable()`，把实时速率表面和历史统计表面隔开。

## 本次现场复核：两个旧运行实例

### Tauri 的“双遍”现象

旧的 0.8.3 Tauri 实例的 `performance-trace.log` 确实记录了两个不同的 full owner，而不是同一个 owner 把同一阶段打印了两遍：

- flight `29`：`intent=full`，来源 `cadence`，同步约 `3.68 s`，`dashboard_data` 约 `16.07 s`，总计约 `21.54 s`；
- flight `30`：`intent=full`，来源 `attribution`，同步约 `2.99 s`，`dashboard_data` 约 `25.73 s`，总计约 `30.67 s`；
- 随后 flight `31` 又由 `cadence` 触发了另一轮 full；flight `32` 是 full cache hit，但仍会展示候选文件核对和提交阶段。

因此用户看到的“发布后又重新跑几千个文件”在旧运行版本上是事实。直接触发原因是旧前端把额度/归因边界请求送进了完整 dashboard command；当前源码已经把 `quota`、`attribution`、`catch-up` 切到 `read_usage_summary_snapshot`，完整 dashboard 只保留给 cadence、source-change、manual 和 retry。当前正在运行的旧二进制没有被替换，所以现场仍可能看到旧行为，必须重新构建并替换后才能验收本轮修复。

轻量 summary owner 仍可能核对数千个文件，这是索引正确性所需的增量扫描；它不应再生成完整 24h/7d/30d dashboard aggregate。当前 Tauri progress 文案已区分“增量核对精确索引（轻量汇总）”与“完整精确历史扫描”，避免把两类 owner 误认为两次完整面板发布。

### Swift 的高功耗现象

对运行中的 Swift PID `71030` 做了 8 秒 `sample`：主线程约 `4.49 s/8 s` 都在 `SwiftUICore GraphHost.flushTransactions → AttributeGraph → StatStrip.body`。其中同一 body 内重复进入 `DashboardSevenDayModelData.init → ModelUsagePresentation.rows → OfficialAPIPriceModel.detected`，说明高功耗主要来自 SwiftUI 历史统计视图的重复求值和根视图被实时速率更新牵连，不是后台索引线程持续全量扫 JSONL。

本轮修复先采用低风险的渲染隔离：实时速率更新仍由 `LiveRateView` 自己观察，历史 `StatStrip` 只有输入快照真正变化时才重算；没有改索引格式、没有改变扫描正确性，也没有停掉实时速率功能。替换新构建后需要再次采样确认主线程不再持续落在 `StatStrip.body`，并记录 Activity Monitor 的 Energy Impact 变化。

## 验证结果

- Tauri 前端 `npm run build`：通过；仅保留既有 chunk size/dynamic import warning。
- Tauri 定向状态测试：`47 passed / 0 failed`。
- Swift `swift build`：通过。
- Swift `swift test --filter CodexUsageStoreTests`：未进入执行阶段，工作树内已有的测试源码在 Swift 6 并发检查处失败（`CodexUsageStoreTests.swift:1211`、`1222`、`1259`、`1298`、`1307` 等 `await` 位于 XCTest autoclosure）；这不是本轮 Swift 源码编译失败，需单独修复测试契约后再跑。
- `git diff --check`：通过。

## 仍需做的第二阶段

本轮先止住重复触发，完整的性能收敛还需要继续做：

1. 在两端把完整 dashboard aggregate 按 `published_generation/dashboard_revision` 做增量维护：append 只合并 delta，只有首次冷建、rewrite、provenance/ledger 不安全或 schema cutover 才完整重放。
2. Swift 的 `forEachStoredEvent` 改为优先消费已有 5 分钟 attribution buckets；会话摘录/detail hydration 与数值统计彻底分离。
3. Tauri 首次冷建采用“发现一次、2–4 个解析 worker、单 SQLite writer”的受控并行，保留 `building_generation/published_generation` 原子发布边界。
4. 给两端统一记录 open/lock、discovery、unchanged、append/full parse、ledger、commit、aggregate、publish 的耗时、文件数、读取字节、写入字节和进程 footprint。
5. 用隔离 fixture 测冷建和 rewrite，不删除当前用户索引，不拿真实 Home 做破坏性重建。

这些第二阶段还没有宣称完成，也没有把当前运行中的旧 0.8.3 实例替换掉。
