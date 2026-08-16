# 索引结构与新旧版本兼容性待修复方案

状态：`audit-complete / remediation-pending`

日期：2026-08-15

## 审查基线

- 当前工作树：`/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard`
- 当前分支：`codex/ui-paging-arrow-cues`
- 当前 HEAD：`57a5ff65ea0c553cc6de7470ca27ab5636e66d9b`
- 公开基线：[GitHub v0.8.3](https://github.com/hututuo/codex-token-bar/releases/tag/v0.8.3)，commit `ee557fd1a47fe4cf35485cfd7f613db98f2fa1a0`
- 当前 HEAD 比公开基线多 206 个提交；源码和发布脚本仍使用 `0.8.3/803`。

本文件只记录审查结果和待修复方案，不代表修复、合并或发布已经完成。

## 总体结论

- 未发现 P0：没有证据表明原始 `~/.codex` JSONL 被索引迁移删除或覆盖。
- 有五项 P1：Tauri 并发迁移竞争、旧事件模型归因缺失、版本/更新身份碰撞、旧二进制回滚破坏新派生索引、未知 provenance 覆盖风险。
- 有多项 P2：future session-catalog 处理、缺 schema marker、跨进程锁退避、旧聚合缓存升级、快照 state DB 身份绑定和矩阵测试缺口。
- 普通单实例 v0.8.3→当前的 Token 总量原位升级路径已由既有 fixture 证明；模型费用、并发启动和回滚仍未达发布标准。

## 扫描器与迁移的边界

这两个部分不是同一个东西：

1. **扫描器/parser** 读取 JSONL，计算增量 Token，解析当前模型、缓存输入、输出、推理 Token、时间戳、指纹、来源偏移和 fork/replay 状态，然后写入事件表。Tauri 的 live sink 和 staging sink 使用同一 `EXACT_SESSION_PARSER_REVISION`；Swift 的增量与 full-rebuild 路径也使用同一 parser contract。它们是“两种写入目标”，不是两套并行计价算法。
2. **索引迁移** 只调整 SQLite 结构和 metadata，例如新增 `events.model`、新增 source/checkpoint 字段、修复 orphan、重置特定 replay checkpoint、建立 session catalog。它不会替旧事件重新解析 JSONL，也不会自动把旧事件的 `model` 补进去。
3. 单个实例内，Swift 的 `prepareSchema` 和 `synchronize` 都在同一个独占 gate 内；Tauri 的 `open` 返回后才开始 `sync`，正常顺序不会让同一个对象的 scanner 与 migration 同时执行。但 Tauri 当前 gate 没覆盖整个 open-phase，第二个 open/进程仍可能与 migration、repair 或 scanner 在 SQLite 写层竞争，这就是 P1-1。
4. 因此，“当前扫描器会写入 model 和其他字段”是正确的；“旧索引迁移后就拥有这些字段”是不正确的。旧行只有在被重新解析或通过后续 model backfill 补齐后，才会拥有模型归因。

## P1 问题与解决方案

### P1-1：Tauri open 阶段并发迁移会竞争 SQLite

状态：`confirmed / needs-fix`

证据：

- `ExactUsageIndex::open` 在完整性 gate 释放后才执行 migration、replay repair、orphan repair 和 session catalog：[exact_usage_index.rs:495](../../tauri-app/src-tauri/src/core/usage/token_count_jsonl/exact_usage_index.rs:495)
- 当前 gate 只覆盖连接打开和 quick check：[exact_usage_index.rs:5573](../../tauri-app/src-tauri/src/core/usage/token_count_jsonl/exact_usage_index.rs:5573)
- schema migration 是逐列 `column_exists` 后独立 `ALTER TABLE`：[exact_usage_index.rs:6197](../../tauri-app/src-tauri/src/core/usage/token_count_jsonl/exact_usage_index.rs:6197)
- orphan/session catalog 仍在 open 阶段写库：[exact_usage_index.rs:6012](../../tauri-app/src-tauri/src/core/usage/token_count_jsonl/exact_usage_index.rs:6012)、[exact_usage_index.rs:6462](../../tauri-app/src-tauri/src/core/usage/token_count_jsonl/exact_usage_index.rs:6462)

影响：双端、重复刷新或两个进程同时打开同一 `CODEX_HOME` 时，可能出现 `SQLITE_BUSY`、`database is locked`、`duplicate-column` 或精确统计启动失败。已有一次并发测试出现 `database is locked`，单独重跑通过，符合竞态特征。

解决：

1. 建立覆盖整个 open 流程的 per-path migration owner；不要在完整性 gate 后再放开迁移。
2. 将已知 schema 的列迁移、parser/orphan/session marker 写入同一事务；失败保留旧 marker。
3. 非 owner 有界等待；超时返回 last-good 快照和“其他实例正在迁移”，不得伪装成零统计。
4. 只新增一个“双并发打开 v6/v7”最小复现测试，不重复已有回归测试。

### P1-2：旧事件没有 model，升级只增加空列

状态：`confirmed / needs-design-and-fix`

证据：

- 公开 v0.8.3 的 events 表没有 `model`；当前迁移只是新增列：[CodexUsageHistoryIndex.swift:1997](../../Sources/CodexTokenBar/CodexUsageHistoryIndex.swift:1997)、[exact_usage_index.rs:6197](../../tauri-app/src-tauri/src/core/usage/token_count_jsonl/exact_usage_index.rs:6197)
- Swift 归因按 `COALESCE(e.model, '')` 聚合：[CodexUsageHistoryIndex.swift:1852](../../Sources/CodexTokenBar/CodexUsageHistoryIndex.swift:1852)
- Tauri 的多个 breakdown 查询也直接按 `model` 分组；未知模型会进入 fallback 计价路径，而不是恢复旧真实模型。
- 既有迁移测试验证 Token 数/列存在，未验证旧事件模型桶。

影响：旧事件 Token 总量一般保留，但历史模型占比、7d/30d 模型费用、真实模型计价和自动审查归因可能进入未知模型；没有重新解析旧文件就不会自动恢复。

解决：

1. 迁移发现旧 schema 新增 model 列时，写入 `model_attribution_backfill_required`，并置 `attributionModelBucketsComplete=false`。
2. 保留现有 Token 和主索引，不删除/重建；首屏明确显示“历史模型待补齐”。
3. 增加可中断、可恢复、按来源分批的模型 backfill，只补模型字段，不替换主索引；文件变动或 writer 存在时暂停。
4. Swift/Tauri 使用相同的 incomplete 语义，未知模型不能伪装成零或精确金额。

### P1-3：源码、更新器和发布资产仍是 `0.8.3/803`

状态：`confirmed / release-blocking`

证据：[package.json:4](../../tauri-app/package.json:4)、[tauri.conf.json:4](../../tauri-app/src-tauri/tauri.conf.json:4)、[build_release.sh:8](../../scripts/build_release.sh:8)。当前 storage 已前进到 Tauri schema 8/cache 19、Swift schema 5，而公开版是 Tauri 6/cache 16、Swift 3。

影响：更新器无法区分当前 post-release 源码和公开 v0.8.3；同版本候选可能被旧资产覆盖，用户无法识别实际缓存格式。

解决：下个正式版本必须同时提升 marketing version、build、commit/capability identity；由同一版本清单生成 appcast、Windows metadata、安装脚本和 bundle metadata；更新器拒绝同版本低 identity 覆盖，并保留 last-good 安装备份。

### P1-4：回滚旧二进制会破坏新派生索引

状态：`confirmed / release-blocking`

旧 v0.8.3 遇到 schema 8/5 时会删除并重建旧索引；JSONL 源文件不会被删除，但会冷扫、暂时显示空统计，并可能丢失新模型/归因字段。旧新实例并行时，旧进程还可能 unlink 并重建同一路径，形成派生索引分叉。

解决：回滚前停止两端和后台 owner，原子备份 exact index/WAL/SHM/aggregate/metadata；未来 schema-breaking 版本使用格式代次 namespace；安装器显示“只重建本地缓存，源历史未删除”。

### P1-5：未知 provenance 会被 Swift 当成旧版本重建并覆盖

状态：`confirmed / release-blocking`

证据：当前 schema 版本有 future guard，但 `provenance_revision` 只要不等于当前值，就会删除 attribution ledger、从现有 events backfill 并写回当前 revision：[CodexUsageHistoryIndex.swift:1484](../../Sources/CodexTokenBar/CodexUsageHistoryIndex.swift:1484)。因此较新版本写入的未知 provenance 被旧版本打开时，可能被旧语义覆盖，而不是拒绝打开。

解决：

1. 为 provenance revision 建立显式已知旧版本 allowlist，并定义可迁移方向。
2. 空值/已知旧版本才进入迁移；未知或高于当前版本直接 fail-closed，保留数据库和原 ledger。
3. 将 revision 与 snapshot/index capability 一起写入诊断，避免只显示“缓存失效”。

## P2 问题与解决方案

| 编号 | 已发现问题 | 解决方案 |
|---|---|---|
| P2-1 | Swift/Tauri future session-catalog schema 会 DROP/recreate | future 版本只读拒绝写入；只有已知旧版本迁移。 |
| P2-2 | 有业务表/事件但缺 `schema_version` 可能被当成新库 | 缺 marker 且有数据时拒绝升级并隔离诊断。 |
| P2-3 | Swift relaxed snapshot 未完整绑定 state DB identity | 将 state DB 身份和 generation 纳入签名，不一致就 unavailable。 |
| P2-4 | Swift 跨进程锁抢不到直接失败 | 有界指数退避并返回 last-good，不显示零。 |
| P2-5 | Tauri v16–v18 只有 full refresh 才升级 v19 | 获得可信 binding 后做轻量原子升级；旧缓存继续标 stale。 |
| P2-6 | 缺 old→new→old→new、双端并行和同版本安装矩阵 | 只为这些新路径增加最小 fixture，不重复已有回归套件。 |

## 兼容性矩阵

| 场景 | 当前结果 | 修复后门禁 |
|---|---|---|
| v0.8.3→当前，单实例 | Token 可保留；模型费用不完整 | P1-2 完成且迁移事务化 |
| v0.8.3→当前，双实例 | 有锁竞争失败 | P1-1 single-flight migration |
| 当前→v0.8.3 | 可重建但可能冷扫 | P1-4 回滚门禁、备份、namespace |
| 当前→future schema | 主索引多数路径拒写；目录/provenance 有缺口 | P1-5/P2-1/P2-2 |
| v16–v18→v19 | 可读，full refresh 后升级 | 可信 binding 轻量升级 |
| Swift/Tauri 并行 | SQLite 分开，共享源/锁 | 退避与并行矩阵通过 |

## 修复顺序

1. P1-1：Tauri migration single-flight、事务和锁错误降级。
2. P1-2：旧事件模型 backfill 状态机和双端一致语义。
3. P1-5、P2-1/P2-2：所有未知 future metadata fail-closed。
4. P1-4：回滚/namespace/备份门禁。
5. P1-3：版本、build、commit、capability 和发布元数据统一。
6. 只针对新发现路径补最小复现测试，再进入构建/发布审查。

## 本轮记录

- 本轮新增本文件；未修改索引实现、JSONL、SQLite、版本号或发布资产。
- 未启动/停止 App，未重建真实索引，未 push、merge、tag、upload 或 release。
- 已有回归测试结果沿用上一轮；本轮二次复核由独立只读审查完成，只核对源码与 Git 证据，没有重复执行已有回归测试。
- 二次复核没有发现新的 P0；确认了 Tauri open-phase DDL/marker 竞争、Tauri 未知模型 fallback 计价、Swift future provenance 覆盖和旧版回滚无跨进程保护等结论。

## 精确统计串行化与右上角状态指示器方案

本节是下一轮实现前的冻结方案；本次先记录设计，不直接修改源码或运行真实索引。

### 目标与边界

1. **迁移、修复、扫描、发布派生数据必须串行**。同一个 Codex Home 的 SQLite 精确索引，在同一进程重复刷新、Swift/Tauri 双端并行、两个 Token Bar 进程并行时，都只能有一个 owner 进入 `open → schema migration/repair → scan → publish` 链路。
2. **串行不等于把所有读取都阻塞**。只读的 last-good 快照和进度查询不打开索引、不执行迁移、不启动扫描；它们可以在 UI 侧继续返回旧数据和当前状态。
3. **进度必须来自真实工作量**。不能用固定计时器或“假进度”；先枚举本轮要处理的会话文件/任务总量，再在每个文件、迁移步骤和发布步骤完成时推进。
4. **不改变原始 JSONL、events 的历史语义，不触发无条件全量重建**。状态指示器是可观测性和用户反馈，不是新的统计口径。

### 统一状态模型

两端使用同一组语义（字段名可按 Swift/Rust 习惯映射）：

| phase | 含义 | 进度 | UI 文案示例 | 颜色 |
|---|---|---|---|---|
| `idle` | 没有精确任务运行 | 无 | `更新于 16:05:33` | 绿色/中性 |
| `waiting` | 等待另一个 owner 释放锁 | 可选 | `等待另一实例完成` | 橙色 |
| `preparing` | 固定数据源、读取 marker、计算工作量 | 不定或 0/总量 | `准备精确统计` | 蓝色 |
| `migrating` | schema/metadata/orphan/session catalog 迁移 | 确定的步骤数 | `升级索引结构 2/4` | 橙色 |
| `scanning` | 解析 JSONL 并写入增量/staging | 文件数 0/总文件数 | `扫描精确历史 128/642` | 蓝色 |
| `backfillingModel` | 只补旧事件模型归因 | 文件/事件数 | `补齐模型归因 31%` | 紫色 |
| `publishing` | 导入 staging、提交 generation、更新 last-good | 步骤数 | `发布精确统计` | 蓝绿色 |
| `complete` | 本轮成功完成，等待回到 idle | 100% | `更新于 16:05:33` | 绿色 |
| `failed` | 本轮失败但保留 last-good | 无/最后值 | `读取失败，保留上次可信数据` | 红色 |

状态对象至少包含：`phase`、`message`、`completed`、`total`（未知时为 nil）、`fraction`（只能由真实 total 计算）、`startedAt`、`updatedAt`。`total=0` 或尚未完成预扫描时必须显示不定进度，不得显示 0% 作为伪精度。

### 串行实现

#### Tauri

1. 在 exact index 的数据库路径旁增加一个稳定的 operation lock，并把它保存到 `ExactUsageIndex` 生命周期中，使锁覆盖完整的 `open` 和后续 `sync`，而不是只覆盖连接/quick_check。
2. 同时保留 per-path integrity gate；open-phase 的 DDL、replay/orphan repair、session catalog 初始化都在 gate 和 operation lock 内完成。
3. 锁竞争采用有界等待（例如短间隔轮询、最长约 30 秒），等待期间发布 `waiting`；超时返回 last-good/可诊断错误，不清空数据、不启动第二个迁移者。
4. 已知 schema 列迁移和 marker 写入尽可能合并为单个事务；任何一步失败都保留旧 marker，并将状态置为 `failed`。

#### Swift

1. 保留现有 `withExclusiveAccess/synchronizeExclusively` 的单一 gate，将 `prepareSchema`、模型 backfill 和扫描继续放在同一个 owner 内。
2. 将当前抢锁即失败改为有界等待；等待期间向 store 发布 `waiting`，超时继续保留 last-good。
3. Swift 与 Tauri 共享状态语义和兼容规则，但不共享缓存文件；不能因为一端状态失败而把另一端状态标成失败。

### 总量预扫描与进度来源

1. `preparing` 阶段只做安全的路径枚举和元数据读取，统计本轮候选 JSONL 文件数；不读取正文、不写 events、不重建索引。
2. **必须复用一次 discovery 结果**：预扫描不能再调用一遍目录递归、同步时再递归一遍。discovery 应产出冻结的 canonical candidate manifest（路径、来源、文件身份、size/mtime），后续扫描直接消费它。
3. Swift 当前 `usageJSONLFiles()` 已经先得到 `sessions`、`archived_sessions` 和 `state_5.sqlite` 中的 active rollout 路径，再 canonical 去重；首次索引可直接把这份列表作为 total 并传给 `synchronize`，不要在 progress 计算阶段再次调用 `usageJSONLFiles()`。详情 hydration 前的 staleness 校验也要避免无条件重新枚举，除非明确检测到源代次变化。
4. Tauri 当前 `visit_session_files` 与 `visit_active_rollouts` 把枚举和处理耦合在一起；实现时要增加 discovery/manifest 层，确保 active rollout 也进入 total，扫描和发布阶段只消费同一份 manifest。目录队列的崩溃恢复语义不能因为进度改造而丢失。
5. `scanning` 以实际进入 parser 的 manifest 项数推进；无法读取、越界、查询失败或扫描开始后新增的路径按现有保守规则记 warning，不能把跳过项伪装成成功完成。
6. 如果 active rollout 查询失败、根目录不存在、manifest 在扫描期间失效，`total` 必须变为 nil/不定进度，状态显示“正在计算/来源发生变化”，保留 last-good；不能继续显示看似精确的百分比。
7. `migrating` 使用固定、可审计的步骤总数（列/marker/repair/catalog 等），每完成一个真实步骤推进一次。
8. `publishing` 以 staging 导入和 generation 提交步骤推进；只有提交 last-good 后才进入 `complete`。
9. 所有更新都写入进程内状态表；Tauri 通过只读 command 轮询，Swift 通过 `@Published` 状态发布。进度读取不能重新 `open` 索引，避免 UI 轮询反过来制造锁竞争。

### 右上角 UI

1. 正常状态保留现在的“精确统计 · 更新于 HH:mm:ss”，增加一个小状态点。
2. 非 idle 状态把“更新时间”替换为状态文案；迁移/扫描/补齐使用醒目的色彩和细进度条，状态点与进度条颜色保持一致。
3. 有确定总量时显示 `completed/total` 和百分比；无确定总量时显示不定进度条和阶段文案，不显示虚假的百分比。
4. 状态条不改变右上角原有布局宽度；长路径/错误文案使用 tooltip 或辅助说明，主条只显示短文案。
5. 失败状态保留 last-good 的更新时间，并明确“本轮失败/保留上次可信数据”，避免把失败时间误当成数据生成时间。
6. Swift 与 Tauri 的颜色、阶段命名、无障碍 label、进度条语义一致；默认正常态仍与现有界面兼容。

### 兼容与恢复

- 老索引没有 progress marker 时按 `preparing` 开始，不迁移历史进度，不因此重建。
- 应用重启后只恢复 last-good 数据；中断的迁移/扫描由新的 owner 从安全 checkpoint 继续，不能把上次的“已完成百分比”当作当前真实进度。
- 进度状态是易失的诊断状态，不写入会改变旧索引解释的必需字段；如需持久化，只写可选的 `progressRevision`/诊断快照。
- 未知 future schema/provenance 仍按兼容审计中的 fail-closed 规则处理，状态显示 `failed`，不删除或覆盖数据库。

### 实现顺序与验收

1. 先落 Tauri/Swift 的有界 operation owner 和 open-phase gate，新增最小双 open 竞争测试。
2. 再加入真实总量预扫描和阶段状态 registry，确认不触发额外正文扫描和全量重建。
3. 接入 Swift/Tauri 右上角状态指示器和进度条，补充空闲、等待、迁移、扫描、失败五种 UI 状态测试。
4. 只运行新增的定向测试、类型/编译检查和 `git diff --check`；不重复本轮已经完成的全量回归套件。
5. 最终验收必须提供：同一 Codex Home 双端并行的 owner 日志、迁移步骤数、扫描总量/完成量、last-good 保留证据，以及无索引重建的源状态指纹。

## Luna Max 方案复核（2026-08-16）

本节记录 `luna_worker` 的只读审核结果；审核没有修改文件、没有构建、没有启动 App，也没有重复运行既有全量回归。

### 已确认

- Swift `CodexUsageAnalyzer+SessionParsing.swift:472-490` 已经一次性得到会话、归档和 active rollout 的去重列表；这份列表可以同时作为首次索引的总量和 `historyIndex.synchronize` 的输入，首次索引进度不需要额外递归。
- Tauri 的 `visit_session_files` 和 `visit_active_rollouts` 目前在 `ExactUsageIndex::sync` 内部边枚举边处理；如果另外增加一个独立预扫描，会重复目录/SQLite 查询，并且会改变临时 seen 队列的时序。
- active rollout 必须纳入 total；查询失败、越界、目录不存在或扫描期间源文件变化时，total 不能继续被当作精确值，应退化为不定进度并保留 last-good。
- Swift 当前跨进程锁竞争直接抛错；有界等待不能嵌在持有 `NSRecursiveLock` 的递归 owner 内，否则会造成等待状态不可见或死锁。必须拆出“可等待地取得跨进程 owner”与“持有 owner 执行业务”的两层。
- Tauri per-path integrity gate 当前只覆盖连接/quick_check；open 返回后 migration/repair/catalog 仍可能与第二个 open 竞争。operation lock 必须跨过 `open → sync → publish`，不能在 open 与 sync 之间释放后重新获取。

### 审核后冻结的实现切分

1. 先完成两端 operation owner 的生命周期和有界等待，并补一个双 open 竞争的最小测试；不把 UI 轮询接到 `ExactUsageIndex::open`。
2. Swift 直接复用已发现的 `sessionFiles`；Tauri 把当前枚举改造成冻结 manifest，再由扫描阶段消费 manifest，保留目录队列的可恢复语义。
3. 在 owner 内发布 `preparing/migrating/scanning/publishing/complete/failed`，只有 manifest 有效时才显示 determinate fraction；初次索引的 discovery 期间显示“正在计算索引规模，可能需要数分钟”的不定进度。
4. 再接入 Swift `@Published` 和 Tauri 只读 progress command + 前端轮询，顶部只替换更新时间区域，不改变数据快照和 last-good 语义。

### 新增定向验收点

- Swift 首次索引：会话/归档/active rollout 列表只枚举一次，total 与实际 synchronize 输入一致。
- Tauri 首次索引：manifest 包含 active rollout；目录/数据库查询失败时 total=nil，不显示假百分比。
- 两端双 open：第二 owner 进入 waiting，第一 owner 完成后才进入迁移/扫描；超时保留 last-good。
- 进度查询不创建 SQLite connection、不触发 schema migration、不改变 seen 队列。
- owner 中断/重启后不会复用上次百分比；从安全 checkpoint 继续或重新进入 preparing。
- 顶部 idle、首次索引、迁移、扫描、失败五种状态的文案、颜色、无障碍 label 和不定/确定进度行为一致。

## 本轮实现状态（2026-08-16）

- Tauri：operation lock 现在只覆盖 `open` 初始化阶段和真正的 `sync → publish` 阶段；只读 `ExactUsageIndex` 不再长期占锁，避免历史读取被无关的长生命周期对象阻塞。sync 内仍由 operation lock 与 per-path integrity gate 串行保护。
- Swift：已把一次 discovery 得到的 `sessionFiles` 复用于同步；首次索引显示发现文件总量并按实际候选推进，schema 升级阶段显示迁移进度；跨进程锁改为有界等待。
- Tauri 首次扫描：增加独立的只读预扫描旁路。它只枚举 `sessions`、`archived_sessions` 和 active rollout 的 canonical JSONL 路径，不读正文、不写 SQLite、不触碰 `exact_seen_*`，最多运行 10 秒；成功时给现有扫描回调提供“约 N/总量”，失败/超时立即退回原来的不定进度和真实已处理数量。核心目录队列、崩溃恢复、删除墓碑和增量判断保持不变。
- 两端顶部正常态仍回到“精确统计 · 更新于 …”；迁移、扫描、等待、失败使用状态点/进度条，不改变 last-good 快照。
- 未修改原始 JSONL、事件语义、版本号或发布资产；没有重建真实索引、启动 App、push、merge 或 release。

### 本轮预扫描实测与安全边界（2026-08-16）

- 本机 `~/.codex` 约 2,088 个 JSONL 候选，正文总量约 42.79 GiB；预扫描只读目录/元数据，不读取这 42.79 GiB 正文。
- 接近 Tauri 的 Rust 目录遍历、canonicalize 和去重实测约 20–26 ms；包含 active rollout 查询和完整去重的旁路实测约 100–180 ms，远低于 10 秒保护上限。
- 预扫描结果只存在本轮进程内，用于 UI 分母；扫描期间文件变化时进度仍标记为约数，最终以 durable sync 结果为准。
- 本实现有意没有把预扫描清单接入核心扫描器，也没有宣称它是冻结 manifest；它只是 UI 旁路。若未来要求百分比成为严格计量，再单独进行 manifest/队列重构，不能把本次旁路直接升级为索引输入。
- 修复了 operation lock/integrity gate 生命周期造成的只读连接自锁：门禁在 `open` 和 `sync` 阶段短生命周期持有，连接关闭时的完整性收据顺序保持不变。
- 定向 Tauri 索引测试：`120 passed / 1 ignored`；`cargo check --offline`、TypeScript 类型检查和 `git diff --check` 通过。Rustfmt 组件当前未安装，仅未执行格式检查。
