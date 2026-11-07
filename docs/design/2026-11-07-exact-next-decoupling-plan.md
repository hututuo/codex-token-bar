# Exact剩余大模块：调查结果与下一批方案

日期：2026-11-07（Asia/Shanghai）。用户最初明确选择“继续调查剩余大模块的解耦，先做方案”。本文记录该轮调查和方案；当时没有修改产品、测试或工作流，没有启动构建、迁移数据库或准备安装包。随后获准实施的状态单列如下。

调查基线`fc5c51d6a68d2943adfcd58b50398a64c352cd92`，调查时产品为`ebcdf377`。上一批备份/proof/分区搬运/Exact连接扩展的状态见[已完成方案](2026-11-06-storage-decoupling-plan.md)和[最终执行报告](../maintenance/2026-11-07-storage-transfer-separation.md)。以下保留原调查基线的行号和方案边界。

实施状态更新：用户随后要求继续，三步均已完成。第一步结构初始化提交`b0f2b462`，详见[结构初始化执行记录](../maintenance/2026-11-07-exact-schema-separation.md)；第二步会话目录提交`f23411cc`，详见[会话目录执行记录](../maintenance/2026-11-07-session-catalog-separation.md)；第三步标题同步提交`de4c48ad`，详见[标题同步与整批收束记录](../maintenance/2026-11-07-thread-metadata-separation.md)。最终候选已完成双平台完整回归、非test生产入口、Public097及四版本接续验证。主文件净减少2527行至17,054行，本批已收束；后续迁移/发布/路由仍为规划。

## 建议先做什么

下一批限定为三步，按顺序独立提交和验收：

1. **Exact建表、兼容视图和触发器初始化**：两个函数共1520行，调用边界最集中，优先拆到`exact_usage_index/schema.rs`。
2. **会话目录索引**：约750行，把目录schema、文件观察、首行读取及目录发布归到`session_catalog.rs`，保留原调用入口及连接生命周期。
3. **会话标题同步**：约300行，把外部state读取结果到标题表的转换归到`thread_metadata.rs`，保持单独发布和整代事务内应用两种入口。

三步预计从主文件归位约2600行，减少约13%的集中代码。收益是schema变更、目录问题、标题问题各自有明确入口及测试归属；主文件仍有约1.7万行，深层循环依赖不会因此全部消失。不能仅以行数减少来宣布“完全解耦”。

迁移切换、暂存导入和整代发布是后续独立批次。本轮给出其真实边界及准入条件，避免下一次直接从中间切开。

## 调查范围和规模

下文`Exact`指`tauri-app/src-tauri/src/core/usage/token_count_jsonl/exact_usage_index.rs`；行号绑定本调查基线。行数含注释、空行和平台/cfg分支，用于界定搬迁范围，不是复杂度评分。

| 当前区域 | 位置/规模 | 调查结论 |
| --- | --- | --- |
| Exact主文件 | 19,581行 | 主体是生产流程和大段SQL；内嵌测试主要是钩子及末尾小模块，业务测试已大量在外部文件 |
| 当前/旧结构初始化 | 16211–17730，1520行 | 两个明确入口，适合先归位；不是随意重写成一个静态schema字符串 |
| 会话目录 | 方法2367–2500，134行；schema/辅助17731–18348，618行；另有类型 | 大体集中，但有一项跨旧库发现流程共用的文件检查不能一并私有化 |
| 标题同步 | 11941–12212，272行；另有类型、方法及时间规范化 | 已有stage/apply/publish分工，可保持调用时点抽出 |
| 暂存构建、恢复和导入 | 6247–8017，1771行；另有类型、事件sink及清理 | 连接、并发预算、同快照核验、pending及最终回收互相约束，不宜整段一次移动 |
| 整代发布 | 9091–9757，667行 | 内含pending SQL及约249行finalize；应保留单事务编排者 |
| schema11迁移证明 | 12602–13376，775行；另有事实类型 | 可作为后续只读核验子模块，但摘要和serde结构属于已有兼容合同 |
| schema11切换状态机 | 14116–14681，566行；另有收据、复制、转换和保留流程 | 并非这566行搬走就完成迁移解耦；生产和单测切换机制不同 |
| 路由 | `business_store_route.rs`2389行，其中测试从1618行开始 | 生产约1617行，集中包含启动准入、旧输入恢复、维护及分区定位，不应把全部2389行都算业务实现 |
| 合法旧账覆盖 | `business_store_recovery.rs`493行 | 已相对集中；本轮不再拆成更多小工具 |

本轮通读了拟先拆的目录/标题流程和schema的Rust编排，查看schema三段当前SQL和一段旧SQL的边界、摘要与依赖；没有逐条重新审计其中所有DDL。并复读了发布事务、迁移切换、旧物理清单选择、路由journal关键路径。其他扫描/聚合函数完成符号和调用定位，**没有声称逐行重审整个19,581行文件及其全部子模块**。

本地只读清单在`scratch/storage-next-plan-20261107/inventory.json`，由`inventory.mjs`生成，记录基线、范围及源码SHA256。Exact源码hash仍为`ea6a96260e3e2a33463efc7f5e7f66bc82e6ccc968aa9ed2fe3e5fec5f87e375`。尝试启动的辅助调查模型不可用，未产出审查意见；结论来自主会话直接源码阅读，不称为独立模型复审。

## 第一步：结构初始化模块

移动`initialize_index_schema`和`initialize_legacy_index_schema`两个函数，保留父模块原名称入口/导入。当前初始化函数的真实顺序是：

`ensure_source_observations → 基础表和兼容视图 → dashboard_buckets::install → 缺失列补齐 → 重建轮次视图 → 兼容写入触发器`。

这是包含条件升级的初始化流程，不只是建表常量。原始SQL、字符串内容、批次边界和执行顺序应逐字保留。第一次不把SQL再转存成外部文件，不合并批次，不顺手移除看似重复的DDL，也不新增版本。

新模块依赖限定为父模块的`Connection`别名、`ensure_source_observations`、`column_exists_checked`和现有`dashboard_buckets::install`。调用者继续决定什么时候调用及是否已处在事务内。函数不另开连接、不自行提交迁移事务。`open_at`、schema9/10候选转换、accounting迁移仍留在原位置，分别通过同一个入口初始化结构。

关键测试与验收：

- 复用`future_revision_is_rejected_before_quick_check_or_schema_writes`、`exact_index_refuses_unknown_future_schema_without_overwriting_it`，保证未来版本仍先拒绝。
- 复用`schema11_active_build_fences_current_writes_and_hides_stale_pending_rows`及现有schema9/10→11接续测试，核对兼容视图的写入对象和可见代次。
- 使用同一合成旧库比较拆分前后的`sqlite_master`、模块版本、表行值和sequence；只校验搬迁应保持的事实，不引入新迁移策略。
- 必须运行非test生产fixture及双平台构建。最终该步源码跑Public097与四版本形成状态矩阵，不能因SQL逐字相同便略过生产命名空间绑定。

该步风险中等、范围清楚。验收通过后即可独立交付，不必等待其余两步。

## 第二步：会话目录模块

目标是归位`session_catalog_files`的生命周期：初始化/版本校验、枚举来源、读取session_meta首行、比较观察值、提交目录和读取已发布快照。

移动内容包括`StoredSessionCatalogEntry`、`SessionCatalogObservation`，专用schema常量，`session_catalog_columns`、`validate_session_catalog_schema_version`、`initialize_session_catalog_schema`，以及`load_stored_session_catalog`到专用文件读取/发布钩子的相关实现。两项现有`ExactUsageIndex`公开方法保留薄入口，新模块内部接收原`ManagedIndexConnection`的借用；不移动Home操作锁，不改变连接Drop顺序，不新建目录writer。

边界要特别处理四处：

1. **共享文件检查**：`reject_session_catalog_reparse_point`还被`exact_legacy_recovery.rs:14`和旧输入发现`Exact:18507`使用。该函数先留在父模块供两边调用，不能移入目录模块后迫使旧库恢复依赖目录业务。
2. **共享列合同**：`SESSION_CATALOG_SCHEMA_COLUMNS`同时供`schema11_migration_digests`核对旧目录。归位后只有一个定义，向父模块提供最小可见性，不复制列清单。
3. **外层容错与锁**：`token_count_jsonl.rs:2383`仍负责全局目录构建锁、恢复期只读浏览、刷新失败回退旧快照。目录子模块不吞错误，也不把失败当作空目录。
4. **事务和完整性收据**：保留“先观察/读首行，再进入目录IMMEDIATE发布事务”的现有结构；dirty/eligible标记和发布前故障钩子保持原时点。失误会影响关连接时的完整性凭据，不能只看目录行数。

这一步不把目录观察复用为Token事实证明。目录用物理大小/mtime判定需要刷新，再在首行读取期间核对打开句柄及路径；会计扫描有自己的完整前缀和来源证明，两个合同不合并。

优先复用`core/session_management.rs`中的：`session_catalog_second_refresh_does_not_parse_unchanged_first_lines`、`session_catalog_only_parses_new_or_changed_metadata_and_reuses_append_metadata`、`session_catalog_tracks_archive_moves_and_deletions`、`session_catalog_reparses_truncation_and_physical_replacement`、`interrupted_session_catalog_publish_keeps_old_snapshot_and_retries`，以及压缩来源两项测试。再核对Exact中未来/未标记目录schema拒绝和v1→v2保行测试。

生产fixture的`published-recovery-reads`已验证恢复期目录来自已发布快照且不调用parser，但`catalogActionsVerified=false`明确表示没有执行会话删除等危险操作。该步只做目录职责归位，不把这一报告扩大成删除行为已验收。只有缺少与提取边界有关的反例时才加测试；不用新建一套目录测试框架。

## 第三步：标题同步模块

把`StagedThreadMetadata`、`ThreadMetadataStage`、`ThreadMetadataApplyOutcome`及11941–12212的函数放入`thread_metadata.rs`，连同专用标题fallback/时间规范化小工具。继续使用已有`external_state`模块只读访问state数据库，不另写读取器或缓存。

保持三种入口的区别：

| 入口 | 输入/输出 | 事务拥有者 |
| --- | --- | --- |
| stage | Home、既有来源签名 → Unchanged/Failed/Updated | 只读外部来源，不发布目标数据 |
| apply | 已准备数据及调用者的`&Transaction` → 内容/签名是否变化 | 调用者；被整代finalize使用，子模块不能commit |
| metadata-only publish | 原可写连接及stage → revision | 保留原独立IMMEDIATE事务；不能被finalize路径调用来嵌套事务 |

必须保留：必需字段缺失或读取失败时保留原标题及签名；合法空结果按原语义处理；只有内容变化才推进相关revision；仅标题变化不能使数值缓存失效。Windows目前按真实行内容和物理身份生成来源token，macOS可用持有只读连接的快照机制，两者保持。

复用`p1_4_failed_thread_metadata_staging_keeps_published_rows_and_signature`、`thread_metadata_single_row_update_does_not_rewrite_unchanged_rows`、`thread_metadata_signature_only_change_does_not_advance_revision`、`thread_metadata_complete_stage_adds_and_removes_only_changed_rows`、`thread_metadata_preserves_formal_title_and_bounds_unicode_fallbacks`，以及`dashboard_snapshot_reuses_numeric_cache_after_thread_metadata_changes`。`runtime_recovery`中的旧可选列、缺必需列和WAL-only提交测试/生产场景需保持实际执行。

Summary和Full路径调用标题同步的时点以当前可执行代码为准。不能在搬迁时根据零散注释顺手改变Summary行为、来源token或缓存失效规则。

## 迁移、发布和路由：后续怎样拆

这些部分存在可划分的职责，但本轮证据尚不足以建议一次性实施全部拆分。

### schema11：先把证明和协议边界列清楚

迁移实际阶段为`Prepared → Copied → Migrated → Validated → Switching → Switched`；成功普通扫描后才由保留流程标记`Retained`。`Validated`跨进程恢复必须重做候选验证，持久化phase不能当成本次打开已经生成的内存证明。

`Schema11CandidateManifest`、`SourceReceipt`和`MigrationFacts`存在序列化字段/默认值；`protected_tables`的覆盖判定允许新证明包含旧合同没有登记的新增受保护表，同时要求旧登记表摘要保持。不能简化为对象全等或只比较行数。

后续优先候选是约775行的`schema11_*facts/digests`，连同事实类型成为`migration/proof.rs`；保留输入连接和schema版本、逐字段编码与排序，快照由调用者拥有。它仍须读取目录列合同和ledger受保护表摘要，不能套用普通Container proof，也不能为“通用化”更换摘要格式。

状态机与平台切换再单独处理。生产`schema11_finish_candidate_switch`通过路由克隆回滚分区、替换活动分区、seal/校验和移除候选；`cfg(test)`分支则对独立物理SQLite及sidecar改名。二者测试不能互相代替。旧物理清单解析器`exact_legacy_recovery`只选择已提交main，只有明确Switching且main缺失时才选择rollback；它不继续旧writer、不导入candidate，和A中的新迁移编排保持不同职责。

开始迁移状态机拆分前，还须针对每个入口补齐：调用时持有的Home/文件/路径锁、当前phase、磁盘与A中的事实、下一次持久化点、每个返回后的连接是否关闭。现有`exact_index_schema11_switch_interruptions_resume_without_jsonl_reparse`等是基础，不代表任意DDL中断都已覆盖。

### 整代发布：保留一个事务拥有者

现在`finalize_generation`的核心链如下，全部处在同一个IMMEDIATE事务内；图中“旧代已被替换”的早退分支省略，实施时必须保持。

```mermaid
flowchart LR
    A[核对building代次] --> B[保留缺失来源旧账及canonical]
    B --> C[标题与派生数据/归因]
    C --> D[发布pending及数值代次]
    D --> E[更新revision与聚合水位]
    E --> F[清building标记并certify]
    F --> G[写暂存消费回执]
    G --> H[一次commit]
```

以后若要拆，可先把`publish_schema11_pending_generation`及紧邻的tombstone处理作为接收`&Transaction`的SQL应用模块，finalize仍拥有begin/commit和顺序。不能把667行整体切成各自自开事务的“事件服务、聚合服务、回执服务”。Summary/Full模式、已有聚合水位落后和缺失pending保全必须继续一起测试。

暂存导入同样不宜并入最终发布模块。它验证并挂载同一不可变恢复快照，在单来源事务里写pending及关联；最终发布才写消费回执，之后才可回收。`stage_pool`仍拥有池状态/版本/锁，`StoreConnection::exact`仍提供同A的受限桥接。后续新模块不能为了类型方便再恢复一次stage、另开writer或提前消费。

### 路由：先分准入，后分旧输入策略

后续可以调查`business_store_route/admission.rs`：归位初始化marker、运行时ready/readable和活动A物理身份复核，让Exact桥接依赖准入合同。它必须保留同一个`ACTIVE_CONTAINER_IDENTITY`状态和每次动态检查；不能换成缓存的`bool ready`，不能让已绑定连接绕过owner/根版本复核。

`open_store_at_address_with_hook`约321行的导入编排暂时保持：先验证/保留快照和历史，再写journal，导入时在写事务内复核来源与目标，最后复查来源并按初始化状态完成激活。新来源持续追加、目标新增独有账和旧v1路径清单是不同事实，不能统一成一个“文件变了就重来”的分支。

若再分策略，先定义只读判定输出，明确它只描述候选和预期proof，不能自行授权覆盖；执行器仍在原事务内重新核对。当前`validate_pending_snapshot`还可能从相同proof来源重建备份，不能因函数名有validate就错误地当作纯函数。

## 每一步的约束与完成标准

- 延续项目云端构建要求，本机只读检查和编辑。每步一个产品提交，先固定差异，再以该SHA编译/测试，保留失败、跳过和重试原因。
- 直接比较搬迁前后的完整函数/SQL/父模块，而非只查“原代码片段还在”。保留错误优先级、事务种类、连接和锁的生命周期。
- 从父文件移动代码后，`super::`的含义和`pub(super)`的可见范围都会变化；逐项列出导入和调用方。外层公开方法优先保留薄入口，不能批量升成`pub(crate)`或`use super::*`来掩盖依赖问题。
- 新模块必须继续使用父模块的`Connection`/`Transaction`别名：生产是绑定分区的StoreConnection，单测才是普通rusqlite。直接在子模块导入普通rusqlite连接会绕过生产绑定，是明确禁止的替换。
- 先复用实际业务测试，再补真实缺口；测试计数不是覆盖率。普通库测试、非test生产fixture、历史producer和安装运行分开记录。
- 第一步结构初始化及第二步目录schema的最终提交须有当前Public097和四版本双平台接续证据。标题同步至少有双平台当前生产入口/旧state读取场景。最终三步统一到同一候选后再封存历史链结果。
- 若搬迁需要改SQL、数据格式、线程/事务模型，停在该步重新评估；不能将行为修复藏在结构提交里。新模块不增加已打开数据库数量、每次刷新复核次数或持锁范围。
- 完成三步即结束这一批。迁移/发布/路由不自动加入；以后各自先完成剩余调查再开独立方案。回退只回退源码提交，不能用旧整库覆盖新增账。

调查时建议先执行第一步`schema.rs`，因为它能归位最大的集中片段，接口也最少。现三步已按顺序实施，并在最终候选统一验证；这里的调查与实施没有发现并复现新的数据错误，不把“存在相互依赖”写成兼容性故障。进一步迁移/发布/路由改造仍须按上述边界另行完成调查和方案，不自动并入已收束的三步。
