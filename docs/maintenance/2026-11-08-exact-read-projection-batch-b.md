# Exact 拆分批次 B：读模型、派生投影与账本边界

按[总计划](../design/2026-11-07-storage-global-decomposition-master-plan.md)执行批次 B。基线为批次 A 封存提交 `8bfaa5c7602df5b09fbe86669468a119a83cd88c`；工作树 `f97f/codex-token-dashboard`，分支 `codex/storage-responsibility-split-20261106`。本批不推进 C/D，不调整数据库格式、SQL、版本、缓存策略或性能算法。

## 职责归位

| 文件 | 本批职责 | 行数 |
| --- | --- | ---: |
| `exact_usage_index/read_model.rs` | summary、dashboard 完整快照与统计/趋势/排行/摘录；已发布 turn 请求分页；仅此域使用的汇总与时间格式辅助 | 2,106 |
| `exact_usage_index/projections.rs` | 数值聚合身份、独立修复、显示水位、按文件/代次聚合维护、归因安全状态与投影 | 1,629 |
| `exact_usage_index/ledger.rs` | 原有 pending 对账与保全；补入暂存与已发布事件核对、墓碑兼容入口、缺失 enrichment 来源保全入口 | 502 → 693 |
| `exact_usage_index/store_metadata.rs` | 补入借用现有连接的启动 metadata 解码，不打开连接、不拥有事务 | 141 → 179 |
| `exact_usage_index/contracts.rs` | 补入共享时间间隔和纯整数转换，不执行 I/O | 399 → 414 |
| `exact_usage_index.rs` | 保留状态、连接寿命、open/sync/finalize、扫描暂存与迁移编排 | 14,321 → 10,505 |

已有 `ledger/pending_preservation.rs`、`ledger/missing_source.rs` 和 `canonical.rs` 继续保留专用边界。没有为了凑行数重复搬动；`ledger.rs` 集中对账和缺失源入口，canonical 仍通过原调用链参与最终发布。`message_links`、`empty_sources`、`representations`、`canonical` 改为直接导入各自实际使用的投影/合同 helper。

## 快照、写入与误导命名的逐项复核

| 入口 | 实际副作用和本批归属 |
| --- | --- |
| `dashboard_data_at` / `prepare_dashboard_event_snapshot` | 前者仍在 `self.connection` 开一个 deferred snapshot；后者在同一连接创建 TEMP selector、表和视图。全部统计、趋势、排行、摘录到原 commit 为止共用该快照。TEMP 准备不是纯查询，模块与方法注释明确禁止另开连接或另行提交 |
| `turn_candidates` / `representations::verify_excerpt_source` | 摘录可在当前连接、当前 snapshot 内通过 savepoint 写物理证明和 availability；published-read-only 分支仍跳过这一步。保留既有实现与前批注释，不把它归为无副作用工具 |
| `summary_at` | autocommit 时拥有 deferred snapshot，否则借用调用者事务；重新读取文件身份，原 `i64::checked_add` 溢出报错保持。与可复用贡献缓存入口分开 |
| `summary_with_file_contributions` | 保留原独立 snapshot、调用者贡献 map、generation 复用条件和原饱和折叠。没有为了统一方法而改写成 `summary_at` 的另一套语义 |
| `read_cache_turn_requests` | 保留仅已注册、已发布只读 open，以及原 anchor/target/page 同快照；没有改用可恢复/导入的通用 open |
| `ensure_dashboard_aggregates` | 明确为可写修复入口，保留原独立 IMMEDIATE 事务、identity 命中无写锁快路径、必要计数/进度通知及自检；不塞入 dashboard 的读取 snapshot |
| `mark_dashboard_aggregate_published` | 独立 IMMEDIATE 事务推进显示 generation/settled watermark，和数值修复/Exact 最终发布分别归属 |
| `mark_dashboard_changed` | 借用调用者事务写 generic/numeric dirty flags。标题专用路径继续使用既有 generic revision，不使数值缓存失效 |
| `synchronize_attribution_ledger` | 借用原发布事务写归因行、epoch 和 canonical legacy floors；不自行开启第二次提交，历史归因证据不是可随意重建的数值桶 |
| `staged_enrichment_matches_published_events` | 名为比较，实际上会 attach/mount 暂存、查询、detach；归到账本核对，保持比较错误优先于 detach 错误的规则 |
| `verify_pending_import` | 借用导入事务，使用 TEMP 对账对象；失败由导入者回滚，不从另一个快照判定后清空 pending |
| `record_missing_event_enrichment_source` | 保留单来源 IMMEDIATE 事务，先保全完整 pending 为 unavailable；只有没有存活 pending 历史的目标才进入原空墓碑分支。缺失原文不清零旧账，不扫描清理其他来源 |
| `prune_published_tombstone_versions` | 历史清理名，实际上有意不删 schema11 tombstone 和 generation-0 reservation；原 no-op 不变，注释解释保全理由 |
| `peek_startup_identity` | 保留根启动层。虽然函数体中的旧说明称只读，生产仍可能经 `open_read_only_index` 进入旧库 admission；新增函数注释说明既有差异，没有在本批顺手改变恢复行为 |
| `sources_changed` | 会准备 TEMP observations 并遍历来源，保留根扫描层，不能按 predicate 名字放入只读模型 |

`ExactUsageIndex` 字段与次序、managed connection、Home 租约、per-path gate、完整性收据和生产 `StoreConnection` / `StoreTransaction` 绑定不变。`connection.rs` 全文件未动。`finalize_generation` 继续独占原 IMMEDIATE 发布事务，ledger、canonical、归因、pending、revision/水位和 stage-consumption receipts 的顺序及唯一 commit 不变。

移动后的方法仍实现同一个 `ExactUsageIndex`；原父域可见方法在子模块用 `pub(in super::super)` 保留原调用范围，不增加全 crate 的公开 API。根路径只保留显式导入/转出；原函数体中的 `super::accounting`、`super::update_precise_dashboard_progress` 通过根层明确别名绑定原实现，没有新增转调函数。

## 静态等价核对

本地只做源码检查，没有启动本地 Cargo/SwiftPM/Xcode/前端构建。对 normal、test 和 business-store-fixture 的导入与调用点进行源码检查，21 个读模型私有方法没有域外调用；词法检查不替代云端类型检查。

- `extract.mjs --verify`：从固定基线重建全部 10 个新/变动 Rust 文件，只允许 imports、可见性和函数体外注释变化；其余 211 个既有 Rust 源文件逐字未变。
- 独立 `verify-bodies.mjs`：397 个函数体、1,905 个业务字符串/SQL/格式字面量逐字保持；只排除新增 import 的 cfg 属性，不排除函数体或 SQL。
- 内存副本中的三种变异——更换 snapshot 开始方法、把 checked 加法换成饱和加法、改动 SQL——均被拒绝。这是静态核对器负控，不冒充运行时故障注入。
- 10 个文件通过 rustfmt stdout 语法解析，不输出改写后的源码；`git diff --check` 通过。

证据保存在 `scratch/exact-read-projection-b-20261108/` 的重建脚本、`equivalence.json`、独立词法脚本和 `body-equivalence.json`。既有测试函数身份与测试源码不变，不新增照抄实现的测试。

## 云端验收

待本次固定源码的双平台完整 Rust 和非 test 生产场景运行完成后填写。此时静态核对已经通过，但不表示云端编译和运行验收已经通过。

按本批计划不单独重跑四版本历史矩阵或 Public097，不宣称性能、已安装应用或正式数据库实测。未访问正式数据库、安装、合并主线或发布。用户原 Windows 报告及未跟踪资料保持原状；原报告 SHA256 为 `63801116c53adee10cb0692cdad6553e6187906f7659ae0aea67b69d4f24ecef`。
