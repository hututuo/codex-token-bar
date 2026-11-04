# 稳定修复接手复核

日期：2026-11-04（Asia/Shanghai）。用户明确要求：这一版先修掉前面连续错误并收束稳定，下一版再处理遗留优化。本文是当前入口；早期调查和失败日志保留，不能将历史中间状态当成当前结论。

本轮从 `0a125e15d692ce9233b54a464eca3dea475e5c4d` 新建本地分支 `codex/stabilize-recovery-20261104`。工作树为 `/Users/huyiyang/.codex/worktrees/tokenbar-integrated-recovery/codex-token-dashboard`；原项目目录的 `codex/cold-history-read-paths` 及未提交资料保留。本轮不更新正式数据库，不安装、重启、推送、合 main 或发布。

本地实质修复固定为：`6699894a`（旧 state 读取与 panic 通知验证）、`40435567`（日志脱敏与故障隔离）、`9bbff0fc`（完整报告、实际测试执行及反向门禁）、`b3cba9ae`（第二独立审查发现的五组遗漏）。中间 `4aba703c` 是首次资料收束，第二独立审查后继续修复；`b3cba9ae` 之后的收束仅更新文档。最终 HEAD、逐文件摘要与实际日志由 `scratch/integrated-recovery/stabilization-20261104/final-verification.json` 记录。它是本地稳定候选源码的收束点，还不是新的已发布安装版本。

## 原始故障与接续修复

| 阶段 | 问题与原因 | 已接入的处理及证据边界 |
|---|---|---|
| 0.9.7 搬迁，0.9.9 升级失败 | cache 原件与 support 活动副本并存；搬迁元数据、后续新增账目使整库证明不同，发现器将正常接续当冲突 | 识别搬迁凭据、来源身份和历史覆盖；不能按 mtime 选赢家或相加两个副本。见 [双旧库诊断](2026-10-31-dual-legacy-ledger-diagnosis.md) |
| 0.9.10 再次失败 | 额度维护时钟前进、Exact 合法补全、原文不可用及旧 v1 批次接续等状态未完整区分 | 窄口径接纳已知变化、事务内保护目标独有新账，保留原始冻结材料。用户脱敏包没有真实 SQLite，合成复现不等于受影响 Windows 现场验收。见 [0.9.10 跟进](2026-11-01-0910-migration-followup.md) |
| PR6／PR7 整合 | 非法事件通道、旧额度字段、旧 stage、外部 state 被冻结导入、结果接收和补全进度等问题分散在不同分支 | 已逐项整合，保留 A/B 所有权、只读 admission、固定暂存池、可接续恢复。不能整份叠加冲突实现。见 [16 项映射](2026-11-02-integrated-recovery-progress.md) |
| PR8 增补 | 重试候选不能证明覆盖旧账、活旧库路径别名、pending 历史、JSON 键序、Unicode 路径碰撞、Windows 8.3／混合分隔路径 | 最终适配到 `28a0dc6a`，其双端常规、公开 0.9.7 升级及八路形成状态检查通过。八路使用历史 Rust producer，不是原生 Swift 历史 producer 或完整 App 验收。见 [PR8 增补](2026-11-03-pr8-recovery-supplement.md) |
| build991 首次维护崩溃 | 首次后台 timer 回调继承 MainActor 隔离，实际 App 约 34 秒后 trap | `c5e3714d` 显式 `@Sendable`；build992 在本机跨过崩溃窗口并继续更新。Windows 候选任务仍有一条冷读取 2 秒超时，整组 failure 保留。见 [崩溃记录](2026-11-03-stage-maintenance-startup-crash.md) |
| build992 后源码接续 | Claude 本地速度／标题、缓存时效计价、Desktop 本地额度在后续提交中继续变动 | 这些是 source-only 增补，不能再写“c5 后仅文档”。额度代码 `b82c042c` 有定向双端证据，未安装。见 [Desktop 本地额度](2026-11-04-claude-desktop-local-quota-integration.md) |
| 本轮复核 | 实时会话和 Mac 统计备用入口仍假定新 state 字段齐全；测试只覆盖了带齐字段的“最小表” | 先以旧表实际运行复现，再补逐列兼容、NULL、时间单位、标题来源及只读保全测试。具体见下文 |

2026-11-04 再次只读核对：main 仍为 `d831ae41`，PR6 `41058ffe`、PR7 `faa06a5b`、PR8 `3cbd383f` 的头部未变且仍开放。三个 PR head 本身不在当前祖先链中，因为采用的是逐项适配；已适配的 `02c493fa`、`28a0dc6a`、`c5e3714d`、compaction `f5b7358e` 和 Desktop quota `b82c042c` 均为当前基线祖先。不能仅凭未做整份 merge 判断修复遗漏。

## 本轮确认的产品遗漏

外部 `state_5.sqlite` 的上游初始表没有 `first_user_message`、`preview`、`updated_at_ms`、`thread_source`、`name`；它们是后续逐项添加的。现有 Exact 账本 metadata 已做兼容，但同库的独立消费者没有全部覆盖：

- Rust `live_rate/state.rs`：会话列表硬读 `first_user_message`／`preview`／`updated_at_ms`，单条与批量标题也强制首条消息列；可空文本却读为非可空字符串。旧格式实际报缺列，NULL preview 实际报 `InvalidColumnType`。
- Swift `LiveRateMonitor+Database.swift`：实时会话排序强制毫秒字段；`archived = 0` 漏掉 NULL 标志的行。
- Swift `CodexUsageAnalyzer+StateSQLite.swift`：统计备用读取、统一刷新、标题和插件读取仍强制这些可选列及 `reasoning_effort`。从原源码抽出的六条 SQL 在旧表上四条缺列失败，两条 COUNT 成功。

修复只改变只读查询：按实际列投影，保留已有字段，缺少可选内容以 NULL 表达；时间先归一到毫秒，避免已有毫秒值再乘千，新的毫秒列为空时仍读取旧列。Swift schema 检查和行读取位于同一只读事务。缺必需字段继续失败，不能制造成功空账。没有 ALTER 外部表、新 schema、parser revision 或历史重算。

新增测试覆盖两端各 16 种可选列组合、秒／毫秒／只有毫秒／NULL 回退、归档与子任务筛选、正式标题与首条消息区别、缺必需字段、源文件读取前后不变。真实生产读取函数直接参与测试；小模块结果和完整产品模块结果分别记录。

第二独立审查另发现有效 SQLite 缺少 `threads` 表时，Rust rollout 读取会把空 schema 当成缺可选列并返回成功空集合。`b3cba9ae` 让空 schema 明确报 `missing threads table in state database`；合法空 `threads` 和旧格式缺可选 `rollout_path` 仍维持原合同。新增真实入口回归修前 1 失败、修后通过，同时核对源文件字节不变。

Swift 完整测试编译另外暴露既有 `MultiClientCacheRankingTests` 的 `Int??` 泛型断言不匹配。将查询值和首行明确 `XCTUnwrap` 后比较，空行或 NULL 仍失败；不以零默认值使两个缺失值“相等”。此项只修测试编译，不改产品排名逻辑。

独立审查还实际复现了诊断脱敏遗漏：Swift 不展开 `userInfo`，但错误描述、原因、路径及底层错误仍可含凭据；Tauri 的对象键过滤和 Bearer 过滤也漏掉普通错误字符串中的 URL 密码、API key、Basic 和 Cookie。根在两端格式化出口补已知凭据语法脱敏，先脱敏再截断，Tauri 在 JSON 转义前逐字段处理，保留普通路径、错误码、Token 数量及原因链。Swift 四个新测试在修前产生 19 条失败断言；Tauri 两个新测试修前失败，修后通过。测试仅用合成值，没有证据表明曾发生真实凭据泄露，也不将语法过滤说成能识别所有无标签秘密。

日志通知也实际存在反向干扰：观察者抛错会打断其他观察者，`console.warn` 失败会从记录函数逃逸。按回调逐项隔离后，独立三个反例从失败变为通过；真实 `command.ts` 的三种调用方式在故障观察者和输出端下仍分别返回成功值、fallback／null 或抛出原始失败。测试以合成 native bridge 驱动实际前端模块，没有触发真实操作。成功结果携带的 diagnostics／warnings 同样改用已脱敏、有界、能处理循环对象的 formatter；原 JSON.stringify 路径有单独的修前失败日志。

## Windows 超时与反向门禁

历史任务 `41615273400` 实际失败点是：注入 panic 后，要求下一次包含 unread、文件和 tokenizer 工作的完整冷 snapshot 在两秒内结束。该测试没有在 panic 发生时建立一个已经等待的 reader，因此不能由它单独判定条件变量通知正确，也不能由超时断言认定是生产死锁。

本轮将两项行为分开：真实 snapshot 必须重新取得 claim 并完成，检查 refresh_count；另一个同步测试用持锁发送信号和原子 condvar wait 建立已经等待的 reader，在注入 panic 后要求通知及 claim 清除。没有改生产等待预算或放宽原来的两秒通知时限。历史 Windows 失败原因仍不能由本机通过完全解释，新 Windows 包级复测仍待完成。

用户另行要求一个普通 Astra Max 会话独立审查所有门禁、补负控与日志。会话 `01a1a65f-de0a-7520-983c-e9e2330036f4` 负责工作流／检查脚本／独立测试，根负责产品修复和最终复核。该审查须证明删除安全判断会被拦住，且检查跳过、报告缺场景、源码错配、旧 PASS 遗留等假绿路径；结论以其 [独立记录](2026-11-04-adversarial-gate-audit.md) 为准，不能将独立会话的存在本身当成质量证明。

独立审查已交付：旧生产报告门禁只剩两条并发检查仍能通过，已改为完整既有场景集合及关键事实；成功文件只在最终校验通过后产生，失败保留原始输出与 FAIL 判定。Swift／Rust 关键安全测试要求真实执行，Node 空文件／TODO／零测试及要求执行却跳过的测试会被拒绝。标准 CI 成功封条排除 Claude 局部模式，明确区分未请求与已请求的升级／压力矩阵。删除旧账覆盖判断的源码变异确实使合成 300 变为 100／299，删除通知／claim 清除及给结构化日志增加自由文本字段也都被测试抓住；抽取模块的边界见独立记录。

根在最终复核门禁时继续发现并修复三个具体缺口：SwiftPM 多测试包被最后空包遮盖、Rust ignored 逐项记录未与摘要核对、仅 HEAD 相同仍可夹带 tracked 源码修改。新负控先失败后通过；Swift 按各已完成 bundle 汇总并处理真实 stdout／stderr 行交错，完整实际日志的 100／67／14+1 skipped／9 结果均被正确接收。指定源码 SHA 的执行拒绝运行前 tracked 修改，运行后再次核对 HEAD 与 tracked diff；本地 WIP 则记录 diff 摘要和 dirty 状态，不能冒称仅基线 SHA 的结果。

用户随后要求第二个普通 Astra Max 会话与根互补审查。会话 `01a1a6aa-7d49-7380-a278-2d37054dc8dd` 从原始故障与代码重新检查，并在 `4aba703c` 独立复现五组 P2；其 [独立报告](2026-11-04-second-independent-review.md) 保留修前证据与修后复核的阶段区别。除上述缺表之外，根补修如下：

- Node 分别记录 suite skip／TODO，并拒绝只有空 suite 的测试文件；含其他通过测试不能替代本文件执行。允许的可选平台跳过仍显式计数，`--no-skips` 拒绝跳过整个 suite。
- Swift 已开始的 suite／case 必须有完成记录；没有完成 bundle 或顶层 suite 不能退回 class 摘要。末尾合法空 bundle、真实输出交错及既有完整日志仍被接受。
- exact SHA 模式前后拒绝未跟踪且未被 Git 忽略的输入；仅对明确列出的产物放行并写入证据。CI 例外限于三份 production 报告和 `visual-previews/*.png`；包装器自身的日志／判定路径自动记录。本地 WIP 仍可执行，但记录未提交差异和未跟踪输入。这是源码身份检查，不宣称隔离了一切动态构建输入。
- 两端脱敏覆盖 `OPENAI_API_KEY`／`ANTHROPIC_AUTH_TOKEN` 等带前缀赋值，TS 也处理对象键内的 URL，使用无原型对象保留 `__proto__` 普通数据键。普通 Token 计数、路径及错误码正控保持。任意双重编码的 Swift 错误文本仍属已知语法边界，尚无固定产品来源，未扩大本版解析范围。

这些永久回归先在修前运行：Python 新增检查产生 7 条失败（其中一条为尚无输出例外接口，其余为错误接收的反例），Node suite 三项失败，TS 两项失败，Swift env 8 条失败断言，Rust 缺表一项失败。根修后已通过。第二会话在 `b3cba9ae` 用原输入独立复核，五组已复现遗漏全部关闭；17 个涉及文件前后摘要一致并逐份匹配该提交。正常测试、合法空表、optional suite skip、明确许可的输出和全 tracked 的真实 Cargo 正控仍通过；详见其报告末尾及 `second-audit/recheck-b3cba9ae/summary.json`。

## 验证记录

以下是本轮已执行的源码验证；不代表稳定安装包已发布或 Windows 现场已验收。

| 检查 | 本轮实际结果 |
|---|---|
| 旧代码反例 | Rust 生产 state 小模块 6 项中 5 项失败；Swift 旧实时读取确实缺列／漏行；原 Mac dashboard SQL 四条缺列。日志保留 |
| Rust 完整产品模块编译及相关执行 | 实时统计从 167 增至 168 项，最终通过；此前多客户端 53、恢复 26、PR8 8、路径身份 12、启动 6、额度历史 5 项通过。只运行选定过滤范围，无跳过，平台为本机 macOS |
| Swift 小模块 | 实际存储／读取源码 19 项通过；外围未用依赖有 stub，不替代完整产品编译 |
| Swift 完整模块 | 实时／多客户端／存储 100 项、历史恢复 67 项、错误详情／历史日志／独立隐私 9 项通过；第二轮最终源码绑定的相关组 23 项通过。以上均零失败、零跳过；另一次日志隔离组合 14 通过、1 性能 profile 明确跳过。组合之间有重复，不累加成唯一用例数 |
| 前端 | 最终本机 Node 24.13.1 全前端 1,421 项通过，零跳过／TODO／空文件；运行前后 537 个 src 文件和两个执行脚本（共539）摘要一致。TypeScript／Vite 构建通过；此前 1,419 项独立证据保留 |
| Python 检查器／工作流合同 | 初始 24 项、独立版本 90 项、首次根复核 94 项后，第二轮全套 97 项通过，零跳过；不是历史 producer 矩阵重跑 |
| 反向门禁与日志 | 旧账覆盖／通知／claim 清除／日志字段四类源码变异均命中；第二独立线程再次删除 notify／clear 均失败。最终 Node 24 全部 scripts 111 通过＋1 Windows 环境跳过，cloud 包含于其中，不重复累计 |
| Windows／安装包 | 本轮新代码未在 Windows 执行，未打包／安装；历史 failure 继续保留 |

本机证据目录：`scratch/integrated-recovery/stabilization-20261104/`。包含旧失败、新日志、原始 Windows failure、分支祖先清单及源文件身份；最终清单为 `final-verification.json`，先前清单保留为 `final-verification-pre-second-review.json`。独立清单另为 `gate-audit/review-evidence-manifest.json`、`second-audit/review-manifest.json` 及第二报告标明的修后清单。目录不入 Git，文档保留可重跑入口和范围说明。初次格式检查和中间测试失败原样保留；最终状态由清单的文件身份和范围确定。

最终实质提交 `b3cba9aefbb458803357730864d6c87a67a71b38` 经真实执行包装器验证：Swift 23、Rust live_rate 168 项通过，零跳过；执行前后 HEAD 相同、tracked diff 为空、未许可未跟踪输入为空。对应 `second-swift-exact.execution.json`／`second-rust-exact.execution.json`。之后仅文档收束不重跑无关产品测试，最终清单核对产品文件与被测提交一致。

收紧后的解析器再次接受既有真实日志：本轮各组计数不变；历史完整 Swift 2,271 通过＋36 skipped、Mac Rust 1,695 通过＋14 ignored 被接受，原有失败的 Mac／Windows Rust 日志仍拒绝。仅去掉 hosted 传输时间戳和 ANSI 包装，未改测试结果；这是历史日志解析正负控，不能算新的跨平台执行。

本轮直接产品验证命令（在本文工作树执行，输出保存到上述目录）：

```sh
swift test -j 3 --filter 'LiveRateStateCompatibility|StateDashboardCompatibility|BusinessSnapshotRetry|CodexBusinessDatabase|ExactStageMaintenance|MultiClientCacheRanking|MultiClientUsage|ClaudeDesktopQuotaHistory|ClaudeLocalQuota|MultiClientQuotaAutodiscovery|MultiClientProduct|IntegratedClientPresentation'
swift test -j 3 --filter 'Incident0910MigrationRecovery|BusinessDatabaseMigration|PublishedLedgerAdmission|PublishedModuleRead|ExactStagePoolCrash|RecoveryDiagnosticsTests'
swift test -j 3 --filter 'DiagnosticErrorDetailsTests|DiagnosticLogHistoryTests|RecoveryDiagnosticsPrivacyTests'
CARGO_PROFILE_TEST_DEBUG=0 CARGO_PROFILE_DEV_DEBUG=0 CARGO_BUILD_JOBS=3 CARGO_INCREMENTAL=0 cargo test --locked --offline --manifest-path tauri-app/src-tauri/Cargo.toml --lib core::live_rate -- --test-threads=1
node scripts/cloud/run-node-tests.mjs tauri-app/src --no-skips
npm --prefix tauri-app run build
```

Rust 其余六组使用同一命令，过滤项依次为 `multi_client_`、`core::business_store_recovery`、`pr8_recovery_tests`、`path_identity`、`core::business_startup`、`core::quota_history::database`。SwiftPM 会在后续空测试包再输出零项汇总，统计以各测试包实际执行记录为准，不能只取日志最后一条，也不能重复累加嵌套 suite。

## 收束方法与下一版边界

这一版保留经过证明的 A/B 结构与已适配修复，按故障类型统一检查读取入口和恢复状态。相同输入无变化重开、合法历史接续、失败保留现场、目标独有事实保护继续是约束。每个补丁都要有坏输入反例和相同源代码的相关测试；报告应验证实际执行项与最终结果，不能只数测试名或看父任务成功。当前不再铺新存储架构。

下一版留存事项：

- 大批补全写锁、Rust 总耗时、无变化 P95、Windows 日志开销及隐藏／唤醒资源优化。原压力 Swift 最长写锁 284.589 秒，Rust Mac 737.853 秒／Windows 1093.275 秒，P95 1.237～2.883 秒及日志 6.413% 的 FAIL 保留；本轮没有重测为达标。
- 旧物理数据库、重复备份和 schema11 rollback 的安全回收；需所有权、内容与恢复引用证明，现阶段保留。
- Claude 缺少缓存时效时按订阅默认 1h 的规则：目前缺可靠的订阅／API 身份区分，尚未实现。HTTP 磁盘额度缓存 provider 仅调查，尚未接入。
- 更完整的真实用户 Windows 恢复与安装验证、原生 Swift 历史 producer 范围、跨平台完整包级验收。它们是剩余验证边界，不能被性能延期豁免或写成已经通过。

本轮不将“所有未知错误都消失”作为承诺。源码修复、自动化、安装和用户现场验收分别报告；正式稳定版本号及发布需在最终源码和打包证据明确后另行决定。
