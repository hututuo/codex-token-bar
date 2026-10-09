# 压缩历史读取入口与成本审查

2026-10-05，源码基线 `16711ea208e111ba6711c11094626f26b795c3c4`。root 审查 Swift 与前端调用，GPT-6.1 Sol xhigh 独立审查 Rust/Windows。以下表格和行号保留基线调用路径与当时成本，**不表示最新代码仍有这些缺口**。整改约束见[冷存储策略](compressed-history-cold-read-policy.md)，已完成的改造及当前边界见[实施记录](2026-10-05-cold-history-implementation.md)。

具体接口替换、来源状态处理及工作量验收见[改造方案与实施范围](compressed-history-implementation-plan.md)。

## 判断方式

mtime 在文件系统属性中，不在 zstd 帧头中。固定 Codex CLI v0.160.0 上游压缩器保留原 mtime，并声明原始字节长度。普通文件与 zst 使用同一 logical source 和 decoded-byte checkpoint；不能用压缩物理长度与 checkpoint 比较。

完整可信旧索引、相容的逻辑长度/mtime、受支持的单帧结构及稳定的前后物理观察，允许保留旧数值账本。mtime/长度不是正文相同的证明，也不认证旧原文 offset。未索引消费、必需数值迁移及真实变化仍需正式解析。

读取成本分为：

| 级别 | 实际工作 |
|---|---|
| 属性/SQL | stat/fstat、现有索引/持久投影；不创建正文解码工作 |
| 帧结构 | 遍历帧及块头，跳过压缩块载荷；不解码正文，但工作量随块数量增加 |
| 测长 | 未声明逻辑长度且没有可复用缓存时完整流式解码；不等于统计解析 |
| 前缀/片段 | 从起点解码到逻辑 offset，或读取首行；逻辑 seek 不支持压缩随机访问 |
| 整源解析/证明 | 流式读取正文，解析必要统计或计算旧 chunk/prefix SHA；另须区分真实 EOF 与旧 prefix 终点 |

两端 reader 缓存的是物理版本对应的布局/逻辑长度，不是展开正文或片段。进程重启、物理变化或缓存淘汰后不能依靠暖缓存。Swift 缓存达到32768项整体清空；首次 inspect 的结构遍历有100万块上限。这些上限均不是 UI 时延保证。

## Swift / macOS

下表包含会创建 reader 的直接入口及其上层使用场景。文件均位于 `Sources/CodexTokenBar/`，行号对应上述 SHA。

| 入口及调用链 | 自动触发/条件 | 压缩读取成本与现状 |
|---|---|---|
| `loadFastSnapshotResult → cachedPreciseSnapshot → sessionTreeSignature → sessionCacheKey → SourceFileObservation.read → logicalSize`（Analyzer:136/345，SessionParsing:657/1089，Observation:22） | Store:794 的不含精确扫描刷新、缓存读取；同一签名链也用于精确刷新和 compact 后的 receipt | **判断缓存前**就打开 zst。声明长度/暖布局不解码正文；未知长度冷 miss 完整测长。不是所有快速读都只读已有索引 |
| `loadLastGoodSnapshotResult`（Analyzer:128） | Store:766 首次精确加载的先行画面 | 只读路径/身份绑定的持久投影；这条启动先行路径不枚举正文。不能与上一条 fast 校验路径混为一谈 |
| `loadCompactSummary → historyIndex.synchronize`（Analyzer:221/243） | Store:2295 定时刷新、compact 请求；后台间隔由设置决定 | “轻量”只表示聚合 SQL 轻量，**同步仍可解析来源**。先 `sourceSignatureMetadata` 测长，再决定旧账复用；稳定 represented 来源可跳过正文 |
| `loadSnapshot → loadFromTokenCountJSONLExclusively → synchronize`（Analyzer:76/516/723） | 手动刷新、首次完整加载、完整图表刷新、compact 失败回退 | 新源、变化、不完整 checkpoint、必需 enrichment 会进入单源追加/暂存解析；不是可全部禁止的正文读取 |
| `sourceSignature → contentProbe`（HistoryIndex:8250/8346） | 同步变化比较、append 前后、stage 前后、复用 stage 校验 | SHA 输入虽仅首尾各4KiB，seek 到尾部仍解码几乎整个前缀。打开 handle 与路径分别签名、倒退 seek 重置后，可增加多次解码 |
| `repairMessageLinks → scanMessageLinks → PaginatedHistoryBoundary.metadata + streamIndexedSessionLines`（HistoryIndex:2734/4592，SessionParsing:157/1100） | compact/完整同步；旧可用 binding 缺 prompt 与 receipt 时 | **可选问答补全仍可整源扫描/hash**，没有实际 zst 冷源门。Swift 在表示关联之后执行，已撤销的 binding 不进入 pending；不能套用 Rust 的 pre-scan 时序，但已有匹配 available bindings 仍有风险 |
| `hydratingTurnExcerpts → turnSourceReferences → verifyRestoredExcerptSource → sourceChunksMatch`（SessionParsing:418，HistoryIndex:3436/3507/6380） | 完整数值发表后的排行摘录补全 | 开压缩排行时在 proof 前跳过实际 zst；关闭设置但 zst 尚在则可达。metadata-only/raw unavailable 需要**整源 chunk + EOF 证明**；已有 proof 则复用。此证明仍持索引进程锁与跨进程锁，且逐选中源加载整张 sources |
| `hydratingTurnExcerpts → readIndexedLine / streamIndexedSessionLines`（SessionParsing:436/455/1251） | 上一条可用引用返回后，自动补问答 | 每个 prompt、每个 assistant 合并区间分别打开 reader；同源不同片段反复丢弃前缀。按文件分组并未等于单 reader。180/220字符限制只约束显示，巨大单行仍可物化整行 |
| `repairExplicitSubagentReplayBoundary → PaginatedHistoryBoundary.read / probeExplicitSubagentSessionFile`（HistoryIndex:3889/4217/5717/5811） | 旧 parser/replay revision 打开索引时；未解决则下次打开重试 | 首行/边界读取，首行有界；必要迁移，不是日常所有历史全解析。迁移期间同次 open 可执行两次探测；若随后排入单源重建则解析该源 |
| `stageFullRebuild / reusableStage / importStagedFullRebuild`（HistoryIndex:6935/7595/7934） | 必要重建、enrichment、崩溃恢复或来源转换 | stage 正式读取；复用 stage 可能重新 contentProbe + bounded 全 prefix hash；导入旧 partial chunk 差异会新开 reader 解码到尾块；format 检测 `UsageEventLedger.isPaginatedFile` 又读首64KiB。**复用 hash 分支遗漏 EOF 的旧缺陷仍在** |
| `synchronizeSessionCatalog → sessionCatalogFileSignature / sessionCatalogFirstLineFingerprint`（HistoryIndex:2085/2335/2359） | 会话管理目录底层方法 | 原语能读 zst：签名未知长度测长，首行 fingerprint 无独立输入长度上限。但**当前 Swift UI scanner 只枚举现存 jsonl，trusted binding 不透明 fallback，metadata 明确拒绝 zst**。正常已有 zst 不从此 UI 枚举进入；转换竞态或以后扩展接入仍须统一冷策略，不能写成当前普通会话列表必然扫描全部 zst |

### Swift 直接 reader 调用点覆盖

对 production Swift reader/open/logicalSize/ZSTD 调用做全集检索，覆盖67个文本匹配（包含协议、实现、路径识别，不是67个外部接口）。直接打开点与上表对应：

- SessionParsing:1119/1252；Observation:30/41；UsageEventLedger:43；PaginatedHistoryBoundary:33。
- HistoryIndex:2346/2362（catalog）、2456（metadata reuse）、5811（replay）、6151（append）、6419/6445（chunk proof/audit）、6969（stage）、7934（partial old tail）、8310（hash）、8347（probe）。
- 传入已有 handle 的解析/边界/签名也纳入；边界 reader 将 cursor 复位到0再恢复，压缩非零 cursor 的恢复也要解码前缀。
- reader 内 `logicalSize:203` 的完整测长、`seek:193` 的弃前缀、`validateDecodedEnd:220` 的终点验证和 `inspect:227` 的帧/块遍历分别记录。单纯 `physicalURL/logicalURL/isRollout` 不是解码。

## Rust / Tauri / Windows

Rust 上层接口、自动刷新与内部 reader 路径由独立 Sol 审查；逐打开点证据保存在 `runs/20261005-compression-reaudit/rust-entrypoints.md`。不能因 `run_blocking_command` 或 single-flight 就认为单次工作有解码预算；它们防止主线程阻塞或重复 owner，不能中断无预算的单文件读取。

| 外部接口/场景 | 内部入口 | 压缩读取成本与现状 |
|---|---|---|
| `read_precise_dashboard_source_probe`（commands/dashboard:1920，frontend usePreciseDashboardLoad:172） | `precise_dashboard_source_probe → read_only_source_probe → source signatures` | 每次非强制 cadence 在精确加载前比较来源；250ms只在文件边界检查，未知长度冷 miss 的 `RolloutReader::open` 可完整测长。前端“不会读正文”的注释不覆盖这层实际测长 |
| `read_precise_dashboard_snapshot`（commands/dashboard:1653）及 `schedule_precise_dashboard_aggregate`（:1706） | 序列化 Full owner → `ExactUsageIndex::open + sync` | 来源比较/估计、必需迁移/重建、Full pre/post `message_links::repair`、最后排行 proof/摘录。7天设置仅约束最后排行，不能关闭前面的签名/目录/repair |
| `read_usage_summary_snapshot`（commands/dashboard:1896） | `refreshed_usage_summary_snapshot_with_interval`（token_count_jsonl:2769）→ Summary owner | 60/150/300/600秒 cadence或0强制，加入已有或启动新 owner；Summary 仍 open+sync，可测长/必要解析，但不执行 Full 排行摘录 |
| 已完成 Summary 提升为 Full（token_count_jsonl:1649/1671） | `sources_changed`（exact_usage_index:3346）直接对比全集 file_signature | 即使复用 Summary generation、绕过带时间预算的 estimate，仍可未知长度冷测长。Full aggregate cache hit 判断也在索引同步之后，不能把缓存命中解释为零来源 open |
| `list_session_management_catalog`（commands/session_management:14） | `list_catalog → scan_rollout_supplements → session_catalog_snapshot → ExactUsageIndex::open → refresh_session_catalog` | Rust 与 Swift 不同：sessions/archived 全集观察包含 zst；即使 catalog 可复用，观察前的签名 open 仍可能测长；new/changed entry 再读取首行。持全局 catalog gate，可能拖慢会话列表 |
| `archive_session_threads`、`unarchive_session_threads`、`prepare_session_delete_confirmation`、`delete_session_threads`、`create_session_recovery_archives`（同文件:43/58/73/88/112） | 安全 preflight/resolve → catalog | 后续 mutation/归档正文采用普通文件，但**前置目录核对**仍可唤醒压缩签名/首行，不能因最后操作拒绝 zst 就认定整条链无解码 |
| `acknowledge_attribution_safety`（commands/dashboard:1806）及成功 owner 后的 storage maintenance | 打开精确索引及其 migration | 旧 revision 的 fork/paginated metadata 探测可读首行；通常同一 owner 已完成 marker，maintenance 不会再次做迁移探测。不能因入口只做确认/维护就忽略首次 open 成本 |
| 必要数值同步中的 stage 完成/恢复/导入 | `build_staged_full_rebuild → validated_staged_full_rebuild → import`（exact_usage_index:6112/6762/6903） | 压缩 stage 再验证会新开 reader，seek 到逻辑终点再 EOF，即使 metadata 稳定、不额外算 SHA 也会完整解码；导入前再验证又可能一遍。漂移时还需 opened/path 的旧 prefix hash。属于必要安全证明的复用优化，不能直接删除验证 |

Rust 的旧 `message_links::repair` 在 Full 主来源表示关联之前也运行：旧 plain→zst、available binding 缺 prompt、receipt 缺失时可先整源 marker scan/hash，再由主同步撤销绑定。已有 numeric checkpoint 和开启7天排行均不能阻止这个前置工作。Summary 不执行这项 Full repair。

前端触发也须分开：`useDashboardData:1012` 主窗口和 `useCompactPanelSnapshot:142/172` 激活后立即调用 Summary，再按设置间隔刷新；`useDashboardData:1035–1090` 的 aggregate cadence 强制 Full，跳过前置 source probe；`useCompactPanelAggregate:43` 在5/10/15/30分钟边界触发 Full。会话目录是 workspace 打开、手动刷新/重试及操作后刷新（SessionManagementWorkspace:242/486/539/606/632），没有定时 catalog 全扫。不能把 source probe 写成所有刷新必经，也不能把目录风险写成后台每秒触发。

Rust 正式解析、空源/来源类型识别、fork/replay migration、catalog 首行、表示 raw proof、append prefix/chunk、stage 再验证、message markers 与 prompt/assistant 片段均经 `rollout_source.rs`；未知长度测量可能附加在上述任何 open 前。声明长度正常帧与同物理版本暖布局不走完整测长。正式必要扫描不能用简单“不解压”替代，否则未统计消费会遗漏。

另有必要证明的去重机会：`revalidate_metadata_only_file`（exact_usage_index:10045）按 `[首块, 尾块, 中间块]` 验证。压缩源至少3块时，先解码到尾再倒退中间重置，最后 EOF 补尾，约两遍逻辑正文解码，虽然每块 SHA 只计算一次。此路径限同长度物理变化且无法 complete metadata reuse、有 checkpoint 的正式复核；稳定相同物理观察不走它。压缩源改为升序 chunk 可保留完整证明、减少至单遍，普通源可保留首尾快速排错。

### Rust 直接 reader 调用点覆盖

74个文本匹配包含 reader 实现/测试/路径识别，独立审查识别出19个生产 `open/from_file` 调用点，按以下类别全部覆盖：

- exact_usage_index.rs：2979（必需 enrichment）、6112（stage）、6706/6762（旧 stage metadata/完整复验）、9521（正式 source）、10192（发表 committed 集合）、10379（漂移 append）、14991（旧 replay）、17083（catalog）、17565（通用 signature）、17619（漂移 prefix）、18221（可重启旧 stage）。
- session_parser.rs：474（message links）、674（range excerpt）、1117（legacy subagent 首行）。`:714` full-result helper 为 cfg(test)，不算生产入口。
- exact_usage_index/ledger.rs：124（旧 partial tail）、157（format）；representations.rs：141（原文 full proof）；empty_sources.rs：43（空普通源转换竞态）。
- 已有 handle 的 append audit、首行 cursor 恢复、chunk/prefix hash、EOF 也覆盖；state/index/stage/receipt SQLite 路径使用通用 signature 时实际为 Plain，不是压缩历史读取。HTTP GzDecoder 为响应 gzip，不是 rollout zstd。

## 已核对的无自动 zstd 解码入口及边界

| 接口/模块 | 结论与边界 |
|---|---|
| Rust `read_dashboard_snapshot`（commands/dashboard:1583） | startup cached aggregate/peek identity；miss 走 state_sqlite。没有因 miss 自动转 Full decoder 的隐式路径 |
| Rust `read_cached_dashboard_snapshot`、`read_sidebar_trend`、精确 progress | 已有投影/进度；不运行 history decoder。后续前端精确请求是另一条链 |
| Rust `rebuild_precise_index_for_current_version`（commands/dashboard:1739） | 当前实现立即拒绝自动删除式恢复，保留旧索引；没有 open/decoder 或自动重建。不能按命令名推测执行行为 |
| 两端实时速率/运行中会话、Swift unread fallback | 普通 File/FileHandle + SQLite/现有摘要；Rust live-rate 精确摘要 cache miss 给空值/警告，不创建同步 owner。Swift RunningThreadScanner 仅接受存在的普通 jsonl。没有自动解压；旧逻辑路径变为 zst 时可能缺数据/回退，不等于透明支持压缩 |
| 额度 HTTP、额度周期历史 SQL、价格计算、更新器/诊断展示 | 本身不创建 rollout decoder；由已有统计触发的界面更新不能反向推断它们要读正文 |
| Auto-resume 的额度 tick / app-server 调用 | Token Bar 不从这些调用创建 history decoder；Codex 自身处理只读/恢复追加时可按上游规则解压。这属于外部 Codex 行为，不能声称 Token Bar 策略能阻止 |
| Swift 会话正文页/删除恢复包 | `compressedContextUnsupported` 或普通 pinned 文件；不透明展开 zst。不要为了“全部兼容”顺手添加全文件解压 |
| Rust `read_session_context_page`（session_management command:27） | 当前普通 File 与普通 metadata fallback；不调用上述 catalog decoder。压缩只读正文不透明支持 |
| Markdown 导出/工作区移动/provider repair | 现有普通文件读取/重写路径，没有另一套隐藏 zstd reader；导出由用户发起。逻辑 plain 不存在会失败；直接 zst 路径不保证正确解析。不把无解压等同功能兼容。Rust mutation 的 catalog preflight 单独见上表 |
| provider 备份/恢复归档 | 显式复制/校验/ZIP操作；Swift Data(contentsOf:)可全载归档成员，但不调用 rollout zstd decoder。ZIP恢复与自动冷历史解码是不同成本，不能漏报大文件内存，也不能误称每轮自动解压 |
| watcher/source discovery/路径归一化 | 路径与属性观察本身不解码；后续 dirty/sync 可触发读取。Rust 非标准 Home 注册 zst 的事件 predicate 缺口仍待修，不能用反复全文轮询补漏 |

检索还核对了 JS bridge resource 读取（Swift DeleteBridge:1805/1813/1824/1832），读取的是注入 JS 模板，非聊天正文；HistoryIndex:1411/7270 的 FileHandle 是 SQLite/stage fsync，非 rollout。认证/配置 JSON、保存的 snapshot、frame 依赖实现与测试匹配也未当成新外部解码入口。

## 收束顺序与验收

1. **先切断轻量路径的完整测长**：probe、Swift snapshot signature、Rust catalog observation 用物理观察+已关联可信 logical size；未知返回 unknown/changed，正式数值 owner 做必需解析。首次布局检查与正文解码分别计数，不仅观察“hash调用数”。
2. **可选冷正文在最底层统一挡住**：实际 preferred zst 在 message-link repair、排行 proof、片段 reader 创建前延期；不能只在最后7天集合挡一次。设置关闭后现有 zst 同样需该保护；保留标题/数字，未完成 receipt 如实保留。
3. **必要读取去重**：同源片段单个向前 reader；解析/现有证明 pass 保留首尾小窗口，避免 signature 尾 seek 重复前缀；目录首行不要为同一版本反复打开。保留 handle/path 稳定性、合法 prefix 与真实 EOF 区别。
4. **控制尾延迟和故障反复**：可选正文有界单行/批次、取消；证明短锁取计划、锁外处理、短事务复核。失败物理版本有界重试/退避。这些是整改目标，当前尚非全部实现。
5. **原3项正确性缺口一并验收**：Swift stage EOF、单来源错误隔离、Rust 非标准 Home zst notify；不要以性能短路绕开账本安全。

验收至少跨：声明/未知长度、暖/冷进程、设置开/关、完整/未完成索引、旧 available NULL prompt、plain→zst→plain追加、双表示、坏尾帧、多帧、巨大单行及同源多个片段。断言稳定完整冷源重复 probe/compact/full/catalog 的可选 decoded bytes=0、whole-source hash=0；真正新消费仍由必要解析精确入账。对同源与其他健康来源分别检查取消、故障及锁等待。

本文件保留的是基线生产调用点与上层接口审查。后续产品代码、新增工作量回归和同 SHA 云端检查见实施记录；客户 Windows 性能与恢复仍为 NOT_RUN。不能把基线源码风险写成已发生的客户卡死，也不能把旧 CI 通过写成最新整改验收。
