# 压缩历史冷读取：实施与验证

日期：2026-10-05。基线 `16711ea208e111ba6711c11094626f26b795c3c4`，代码分支 `codex/cold-history-read-paths`。

初次实施代码和测试 SHA：`29c84923a543eed21b35c9f91672e6e140cdcdcf`。产品实现位于 `99acca5e`、`5409141d`；`035279a5`、`fb098230`、`29c84923` 修正回归测试的时序、临时目录和标准消息/追加输入。初次实施同 SHA 云端检查：[CI 37313120365](https://github.com/hututuo/codex-token-bar/actions/runs/37313120365)，最终状态 **PASS**。已下载并核对 `ci-passed-29c84923a543eed21b35c9f91672e6e140cdcdcf/checked-source.json`，其 source SHA、run ID 和 passed=true 与该 run 一致。本文只记录代码实施；没有合并、签名、安装或发布。

发布前两位 GPT-6.1 Sol Max 独立复审补上路径转换/悬空分类、Swift实际缺失错误码、重复metadata打开、缺失leaf父目录alias及catalog witness key问题。最终代码/测试 SHA `1c1e624e90319d7c8e80509817cf526bfce86b54`，七项同 SHA CI 全部通过，详见[复审及最终证据](2026-10-05-sol-max-prepush-audit.md)。下文测试数量是初次实施历史证据，不替代复审版本验收。

## 判断规则与数据保留

保持 schema14、逻辑 `.jsonl` source ID、解码字节断点、旧消费账本及既有迁移。没有第二账本、全文缓存、持久解压历史或新的加载按钮。

| 情况 | 本轮行为 |
|---|---|
| 普通和压缩同时存在 | 普通优先；只统计一个逻辑来源，不解码压缩副本比较内容 |
| 普通文件存在但不安全或不可读 | 诊断并保留可信旧结果，不静默退到压缩副本 |
| 完整可信的冷来源，物理观察未变化 | 轻量探针、签名、稳定同步复用已存逻辑大小和断点；不创建解码测长工作 |
| 未登记、物理变化、不完整断点、必需数值 enrichment 未完成 | 轻量入口返回 unknown/changed；由正式统计处理需要的来源，不把它视为缺失或零值 |
| 可选问答、旧 message-link 补全、原文引用遇实际压缩表示 | 在创建 decoder/proof 前延期；保留数字、标题，缺失问答不冒充补全完成 |
| 恢复普通文件 | 沿用原 source ID；需要时验证旧 chunk/prefix，再恢复绑定或增量追加，不重计旧消费 |
| 来源读取或校验失败 | 保留可信账本、断点和已发表投影；可选错误隔离到该来源 |

mtime 来自文件系统，官方压缩器保留原 mtime；帧声明的是原始长度。二者允许旧数字的表示关联，不能证明正文逐字节相同。实际文件身份/ChangeTime/ctime 等变化标记仍必须匹配。

双表示规则与固定官方 Codex CLI `rust-v0.160.0` / `a956835d020762cb2b570053af06f643a11c0ecc` 一致：发布压缩文件后再删除普通文件、恢复普通文件后再删除压缩文件，所以有正常共存窗口，也可能有删除失败残留。详见[方案中的上游依据](compressed-history-implementation-plan.md#双表示同时存在上游确认与具体规则)。Token Bar 不自动清理任何一份用户历史。

## Swift/macOS 改动

- `SourceFileObservation.readPreferredPhysical` 只选择安全 preferred 路径；plain 用单次 lstat 提示、zst 核对 stat/fstat；逻辑大小与物理大小分开。
- 精确索引一次 SQL 查询持久完整来源 witness，由调用端核对一次当前物理观察；`sessionTreeSignature` 和同步前置签名复用同一物理版本的逻辑大小。未知来源保留在签名集合，不能通过丢掉条目制造假 unchanged。
- 旧 message-link repair 与排行引用在实际 zst 的冷门处停止，独立于压缩设置。Swift 原文验证用单条来源查询，避免逐来源加载整张 sources。
- 普通摘录按文件共享 pinned reader、prompt offset 去重及 assistant 区间合并。引用携带验证时的物理观察；读取前后核对描述符与路径，暂存输出只在整个来源稳定后合并。
- 可选来源的 I/O、变化和 proof 错误只跳过该来源；SQLite、取消及数值扫描错误仍保留原上抛规则。
- 必要解码 pass 保留最多首尾各 4 KiB 的小窗口；物理版本一致时复用 probe，避免再 seek 到尾部重复解码前缀。没有保存全文。
- 暂存复用补齐真实压缩 EOF 校验，包括损坏的零输出尾帧。刚完成 parser/hash/EOF 的 owner 内证明可短期复用，绑定来源签名、prefix hash、stage 文件版本和 artifact ID。重启、物理变化或另一份 stage 不继承该证明。
- catalog 只复用同一物理版本且可复用的冷条目；未知冷来源不为标题解码，刷新延期并保留原目录。Swift UI 仍采用已有普通文件准入，不扩大压缩正文操作能力。

## Rust/Tauri/Windows 改动

- source probe、扫描数量估计、`sources_changed`（包括 Summary 提升 Full）改用轻量签名；未知长度无可信索引/布局缓存时返回 unknown，不先完整测长。
- discovery 的 unknown candidate 保留，不能当 missing/incomplete；完整来源观察一次 SQL 加载，避免每来源单独查整库。
- 稳定完整 compressed 来源的复用移动到正式 reader 打开之前；首次表示关联、未知或真实变化仍走原正式验证。
- Full 前后 message-link repair、原文 proof 和排行摘录都按实际 preferred zst 提前延期。设置仅继续控制七天排行范围；关闭设置不会自动读取尚存的压缩正文。
- 普通摘录把同源 prompt/assistant 请求排序并合并区间，一份 pinned descriptor 读取后分发结果；验证回调在读取前后核对描述符，外层再核对当前路径。
- `metadata_only` 普通源恢复原文时，旧全 chunk/EOF 证明通过后记录当前观察并恢复绑定。同长度、恢复 mtime 但物理变化的已认证来源不显示旧 offset 正文；可选查询不改写上一代正式绑定。
- 必需 compressed chunk proof 按 offset 升序，避免先尾块再倒退中间导致第二遍解码。普通文件保留首尾快速排错。
- stage 验证复用只在同一 owner 内，继续检查 manifest/parser/counts/size/文件版本；重启后先做必要 EOF 验证，不因 stage 存在就省略。
- watcher 覆盖 Home 内已认可的非标准目录 `.jsonl.zst` 创建/变化/改名/删除；Home 外的来源仍拒绝。
- catalog 没有可信冷元数据时延期本轮刷新，保留原目录及危险操作安全门；不自动读首行补标题。

## 成本与安全边界

稳定完整冷来源的零正文读取是按准入条件成立的结论。初次原生帧结构关联仍要检查块头；初次未声明长度、多帧、旧迁移或真正新消费可能有必要的解码、hash 和解析成本。

普通可选摘录限制单行 1 MiB、单来源批次 8 MiB；超限来源的问答延期，数字和其他来源保留。Swift 失败读取也消耗本批预算，成功读取按实际字节退款。数值 parser 不使用这些显示预算，不因此漏计消费。

原有 owner/single-flight/刷新 cadence 和失败重试规则保留。本批内共享同来源验证与摘录结果；没有新增跨批次的坏物理版本缓存、持久退避账本或锁外 proof 并发重构。必要的普通完整证明仍沿用原锁策略，不能把本轮称为所有大文件最坏时延都有上限。

## 验证记录

| 检查 | 状态 / 范围 |
|---|---|
| Root 集成核对与 `git diff --check` | PASS；未修改索引版本和数值账本结构 |
| Swift 语法及 reader/observation 聚焦 typecheck | PASS；未恢复本地大编译缓存 |
| 独立 GPT-6.1 Sol xhigh 复审 | PASS / SOURCE_CONFIRMED；物理观察、单来源隔离、预算、owner-local stage proof；代理未运行测试 |
| Swift 全套测试及发布脚本契约 | PASS；1658 项测试，7 skipped，0 failure；契约 103 项，102 passed，1 skipped |
| Rust/macOS | PASS；1202 passed、10 ignored、0 failed；两万文件压力回归通过 |
| Rust/Windows 与 Windows 打包脚本 self-test | PASS；1153 passed、10 ignored、0 failed；两万文件压力回归及 self-test 通过 |
| 前端与云端脚本契约、生产构建、生产依赖审计 | PASS；1170 + 11 项测试、0 failed；构建和 audit 通过 |
| Windows updater 故障回归 | PASS；启动失败、锁定覆盖、带空格/中文的目录及快捷方式修复 fixture |
| 同 SHA 云端证据 | PASS；CI 37313120365 及 checked-source.json 已核对 |
| 真实历史性能、客户 Windows 压缩恢复与文件锁交互 | NOT_RUN |
| 打包、签名、安装、升级、发布 | NOT_RUN |

新增回归包括：稳定 unknown-length 冷索引的 probe/sync/Full 零 decoded bytes/structure blocks；unknown 损坏来源在 discovery 中不解码但仍保留候选；设置关闭也不读冷问答；catalog 冷元数据复用；坏零输出尾帧的 stage 恢复拒绝；同来源重复摘录合并；巨大显示行/描述符漂移拒绝；非标准 Home watcher；同长度恢复 mtime 的正文变化及安全恢复。

每测试线程隔离记录 reader open、decoded bytes、structure blocks。没有新增全源 hash 字节、最大 RSS 或独立 proof pass 的计数；不将合成测试耗时当客户性能指标。旧版本迁移、重复计数、断点、压缩损坏和账本保留回归继续由完整 CI 执行。依赖实际旧版导出备份、真实 Home 或外部服务的 opt-in 测试仍 skipped/ignored；不把这些合成回归当实际旧客户端升级恢复通过。

修正前的失败与被取代的检查均保留记录：

1. [37308598559](https://github.com/hututuo/codex-token-bar/actions/runs/37308598559)，`99acca5e`：Rust 摘录使用的旧 proof 缺少当前物理版本门；修正在 `5409141d`，变化后的正文拒绝显示。
2. [37311031488](https://github.com/hututuo/codex-token-bar/actions/runs/37311031488)，`5409141d`：两项 Rust 新增测试未创建临时目录；原回归将“正式 owner 已验证绑定”错误当作“仍等待 lazy proof”，错误要求 optional 查询撤销正式绑定。`035279a5` 修正 fixture/时序，并保留变化正文拒绝和 120 tokens 不重计断言，新增恢复后的摘录检查。Swift 新 stage 测试把 120 改写为无证明的 127，现有账本正确保留 120，测试却期待覆盖；`29c84923` 改为保留旧字节前缀再追加 7，用 `append_ready=0` 迫使 full stage，验证合法恢复后 127，不改生产账本准入。
3. [37312043161](https://github.com/hututuo/codex-token-bar/actions/runs/37312043161)，`035279a5`：Rust macOS 为 1201 passed / 1 failed / 10 ignored；仅合并摘录的新 fixture 缺时间戳，被标准消息解析器拒绝，`fb098230` 补齐。该 run 和等待中的 [37312762224](https://github.com/hututuo/codex-token-bar/actions/runs/37312762224) 已被更新的源码检查取代并请求取消，不能作为全 CI 通过证据。

基线风险与调用点保持在[入口审查](compressed-history-read-entrypoints.md)，实际策略见[冷存储策略](compressed-history-cold-read-policy.md)，设计与未扩大的范围见[改造方案](compressed-history-implementation-plan.md)。
