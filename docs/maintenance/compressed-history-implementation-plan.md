# 压缩历史读取的最小改造方案

2026-10-05。基线 `16711ea208e111ba6711c11094626f26b795c3c4`。状态：**核心改造已实现，云端回归记录单列**。调用点依据[入口审查](compressed-history-read-entrypoints.md)，行为约束依据[冷存储策略](compressed-history-cold-read-policy.md)。具体提交、验收及未扩大的范围见[实施记录](2026-10-05-cold-history-implementation.md)。下文保留设计规则，实际边界以实施记录为准。

## 目标及判断规则

完整可信、物理版本稳定的压缩来源，日常探针/快照/摘要/排行/目录不解码正文、不做整源哈希；数字、标题及已经安全保存的信息复用旧索引。未统计的数据和真实变化仍交正式统计处理。schema14、原 source ID、decoded-byte checkpoint、原消费账本继续使用，不进行全库重建。

mtime 从文件系统读取；声明逻辑长度来自帧布局，两者仅作为数值来源关联条件，不能认证正文。普通文件存在时优先普通；设置关闭不会展开已有 zst，所以是否延期正文按实际选中的物理表示判断。

| 当前情况 | 检查/处理 | 正文解码 |
|---|---|---|
| 已登记压缩表示、物理观察一致、可信完整数值覆盖与必需 parser/enrichment 已完成 | 直接取已保存 logical size、断点和数字；旧原文 proof 状态维持原样 | 无 |
| 可信完整 plain 旧账首次转 zst | 正式 owner 一次结构检查；受支持单帧声明长度、原 mtime、前后物理稳定性与旧覆盖匹配时登记 metadata_only、撤销未认证 raw bindings | 不解码正文；初次结构检查有块遍历成本 |
| 首次表示关联但未声明长度/多帧/条件不满足 | 轻量接口返回 unknown/changed，不测长；正式 owner 按既有解析/核对处理 | 必要时有 |
| 从未索引、旧 checkpoint 不完整、必需数值迁移待完成、真实来源变化 | 定向正式扫描该来源；成功后保存新的覆盖和物理观察 | 必要时有，不扩成全库重建 |
| 可选 prompt/assistant/原文 proof 请求且当前 preferred 表示是 zst | 自动读取延期，使用已有安全结果、标题和数字；缺失问答保持缺失，不写完成 receipt | 无 |
| zst 恢复为 plain 并追加 | 复用逻辑身份，按现有旧 prefix/chunk 证明与断点增量处理 | 普通正文读取；只新增实际消费 |
| 来源损坏/不可读/转换不稳定 | 保留上次可信数字；诊断记录物理版本和阶段，沿用 owner/刷新节奏 | 可选来源在同批内不重复验证；未新增跨批次物理版本失败缓存 |

“检查命中索引”前不能创建会暗中测长的 reader，否则短路失效。mtime/大小相同但物理身份/变化标记不同，不能按稳定版本直接复用。

### 双表示同时存在：上游确认与具体规则

重新核对保存的官方 `rust-v0.160.0` / `a956835d020762cb2b570053af06f643a11c0ecc` 五个源码文件，SHA256与原抓取清单一致。

- 压缩发布：[compression.rs:908–932](https://github.com/openai/codex/blob/a956835d020762cb2b570053af06f643a11c0ecc/codex-rs/rollout/src/compression.rs#L908) 先 persist 压缩产物，再复核源状态并删除 plain。两步之间会共存；remove_source失败或在两步之间退出可能保留两个文件。后者是调用顺序推演，非本轮崩溃实测。
- 恢复追加：[compression.rs:153–168](https://github.com/openai/codex/blob/a956835d020762cb2b570053af06f643a11c0ecc/codex-rs/rollout/src/compression.rs#L153) 先发布 plain、更新元数据/同步，再删除 zst；同样有共存窗口及删除失败残留的可能。
- 原来就有 plain：[compression.rs:119](https://github.com/openai/codex/blob/a956835d020762cb2b570053af06f643a11c0ecc/codex-rs/rollout/src/compression.rs#L119) 直接返回，不清理同名 zst；压缩 worker 遇已有 zst也跳过（:838）。不能依赖下次运行一定自动清理残留。
- 官方目录枚举跳过有 plain sibling 的 zst（:1293）；普通/压缩读取优先 plain（seekable_reader.rs:21，compression.rs:1306）。不是比较mtime后选更新者，也不会全文比较两份正文再决定。
- 官方测试 `rollout_file_from_path_hides_compressed_sibling_when_plain_exists`（compression_tests.rs:200）覆盖隐藏 sibling 的枚举规则；测试源码已核对，本轮未编译官方工程。

实施规则：

1. 同逻辑路径的两个表示只保留一个 source ID，普通优先；扫描枚举去重，不拼接、不双计、不合并两份事件。
2. plain 存在就按普通来源的索引/增量规则处理，不能因为旁边有 zst而跳过活跃正文；不为比较双表示额外解码 zst。
3. plain 不可读、不安全、损坏或比原可信账更短，不静默选择 zst覆盖旧账。继续普通路径的安全核对/诊断与历史保留策略，不把坏正文当新零值。
4. 只在 plain 确实不存在且压缩来源符合安全准入时读取/复用 zst。开读后或提交前 preferred 表示/身份变化，则本次计划失效，重新解析实际表示；不将两份来源的断点混用。正常持有句柄的旧快照可供只读使用，但不能绕过新数值发表的路径/代次稳定性检查。
5. 不由 Token Bar 自动删除所谓“多余”zst或plain；双表示本身不等于数据损坏。临时 `.tmp` 文件不当正式来源。保留现有ledger与decoded checkpoint，plain恢复需要raw proof的情况仍执行相应验证。

验收补充：双表示内容相同/不同、plain比zst长/短、mtime相同/不同、plain损坏/不可读、压缩发布中断、materialize发布后未删zst、reader选zst后plain出现。断言选择规则与官方一致、计数只有一份、不额外解码zst做比较、来源转换不发表混合代次。Swift/Rust reader当前已实现基本plain优先，改造重点是让所有新轻量入口和optional冷门沿用同一preferred选择与前后稳定性检查。

## 第一组：拆开物理观察与逻辑读取

增加语义明确的轻量观察函数：只解析 preferred 普通/zst 路径、stat/fstat、身份/ChangeTime/ctime、物理大小与 mtime，**不创建 zstd decoder**。返回 storage kind 与 physical observation，physical size 不放进 decoded-size 字段。

索引层增加复用判断：用逻辑路径查询已有 source/representation/observation，检查完整 checkpoint、当前必需 revision/pending 状态及物理版本。匹配则返回可信 logical size；不匹配返回 unknown/changed，不能退回现有测长函数。小查询或同步本轮一次加载的 sources map 共用，避免每来源再加载全目录。

| 替换位置 | 改法 |
|---|---|
| Swift `SourceFileObservation.read(at:)` / `sessionCacheKey` / `sessionTreeSignature` | 拆出物理观察；snapshot 验证用索引提供的 logical size；未知明确使缓存未验证，不通过 compactMap 丢掉来源制造假 unchanged |
| Swift synchronize 的 `sourceSignatureMetadata` 前置分支 | 先查稳定已关联完整来源，再决定是否需要正式 reader/测长；需要正文的分支继续用原严格签名和发表验证 |
| Rust `read_only_source_probe`、scan estimate、`sources_changed`（含 Summary→Full） | 用轻量观察结果对比已发表索引；unknown 使正式 owner 接管，250ms 内不调用 eager-measure `RolloutReader::open` |
| Rust `process_session_file` / `representations::reuse_complete` | 将稳定已关联复用提前到 reader 打开之前；新表示关联仍在正式 owner 通过受支持布局及前后观察核对，不直接用 mtime 猜内容 |
| 两端 catalog signature | 复用当前物理版本对应的已有 catalog 元数据/可信 logical size；未知不要为展示目录先完整测长 |

轻量探针 unknown 不当扫描失败、不当来源缺失，也不清除原账；正式 owner 的真实失败仍停止新精确结果发表。未知源扫描成功后下一轮匹配物理版本，不再测长。首次单帧结构检查在正式 owner 进行并区分工作量，稳定关联后不用每轮检查块头。

## 第二组：统一可选冷正文门

在 message-link repair、排行引用/proof、prompt/assistant reader 创建前共用一个判断：actual preferred storage 为 zst 时，不自动读取。检查必须在 `file_signature`（Rust 会隐式测长）、`logicalSize`、hash 和 reader open 之前。

- Swift：`repairMessageLinks`、`turnSourceReferencesExclusively`、`hydratingTurnExcerpts` 的片段阶段。
- Rust：`message_links::repair` 的前后两次入口、`verify_excerpt_source`、`visit_source_range_lines`。
- 是否七天排行仍按现有设置；冷正文门独立于设置。设置关掉后可恢复历史数字排行，不自动展开尚存的 zst。
- 冷源的 optional receipt 保持未完成，但不阻止已经完整的数值账本复用；不把“问答缺失”当 model/accounting 必需 enrichment。
- 可选来源错误只影响该来源，其他健康摘录照常返回；数据库/代次异常和必要数值扫描错误仍上抛。

此组不增加“加载压缩历史”按钮、不生成展开临时历史、不引入全文缓存。已有界面的标题/数字照常使用，暂缺摘录不冒充空会话或零消费。

## 第三组：目录与操作前置检查

Rust catalog 展示先读 state DB/已存 catalog；稳定冷源用缓存 metadata，不为了目录标题解码。没有可信缓存的冷来源导致本轮目录刷新延期，保留上次目录并关闭不安全操作；本轮不新增占位条目。不能为了补标题自动全文测长。

归档/删除/恢复包的安全前置检查不能把缓存标题或旧首行视为当前身份认证：先确认所选目标实际表示与当前安全策略。当前只支持普通正文的目标继续要求普通 pinned source；压缩目标提前报告不支持，避免先为整个目录解码再失败。全目录枚举和必要唯一性检查保留，普通/压缩的安全拒绝不得因优化被绕过。

Swift catalog UI 当前 plain-only，不顺手扩大支持范围；底层观察函数使用同一成本规则，覆盖转换竞态，保持不完整枚举时原目录保留和危险操作关闭。

## 第四组：必要读取去重与已知缺陷

1. **Rust chunk 顺序**：压缩来源按 offset 升序做完整 chunk proof，避免 `[首,尾,中间]` 倒退重置；所有 chunk、真实 EOF、前后物理稳定检查照常。普通源可保留首尾快速排错。
2. **Swift 首尾 probe**：必要解析/hash 同时收集原首尾小窗口；物理观察未变时复用该 pass 结果，避免路径/handle 再取尾4KiB导致重复前缀解码。物理变化仍执行原 prefix 核对，不能删发表保护。
3. **stage 重复校验**：同一 owner 内刚完成 full hash/chunks + EOF 且物理观察未变，可用短寿命验证结果复用到导入；绑定 source、物理版本、parser/stage artifact、校验范围和期望 hash。提交前重新核对 opened handle 与 canonical path。进程重启、来源变化、验证范围不一致均失效；持久 stage 恢复先做一次必要验证，再在本 owner 复用，不能因 stage 存在就省 EOF。
4. **片段去重**：仍需读取的普通来源按文件合并/排序 prompt 和 assistant 范围，一个向前 reader 分发结果，避免多次打开/读同一范围。可选读取限制单行/批次资源与支持取消；数值 parser 不因显示预算跳过消费。
5. **三个确定缺陷**：Swift reusableStage 补压缩终点认证（区分合法更长 prefix）；Swift 单来源异常隔离；Rust 非标准 Home 内已认可 zst 的 create/modify/rename/remove 事件识别。
6. **锁范围**：优先用冷门消除可选压缩全文 proof 持锁；剩余显式/普通 proof 如仍昂贵，再实施短锁取计划、锁外验证、短事务复核。不能直接去掉现有锁；没有必要把此并发重构作为全部冷门生效的前提。

失败重复的实际范围：沿用现有 owner/single-flight/刷新 cadence，Rust 的失败重试间隔和手动刷新规则不变；可选源的验证结果在本批共用。不新增按物理版本跨批次缓存的退避，也不新增持久失败账本；后续若实测有持续昂贵失败，再单独评估。不能拿 optional 延期来伪造精确发表成功。

## 实施顺序与验收

先实现第一至三组及三个确定缺陷，切断自动旁路；再做第四组必要读取去重。每组是可审查的一阶段，不将新的全文缓存、按钮或索引迁移混进去。按同源码 SHA 运行云端 Swift、Rust macOS/Windows、前端回归；不恢复本地大型编译缓存。

工作量测试比墙钟时间更可靠：本轮给 reader 增加按测试线程隔离的 open、structure blocks、decoded bytes 计数；结合终点损坏、预算拒绝及前后描述符检查断言验证安全性。未新增 hash bytes、最大 RSS 或每类 proof pass 的独立全局计数。检查以下行为：

- 完整稳定 zst、设置开/关、冷/暖进程：重复 probe/fast/compact/Full/catalog 的正文 decoded bytes=0、whole-source hash=0；数值与标题保持。
- plain→原生 zst：一次结构关联，无正文 hash；optional NULL prompt 不触发补全，也不写假 receipt。
- unknown/multiframe/未索引/不完整：轻量路径不测长；正式必要扫描正确统计，成功后稳定轮次复用，失败保留旧账。
- Summary→Full、操作 preflight 和 source 失败重试都单独测试，避免只测排行接口。
- zst→plain→append、双表示、坏尾帧、source 变化、stage 重启/导入：身份/断点一致，不重复消费，错误不提升 proof。
- K≥3 的必要压缩 chunk proof 单向解码；同源多个片段只读取合并范围；健康+坏源、巨大单行、取消和锁等待覆盖。

真实 Windows 客户卡顿、升级恢复、签名安装另行验收。实现已提交，云端检查及遗留边界见实施记录；本轮不发布安装包。
