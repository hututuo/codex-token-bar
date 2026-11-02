# 历史补全、旧账保留与启动风险核查

日期：2026-11-01。核查源码：`f17cdb252e03b72ac76c0b7d077f02fa888c3b92`。
本机进程为正式安装的 0.9.11 / build990。此轮只读取正式账本和采样进程；测试写入仅发生在本工作目录的独立 fixture 中。未修改产品代码、正式数据库、安装或发布状态，未重启应用。

## 结论边界

已确认性能缺陷、进度缺陷和一个可复现的 Mac 启动可用性风险。没有证据支持“必须整体换库才能修复”，也没有证据支持“只复用连接就能完全解决”。未执行正式库全库完整性检查，不能据此宣称整库完整性已验证或账目逐行核对完毕。

旧文件缺失的历史确实存在，故不能以清库后重扫 JSONL 作为升级或恢复方案。现存大量非暂存分区的来源尚未逐项证明，不能按看起来为空或不活跃直接删除。

## 故障时间线与平台归属（用户纠正后补充）

不能把以下三件事合并为同一个现场故障：

1. 此前用户持续反馈的旧库冲突、恢复清单和启动报错，主要现场在 Windows；对应 0.9.9/0.9.10 调查包及 Rust 恢复链路。不能写成 Mac 也一直复现了这些错误。
2. 用户本机 Mac 的新问题出现在这次替换之后。安装回执为旧应用标识 0.9.8 / build987 → 0.9.11 / build990；本轮 Mac 已实证的是历史补全长时间运行、进度失真与大 schema 热点，不是同一条 Windows 启动拒绝的实机复现。
3. 本报告第 4 节 Mac 低空间启动失败属于隔离构造场景中证实的潜在风险，没有证据证明它就是本机这次发生的报错；不能以该复现替代对本机升级后问题的归因。

补充源码对比（公开 0.9.8 → 0.9.11）：BusinessStoreFiles.swift 和 ApplicationStartupCoordinator.swift 未变；BusinessStageDemand 外层、分批、容量检查和 worker 调度源码未变。CodexUsageHistoryIndex 的 parser revision 从 token-event-v3 改为 token-event-v4/compaction-v1，触发旧 receipt 不匹配的历史补全。正式库只读样本仍有 4,160 条旧 parser receipt，与升级触发全量补全的机制相符。

因此当前证据支持“这次 Mac 升级触发大批补全，暴露先前未在本机触发的慢路径”。不能把“代码早已存在”说成“Mac 以前就报过相同错误”，也不能未经差异证据就断言 Windows 的某条恢复修复直接造成了 Mac 问题。本轮先修这个升级触发路径，再分别验证 Windows 原故障与 Mac 潜在启动风险。

## 1. 已确认：进度只显示当前小批次

- `Sources/CodexTokenBar/CodexUsageHistoryIndex.swift:2670`：`BusinessStageDemand` 外层逐批构建，直接转发内部 completed，没有加前序批次已完成量。
- 同文件 `:7336`：每批任务上限为 `min(stagingMaxWorkers=4, stagingMaxReadyArtifacts=8)`，即 4。
- 同文件 `:7445`：每批新建 `StageCollector`，计数重新开始。
- 同文件 `:2930` 的另一条路径已经有 `completedBeforeBatch` 累计逻辑；不能据此认为新增的外层路径也已覆盖。

因此 `4/4124` 不是全局实际完成量，不能据此判断进程卡死。代码缺陷已经确认；这轮未运行完整 Swift 补全回归。

## 2. 已确认：批次上限没有限制持久暂存表总量

- `Sources/CodexTokenBar/BusinessStoreFiles.swift:53`：每个 job 把 TEMP 中的 manifest、fingerprints、events、chunks 复制成四张 MAIN 表。
- `Sources/CodexTokenBar/CodexUsageHistoryIndex.swift:2666`：只有完整 generation 提交后才清理这轮收集的 stage。
- `:2910`：先要求所有 full-rebuild jobs 已有可复用 stage，再进入最终导入；因此不是每四个就释放持久暂存。

正式库两个只读样本：

| 样本 | 表总数 | 已封存 stage | 扣除这部分 stage 四表后的数量 |
|---|---:|---:|---:|
| 前次采样 | 16,453 | 228 | 15,541 |
| 11月1日 18:25 左右 | 24,965 | 2,356 | 15,541 |

两次表数的增加与新增 stage × 4 完全对应。18:29 的另一份短读事务进一步区分了归属：

| 模块 | 分区数 | 表数 |
|---|---:|---:|
| exact.swift | 576 | 14,102 |
| exact.swift.stage | 2,445 | 9,780 |
| body.swift | 348 | 1,392 |

因此存在两种负担：当前补全新增的暂存表，以及本来就存在的大量正式/旧分区表。只停止新建 stage 表，不会自动消除后一种负担。

原始数值证据：`scratch/local-install-0911/backfill-risk-live.json`、`backfill-risk-schema-owners.json`。这些样本发生于不同时间，不能把它们拼成同一个原子快照。

## 3. 已确认：反复打开大库以及 DDL 使缓存失效

- `BusinessStoreFiles.swift:42`：即使传入当前 connection，byteCount 的 seal 查询仍另开连接。
- 同文件 `:99`：stage observation 再另开只读连接。
- `CodexUsageHistoryIndex.swift:7868`、`:7881`、`:7907`：一个 stage 收尾重复经过这些入口。
- 同文件 `:8229`、`:8240`：复用 stage 时，byteCount 和 observation 也会从现有读取连接之外再开连接。
- `CodexBusinessDatabase.swift:95`：`allStores` 每次另外打开容器、读取登记路径；stage 路径查找会用到它。
- `SQLiteDatabaseDriver.swift:849`、`:865`：这些 driver 调用打开、关闭物理连接。
- `SQLiteStoreConnection.swift:212`：每个逻辑分区连接还会读取 schema、安装逻辑目录视图。

正式进程的两次 sample 均落到大库 schema 初始化/解析，最新 sample 还直接命中 byteCount。不能把短采样解读成所有耗时均由这一个入口造成。

正式库只读单条 seal 查询测量（SQLite 3.54.0）：

- 三次新连接：1.294 / 0.838 / 0.880 秒。
- 同一已加载连接的五次查询：约 3–76 微秒。
- 这是单查询测量，不能宣称整个补全会按相同比例提速。

另用独立的 8,002 张空表 SQLite fixture 验证缓存失效机制：

- 另一连接只插入行后，相同查询约 0.011–0.098 ms。
- 另一连接新增四张表并提交后，相同查询约 7.2–7.8 ms。
- 随后再次查询又降回微秒级。

这说明持续 DDL 会使已保留连接也重新加载 schema。该空表测试只证明机制，不代表当前产品耗时或优化后的吞吐。

复现脚本：`scratch/local-install-0911/risk-audit/schema_cache_probe.py`。结果：同目录 `schema_cache_probe_result.json`。脚本只创建并自动回收自己目录中的合成 fixture。

## 4. 已复现：Mac 新发现旧库失败会挡住既有可用账本

生产逻辑：

- `BusinessDatabaseMigration.swift:116`：先发现所有旧输入，之后才判断已有库是否可以快速启动。
- `:154`：只有 pending 为空且 activation=ready 等条件成立才跳过迁移。
- `:166`：先提交 pending journal 和全局 activation=importing。
- `:181`：之后才检查迁移空间；不足则抛错。
- `ApplicationStartupCoordinator.swift:35`：prepare 成功才构造 runtime；失败则保持失败页面。

用七个未修改的生产 Swift 数据库/迁移源码文件编译小型独立 probe。资源入口和未使用的 Exact 依赖由既有 probe stub 提供；测试未调用生产目录发现，也不是完整 GUI/Exact 迁移验收。

隔离复现输出：

```text
initial_activation=ready
injected_space_failure=账本迁移空间不足，未切换旧账。
activation_after_failed_added_import=importing
initialized_marker_still_present=true
existing_ledger_row_still_intact=[123]
routes_active_after_failure=false
activation_after_space_restored=ready
restored_old_row=[123]
restored_new_row=[456]
```

确定的触发条件是：已有 ready A + 启动发现新增旧库 + 导入空间不足。它造成可用性损失，不是这份复现证明了数据丢失，也不是本机这次现场错误已被归因为空间不足。不能简单忽略全部迁移错误来绕过关卡；首次建库、来源冲突、容器缺失和未知格式仍需各自保持安全边界。

复现源码和 fixture：`scratch/local-install-0911/risk-audit/StartupGateRiskProbe.swift`、`isolated-added-import/`。

## 5. 已确认：原始文件缺失的历史不能重扫恢复

本机当前 Home 分区只读计数：36 个 `usage_ledger_sources.missing=1`；当前 events 533,937 行。未读取对话文本，也未逐个重新检查这些路径，因此这里准确含义是“账本已标记来源缺失”。

- Swift：`CodexUsageHistoryIndex.swift:3113` 只标记 missing、撤销文本 binding，不删除已发布 events；`:6653` 排除缺失来源的强制补全。
- Rust：`exact_usage_index.rs:9447` 对应保留已发布消费，只撤销 excerpt binding。
- 现有 `BusinessDatabaseMigrationTests.swift:270`、`:331` 包含迁移后缺失来源保留的测试定义。本轮没有重新运行这两个全包测试，不能把代码存在当成本轮通过。

这意味着任何新库方案都必须迁移已有账本，不能用当前磁盘日志代替全部历史。也不能把 `available=0` 的 binding 数当成缺失事件数量；这些是不同口径。

## 6. 双端核查：共同问题与行为差异

| 核查项 | Mac | Windows / Rust |
|---|---|---|
| 生产 stage 持久表 | 每 job 四张，位于 A | 同样四张、位于 A |
| 重开 A / seal 查询 | 已实机采样、只读测量 | 代码确认，未做 Windows 性能实测 |
| 原始日志缺失时保留账 | missing 路径保留 | missing 路径保留 |
| ready 库遇新增输入失败 | 可挡住整个 runtime，空间不足已隔离复现 | 已初始化 bootstrap 先校验后返回，迟到导入不使用 Mac 同一全局关卡 |

Windows 证据：

- `tauri-app/src-tauri/src/core/usage/token_count_jsonl/exact_usage_index.rs:6879`：`cfg(test)` 打开独立 stage 文件；生产经共享 A 路由。普通单元测试因此不能替代生产路由下的大规模补全性能测试。
- 同文件 `:6988`：TEMP 四表物化到持久表。
- `tauri-app/src-tauri/src/core/business_store_route.rs:61`：已 initialized 的 bootstrap 先验证、执行维护，然后返回。
- 同文件 `:95`：维护失败仅记录性能日志；这与 Mac 的新增旧库全局导入关卡不同。

本轮 Rust 部分是只读代码审查，没有运行 Windows 构建、测试或实机验收。

## 7. 版本不是一串必须逐版执行的新迁移

已按本地发布 tag 解引用到 commit，并读取对应源码；0.9.10/11 源码 SHA 与版本 locator 对照：

| 发布版本 | Swift Exact 主 schema | 容器 / 补全区别 |
|---|---|---|
| 0.9.1 | 6 | 独立旧库 |
| 0.9.2–0.9.3 | 13 | 独立旧库 |
| 0.9.4–0.9.7 | 14 | 独立旧库 |
| 0.9.8–0.9.9 | 14 | 合入 A；新增 BusinessStageDemand；旧 parser revision |
| 0.9.10–0.9.11 | 14 | 同一个 A 容器合同；compaction parser revision 触发历史补全 |

表中 schema 是 Swift；不应把它直接套到 Rust 的早期 schema 数字。主 schema 相同也不代表恢复 journal、parser receipt、暂存格式相同。

引入记录：

- `4e9024e0591479ca2ba2b4759e669ff6f6bf9f56`，2026-10-28 03:23 +08:00：合库、BusinessStoreFiles、BusinessStageDemand；本地 tag 显示首次包含于 0.9.8。
- `e6e9173befa68336192930e58c8423cf7a0ba2c8`，2026-10-31 23:39 +08:00：compaction parser revision，触发旧 receipt 对应来源重算。

## 8. 已有测试能证明什么，尚缺什么

已存在的专用云端 workflow 会用 v0.9.7 源码生成合成数据，再跑生产迁移；Windows 另有 v0.9.3→v0.9.7 输入生成和独立生产 probe。不是“从未测过升级”。

但当前 `release-upgrade-compatibility.yml` 及指定 fixture 不能证明本次规模场景：

- Swift v0.9.7 fixture 只有两个 Home 的小库；模型补全进度断言有 total=1 的用例，无法发现跨四任务批次的回退。
- Rust 普通 stage 测试与生产共享 A 的路径不同；独立生产 probe 不能自动补足万表性能覆盖。
- 未发现该专用门禁用 0.9.8/0.9.9/0.9.10/0.9.11 各版本源码生成的大规模半完成 stage 状态，并逐一升级运行的证据。
- 尚未跑“数千 stage + 既有上万表 + 全轮发布/中断重开 + 旧源缺失 + 重复启动”的组合验证。

本轮实际执行：正式进程短采样、正式库有时限只读查询、隔离生产迁移 probe、隔离 SQLite DDL 缓存失效 probe、版本源码比较。没有全量 Swift/Rust 回归，没有新构建或发布。

## 9. 对后续方案的确定约束

1. 修复对象至少包含累计进度、stage 表累计增长、重复连接/目录读取、Mac 新增旧库对 ready 账本的全局阻塞；只改其中一处不能宣称完全解决。
2. 不改账本 schema/parser revision 不能被当成免测试理由；即使只是换 stage 存储，也必须读取旧 stage、验证 seal/源指纹、恢复中断，且不能把未提交批次当成已发布历史。
3. 不可直接逐批提交正式账来释放 stage；当前整轮原子发布保证需要保留，或先设计并验证等价的代际发布机制。
4. 不删除原库、不从 JSONL 重建全部历史、不把未知旧分区当垃圾清理。现有非 stage 大量表的来源和可回收条件未证明。
5. 不能保证换库一定更安全：物理重建需要额外空间、完整元数据/ID/回执迁移、切换期间新增写入处理和旧格式回退；这些路径本轮未实现或验证。
6. 是否需要整理正式分区或换物理库，应在隔离的大规模生产路径测试中比较，再作决定；当前证据首先支持修复已定位的读写/暂存/启动行为，而不是强制用户再进行一次全账本迁移。

## 10. 逐版本方案补查的两个确定边界

### Windows 0.9.0/0.9.1 的无版本字段 stage

这两版已知 stage manifest 没有 `manifest_schema_version`，但有 complete、path/session、parser/migration、artifact、字节数、integrity、来源签名/前缀和计数字段。旧完整性标志为 `sqlite-quick-check-v1`；已提交但尚未封存的 complete=0 行可以是合法中断。

当前 `exact_usage_index.rs:6419–6454` 的既有 stage 处理依赖 superseded/restartable 分类，而 `:19293–19359` 两个 helper 要求版本字段。旧 v0 因缺列不能进入这两条已知恢复分类，会走未验证 stage 的 Fatal 分支。此结论来自发布源与当前源对比，本轮没有执行旧发布生产者生成的 v0 实例测试；详细方案将其列为必须先红后绿的 T18。

处理不能只是把缺列补成当前版本：新增精确旧布局适配，只识别、保留/隔离，从仍可用的原文建立当前解析任务。旧 stage 本身不具备当前 source/base generation 证明，不能冒充 compaction-v1 成果。

### 两端原子发布机制不同，不能照搬

现有设计契约和当前 Rust 源码一致：Swift 使用整轮外层事务；Rust 在 `exact_usage_index.rs:8006–8072` 保留 building generation，在 `:9421–9607` 最终事务发布 pending/published generation。修复固定暂存存储时应接入各自已有机制，不把 Rust 重写成 Swift 事务结构。

两端 0.9.2–0.9.9 的已知旧 parser stage 即使格式可读，也不能直接满足当前 compaction-v1 完成条件。0.9.10/0.9.11 的 stage 只有完整性、parser、owner、来源及相关代次全部匹配时才可接续。详细执行表与逐版本矩阵见 `docs/design/2026-11-01-ledger-backfill-repair-plan.md`；解引用 commit 的机器可读比对保存在 `scratch/ledger-repair-detailed-plan/release-format-matrix.json`。

## 11. 用户截图三项的逐条代码复核

本节是只读源码核查；未操作正式数据库、未安装或构建。截图提到的另一份现场报告未取得，不能将本节代码证据冒充对其原始SQL/哈希现场的复现。

### 11.1 额度历史：缺列和来源过滤是两件事

- 四列：five_hour_cycle_generation、five_hour_reset_anchor、seven_day_cycle_generation、seven_day_reset_anchor。
- Swift QuotaHistoryStore.swift:1292–1357、1586–1621：peer先检测列，缺cycle列时投影缺省值；本地writer另有ensureSchema。稳定identity的Tauri peer行并非一律被Swift过滤。
- Rust quota_history/database.rs:221–248、447–508：peer查询直接引用cycle列，之后只接收source=swift；quota_history.rs:397–424生产路由以?传播失败。
- quota_history.rs:382–385测试peer路径用unwrap_or_default；quota_history_tests.rs:1460附近旧schema测试只期望保留本地行，不能证明旧peer历史可读。:1533附近还明确断言peer的Tauri来源被忽略。
- 所以确认Windows生产读取存在缺列失败和按来源遗漏历史的风险；不能表述成“Mac所有历史都只收Swift”。无stable identity的旧记录还须另走安全legacy归属，不可只移除source筛选后跨账户拼接。

### 11.2 checkpoint拒绝追加后，旧stage可永久阻塞重建

- Rust exact_usage_index.rs:10496附近：新扫描validation_chunk_hash与stored_tail不符返回false，拒绝追加；:6419–6454按固定路径查旧stage，无法复用又未归类为superseded/restartable时Fatal。
- :7160–7260附近的复用条件包括目标building generation、source/base generation、旧resume/prefix和来源边界；已完整封存但基准不再匹配的stage可能无法复用。
- Swift CodexUsageHistoryIndex.swift:6856及:7534附近存在对应的追加拒绝与既有stage阻塞路径，需一并覆盖。
- 已确认这条阻塞机制；尚未确认截图现场的旧哈希最初由哪个版本、何种写入产生。必须区分真实源文件改写、旧checkpoint算法/边界和旧任务基准变化。不能简单重写hash或删除旧stage。

### 11.3 state_5冻结：Windows精确扫描的生产路由误用

- exact_usage_index.rs:11550附近estimate_active_rollouts、:11878附近stage_thread_metadata把外部state_5.sqlite交给open_read_only_index。
- :15202–15234的open_exact_business_store/open_read_only_index：非测试分支将任意传入路径按exact store调用business_store_route::open_store；测试分支则直接sqlite::open_read_only。
- business_store_route.rs:590–652：已有同store消费回执且无pending时跳过重导入，已有objects且无新snapshot时返回A分区连接。对程序自己的旧账这是消费所有权规则，对仍在更新的state_5则导致读取冻结副本。
- Mac CodexUsageAnalyzer+StateSQLite.swift:10–29、188–206当前每轮读取外部WAL；Windows live_rate/state.rs、usage/state_sqlite.rs的普通读者也直接读原库。故问题不是所有实时读者一律失效，而是精确索引内复用了错误的read-only helper。
- git -S追溯此生产helper的改动到4e9024e0（2026-10-28合库提交）；本轮未跑各发布产物的运行复现，版本范围应由对应源码/生产fixture进一步验收。

三项此前未在方案中逐条闭环，现已补入C04a和T33–T37；状态是“代码问题已定位/现场哈希成因待核对”，不是“修复已通过”。
