# Swift / Tauri 双端精确索引字段契约

状态：当前代码审计版

审计日期：2026-08-16

契约编号：`dual-index-logical-contract-v1`

## 这份契约解决什么问题

Swift 和 Tauri **不需要互相打开、互相写入或互相识别对方的 SQLite 文件**。
两端各自拥有一套物理索引，但都读取同一类 Codex 源文件。

这份契约的目标是避免以后修改扫描器、索引迁移或聚合逻辑时出现以下错误：

- Swift 增加了字段，Tauri 忘记处理；
- 两端都叫 `timestamp`，但单位或精度不同；
- 一端把“总 Token”写进 `tokens`，另一端把它当作输出 Token；
- 一端把未知模型写成 `0`，另一端写成 `unknown`；
- 新增字段时没有声明默认值、回填策略或缺失语义；
- 只迁移主表，遗漏归因表、分块表、临时 staging 表或会话目录。

契约描述的是**逻辑字段和两端物理字段之间的对应关系**，不是要求两端 SQLite 表同构。

## 1. 当前版本和所有权

| 项目 | Swift | Tauri | 说明 |
|---|---|---|---|
| 主精确索引 schema | `5` | `8` | 两套物理格式，不能互换 |
| 当前支持的旧版本 | `2–5` 原位迁移 | `6–8` 原位迁移 | 只要求旧索引升级到同端新版本 |
| 主元数据表 | `schema_meta` | `metadata` | 键名和诊断标记不完全相同 |
| 会话目录 schema | `1` | `1` | 表结构仍不相同 |
| 主解析/replay revision | `token-event-v2-explicit-subagent-delayed-context-v3`（快照兼容标识） | `explicit-subagent-delayed-context-v3` | 语义应保持一致，物理 marker 名称可不同 |
| 主索引文件表 | `sources` | `files` | 生命周期模型不同 |
| 主事件表 | `events` | `events` | 表名相同，主键和字段不相同 |

对应实现：

- Swift schema 和迁移：[CodexUsageHistoryIndex.swift](</Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard/Sources/CodexTokenBar/CodexUsageHistoryIndex.swift:290>)
- Tauri schema 和迁移：[exact_usage_index.rs](</Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard/tauri-app/src-tauri/src/core/usage/token_count_jsonl/exact_usage_index.rs:51>)

## 2. 逻辑实体总览

两端都必须围绕下面这些逻辑实体工作：

1. `source_file`：一个 JSONL/rollout 源文件及其增量扫描状态；
2. `token_event`：源文件中的一个 Token 快照事件；
3. `source_fingerprint`：源文件中用于去重的指纹；
4. `source_chunk`：源文件分块哈希和增量校验信息；
5. `attribution_bucket`：固定时间桶中的来源归因汇总；
6. `session_catalog_entry`：项目/会话目录元数据；
7. `index_state`：schema、parser、generation、provenance 和安全状态。

下文中的“对应”指逻辑语义对应；如果一端没有物理字段，必须明确写成“缺失/端专属”，不能用零值伪造。

## 3. 主索引 `source_file` 字段契约

Swift 的主表是 `sources`，Tauri 的主表是 `files`。

| 逻辑字段 | Swift `sources` | Tauri `files` | 对应规则 |
|---|---|---|---|
| 源文件身份 | `source_id INTEGER PRIMARY KEY` | `(generation INTEGER, path TEXT)` 主键 | 不同身份模型；跨端只比较规范化 `path` 和 source lineage，不直接复制 ID |
| 文件路径 | `path TEXT NOT NULL UNIQUE` | `path TEXT NOT NULL` | 规范化绝对路径；Tauri 允许同一路径保留多个 generation |
| session ID | `session_id TEXT NOT NULL` | `session_id TEXT NOT NULL` | 逻辑一致；均来自源文件会话身份 |
| 文件大小 | `size_bytes INTEGER NOT NULL` | `size INTEGER NOT NULL` | 字节数；名称不同，单位必须保持 byte |
| 修改时间 | `modified_at REAL NOT NULL` | `modified_ns TEXT NOT NULL` | 都表示文件修改时间；Swift 为秒数，可带小数；Tauri 为十进制纳秒文本 |
| 内容探针 | `content_probe TEXT NOT NULL` | `prefix_sha256 BLOB NOT NULL` | 都用于快速判断内容变化；算法/编码不可假设相同 |
| 设备身份 | `device_id TEXT NOT NULL` | `device_id TEXT NOT NULL` | 逻辑一致 |
| inode/file ID | `inode TEXT NOT NULL` | `file_id TEXT NOT NULL` | 逻辑一致；名称不同 |
| 文件状态变化时间 | `status_changed_seconds INTEGER` + `status_changed_nanoseconds INTEGER` | `changed_ns TEXT` | 都是 stat/change 时间；Tauri 合并成纳秒文本 |
| 当前发布/扫描代次 | `last_seen_generation TEXT NOT NULL` | `generation INTEGER` + `published_generation` metadata | Tauri 用文件 generation 和全局 published generation；不能直接当成同一个整数 |
| 追加可用 | `append_ready INTEGER NOT NULL DEFAULT 0` | `append_ready INTEGER NOT NULL DEFAULT 0` | 逻辑一致，0/1 语义一致 |
| 恢复偏移 | `resume_offset INTEGER` | `resume_offset INTEGER` | 源文件字节偏移；必须使用同一字节坐标，不是 Token 数 |
| 上次总 Token | `previous_total_tokens INTEGER` | `previous_total_tokens INTEGER` | 逻辑一致 |
| fork replay 起点 | `fork_replay_started_at REAL` | `fork_replay_started_ns TEXT` | 同一语义；秒数和纳秒文本不同 |
| 正在跳过 fork replay | `is_skipping_fork_replay INTEGER NOT NULL DEFAULT 0` | `fork_replay_active INTEGER NOT NULL DEFAULT 0` | 逻辑一致，命名方向相反：Swift 是“skipping”，Tauri 是“active” |
| 明确 fork 文件 | `is_explicit_subagent_fork INTEGER NOT NULL DEFAULT 0` | `is_explicit_subagent_fork INTEGER NOT NULL DEFAULT 0` | 一致 |
| 上次跳过 replay 的 Token 时间 | `last_skipped_fork_replay_token_at REAL` | `last_skipped_fork_replay_token_ns TEXT` | 同一语义，不同单位 |
| 当前用户 prompt 起点 | `current_user_prompt_offset INTEGER` | `current_user_prompt_start INTEGER` | 同一语义；Tauri 还保存 end |
| 当前用户 prompt 终点 | 缺失 | `current_user_prompt_end INTEGER` | Tauri 端专属；Swift 当前只需起点 |
| assistant 起点 | `assistant_start_offset INTEGER` | `assistant_response_start INTEGER` | 同一语义，名称不同 |
| assistant 终点 | 缺失 | `assistant_response_end INTEGER` | Tauri 端专属 |
| 当前模型 | `current_model TEXT` | `current_model TEXT` | 一致；空值表示无法从当前上下文确认 |
| 审计分块索引 | `audit_chunk_index INTEGER NOT NULL DEFAULT 0` | `audit_chunk_index INTEGER NOT NULL DEFAULT 0` | 一致 |
| 删除标记 | 缺失 | `deleted INTEGER NOT NULL` | Tauri generation/tombstone 机制专属；Swift 通过删除 source 行处理 |
| 文件代次主键 | 缺失 | `generation INTEGER` | Tauri 端专属，不能映射成 Swift `source_id` |

### 主表写入规则

- 新增逻辑字段时，先在本表登记 Swift 和 Tauri 的物理字段、类型、默认值和缺失语义。
- 如果只在一端需要，必须明确标记“端专属”，不能在另一端增加一个没有实际语义的占位列。
- 任何时间字段必须同时写明单位：秒、毫秒、微秒或纳秒。
- `0` 只能表示确实为零；未知、未采集、无法证明必须使用 `NULL` 或独立状态位。

## 4. `token_event` 事件字段契约

Swift 和 Tauri 都有名为 `events` 的表，但不是同一套主键模型。

| 逻辑字段 | Swift `events` | Tauri `events` | 对应规则 |
|---|---|---|---|
| 事件身份 | `(source_id, source_offset)` | `id` + `(file_generation, file_path, ordinal)` 唯一约束 | 跨端只比较规范化 source path、ordinal/offset 和时间；不得复制 ID |
| 来源文件 | `source_id` 外键 | `file_generation` + `file_path` 外键 | 都必须能回到 source_file |
| 源内顺序 | `source_offset INTEGER` | `ordinal INTEGER` | 都是源文件顺序；如果 parser 以字节偏移为准，必须保留字节语义 |
| 时间 | `timestamp REAL NOT NULL` | `timestamp INTEGER NOT NULL` | 都是 Unix 秒；Swift 可保留小数，Tauri 当前按整数秒保存 |
| 总 Token | `tokens INTEGER NOT NULL` | `tokens INTEGER NOT NULL` | 逻辑一致：该事件的总 Token |
| input Token | `input_tokens INTEGER NOT NULL` | `input_tokens INTEGER NOT NULL` | 一致 |
| cached input Token | `cached_input_tokens INTEGER NOT NULL` | `cached_input_tokens INTEGER NOT NULL` | 一致 |
| output Token | `output_tokens INTEGER NOT NULL` | `output_tokens INTEGER NOT NULL` | 一致 |
| reasoning output Token | `reasoning_output_tokens INTEGER NOT NULL` | **当前缺失** | 这是当前双端最重要的结构缺口；若未来计价/统计使用，Tauri 必须新增列并迁移 |
| 模型 | `model TEXT` | `model TEXT` | 一致；未知模型使用 `NULL`，不能写成零金额模型 |
| 用户 prompt 起点 | `user_prompt_offset INTEGER` | `user_prompt_start INTEGER` | 同一语义 |
| 用户 prompt 终点 | 缺失 | `user_prompt_end INTEGER` | Tauri 端专属 |
| assistant 起点 | `assistant_start_offset INTEGER` | `assistant_response_start INTEGER` | 同一语义 |
| assistant 终点 | 缺失 | `assistant_response_end INTEGER` | Tauri 端专属 |
| session ID | 通过 `sources.session_id` 关联 | 直接存储 `session_id TEXT NOT NULL` | 逻辑一致，物理冗余策略不同 |

Swift 事件表定义见：[CodexUsageHistoryIndex.swift](</Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard/Sources/CodexTokenBar/CodexUsageHistoryIndex.swift:1477>)；Tauri 事件表定义见：[exact_usage_index.rs](</Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard/tauri-app/src-tauri/src/core/usage/token_count_jsonl/exact_usage_index.rs:6659>)。

### 事件的硬性不变量

- `tokens` 是总 Token，不等于 output Token。
- `cached_input_tokens <= input_tokens`，除非明确标记数据损坏。
- `timestamp` 统一先转成逻辑 Unix 秒再做 5 分钟分桶；不能直接混用 SQLite 原始值。
- `model = NULL` 表示未知，不得在迁移时伪造为某个具体模型。
- reasoning output 尚未在 Tauri 主事件表落盘；任何依赖该字段的功能必须先补契约和迁移。

## 5. 指纹和分块字段契约

| 逻辑实体 | Swift | Tauri | 对应规则 |
|---|---|---|---|
| 文件指纹表 | `source_fingerprints(source_id, value TEXT)` | `file_fingerprints(file_generation, file_path, fingerprint BLOB)` | 都是“某文件已见过的去重指纹”；键不同，编码不同 |
| 指纹值 | `value TEXT` | `fingerprint BLOB` | 不得直接比较字符串和二进制；比较前使用 parser 定义的 canonical digest |
| 分块表 | `source_chunks(source_id, chunk_index, byte_count, sha256 TEXT)` | `file_chunks(file_generation, file_path, chunk_index, byte_count, sha256 BLOB)` | 逻辑一致，来源键和 hash 编码不同 |
| 分块序号 | `chunk_index INTEGER` | `chunk_index INTEGER` | 一致，从 0 开始的约定必须保持 |
| 分块字节数 | `byte_count INTEGER` | `byte_count INTEGER` | 一致，单位 byte |

## 6. 归因桶字段契约

| 逻辑字段 | Swift `attribution_source_buckets` | Tauri `attribution_source_buckets` | 对应规则 |
|---|---|---|---|
| provenance epoch | `provenance_epoch TEXT` | `provenance_epoch TEXT` | 一致的安全边界概念；两端值不要求相同 |
| 来源 lineage | `source_lineage TEXT` | `source_id TEXT` | 都表示匿名来源身份；不能把 Swift source_id 当作 Tauri source_id |
| 桶起点 | `bucket_start INTEGER` | `bucket_start INTEGER` | 统一为 Unix 秒的 5 分钟桶起点 |
| 模型 | `model TEXT NOT NULL DEFAULT ''` | **当前缺失** | Tauri 归因表当前没有模型维度，模型归因只能从事件/聚合路径得到 |
| input Token | `input_tokens INTEGER` | `input_tokens INTEGER` | 一致 |
| cached input Token | `cached_input_tokens INTEGER` | `cached_input_tokens INTEGER` | 一致 |
| output Token | `output_tokens INTEGER` | `output_tokens INTEGER` | 一致 |
| reasoning output Token | `reasoning_output_tokens INTEGER` | **当前缺失** | 若需要按模型/来源精确计价，Tauri 归因表必须补齐 |
| 总 Token | `total_tokens INTEGER` | `tokens INTEGER` | 逻辑一致，物理名称不同 |
| 调用次数 | `calls INTEGER` | `calls INTEGER` | 一致 |

Swift 归因表定义见：[CodexUsageHistoryIndex.swift](</Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard/Sources/CodexTokenBar/CodexUsageHistoryIndex.swift:1626>)；Tauri 归因表定义见：[exact_usage_index.rs](</Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard/tauri-app/src-tauri/src/core/usage/token_count_jsonl/exact_usage_index.rs:6688>)。

### Tauri 当前到底如何做归因

Tauri 现在把“来源归因”和“模型归因”拆成两条链路，不能把两者混为一谈：

1. **来源/共享账号归因**：`synchronize_attribution_ledger` 从当前已发布的
   `events` 读取事件，按 `5 分钟桶 + session_id` 汇总，再通过
   `opaque_attribution_source_id(session_id)` 做 SHA-256 匿名化，写入
   `attribution_source_buckets`。因此 Tauri 表里的 `source_id` 实际是“匿名 session 来源”，
   不是 `files` 表的 `file_generation` 或 `path`，也不是模型 ID。
2. **模型归因**：`dashboard_stats` 和 `usage_series_bundle` 直接查询
   `published_events GROUP BY model`，生成 `ModelTokenBreakdown`。这条链路使用主事件表中的
   `events.model`，不读取 `attribution_source_buckets` 的 `source_id`。
3. **当前能力边界**：Tauri 可以回答“这个 5 分钟桶/来源消耗了多少 Token”和“这个时间段各模型消耗了多少 Token”，
   但不能仅凭现有来源归因表回答“某个匿名来源在这个桶里分别用了哪些模型、各模型多少钱”。

Swift 的来源桶 key 同时包含 `sourceID + bucket_start + model`，因此 Swift 可以在持久化归因桶里保留模型维度。
这也是当前契约中把 Tauri 的 `model` 标记为“缺失”而不是假设已对应的原因。

如果以后产品要求“共享账号来源归因也按模型拆分”，应新增 Tauri 的
`attribution_source_buckets.model`（并把它加入主键/唯一约束），同时补上 reasoning 字段、迁移、回填和旧索引测试；
不能在读取时拿整桶金额按模型比例反推。

当前实现锚点：

- 来源桶写入：[synchronize_attribution_ledger](</Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard/tauri-app/src-tauri/src/core/usage/token_count_jsonl/exact_usage_index.rs:4117>)
- 模型总览/曲线分组：[dashboard_stats / usage_series_bundle](</Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard/tauri-app/src-tauri/src/core/usage/token_count_jsonl/exact_usage_index.rs:1680>)
- 来源 ID 匿名化：[opaque_attribution_source_id](</Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard/tauri-app/src-tauri/src/core/usage/token_count_jsonl/exact_usage_index.rs:7795>)

## 7. 会话目录字段契约

| 逻辑字段 | Swift `session_catalog_entries` | Tauri `session_catalog_files` | 对应规则 |
|---|---|---|---|
| 路径 | `path TEXT PRIMARY KEY` | `path TEXT PRIMARY KEY` | 一致 |
| 是否归档 | `archived INTEGER` | `archived INTEGER` | 一致，0/1 |
| thread ID | `thread_id TEXT` | `thread_id TEXT` | 一致 |
| cwd | `cwd TEXT` | `cwd TEXT` | 一致 |
| session ID | `session_id TEXT` | `session_id TEXT` | 一致 |
| fork 来源 | `forked_from_id TEXT` | `forked_from_id TEXT` | 一致 |
| parent thread | `parent_thread_id TEXT` | `parent_thread_id TEXT` | 一致 |
| 来源类型 | `source TEXT` | `source TEXT` | 一致 |
| 文件大小 | `size_bytes INTEGER` | `size INTEGER` | 单位 byte，名称不同 |
| 修改时间 | `modified_seconds` + `modified_nanoseconds` | `modified_ns TEXT` | 单位相同但编码不同 |
| 创建时间 | `created_seconds` + `created_nanoseconds` | `created_ns TEXT` | 单位相同但编码不同 |
| 设备/文件身份 | `device_id` + `inode` | `stat_device_id` + `stat_file_id`，另有 `device_id` + `file_id` | Tauri 同时保留 stat 身份和逻辑文件身份 |
| 状态变化时间 | `status_changed_seconds` + `status_changed_nanoseconds` | `stat_changed_ns` 与 `changed_ns` | Tauri 合并为纳秒文本并区分 stat/逻辑变化 |
| 首行结束偏移 | `first_line_end_offset INTEGER` | `first_line_bytes INTEGER` | 逻辑一致，名称不同 |
| 首行摘要 | `first_line_sha256 TEXT` | `first_line_sha256 BLOB` | digest 语义一致，编码不同 |
| 最后观察代次 | `last_seen_generation TEXT` | `last_seen_generation INTEGER` | 逻辑一致，类型不同 |

会话目录本身不应承担 Token 计数；它只负责项目、thread、归档和文件发现。

## 8. 临时 staging 索引字段契约

两端都有按单文件建立的临时 staging SQLite，但它们会在导入主索引后删除，不属于用户长期数据。

| 逻辑实体 | Swift staging | Tauri staging | 对应规则 |
|---|---|---|---|
| manifest | 有 `session_id`、文件 stat、replay 状态、event_count、resume_offset、current_model | 以上字段外，还包含 `path`、`parser_revision`、file ID、prompt/assistant end、fingerprint_count、chunk_count | Tauri 字段更多；新增字段要分别更新 staged validator |
| staged event 顺序 | `source_offset` | `ordinal` | 逻辑均为源内顺序 |
| staged timestamp | `REAL` | `INTEGER` | 同主事件表的时间规则 |
| staged token breakdown | Swift 含 reasoning output | Tauri 当前缺 reasoning output | 与主事件表保持同样缺口 |
| staged fingerprint | `value TEXT` | `fingerprint BLOB` | 编码不同 |
| staged chunk | `chunk_index`、`byte_count`、`sha256` | 相同逻辑字段 | hash 编码不同 |

## 9. 元数据和安全状态契约

元数据不是业务事件，但决定迁移、发布和归因是否安全。

| 逻辑状态 | Swift | Tauri | 规则 |
|---|---|---|---|
| 主 schema version | `schema_meta.schema_version` | `metadata.schema_version` | 各端独立递增；新增持久列必须提升对应版本 |
| provenance epoch | `schema_meta.provenance_epoch` | `metadata.attribution_provenance_epoch` | 两端值不要求相同，但都必须在来源不可证明时旋转 |
| provenance revision | `schema_meta.provenance_revision` | 由 parser/replay 和 attribution marker 组合维护 | 语义必须登记，未知 revision 不得伪造为旧 revision |
| parser/replay revision | `fork_replay_boundary_revision` | `fork_replay_boundary_revision` | 逻辑应一致；修改 parser 语义时两端都要更新契约 |
| attribution generation | `attribution_generation` | `attribution_unsafe_generation` 等安全 marker 组合 | 不能跨端直接比较数字，只比较本端是否可证明连续 |
| 当前扫描不安全 | `attribution_current_scan_unsafe_cause` | `attribution_current_scan_unsafe` / `attribution_current_scan_incomplete` | 都必须阻止不安全基线推进 |
| 已发布代次 | session catalog 的 `published_generation` | `metadata.published_generation` 和 catalog published generation | 端内使用，不跨端复用 |
| source ID 序列 | `source_id_sequence` | 无对应字段 | Swift 端专属自增 ID 状态 |
| Codex Home 身份 | 无同名字段 | `codex_home_identity` | Tauri 端专属防止索引串 Home |
| 普通 revision | 无同名字段 | `revision` | Tauri 端专属 dashboard/source revision |
| orphan repair revision | 无同名字段 | `orphan_repair_revision` | Tauri 端专属完整性修复 marker |
| state SQLite stat | 无同名字段 | `state_size`、`state_modified_ns` | Tauri 端用于 state_5.sqlite 变化检测 |
| ledger integrity | 无同名字段 | `attribution_ledger_epoch`、`attribution_ledger_integrity_v1` | Tauri 端专属完整性证明 |

端专属 marker 不需要在另一端强行添加同名字段，但必须在代码和文档中标明用途，避免被误当成共享业务字段。

## 10. 当前审计结论

### 已经可以认为逻辑对应的字段

- 源文件路径、session ID、大小、修改时间、设备/文件身份；
- append/resume/replay 状态；
- 当前模型；
- 总 Token、input、cached input、output、调用次数；
- 事件时间和五分钟桶语义；
- 指纹、分块、会话目录的基本语义。

### 当前不能认为一一对应的字段

1. Tauri 主事件表缺 `reasoning_output_tokens`；
2. Tauri 归因表缺 `model`；
3. Tauri 归因表缺 `reasoning_output_tokens`；
4. Swift/Tauri 事件时间的 SQLite 类型和精度不同；
5. Swift 的 source ID 模型与 Tauri 的 generation/path 模型不同；
6. Tauri 有 generation/tombstone，Swift 没有完全等价列；
7. Tauri 事件直接保存 session ID，Swift 通过 source 表关联；
8. Swift/Tauri session catalog 的 stat 字段拆分方式不同；
9. 两端 staging manifest 的字段数量和校验要求不同。

因此，未来如果新增字段，必须先回答：

- 它属于哪个逻辑实体？
- 是两端都需要，还是某端专属？
- 两端物理字段分别叫什么？
- 类型、单位、精度是否相同？
- 缺失值是什么？`NULL`、空字符串、0 还是独立状态位？
- 旧索引如何迁移？需要回填还是只对新事件生效？
- 是否需要同步更新 staging、归因表、cache 和导出 DTO？

## 11. 后续新增或修改字段的固定流程

1. 先修改本契约，新增一行逻辑字段和两端映射。
2. 标明变更类型：`additive`、`rename`、`type-change`、`semantic-change` 或 `endpoint-only`。
3. 为 Swift 和 Tauri 分别增加同端 schema migration。
4. 新字段优先使用 nullable/default，不得让旧索引因为缺列直接读失败。
5. 如果字段是计价或统计字段，补充事件表、归因表、staging 表和聚合 DTO 的映射。
6. 如果字段涉及时间、Token 或金额，必须写单位、精度和舍入规则。
7. 迁移必须幂等、事务化、可中断恢复，不允许无条件全量重建。
8. 增加最小双端 fixture：同一源 JSONL 输入，比较归一化后的逻辑结果，而不是比较 SQLite 列名。
9. 更新契约中的当前版本和迁移入口。
10. 代码 review 时以本契约为字段核对清单。

### 变更规则

- **新增字段**：允许；两端分别加 nullable/default 列和读取逻辑。
- **字段改名**：先双读旧名和新名，再逐步只写新名；契约保留旧名映射。
- **类型改变**：不要直接改原列；新增兼容列并做显式转换。
- **含义改变**：必须新增逻辑字段或 revision，不能只改注释。
- **删除字段**：至少保留一个兼容读取周期，并在契约中标记废弃版本。
- **未知字段**：忽略未知 JSON/DTO 字段，但未知 SQLite schema/provenance 必须保留并安全拒绝写入。

## 12. 推荐的契约检查测试

以后每次索引字段变更只需要增加针对性测试，不需要重复跑全部历史回归：

- Swift 旧 schema → 当前 schema：字段存在、默认值正确、旧 Token 数不变；
- Tauri 旧 schema → 当前 schema：字段存在、默认值正确、旧 Token 数不变；
- 缺少可选字段：读取成功并使用声明的默认值；
- 缺少必需字段：明确失败，不显示为零；
- 同一 JSONL：Swift/Tauri 归一化事件的 Token、时间、model、source lineage 一致；
- reasoning output、模型归因、时间精度等当前差异有明确断言；
- migration 重跑不会重复加列、重复计数或重建整个历史；
- 新字段出现在主表时，staging、归因和聚合路径不会静默遗漏。

## 13. 代码锚点

- Swift 主表和事件表：[CodexUsageHistoryIndex.swift](</Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard/Sources/CodexTokenBar/CodexUsageHistoryIndex.swift:1452>)
- Swift schema 迁移：[CodexUsageHistoryIndex.swift](</Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard/Sources/CodexTokenBar/CodexUsageHistoryIndex.swift:2038>)
- Swift staging schema：[CodexUsageHistoryIndex.swift](</Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard/Sources/CodexTokenBar/CodexUsageHistoryIndex.swift:2918>)
- Tauri 主表和事件表：[exact_usage_index.rs](</Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard/tauri-app/src-tauri/src/core/usage/token_count_jsonl/exact_usage_index.rs:6626>)
- Tauri schema 迁移：[exact_usage_index.rs](</Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard/tauri-app/src-tauri/src/core/usage/token_count_jsonl/exact_usage_index.rs:6498>)
- Tauri staging schema：[exact_usage_index.rs](</Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard/tauri-app/src-tauri/src/core/usage/token_count_jsonl/exact_usage_index.rs:3237>)
- Swift 统计 DTO：[Models.swift](</Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard/Sources/CodexTokenBar/Models.swift:80>)
- Tauri 统计 DTO：[dashboard.rs](</Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard/tauri-app/src-tauri/src/models/dashboard.rs:163>)

本契约只描述当前代码的事实。以后任何字段改动都必须先更新本文件，再修改扫描器、迁移和聚合逻辑。
