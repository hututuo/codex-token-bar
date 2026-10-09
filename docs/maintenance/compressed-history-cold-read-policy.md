# 压缩历史的冷存储读取策略

日期：2026-10-05。审查基线：main `16711ea208e111ba6711c11094626f26b795c3c4`。
参与：root 与 GPT-6.1 Sol xhigh，分别审查后交叉核对。

本文记录基线审查和实现约束。2026-10-05 已完成本轮产品改造，实施细节和同 SHA 云端检查状态见[实施记录](2026-10-05-cold-history-implementation.md)。保留 schema14、现有消费账本、来源身份、分块证明及字节断点；后文的基线缺口不能作为最新代码状态。

所有已追踪的上层接口、自动触发条件及 reader 调用点见[读取入口与成本审查](compressed-history-read-entrypoints.md)。其中补充 Swift fast snapshot 的缓存前测长、Rust 会话目录及操作前置核对、首次帧结构遍历和必要 chunk 校验的重复解码；不能仅修排行就宣布全入口不唤醒冷源。

## 1. 上游源码支持的判断

对照固定的 Codex CLI `rust-v0.160.0` / `a956835d020762cb2b570053af06f643a11c0ecc`，本轮重新核对保存的源码及其 SHA256。该版本不是未来所有 Codex 版本或任意第三方压缩文件的保证。

- [compression.rs:336](https://github.com/openai/codex/blob/a956835d020762cb2b570053af06f643a11c0ecc/codex-rs/rollout/src/compression.rs#L336)、[:947](https://github.com/openai/codex/blob/a956835d020762cb2b570053af06f643a11c0ecc/codex-rs/rollout/src/compression.rs#L947)：候选普通文件的最后修改时间至少过去7天。不是创建时间，也不是“最近没有被查看”。发布前另有源属性复核及 writer/publication 协调，正在使用的写入器可阻止转换。
- [compression.rs:874](https://github.com/openai/codex/blob/a956835d020762cb2b570053af06f643a11c0ecc/codex-rs/rollout/src/compression.rs#L874)：压缩产物保留原 mtime；原始长度由 encoder 声明。mtime 不在 zstd 帧头中。
- [seekable_reader.rs:21](https://github.com/openai/codex/blob/a956835d020762cb2b570053af06f643a11c0ecc/codex-rs/rollout/src/seekable_reader.rs#L21)：普通表示优先，普通路径不存在才读取压缩副本。
- [compression.rs:65](https://github.com/openai/codex/blob/a956835d020762cb2b570053af06f643a11c0ecc/codex-rs/rollout/src/compression.rs#L65)、[seekable_reader.rs:44](https://github.com/openai/codex/blob/a956835d020762cb2b570053af06f643a11c0ecc/codex-rs/rollout/src/seekable_reader.rs#L44)：只读历史可以直接解码 zst。seekable reader 也能使用匿名临时解码快照，不改变 Home 内的持久表示。因此 zst 存在不能证明用户从未打开、读取或检索过会话。
- [compression.rs:117](https://github.com/openai/codex/blob/a956835d020762cb2b570053af06f643a11c0ecc/codex-rs/rollout/src/compression.rs#L117)：为追加 materialize 时先发布普通 JSONL，再移除压缩副本；展开阶段仍保留旧 mtime，实际追加才产生新的数据变化。出现普通文件本身不等于已经新增消费。

因此，**Token Bar 将实际压缩表示作为可选正文读取的冷存储标记，而不是“用户当前没打开”的行为证明。** 实际活跃写入与增量统计按物理表示及可观测的大小、mtime、身份/变化标记判断。无需监视用户窗口或读取正文来猜当前页面。

## 2. 如何选择当前来源

同一 Home、同一逻辑 `.jsonl` 路径与 source ID，按当前磁盘状态选择一个来源：

| 磁盘状态 | 选用表示 | 行为 |
|---|---|---|
| 普通 JSONL 可用，含普通/压缩同时存在 | 普通优先 | 沿用普通源处理；压缩副本不另计一次 |
| 普通不存在，压缩副本为允许的普通文件 | 压缩 | 可选正文默认延期；可信历史优先复用 |
| 两种表示正在转换 | 重试解析表示并核对物理观察 | 不把瞬时不存在当历史删除，不把过期路径绑定给新来源 |
| 普通存在但不可读、路径不安全、来源异常 | 保留旧可信结果并诊断 | 不偷偷退到一个可能过时的压缩副本，也不当作空数据 |
| 两种表示都缺失且已可靠确认 | 原文不可用 | 保留历史消费，撤销原文可用性，沿用现有 missing 策略 |

身份/变化标记采用各平台已有物理观察：Unix 的设备/inode/ctime 等；Windows 的文件身份/ChangeTime 等。修改时间相同不是内容相同的证明。保持现有 Home 包含关系、注册来源认可及符号链接安全检查。

Codex state DB 常仍保存逻辑 `.jsonl` 路径，设置关闭后已有 zst 也不会因此展开。**不能用 state 路径后缀或压缩设置代替实际文件解析。** 每个读取入口必须复用同一选择规则。

## 3. 冷存储优先复用可信索引

目标：稳定、已完整索引的压缩历史，在探针、日常刷新、排行问答补全中正文解码字节为0；数字、标题、模型、轮次、时间等从已有索引/已有 metadata 读取。

### 已关联且物理观察没有变化

- 复用原 source ID、logical size、checkpoint、ledger、已知标题及数值投影。
- 用 watcher 事件和既有轻量刷新节奏检测变化；必要的物理 stat/fstat 保留。
- 不为“确认仍然冷”解码、不重新计算全来源 hash、不重新扫描帧块、不测量未知逻辑长度、不补全历史问答。
- 帧布局/长度与内容证明结果绑定到物理观察；稳定时复用，变化时失效。帧布局缓存不等于正文缓存。

### 首次从普通表示转换为压缩表示

已有来源必须具有可信完整消费/断点，满足当前 parser、迁移及影响数值可信性的必需 model/accounting enrichment 与 pending 准入条件；受支持的原生单帧结构、声明逻辑长度、原 mtime 与完整旧索引相容，前后物理观察稳定时，可一次轻量关联后保留旧数字。

可选 message-link/问答 receipt 缺失不阻止完整数字旧账复用，也不能伪标补全完成。不得把可延期的摘录补全当成统计准入条件，从而重新全文解析冷来源。

表示变化会改变物理身份，**不要求先做全文 hash 才能保留旧账**；否则冷存储复用失去意义。登记 `metadata_only`，撤销尚未认证的旧原文绑定，不晋升 `verified_full`。长度/mtime/结构是来源关联证据，不是正文逐字节证明。

### 表示不明、来源变化、未索引或索引不完整

轻量探针只返回 changed/unknown，把必要统计交给正式 owner。未声明逻辑长度不能在 probe 中先全解码测长；有匹配物理观察的可信旧 logical size 可直接复用。

正式统计仍按既有流式解析、旧分块/谱系及账本核对处理需要的新覆盖；**不能因 zst 被分类为冷存储就跳过未统计消费，或只用旧数字冒充新的精确覆盖**。unknown-length、多帧、真实追加/改写等所需解析保留，不重建全部旧索引。

失败保持上一份可信发表结果和断点，报告来源/阶段/原因；不发表部分新账，不生成删除墓碑。本轮沿用原有 owner/single-flight、定时刷新及失败重试节奏；可选摘录在一批内复用单来源验证结果，失败不逐条重验。未新增跨批次的“失败物理版本”缓存或持久失败账本，不能宣称进程间完全不重试同一坏源。

## 4. 所有可选读取入口遵守同一策略

**可选压缩正文不自动唤醒的规则独立于压缩设置。** 设置仍按已实现的产品契约控制“排行仅7天活跃”的集合与说明；关闭设置可恢复历史数字/标题排行，已有 zst 的正文仍默认延期。不要借性能修复无条件修改排行范围。

基线待收束的入口（实际修改和边界见实施记录）：

| 入口 | 基线缺口 | 目标 |
|---|---|---|
| Rust 只读 source probe/预扫描估计 | `file_signature → RolloutReader::open`可因未知长度全解码，250ms只在文件之间检查 | 首先物理观察与可信索引匹配；unknown 不解码测长，交正式统计 |
| Rust 旧 message-link repair | Full pre-scan 可在表示关联/撤销绑定前，为旧缺失 prompt 关联全源解码/hash | 冷压缩源的可选补全延期或按需求执行；不伪标 receipt 完成 |
| 两端排行 prompt/assistant 摘录 | 跳过 zst 目前主要受设置驱动；关闭后已有 zst 可反复解码 | 根据实际 preferred 表示，在创建 decoder/proof 之前决定延期；数字和标题保留 |
| 原文 proof | 整源证明仍可能占用 Home/index owner | 显式需要时单源处理，短锁取计划、锁外校验、短事务复核后提交 |
| Swift source lookup | 每个选中源加载整张 sources | 使用已有单条 SQL；避免解码无关 checkpoint/state |
| Swift signature probe | 尾4KiB seek可能重复整前缀解码 | 在必要解析/hash pass复用小首尾窗口，保留handle/path稳定性保护 |
| watcher 与缓存 | 非标准 Home 目录的 zst 被 predicate 漏掉 | 与 scanner 复用格式识别；create/modify/rename/remove使同源观察失效，避免盲扫正文 |

“延期”是可选原文未加载，不是来源删除、零消费或数据损坏。已有安全可复用的标题/数值无需正文重建。不得仅将 reader 移入缓存，却仍为每轮片段从0解码。

显式原文读取如需引入产品入口，另按实际 UI 范围实现；当前没有已上线的“加载问答”按钮。工程契约为同源 offset/range 去重、排序、单次向前读取，有界单行/批次内存、支持取消；完整证明时将已有 chunk 校验、EOF 与所需短摘录合成同一次 pass。失败/取消不提升 proof、不恢复不可信绑定，不影响其他健康来源的可选摘录。数据库/代次异常及统计扫描继续遵守安全失败规则。

## 5. 恢复普通文件并继续写入

探测到普通表示后优先选普通文件，仍使用原逻辑 source、消费账本及 decoded byte checkpoint，不增加另一份来源或重复加旧消费。

- 同大小、保留 mtime 不能证明正文前缀相同。恢复原文须沿既有 chunk/prefix 与前后物理稳定性验证。
- 追加沿既有准入、尾块/轮换审计、解析状态及账本去重规则；需要完整 prefix 证明时仅核对该来源，不触发全库 hash。
- 合法更长来源验证的是旧 prefix，不把旧长度当当前 EOF；完整压缩内容证明必须消费真实终点，拒绝坏零输出尾帧。
- 原文缺失/转换失败仍保留历史数字；跨 Home/同名不同来源不能仅凭路径尾部或 UUID 自动合账。

## 6. 基线审查与本轮修复状态

已完成：基础压缩兼容 `dc372744`；恢复原文与追加保护 `b231f69e`；设置驱动的活跃排行/缓存契约 `edb2e862`。Windows 更新链路 `16711ea2`不包含以下修复。

基线的3项确定缺陷现已修复，并增加对应回归：

1. Swift `reusableStage → contentHash`漏压缩 EOF；必须接在现有 hash reader 上，并保留合法更长 prefix 政策。
2. Swift 一个来源的 I/O/解码 proof 异常让整批摘录失败；只隔离可选来源错误，数据库错误仍上抛。
3. Rust watcher 漏 Home 内标准目录之外的 `.jsonl.zst`事件；补齐已认可来源的 dirty/连续性覆盖。

同源普通摘录合并读取、Swift 单来源查询、轻量探针 unknown、不唤醒冷 message-link repair、必要扫描首尾窗口复用和阶段证明复用也已实现。剩余普通原文完整证明仍沿用原锁策略；本轮没有实施锁外证明并发重构。原文缺失不影响已有数字，巨大显示行/批次受预算约束，数值 parser 不受显示预算限制。

不增加新 schema、第二账本、持久展开历史或全历史正文缓存。本轮不实施旧提案中的加载按钮和全文 LRU；实际可选显示预算为单行 1 MiB、每来源批次 8 MiB，数值 parser 不使用这项预算。

## 7. 必要验收

验收以工作量与结果断言为主，不使用合成 wall-time 倍数作为客户性能指标：

1. 已完整索引的稳定 zst：压缩设置开/关都保持旧数字/标题；多次 probe/full refresh 的可选正文 decoded bytes=0，whole-source hash=0。
2. 旧 plain→zst、NULL message links、旧可用 bindings：Full pre-scan不唤醒可选补全，数字/断点不变，不伪标补全 receipt。
3. unknown-size冷布局：轻量probe不完整解码测长，返回changed/unknown；正式必要解析仍正确统计。
4. zst→plain→append、双表示并存：相同logical ID，只加入新增消费；旧 prefix变化被拒绝或按既有核对处理。
5. stage完成后来源转换并接坏尾帧：复用/导入拒绝，旧账与断点保留；合法重试只计一次。
6. 可选原文健康+坏来源：健康摘录仍可用，坏来源有界诊断；统计扫描不因隔离而漏掉失败源。
7. 非标准Home目录的普通/zst创建、改名、删除：watcher覆盖一致；Home外仍拒绝。
8. 同源多片段、巨大单行、取消及并发更新：解码去重、内存有界；同源变化不能晋升过期proof，下一数值owner可继续；无关变化不强迫全历史重读。

此前真实聊天进度回查、联合源码审查及小型组件复现（Rust10/0）属于基线证据。最新产品改造与云端回归记录独立列在实施记录，不能用旧 CI 代替。真实历史性能、Windows 用户恢复/安装仍为 NOT_RUN；尚未打包或发布。
