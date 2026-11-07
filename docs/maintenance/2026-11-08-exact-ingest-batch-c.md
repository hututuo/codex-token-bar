# Exact 拆分批次 C：扫描、checkpoint、暂存与回填

按[总计划](../design/2026-11-07-storage-global-decomposition-master-plan.md)执行批次 C。固定基线为批次 B 封存提交 `fa93f4452715900c6ace85e208cd088cbed8d6a5`，工作树 `f97f/codex-token-dashboard`，分支 `codex/storage-responsibility-split-20261106`。本批仅重新归属实现和显式依赖，不改变 SQL、数据库/暂存格式、解析器版本、回填算法、并行上限或迁移状态机；批次 D 尚未实施。

## 实现边界

| 文件 | 本批职责 | 行数 |
| --- | --- | ---: |
| `exact_usage_index/ingest.rs` | 权威扫描、独立 append 事务和 checkpoint；两个独立 EventSink；stage 构建、验证、导入、回收请求；来源字节复核和 enrichment 候选选择 | 3,741 |
| `exact_usage_index/sources.rs` | 候选发现、已发布只读探针、扫描目录队列、路径边界三态、物理/逻辑文件观察；保留原 writer 的 TEMP 状态 | 1,233 |
| `exact_usage_index.rs` | 根状态、Home/连接租约、open、同步/回填阶段顺序、begin/resume generation、最终发布事务和迁移生命周期 | 10,505 → 5,695 |

将来源观察单独归位是为了让读模型、目录、表示层、导入和迁移使用同一套原有 I/O 合同，而不依赖 stage worker 或把逻辑长度计算伪装成纯工具。`sources.rs` 明确不是纯读取层：writer 遍历会维护 TEMP 队列、抑制误判缺失，观察记录 helper 会写调用者连接。

已有 `empty_sources.rs` 的新空源专用事务、`runtime_recovery.rs`、`stage_pool.rs`、池 backup/codec/receipt 子模块继续保留。空源 lane 的函数体与类型不变，仅改为显式导入 ingest 的预留入口和 sources 的观察入口。read_model、ledger、representations、message_links、session_catalog、schema、runtime_recovery 同样只调整 imports。原测试模块与测试名称不移动。

## 暂存同一性与发布时点

1. `build_staged_full_rebuild` 继续从 worker 实际打开的源句柄确定普通扫描边界；discovery 仅为候选提示。enrichment 对已发布前缀的例外仍原样保留。生产 builder 使用原 unbound scratch/TEMP/deferred 事务，单测使用原物理 SQLite/IMMEDIATE 路径；不把它们强行统一。
2. pool 导入仍只恢复一次：`import_staged_full_rebuild` 打开 stage → 将同一句柄传给 `validated_staged_full_rebuild` → 比较 artifact ID、大小与 seal 身份 → 将该 stage 的 `unbound_connection()` 挂载。没有改为重新恢复/重新解码另一份快照。原 fixture 的 restore-count 检查不变。legacy/test 原有 attach 分支分别保留，不声称它们与 pool 的物理机制相同。
3. 导入仍在原 IMMEDIATE 事务内验证 source ID、snapshot pending、对账、写 checkpoint/投影并登记 `mark_exact_stage_pending` 或 legacy pending 关联；不写消费回执。导入结果优先于 detach 错误的规则保留。
4. 根 `finalize_generation` 仍是唯一最终发布者，保留 `canonical::certify` → `consume_exact_stage_generation` → commit 的顺序。pool 消费状态与 consumption receipt 同属这个提交；没有提前移入单文件导入。
5. 主流程单文件导入后原本就调用 `remove_staging_database_storage`。生产池回收检查匹配的已提交回执且仅接受 consumed 状态；早期调用可能取得池句柄并开启短事务，但不删除 payload。legacy namespace 留给有界回执 sweeper。发布后原 `remove_staging_directory` 再触发有界回收；单测的物理删除仍是原路径。

## 扫描、断点与误导命名复核

| 入口 | 保留的真实行为和注释 |
| --- | --- |
| `SqliteEventSink` | 在调用者 append 事务中写索引事件，并登记账本 binding/compaction correction |
| `StagingEventSink` | 只写 private stage 的事件和指纹，compaction 修正限于该暂存事件集；不承担最终账本 binding，不与前者合并 |
| `append_session_file` | 原自有 IMMEDIATE 事务；仅 `checkpoint.generation != generation` 时复制 checkpoint。事务开始后的早退 `Ok(false)` 继续依赖 Drop 回滚复制/部分解析结果。成功分支仍在 checkpoint、chunks、数值投影和 dirty marker 写完后唯一 commit |
| `process_session_file` | 用实际打开源的身份和已持久化 checkpoint 判断复用、元数据变化、追加或全量重建。NotFound、不可读、越界/不完整区分保持；discovery 旧签名不限制新增尾部 |
| `reserve_staging_source` | 可能把唯一且已缺失的同 session 来源重绑到归档路径，插入 generation-0 来源或补 session ID；是可写身份操作，不是纯分配 |
| `validated_staged_full_rebuild` | 会检查 manifest、checkpoint、codec、seal 和源字节；调用的 `staged_store_signature` 对旧 namespace 可能执行 seal，不是纯 predicate |
| `staged_store_signature` | pool 路径读取现有 seal；legacy observation 缺失可补 seal。不能替代物理 stat |
| `revalidate_metadata_only_file` | “metadata-only”描述被接受的变化；实际读取内容块，核对句柄/路径身份，再在自有 IMMEDIATE 事务中提交观察值。数值 revision/缓存语义保持 |
| `validate_building_generation_commit_scope` | 确认原文缺失时会开启单来源 IMMEDIATE 事务，保全完整 pending 并标记 unavailable；其余分支读块和压缩终点。仍在原最终发布之前，不变成第二个 publisher |
| `restartable_private_stage` / `superseded_compaction_private_stage` | effectful open 可以恢复池影像或准入旧 namespace，旧 parser 分支还会读原文。归 stage 生命周期，不进入只读工具层 |
| `file_signature` / `file_signature_from_handle` | 打开 rollout reader、读取物理身份并求逻辑长度；压缩源不是纯 stat。保留之前注释，并在新模块和 handle helper 明确说明 |
| `lightweight_file_signature` | 前后打开物理句柄核对身份，可查询缓存逻辑长度；未知长度保留未知，不以文件大小冒充逻辑长度 |
| `sources_changed` / `visit_session_files` / `prepare_scan_temp_tables` | 使用原根连接的 TEMP 队列和 snapshot，维护 completeness 并保全不可读目录下旧来源；不另开扫描服务连接 |

`ManagedIndexConnection::Drop`、per-path gate、完整性 receipt、生产 `StoreConnection` / `StoreTransaction` 类型绑定、根状态字段顺序和 Home 租约保持。测试 hooks/counters 留在根层，子模块引用同一份状态；没有新增状态、后台任务或额外 worker。

## 移动等价与导入检查

证据目录为 `scratch/exact-ingest-c-20261108/`。

- `extract.mjs --verify` 从固定基线完整重建 11 个新/变动 Rust 文件，仅允许模块/显式 imports、保持原域范围的可见性以及函数体外注释变化；其余 212 个既有 Rust 源文件逐字不变，包含 pool 和生产 namespace/receipt 实现。
- 独立词法核对 `verify-bodies.mjs` 比较 **359 个函数体、1,918 个业务字符串/SQL/格式字面量**，全部字节一致。数字指这 11 个文件的范围，不是整个仓库函数数。
- 内存副本故意改挂载句柄、改 checkpoint 代次复制条件、把 pending 登记变成提前 consumption、改 SQL，四种变异均被拒绝。它们是静态校验器负控，和云端运行时负控分开记录。
- 11 个文件通过 rustfmt stdout 语法解析，未改写源码。检查 root 内 23 个剩余跨模块依赖；新模块的 37 个私有自由函数没有域外调用；普通/test/fixture 的 cfg、原父级 `super::` 路径和历史 archive 注入入口均做源码检查。
- discovery 外部可见类型/字段保持原 `token_count_jsonl` 范围；仅根编排使用的候选路径/签名和边界字段开放到 Exact 域。sink、durability handle 和目录签名内部类型仍私有。

不运行本地 Cargo、SwiftPM、Xcode 或前端构建；不为机械移动改写已有测试或门禁。

## 云端验收

待固定源码的双平台完整 Rust、两端各 16 个非 test 生产场景、备份清理负控及 0.9.8–0.9.11 × macOS/Windows 历史接续矩阵完成后封存。静态核对通过不表示运行验收已经通过。

本批不运行 Public097 或全量性能矩阵，不宣称安装/UI 或正式用户数据验收。未访问正式数据库、安装、合并主线或发布。原有 Windows 报告与未跟踪材料保留，报告 SHA256 为 `63801116c53adee10cb0692cdad6553e6187906f7659ae0aea67b69d4f24ecef`。
