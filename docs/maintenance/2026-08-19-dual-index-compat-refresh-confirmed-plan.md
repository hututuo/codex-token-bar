# 15 项索引兼容与刷新性能问题：收敛修复方案

状态：仅针对已确认的 15 项问题；不扩展为索引系统整体重构。

基线：`main@2144cb68031af6c985380e7927d04bb66b72c757`，2026-08-19 现场核对，工作树干净。

问题来源：`notes/index-compatibility-review-confirmed_v01_20260819.md`。

解决方案审核依据：`codex-token-bar_双端索引兼容与刷新性能修复实施设计_决策草案.docx`。

## 1. 本轮严格范围

本轮只修 P1-1 至 P1-7、P2-1 至 P2-8，共 15 项已确认问题。每个修改必须能映射到问题编号、现有代码证据和定向验收；不能因为“以后可能需要”新增第二套 parser、统计、计价、缓存或调度系统。

不把 S1（Tauri 新文件最多延迟一个 discovery 周期）或 S2（Swift marker 先于 snapshot 写入）当作本轮确认故障。它们保留在原报告中作为后续观察项，不进入本轮修复提交。

## 2. 逐问题修复方案

### P1-1：Tauri 无变化刷新仍创建/清理 generation

修改范围：`tauri-app/src-tauri/src/core/usage/token_count_jsonl/exact_usage_index.rs`。

- 在进入 `begin_or_resume_generation` 前增加只读变化判断：已发布文件身份、checkpoint、源签名、删除墓碑和已有派生行均无变化时直接复用当前 published generation。
- 无变化路径不得复制 `dashboard_5m`、`dashboard_turn_candidates`，不得创建后再删除空 generation，不推进 generation/revision，不产生 WAL 写入。
- 有变化时仍沿用当前 writer、published selector 和原子事务，不引入新聚合算法。

验收：连续 no-op refresh 的 generation、revision、aggregate 行数、`total_changes` 和 WAL 均不变；append/rewrite/delete 仍能正常发布。

### P1-2：Swift 每次完整读取全部历史聚合

修改范围：`Sources/CodexTokenBar/CodexUsageHistoryIndex.swift`、`Sources/CodexTokenBar/CodexUsageAnalyzer.swift`。

- 将历史聚合读取改为按当前视图需要的有界 SQL：今日、7d、30d、最近图表、峰值/连续天数和排行榜分别读取各自必要范围。
- 不在每次刷新中把全部 `dashboard_5m`、全部 session aggregate 和全部候选行搬入内存。
- 首次建立或派生 projection 确实缺失时才允许受控回填；普通刷新不触发回填。

验收：长历史 fixture 下读取行数与视图范围相关，不随 lifetime 桶数无界增长；结果与原完整算法一致。

### P1-3：Swift 排他锁覆盖长任务

修改范围：`CodexUsageAnalyzer.swift`、`CodexUsageHistoryIndex.swift`。

- 保留现有写入安全边界；缩短 `withExclusiveAccess` 只覆盖 discovery/checkpoint 写入、必要事务和发布。
- SQL 数值读取使用一致只读快照，内存 DTO 构建、图表格式化和 detail/excerpt hydration 移到锁外。
- busy/locked 返回 transient 状态，保留 last-good，不显示零或横杠。

验收：锁等待不再覆盖整个历史聚合；第二个读取者不会因长时间内存派生而被阻塞。

### P1-4：Tauri state metadata 读取失败清空 last-good

修改范围：`exact_usage_index.rs` 的 `sync_thread_metadata`。

- 先只读读取并校验 `state_5.sqlite`，成功形成完整 staging 后再替换 `session_metadata`。
- 读取失败、prepare 失败、busy 或签名漂移时保留旧 metadata 和旧签名，不推进 `state_size/state_modified_ns`。
- `state_5.sqlite` 只读；不修改 Codex 原始 state 数据。

验收：模拟 state DB 失败后标题、更新时间和旧 identity 保持；下一轮仍会重试。

### P1-5：旧索引增加 model 列但不回填历史模型

修改范围：Swift/Tauri 当前迁移入口和既有 SessionParser/索引 writer。

- 该问题是双端问题：Swift 当前旧 schema 迁移只补 `events.model` 列；Tauri 也只补 `events.model` 和 `files.current_model` 列，既有历史事件仍为 `NULL`。
- 下一版分别提升 Swift/Tauri 的 exact schema 版本。只有检测到受支持的旧 schema 时才进入一次“索引升级 owner”；fresh current schema 直接建立当前结构，不做历史迁移。
- 整个升级按固定顺序串行完成，升级结束前不启动该 Home 的日常增量 owner：
  1. **结构迁移**：幂等增加 nullable `model`；Tauri 同时完成 P2-7 所需的 nullable `reasoning_output_tokens`。这一阶段 JSONL body read 为 0。
  2. **历史事件补齐**：使用当前唯一 SessionParser，按旧索引中每个已发布 source 的正式 checkpoint/已提交字节水位解析到 staging。Swift 补 model；Tauri 在同一次历史读取中补 model + reasoning，避免扫描两遍。
  3. **一致性核对**：逐来源核对事件数量、ordinal/identity、timestamp、input/cached/output/total、source offset、文件身份和稳定前缀 hash。任何一项不一致，不覆盖旧 events，只把该来源交给单文件 reconciliation。
  4. **来源级提交**：用短 writer 事务写入补齐字段并更新受影响的模型/reasoning projection。每个来源保存当前 enrichment revision，已提交来源中断重启后不再重复。
  5. **升级完成**：只有全部旧来源完成、明确保留为合法 Unknown/NULL，或所需单文件 reconciliation 也已经在升级 owner 内完成后，才写入新的最终 schema/enrichment revision，并允许正常增量扫描启动。仅登记了待恢复来源时，升级仍未完成。
- 活跃文件的迁移边界固定为旧索引已正式发布的 checkpoint。迁移期间新增尾部不追读；整体迁移完成后，第一次正常增量扫描再从该 checkpoint 继续。
- 未来再次启动时，当前 schema + 当前 enrichment revision 直接跳过迁移，只执行日常增量，不再扫描历史模型。
- 未知/更高 schema 在任何加列、历史读取或写回前 fail-closed；不能把 future index 当成旧索引迁移。

验收：双端 v0.8.3 fixture 和当前未补齐 fixture只触发一次升级；升级完成后重启历史读取字节数为 0；总 Token、事件身份和 checkpoint 不变；历史模型逐项补齐；Tauri reasoning 同轮补齐；中断续跑不重复累计、不丢事件、不产生伪模型。

### P1-6：发布配置仍可能显示 0.8.3

修改范围：只作为发布门禁检查，不在本轮提前改版本号或发布资产。

- 发布前统一核对 `package.json`、Tauri config、Cargo、Swift bundle、Windows 和构建脚本的版本/build/capability。
- 最终发布版本由单一版本清单驱动，不能只改其中一个文件。
- 旧版本不得覆盖新 capability/storage identity；正式发布前验证升级、重复安装和 downgrade 行为。

验收：构建产物内版本、build number、storage/parser capability 与 release metadata 完全一致。未完成其余 14 项门禁前不构建正式资产。

### P1-7：Swift 未知 future provenance 会被按旧版重建

修改范围：`CodexUsageHistoryIndex.swift` 的 provenance 判断。

- 明确区分 `known legacy`、`current`、`stored > current/unknown`。
- future/unknown 在任何 DDL、DELETE、账本重建或 revision 写回前直接 fail-closed。
- 已知旧版本继续走现有受测迁移边，不引入新 parser。

验收：future provenance fixture 的数据库、账本、marker、WAL 和源数据均不变；known legacy fixture 仍可幂等迁移。

### P2-1：未知 future session catalog 直接 DROP/recreate

修改范围：Swift `CodexUsageHistoryIndex.swift`、Tauri `exact_usage_index.rs`。

- 已知旧 catalog 版本只走已登记迁移；未知或更高版本直接拒绝写入。
- 禁止把“版本不等于当前”当成 DROP/recreate 条件。
- 不删除未来版本额外列和 sentinel；错误状态保留 last-good。

验收：future catalog fixture 打开后 schema、行、marker、WAL 不变；known legacy 迁移结果字段一致。

### P2-2：Swift 重复打开 state DB 和重复 discovery

修改范围：`CodexUsageAnalyzer.swift`、`CodexUsageAnalyzer+StateSQLite.swift`。

- 一次 refresh 只建立一个 `RefreshContext`，复用一次 state DB 读取、一次目录 discovery、canonical path 和本轮候选清单。
- 初步 discovery 只决定本轮候选、处理顺序和进度总量，不是索引事实；候选清单过期不触发第二次目录发现。
- 每个候选文件在本轮正式扫描中只进入一次。进入该文件的正式流程时只读取一次当前身份并冻结 `observedEnd`；初步 discovery 记录的大小只用于候选和进度，不是正式读取上界。
- 正式扫描以数据库最近一次成功发布的 `resumeOffset` 为起点，只读取 `[resumeOffset, observedEnd)`；如果末尾是半行，只提交到最后可完整解析的位置。
- 本轮提交前只做一次轻量确认：文件身份仍相同、当前大小不少于 `observedEnd`、截至 `observedEnd` 的前缀 hash 未改变。
- 正常追加漂移（文件变大且冻结前缀不变）不重扫、不失败、不重新启动 owner；本轮提交实际解析完成的 checkpoint，把 `currentSize - committedCheckpoint` 记为待追尾水位，下一轮继续。
- 破坏性漂移分两种时点处理：
  - 正式扫描进入文件时已确认截断、替换、inode/file ID 变化或前缀变化：以进入时刚冻结的当前身份和 `observedEnd`，在本轮对该文件执行一次定向 rebuild。
  - 提交前才发现破坏性变化：丢弃该文件本轮 staging，保留该文件上一份 last-good，登记下一轮单文件恢复；不让该文件在同一轮重新进入，也不影响其他文件提交。
- 文件在 discovery 后新建、但不在候选清单中时，当前轮不处理，下一次 refresh 发现；这不是遗漏，也不需要让 owner 追着目录变化循环。
- 本轮成功提交后保存实际 `resumeOffset`、parser state、文件身份和前缀 checkpoint。下一轮只从这个真实 checkpoint 继续。
- 收尾不再无条件调用 `usageJSONLFiles()`，也不引入跨刷新永久 manifest。

示例：上次 checkpoint 为 12 MB，discovery 冻结 `observedEnd=15 MB`，扫描期间文件追加到 18 MB；本轮只扫描并提交 12–15 MB，下一轮再扫描 15–18 MB。

验收：一次 refresh 的 state DB open、目录 discovery、canonicalization 和每文件正式入口都只有一次；扫描中持续追加不会无限循环、不会启动第二 owner；追加前缀不变时 checkpoint 单调推进；截断/重写/替换/删除只影响单个文件。

### P2-3：Swift 稀疏删除扩大 dirty 范围

修改范围：`CodexUsageHistoryIndex.swift` 的 dirty bucket/session 计算。

- 保存精确受影响 bucket、session、date 集合，不用最小/最大边界合并相隔多年的范围。
- 删除 source 时使用索引或集合查找，避免对每个删除项反复线性扫描。
- 只替换旧贡献受影响的 projection 行。

验收：删除相隔多年的两个 source 只重算两组真实受影响范围，不扫描中间所有 5 分钟桶。

### P2-4：Swift compact today 缺少下一日上界

修改范围：`CodexUsageHistoryIndex.swift` 的 `compactTotals`。

- 统一使用半开区间 `[todayStart, tomorrowStart)`。
- `tomorrowStart` 由当前日历和时区计算，不能简单加 86,400 秒。
- 与 Tauri 今日查询使用同一边界语义。

验收：未来事件不计入今日；23 小时日、25 小时日、时钟回拨和跨设备导入 fixture 双端一致。

### P2-5：summary/full 覆盖边界不一致

修改范围：Swift snapshot/store 与 Tauri `dashboardMergers.ts`。

- 在现有 payload 上补齐最小必要 lineage：Home identity、usage/revision、coverage kind、observed/settled boundary 和 exact generation。
- summary 只能更新摘要；settled-only full 不能覆盖更新的开放桶摘要。
- 失败只改变状态并保留 last-good，不用 `generatedAt` 单独决定新旧。

验收：summary/full 乱序、同毫秒、失败重试和部分覆盖 fixture 不会让今日数值下降成旧值或待读取。

### P2-6：Tauri 使用启动时固定 offset 计算历史日期

修改范围：`localtime.rs`、`exact_usage_index.rs` 的日期分桶。

- 不再把启动时固定 offset 应用到全部历史事件。
- 使用事件时间对应的 IANA timezone 规则计算 local day；UTC 事实和 5 分钟桶保持不变。
- 时区变化只使本地日视图失效，不重写 exact events。

验收：UTC+8、America/Los_Angeles、DST 春秋切换、非整小时偏移和运行中切换时区 fixture 双端一致。

### P2-7：Tauri 丢弃 reasoning_output_tokens

修改范围：`session_parser.rs`、`exact_usage_index.rs` 的事件 DTO/schema/writer。

- canonical `events` 增加 nullable reasoning 字段；旧事件保持 `NULL`，真实零才写 `0`。
- parser、staging、writer 和 Swift 字段契约逐项对齐。
- 本轮只补齐 canonical event 数据和已有真实消费者所需字段，不扩散到没有消费者的所有 projection。

验收：NULL/0/>0 fixture 双端一致；结构加列阶段 JSONL body read 为 0；历史 model/reasoning 由 P1-5 的同一次事件补齐阶段读取，不重复扫描；新扫描事件可以直接保存 reasoning。

### P2-8：Swift/Tauri totalSessions 和 latest 口径不同

这一项必须先固定产品口径，见第 3 节。代码修复只在口径确定后进行，不同时修改无关排行榜语义。

## 3. 需要和用户讨论的内容

本轮真正需要产品口径确认的只有 P2-8：

1. **totalSessions**：统一为“已发布 Token 事件中的 distinct session”，还是继续显示 state DB 中的全部 Codex thread。
2. **latest**：统一为每个 session 的最新 Token 事件，还是保留现有 `input_tokens >= 1000` 的业务过滤；二者不能继续共用同一个字段名。

P1-6 只是发布门禁问题，本轮不改版本号、不构建正式资产、不发布；等 15 项修复完成后按门禁执行，不需要现在扩展讨论。

其余问题按上面的技术方案直接修复，不再另起 storage namespace、FormatManifest 重构、全新刷新调度器、通用 maintenance cursor 或第二套聚合算法。

## 4. 修复顺序

1. 先修 P1-1、P1-4、P1-7、P2-1：无变化写入、last-good、future fail-closed。
2. 再修 P1-2、P1-3、P2-2、P2-3：Swift 读取、锁、重复 discovery、dirty 范围。
3. 再修 P1-5、P2-7：model/reasoning 字段和旧来源补齐。
4. 再修 P2-4、P2-5、P2-6：today、summary/full、timezone 口径。
5. 讨论并修 P2-8。
6. 最后执行 P1-6 发布门禁；在此之前不构建正式发布资产、不 push、不 tag、不上传。

## 5. 本轮验收

- 每个提交必须标注对应 P 编号，不能混入未确认的新功能。
- v0.8.3 Tauri schema 6、Swift schema 3 兼容 fixture：结构迁移阶段 JSONL body read 为 0；P1-5/P2-7 的历史事件补齐单独计量读取字节，不能伪装成结构迁移，也不能重建整个 exact index。
- future provenance/catalog fixture：第一次写入前 fail-closed，数据库、WAL、SHM、marker 不变。
- no-op refresh：不创建 generation、不复制/删除整代 projection、不增长 WAL。
- append/rewrite/delete：只影响对应文件、bucket、session 和 projection。
- state 读取失败：保留 last-good 并在下一轮重试。
- model/reasoning enrichment：幂等、可中断、事件数量和主 Token 不变。
- today、summary/full、timezone 和 session/latest 使用固定 fixture 对账 Swift/Tauri。
- 只跑与 15 项问题直接相关的定向测试；不把全量构建、全量历史扫描或正式发布当作本轮修复的一部分。

本文件不替代原始审查报告，也不修改 Word 草案；它只是把 15 项确认问题收敛成可执行的修复清单。
