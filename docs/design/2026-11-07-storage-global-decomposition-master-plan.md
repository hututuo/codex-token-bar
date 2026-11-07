# Exact 与业务库路由：全局复盘与一次性拆分总计划

日期：2026-11-07（Asia/Shanghai）

范围：`exact_usage_index.rs`、`business_store_route.rs` 及它们直接依赖的现有模块。

状态：只读调查与规划；本次没有修改产品代码、测试、工作流或数据库，也没有启动本地构建。

本文的调查数字和行号绑定 `ba9b222ef5e1c2de5f4368f63dbb56d2912b3270`。用户确认后，批次 A 已完成，见[执行记录](../maintenance/2026-11-07-exact-foundation-batch-a.md)；批次 B 已完成，见[读模型、投影与账本执行记录](../maintenance/2026-11-08-exact-read-projection-batch-b.md)；批次 C 已完成，见[扫描、checkpoint、暂存与回填执行记录](../maintenance/2026-11-08-exact-ingest-batch-c.md)。C 受测产品 `a865072a1208a39d27261b0e0730869678bd6080` 已通过双平台完整 Rust、生产场景、备份负控及四版本双平台历史接续矩阵。不改写下文原调查基线；批次 D 尚未实施。

## 结论先行

当前待整理的两个主文件合计 **18,074 行**：Exact 主文件 15,892 行，业务库路由 2,182 行。路由文件中约 1,410 行是生产流程、约 772 行是内嵌测试；Exact 的主要业务测试在外部测试文件，主文件仍包含少量 `cfg(test)` 钩子和测试辅助。因此不能把 18,074 行都当成同等的生产复杂度。

前六次提取没有造成已观测的运行时回归，也没有新开连接或改变事务；但它们并没有同等程度地减少依赖。会话目录、标题同步、路由准入和迁移证明形成了可审查的局部边界；结构初始化有明确的调用合同，但仍依赖主文件的 schema 辅助；暂存发布主要是把一段 SQL 函数换到另一个文件。之前每个小步骤都重复了大范围云端验证，按“几百行一个批次”推进的工程成本明显高于把同一职责一次归位。具体额度消耗没有在证据中单独计量，不能伪造一个节省比例。

终局不应追求把每个函数都拆成独立服务。应形成一个薄的 Exact 外观层、一个连接与完整性层、一个读模型层、一个投影/账本层、一个扫描暂存层、一个迁移兼容层，以及一个保持完整的路由导入协调器。SQLite 快照、IMMEDIATE 事务、暂存池回执和连接析构顺序各自只保留一个拥有者。

## 一、前六次拆分的真实价值

| 批次 | 现在的位置与规模 | 实际形成的边界 | 仍然存在的耦合 | 客观判断 |
| --- | ---: | --- | --- | --- |
| 结构初始化 | `exact_usage_index/schema.rs` 1,526 行；主文件移出约 1,520 行 | 建表、兼容视图、缺列补齐、重建视图和触发器有单一入口，SQL 顺序可集中复核 | 依赖 `Connection` 别名、`ensure_source_observations`、列检查和 dashboard bucket 安装；调用者仍控制事务和启动顺序 | **有边界价值，但不是独立 schema 子系统**。保留原函数体和顺序是正确的，不能再把它包装成泛化迁移服务 |
| 会话目录 | `session_catalog.rs` 753 行；主文件净减 705 行 | 自有目录类型、观察值、解析/发布事务和快照入口；目录增量重算逻辑能单独审查 | 共享 `reject_session_catalog_reparse_point`、列合同和 `ManagedIndexConnection`；旧库发现仍需父层入口 | **实质解耦**。它拥有一个稳定的投影合同，但不拥有全局锁、连接 Drop 或旧账恢复 |
| 标题同步 | `thread_metadata.rs` 328 行；主文件净减 304 行 | `stage`、借用调用者事务的 `apply`、独立 metadata-only 发布三种入口和阶段类型集中 | 依赖父层 metadata 辅助和 `external_state`；标题变化与数值 revision 的关系仍由调用者决定 | **实质解耦**。这是投影边界，不是独立数据源服务 |
| 迁移证明 | `migration/proof.rs` 803 行，入口 8 行，合同测试 78 行；主文件净减 771 行 | serde 事实、lineage、摘要生成和 `preserves` 比较集中，证明类型的可见性已收窄 | 仍依赖账本、目录列清单、父层摘要编码、多个 metadata 常量；切换、候选文件和事务仍在父层 | **有实质边界，但只隔离“证明”**。不能宣称迁移流程已解耦 |
| 暂存发布 | `publication.rs` 401 行；主文件净减 391 行 | pending generation 的 SQL 入口独立，函数接收调用者事务 | 只依赖父层 `Transaction`、`ledger` 和表检查；最终发布顺序、revision、消费回执仍由 `finalize_generation` 拥有 | **低收益的局部搬运**。文件边界有用，但没有形成新的状态所有权，不应再用同样粒度继续拆 |
| 路由准入 | `business_store_route/admission.rs` 230 行；路由主文件净减 207 行 | marker、ready/readable、物理文件身份和 `ACTIVE_CONTAINER_IDENTITY` 由一个模块拥有；私有状态没有复制 | 仍由父层 bootstrap、owner、根版本、journal 和收据流程调用；Exact 与 route 的桥接循环仍在 | **实质解耦**。准入检查有集中入口，但它不等于完整的业务库安全层 |

### 这些拆分带来的实际收益与代价

- 运行时收益来自原有逻辑本身，不来自 Rust 文件边界。函数调用不会因为换文件而自动变快；当前证据没有显示模块拆分改变查询次数、连接数或回填算法。
- 结构收益是私有类型和入口更容易定位，尤其是目录、标题、准入和证明。反过来，主模块现在仍是大量共享常量、类型和 helper 的导入中心，`ledger.rs`、`canonical.rs`、`representations.rs`、`runtime_recovery.rs`、`empty_sources.rs` 还使用 `use super::*`，说明深层依赖尚未收束。
- 兼容性证据很强：前六次均保留了函数体/SQL、旧测试身份和双平台历史验证；但这证明的是行为保持，不是“依赖已消失”。没有证据表明这些模块成为可脱离 Exact 主状态的独立库。
- 工程成本偏高：每次几百行移动都重复双平台完整库、非 test 生产入口、历史数据库和 Public097 的验证。以后应按完整职责批次验收，单个小模块只做结构等价核对，不再单独消耗一整套历史矩阵。

## 二、剩余代码的状态、连接与事务地图

### 1. 根状态和连接寿命

`ExactUsageIndex`（当前文件约 252 行附近）持有：

- `ManagedIndexConnection`；
- `_operation_lock: Option<AppOperationGuard>`；
- `published_read_only`；
- `migration_pending`。

字段顺序有意保证 managed connection 先关闭、操作租约后释放。`ManagedIndexConnection` 的 `Drop`（约 561–680 行）必须在连接仍存活时读取 receipt 元数据，随后关闭连接，再进入 per-path gate 写出关闭后的完整性收据并减少全局 active count。把 `Drop`、gate、receipt state 分到不同小文件会破坏这个时序；它们应作为一个连接/完整性层整体移动。

生产 `Connection`/`Transaction` 是业务库绑定后的别名，单元测试才使用普通 rusqlite。子模块若为了编译改用普通 rusqlite 连接，就会绕过 namespace binding，属于回归而不是重构细节。

### 2. 各区域调查结论

| 区域 | 当前行段/规模（粗分） | 共享状态、连接和事务 | 拆分便利度 | 风险与建议 |
| --- | --- | --- | --- | --- |
| 打开与同步主流程 | `1599–3642`，约 2,044 行；含 `open_at`、`sync_with_scan_plan_mode_once` | Home 锁、跨进程路径锁、完整性 gate、managed connection、`published_read_only`/`migration_pending`；同步期间要保持同一连接和锁 | 中 | 适合作为根编排者保留。可以把被调用域移出，不能把 `open_at` 或同步闭包切成多个各自打开/提交的 service |
| 查询、摘要、dashboard | `3643–5343` 等，粗计约 3,051 行，混入聚合修复和 attribution | `summary_at` 在 autocommit 时创建快照；`dashboard_data_at` 在一个 deferred snapshot 内创建 TEMP selector/views，再完成 totals/activity/trends/ranks/excerpts；摘录验证可在该连接内用 savepoint 写回物理证明 | 中高 | 适合成为一个读模型批次，但不能按“统计/趋势/排行”各拆一个连接。数值缓存与标题 projection 的失效规则必须保持分离 |
| 聚合修复与归因 | 与上一区域交错，约 1,500–2,000 行 | `ensure_dashboard_aggregates` 有单独 repair txn；generation 发布、dashboard watermark、attribution provenance 有不同代次和 marker | 中 | 作为投影/账本层处理；不能把 repair txn 塞进 dashboard 读取快照，也不能把 attribution 当作普通 disposable aggregate |
| 暂存构建、校验、导入 | `5741–7807`，约 2,067 行，另有 shared staging types、两个 event sink | worker 只生成 sealed artifact；private scratch SQLite 与正式 A 分离；导入时在同一不可变 stage 上做 IMMEDIATE 事务；stage association、publication consumption、pool reclaim 是三个不同时点 | 低到中 | 可在一个“扫描暂存”批次中移动到 `ingest`，但必须保持 builder/validator/importer 的顺序和同一 artifact。不能先消费回执或提前删池文件 |
| 增量扫描、checkpoint、来源发现 | `9407–11396`，约 1,990 行，另有文件签名和路径 helper | `append_session_file` 自有 IMMEDIATE 事务，checkpoint 只在代次变化时复制；物理身份、prefix/EOF 验证和缺失/不可读/越界三态决定能否发布 | 中 | 适合与暂存构建同批，但 discovery 只能提供 hint，不能替代权威扫描。`empty_sources` 是特殊的新空源事务，不应与普通 full rebuild 合并 |
| 历史迁移与兼容 | `11397–13143`、`13907–14642` 粗计约 2,483 行，proof 已部分移出 | schema9/10 candidate txn、schema11 phase、候选/rollback 路径、seal、route clone/replace、accounting migration 各有独立边界；生产和 `cfg(test)` 的切换物理机制不同 | 低 | 只能作为一个迁移生命周期批次处理。证明、文件切换、accounting 迁移可分文件，但 phase、锁、回滚和重启恢复必须由同一 owner 统筹 |
| 连接恢复与完整性 | `13144–13906`，约 763 行，另含根类型/Drop | per-path gate、active count、receipt、quick-check、orphan 检查、读写连接绑定；恢复不能删除/重建损坏库 | 中 | 是高收益边界，但必须连同 `ManagedIndexConnection`、Drop 和 receipt state 一起移动。不能只抽 `quick_check` 或只抽 gate |
| 业务库路由剩余部分 | 生产约 1,410 行，测试约 772 行 | bootstrap 的 initialized marker 是跨 SQLite/文件系统的提交点；journal 写入先于替换；导入事务内要重新核对 source/target proof，激活后还要复查 source | 中 | `open_store_at_address_with_hook` 保持完整。可把 exact namespace 查询和旧输入策略分成两个高内聚文件，但不能把最终事务复核拆走 |

### 3. 最容易被误拆的几个真实不变量

1. **同一快照**：dashboard 的 TEMP 表和多个查询必须在同一个连接/快照内；拆成查询服务会产生跨快照读到不同代次的风险。
2. **同一暂存 artifact**：`validated_staged_full_rebuild` 验证的 handle、seal、manifest 和 `import_staged_full_rebuild` 挂载的内容必须是同一份；重新打开或重新解析会破坏证明。
3. **发布原子性**：`finalize_generation`（约 8906–9154 及其调用链）在一个 IMMEDIATE 事务内完成 pending、canonical、标题/派生数据、revision、水位、certify 和 stage consumption。`publication.rs` 可以继续提供 SQL helper，但不能变成多个独立提交者。
4. **历史保全**：缺失原文时，账本保留 complete pending 数值并标记 unavailable；不能因“清理暂存”而删除旧账或把它变成零。
5. **连接析构**：关闭连接、等待 gate、写 receipt 和 active count 的先后顺序是完整性合同，不是普通资源清理。
6. **路由提交点**：全局 initialized marker 的写入不是 SQLite 事务的一部分；journal、fsync、替换、source recheck 和 marker 的顺序不能由抽象 service 自行重排。

## 三、终局架构建议

下面的行数是把现有两个主文件中的代码重新归位后的粗略范围，包含必要的显式契约/导入，**不是新增代码预算，也不是复杂度证明**。已有的 `schema.rs`、`session_catalog.rs`、`thread_metadata.rs`、`publication.rs`、`migration/proof.rs`、`stage_pool*.rs`、`representations.rs` 等继续存在，不为追求文件数量而合并。

### Exact 终局

```text
exact_usage_index.rs                 1,700–2,000  外观、根状态、open/sync/finalize 编排
exact_usage_index/connection.rs        950–1,250  ManagedIndexConnection、gate、receipt、recovery
exact_usage_index/contracts.rs         800–1,050  Exact 领域类型、source/checkpoint/stage 合同、共享摘要编码
exact_usage_index/read_model.rs      2,300–2,700  summary/dashboard 单快照读取、turn/excerpt 读取
exact_usage_index/projections.rs     1,500–1,900  dashboard aggregate repair、watermark、归因投影
exact_usage_index/ledger.rs            900–1,200  pending/ledger reconciliation、缺失源保全、canonical 入口
exact_usage_index/ingest.rs          3,500–4,000  discovery、authoritative scan、checkpoint、stage build/import
exact_usage_index/migration.rs       2,000–2,400  schema9/10、schema11 phase/switch、accounting migration 编排
exact_usage_index/recovery.rs          650–850  orphan/legacy path 选择和恢复桥接（不含 connection Drop）
```

这九个范围合计约 15,900 行，与当前 Exact 主文件数量同量级。`schema.rs`、目录、标题、发布和 proof 是已建立的专用子模块；它们通过窄的 `pub(super)` API 接入上述域，不再通过 `use super::*` 把主文件当全局命名空间。

根文件应继续保留：`ExactUsageIndex` 字段、`open_at` 外层锁顺序、`sync_with_scan_plan_mode_once` 的阶段顺序、`finalize_generation` 事务拥有权、公开 facade、测试 hook 的注册入口。根文件不应继续堆积所有 SQL，也不应引入“仓储/服务/事件总线”抽象。

### 业务库路由终局

```text
business_store_route.rs                         350–450  bootstrap、公开 facade、维护入口
business_store_route/import_coordinator.rs      550–700  journal/旧输入/快照/替换/激活完整协调器
business_store_route/exact_namespace.rs         350–450  Exact owner、注册、candidate、receipt 桥接
business_store_route/path_identity.rs              420  现有路径身份兼容，保持独立
business_store_route/admission.rs                  230  已完成的准入边界
inline/外部路由测试                                772  暂不为拆文件而移动
```

`open_store_at_address_with_hook` 约 321 行仍属于 `import_coordinator.rs` 的一个完整函数；`validate_pending_snapshot` 虽然名字像 predicate，但它可能按相同 source proof 重建 frozen backup，不能当纯函数拆到通用 validator。

### 不应拆的代码

- `open_at` 的外层顺序、锁和候选选择；只允许调用迁移/连接模块，不允许让子模块重新决定启动事务。
- `sync_with_scan_plan_mode_once`、`synchronize_event_enrichment` 的阶段编排；它们可以调用 ingest/projection helper，但不应被拆成互相不知道 completeness 的多个入口。
- `finalize_generation` 和其一次 IMMEDIATE 提交；`publication.rs` 保留为 SQL 应用 helper 即可。
- `ManagedIndexConnection`、`Drop`、integrity gate、receipt 状态；必须整体移动。
- `stage_pool` 的池状态、版本、锁、restore/reclaim；它不是普通暂存 parser，不能与 ingest 逻辑合并。
- route 的导入最终复核和 marker 提交点；不能以“策略对象”替代事务内 recheck。
- `business_store_container.rs` 与 `business_store_connection.rs` 的 namespace binding；本次没有必要重写容器层来追求没有循环依赖。

## 四、成体系的实施批次

每批都以现有候选 SHA 为基线，先做源码等价核对，再只在云端编译/测试。任何 SQL、schema、parser revision、事务类型、锁范围、连接数量或错误优先级变化，都停止该批并重新设计；不能把行为修复藏在“重构”提交里。

### 批次 A：连接与领域合同基础

**内容**：把 `ManagedIndexConnection`、integrity gate/receipt、quick-check/orphan 恢复和 Exact 领域 shared types 归位；清掉目标模块的 `use super::*`，改成显式、窄导入。与 `business_store_connection/exact.rs` 只定义既有 typed bridge，不重写绑定逻辑。

**不动**：open/sync 的外层顺序、迁移 phase、stage pool、数据库格式。

**保护**：先核对 Drop 时序和生产 `StoreConnection` 类型，再运行连接/receipt/gate/orphan 保护用例、两平台非 test 生产入口和已有完整性负控。只要出现额外 open、receipt 写入次数变化或绑定连接被转成普通 rusqlite，就退回该批。

### 批次 B：读模型、派生投影与账本边界

**内容**：整体移动 summary/dashboard 单快照读取到 `read_model.rs`；整体移动 dashboard aggregate repair、watermark、attribution 投影到 `projections.rs`；把 pending/ledger reconciliation 与 canonical 保全收拢到 `ledger.rs`。标题和发布模块保持其现有 API，不在本批重新拆。

**保护**：验证 TEMP snapshot 一致性、i64 overflow、固定时区/settled boundary、标题变化不使数值缓存失效、聚合 lag repair、缺失 source 的 pending 175 保全、canonical ledger publication rollback。此批可以做一次双平台完整 Rust/生产验证；不单独重跑四版本历史矩阵。

### 批次 C：扫描、checkpoint、暂存和回填

**内容**：把 source discovery、权威扫描、append checkpoint、empty-source lane、stage builder/validator/importer 和两个 event sink 一起收拢到 `ingest.rs`。`stage_pool` 保持独立，只通过现有 `Pool/Job/Seal` 合同访问。`ExactScanCompleteness`、源漂移诊断和 backfill 进度由根编排者传入/接收，不复制一份状态。

**保护**：验证活动文件追加、截断/中间重写/物理替换、未完成尾部重试、断点恢复、并行 stage worker 上限、同 artifact 导入、pending association 与 publication receipt 的时点、导入失败只回滚请求 namespace。此批需要双平台完整 Rust、16 个非 test 生产场景、现有备份负控和 0.9.8–0.9.11 历史接续矩阵；这些是 ingest 真实风险，不应由单元测试计数替代。

### 批次 D：迁移生命周期与路由恢复

**内容**：把 schema9/10 conversion、schema11 candidate/phase/switch/retention、accounting migration 归入 `migration.rs`；把 route 的 legacy journal/import coordinator 和 Exact namespace bridge 按上面的路由树归位。proof 模块继续只负责事实和比较，`migration.rs` 负责状态机；route 负责跨文件系统提交点。

**保护**：逐阶段检查 Prepared→Copied→Migrated→Validated→Switching→Switched→Retained 的持久化点；验证 production A clone/replace/seal 与 `cfg(test)` 文件改名路径仍分别执行；覆盖 candidate 内容损坏、same-count corruption、Validated 重启重验、schema9/10 append checkpoint、journal source/target recheck、旧 v1 receipts、缺失/unknown/stray WAL 拒绝，以及有效但物理 A 被替换的专用负控（当前证据尚未覆盖后者）。此批及最终候选再跑 Public097、四版本历史矩阵、双平台完整库和生产场景。

## 五、每批共同的验收和成本控制

1. **先固定边界**：记录提交 SHA、父子文件 hash、移动符号清单和 SQL/serde 字节级差异；只允许模块声明、显式导入、可见性和路径变化。
2. **先做结构验证，再做行为验证**：结构验证证明代码没有被机械改写；行为验证按批次选择真实风险。测试通过数不等于覆盖，跳过项、fixture、安装/UI 和性能矩阵必须分别记录。
3. **保留生产别名**：每个子模块继续使用 Exact 的 `Connection`/`Transaction` 类型别名；不可为消除生命周期错误而放宽到 `pub(crate)`、`use super::*` 或裸 rusqlite。
4. **不引入新状态**：不增加连接、不复制 owner/identity cache、不新增后台线程、不调整 stage worker 上限、不改变回填和发布的锁范围。
5. **回滚按源码提交**：若批次失败，回滚本批源码提交和工作树快照；不使用旧数据库覆盖新账，不删除候选、暂存或历史材料。
6. **最终一次收束**：A–D 通过后，在同一个最终 SHA 上跑一套完整双平台/生产/历史/Public097 验证并封存。不要因最终模块数量变化再开新的“反向审查”循环。

## 六、明确的当前未知与边界

本次是架构级逐块调查：已阅读两个主文件的生产流程、主要 SQL 调用边界、现有子模块入口和关键测试清单；没有声称逐字重审每条 SQL 表达式，也没有运行构建或访问正式数据库。当前证据仍有三个应在对应批次补齐的空白：

- route 还没有“当前有效但物理 A 文件被替换”的专用生产负控；
- production seal/namespace 路径与 `cfg(test)` 迁移切换路径必须继续分开验收；
- 没有新的全量性能矩阵，模块拆分本身不能被描述成速度优化。

这份计划的目标是把历史遗留的边界一次收束，减少未来重复搬运和重复门禁；它不能承诺绝对零 bug。真正的安全标准是每个批次都保留原有事务、锁、连接和兼容性合同，并在最终 SHA 上用真实生产入口和历史输入复核。
