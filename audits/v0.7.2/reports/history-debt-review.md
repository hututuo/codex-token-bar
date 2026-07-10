# Codex Token Bar v0.7.2 历史债务考古审查

- 审查角色：历史债务考古 reviewer（只读调查）
- 审查日期：2026-07-10
- 产品发布基线：`v0.7.2^{commit}=e48930a626679230d5d52267c830812f254fdd26`
- audit 集成起点：`origin/main=04124ea5f7d731024496b7b8441d7fec96cc0540`
- audit 工作树 HEAD：`c7050b0537ea64a55dfcd04ceabf2f353a63bc9a`

## 结论摘要

- **P0：0 项。**
- **P1：4 项。** 其中 3 项 confirmed，1 项 suspected。
- **P2：4 项。** 其中 2 项 confirmed，2 项 suspected。
- **P3：2 项。** 其中 1 项 confirmed，1 项 suspected。
- 历史上最频繁维修的“总/今/次、增量缓存、额度解析、实时速率准备态、Radar 调度、未读跨 Home、图表跳动、发布元数据”大部分已经有结构性收口；当前主要剩余风险集中在：**Tauri 修复备份的 SQLite 一致性、fork replay 的时间启发式、Tauri Codex Home 切换未驱动所有数据域刷新、Swift/Tauri 共用额度历史库却使用不同计划身份**。
- `v0.7.2` 到 `origin/main` 只有 1 个提交，产品源码没有变化，差异仅为两份发布 ledger。因此下面的产品 finding 同时适用于发布 tag 与当前 audit 集成起点。
- 本轮没有读取 `audits/v0.7.2/reports/` 下其他 reviewer 的报告，没有构建、启动 App、运行会触发编译的测试、提交或推送。

## Findings First

### P1-01 confirmed：Tauri Provider Repair 的 SQLite 备份不是一致快照，回滚还主动丢弃已复制的 WAL

**代码证据**

- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/core/provider_repair/backups.rs:29` 到 `:48`：Tauri 用普通 `fs::copy` 分别复制 `state_5.sqlite`、WAL 和 SHM；WAL/SHM 复制错误被 `let _ = ...` 静默忽略。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/core/provider_repair/backups.rs:117` 到 `:136`：回滚只恢复主库，随后删除当前 WAL/SHM；备份目录中的 `state_5.sqlite-wal.before` 和 `state_5.sqlite-shm.before` 从未恢复。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/core/provider_repair/backups.rs:209` 到 `:217`：底层确实只是裸文件复制，没有 SQLite backup API、checkpoint 或事务快照。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/core/provider_repair/backups.rs:246` 到 `:251`：备份 ID 只有秒级时间戳，同一秒内两次操作会复用目录。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/core/provider_repair.rs:42` 到 `:66`：JSONL、SQLite、session index 依次改写，不是跨介质事务，备份是失败后的唯一完整安全网。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/Sources/CodexTokenBar/ProviderSyncEngine+Backups.swift:8` 到 `:22`、`:43` 到 `:55`：Swift 使用“秒级时间戳 + UUID”命名，并用 `VACUUM main INTO` 生成一致 SQLite 快照。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/Sources/CodexTokenBar/ProviderSyncEngine+Backups.swift:139` 到 `:151`：Swift 回滚先清 sidecar，再恢复一致主库。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/core/provider_repair_tests.rs:109` 到 `:122`：Tauri 只测试了备份归属校验，没有备份创建、WAL 一致性、恢复内容或 ID 冲突测试。

**历史链**

`ad9b9c9` 已在 Swift 引入一致 SQLite 快照；`68be5c1` 拆出 Tauri 备份时没有迁移该保证。后续 `883d9f4`、`71eae3b` 修的是操作生命周期和过期回写，`b3acbfe` 补的是 Swift 安全路径，`c6bcb2f` 挂载 Tauri 高级入口，都没有触及 Tauri 备份完整性。`git blame` 显示 Tauri 备份与恢复核心从 `68be5c1` 起未再实质修订。

**用户影响**

用户执行 Provider 修复后若后续步骤失败并回滚，未 checkpoint 的 SQLite 数据可能永久丢失；如果复制主库与 WAL 的时点不一致，备份自身也可能无法表达一个有效数据库状态。同一秒重复创建备份还可能覆盖或混合文件，使用户以为存在两个安全点，实际只有一个目录。

**根因状态与兜底性质**

根因没有消失。Swift 由 SQLite 快照结构保证；Tauri 仅靠“通常复制得足够快”和用户手动回滚兜底，现有测试没有覆盖关键风险。

**复现/验证方案**

在一次性临时 `CODEX_HOME` 中开启 WAL 模式，checkpoint 后插入一条仅存在于 WAL 的记录；创建 Tauri 备份，继续改写，再执行回滚，验证 schema、行数和 `PRAGMA integrity_check`。另注入 WAL 复制失败，并在同一秒创建两次备份，确认操作必须失败或生成不同目录。整个验证不应接触真实用户数据库。

**Swift/Tauri 对齐**

不对齐。Swift 有一致快照和唯一 ID；Tauri 两项都缺失。

### P1-02 confirmed：fork replay 的 2 秒启发式会把真实的快速分支调用当成复制历史丢弃

**代码证据**

- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/Sources/CodexTokenBar/CodexUsageAnalyzer+SessionParsing.swift:4`、`:247` 到 `:280`：Swift 在 fork 后进入 replay 跳过状态；只有新 `user_message` 距最后一条跳过 token 至少 2 秒才退出，否则消息和后续 token 都继续跳过。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/Tests/CodexTokenBarTests/CodexUsageAnalyzerTests.swift:377` 到 `:408`：测试夹具明确把 `Immediate branch prompt` 放在 replay token 后 0.5 秒、真实 token 放在 1 秒后，却断言 token/call 都为 0；测试把这项漏算固化成了预期行为。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/core/usage/token_count_jsonl/session_parser.rs:12`、`:150` 到 `:185`：Tauri 使用同一个 2 秒阈值，并在 replay 状态下跳过 token。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/core/usage/token_count_jsonl/tests.rs:149` 到 `:175`：Tauri 也把相邻 `user_message` 判为 replay；`:216` 到 `:244` 只验证了相隔数分钟的新调用。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard/decisions.md:13` 到 `:16`：项目决策仍写着“看到 replay 之后的新 `user_message` 才退出跳过模式”，与当前的“新消息还必须跨过时间阈值”不一致。

**历史链**

`4757ca8` 和 `69c49dd` 建立 Swift fork/cache 口径，`2984513` 区分 fork 与普通 subagent；`e5c7ce1` 把 replay 状态写入 Tauri 增量缓存；`7976b1d` 引入时间宽限；`408020a` 为 Swift 同步密集 replay 规则，并把原本会计入的快速分支夹具改成 0。历史修复成功解决了“复制父会话 token 被重复统计”，但没有可证明的 replay 结束标志，只能在“重复统计”和“真实调用漏算”之间用时间猜测。

**用户影响**

在 fork/branch 后快速发送首个真实问题时，“总/今/次”、会话排行、缓存率和成本估算会永久少一次调用及其 token。用户无法从 UI 判断这是去重还是漏算。

**根因状态与兜底性质**

根因没有消失。当前没有结构化 replay 边界；测试只证明选择了一个折中，并没有证明折中与真实日志语义一致。

**复现/验证方案**

构造含 `forked_from_id` 的 JSONL：复制 token 在 `t=10s`，用户确认是新输入的消息在 `t=10.5s`，该调用 token 在 `t=11s`。当前 Swift 与 Tauri 都返回 0。再分别覆盖 1.999s、2.000s、2.001s 边界，并与真实 Codex fork 日志中的事件 ID、turn ID 或其他可用边界字段比对。

**Swift/Tauri 对齐**

同样存在漏算，但边界仍不完全一致：Swift 用 `>= 2s`，Tauri 用 `> 2s`；Tauri 在没有跳过 token 时还会回退到 fork 起始时间，Swift 不会。精确 2 秒处可产生跨端差异。

### P1-03 confirmed：Tauri 切换 Codex Home 只重载 fast snapshot，没有重新触发 precise usage、quota 和 live thread options

**代码证据**

- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src/state/useDashboardActions.ts:50` 到 `:63`：`reloadInitialSnapshot` 只重载 initial/fast snapshot。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src/state/useDashboardActions.ts:124` 到 `:136`：`updateCodexHome` 和 `restoreAutoCodexHome` 没有递增 `loadGeneration`、`quotaLoadGeneration`，也没有清除旧 quota/thread options。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src/state/loadInitialDashboardState.ts:16` 到 `:46`：initial load 只读 Codex Home、平台能力和 fast dashboard，不读 quota、precise snapshot 或 thread options。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src/state/useDashboardData.ts:69` 到 `:76`、`:169` 到 `:186`：生产 `source` 是稳定单例；只有 `source` 对象身份变化才递增 generations，后端 Home 切换不会改变该对象。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src/state/usePreciseDashboardLoad.ts:30` 到 `:39`、`/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src/state/useDeferredQuotaLoad.ts:30` 到 `:41`、`/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src/state/useLiveThreadOptionsLoad.ts:26` 到 `:39`：三个 deferred loader 都用“当前 generation 已加载”直接返回。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/core/dashboard.rs:33` 到 `:45`：fast snapshot 可能只是匹配缓存或 SQLite 元数据占位；精确 JSONL 扫描属于另一个命令。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src/app/surfaceState.test.mjs:332` 到 `:350`：现有 source-shape 测试只断言 initial reload，不断言 Home 切换会启动三个 deferred loader。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/Sources/CodexTokenBar/CodexUsageStore.swift:56` 到 `:98`、`:118` 到 `:208`：Swift 把 source ID 与 refresh generation 绑定，并拒绝旧 source 结果回写。

**历史链**

`d4d0660` 抽出 Tauri dashboard actions，`49b2cff` 建立 generation 去重，`91a1ce1` 校验手动 Home，`411ef08` 把选中 Home 传给 quota 后端；但前端切换动作从未把“Home 已变化”传播给 deferred generation。Swift 在 `519aebd`、`f8e4e9a` 已修 source-generation 和 live-rate 源切换；`c2e33c7` 只稳定了紧凑面板来源键，没有补上 Tauri 主页面刷新链。

**用户影响**

切到另一个 Home 后，界面可能显示新 Home 名称和 fast/占位数据，却继续保留旧 Home 的账号额度、计划、精确总量或线程选项，直到手动刷新或下一次定时刷新。对多账号/多 Home 用户，这是来源标签与数据内容不一致，而不只是短暂 loading。

**根因状态与兜底性质**

根因没有消失。后端能按选中 Home 读取，但前端依赖 generation 的兼容桥没有被切换动作驱动。自动刷新只是时间兜底，不是来源一致性保证。

**复现/验证方案**

用 mock `DashboardDataSource` 准备 Home A/B 的不同 totals、账号、quota 和线程列表：完成 A 的全部 deferred load 后调用 `updateCodexHome(B)`，断言 B 的 precise/quota/thread 方法各执行一次、旧数据在新结果到达前被标记为 pending/不可归属，并断言 A 的迟到结果不能覆盖 B。

**Swift/Tauri 对齐**

不对齐。Swift 有 source ID + generation 结构保证；Tauri 只对普通 refresh generation 有保证，Home 切换路径漏接。

### P1-04 suspected：Radar full-detail bearer 可从两个客户端静态还原，访问控制取决于“客户端密钥其实可以公开”这一未记录假设

**代码证据**

- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/Sources/CodexTokenBar/CodexRadarStore.swift:53` 到 `:91`：Swift 请求 `/api/v1/current` 并设置 Authorization。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/Sources/CodexTokenBar/CodexRadarStore.swift:94` 到 `:114`：bearer 由随二进制分发的 cipher、mask 和确定性 XOR 逻辑还原。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/commands/codex_radar.rs:7` 到 `:17`、`:51` 到 `:75`：Tauri 内置完全相同的可逆材料和解码算法。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/commands/codex_radar.rs:90` 到 `:99`：测试本身解码并断言 bearer 前缀，证明混淆不是保密边界。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/tauri.conf.json:12` 到 `:16`：WebView CSP 只允许公开 `current.json`/`feed.xml`，但 Rust command 与 Swift 原生网络层仍携带可提取凭据访问 full endpoint。

**历史链**

`3107b21` 在 Tauri 拆分 public summary 与 authenticated full detail；`cf54cb7` 在 Swift 对齐；`086cce9` 修复调度重试。public/full 的传输边界和调度边界已经建立，但客户端凭据从引入之初就是可逆嵌入，后续没有轮换/签发/设备绑定机制。

**用户影响**

如果该 bearer 是服务端秘密或具有写入、昂贵查询、宽速率额度等权限，任何拿到公开 App 的人都可复用它，导致滥用、额度耗尽或被迫全量轮换；一旦服务端撤销，所有已发布客户端的 Radar full detail 同时失效。若它被明确设计为“公开客户端标识”，则不应把混淆描述为隐藏密钥，服务端必须按公开凭据威胁模型限权。

**根因状态与兜底性质**

静态可恢复性是 confirmed；实际安全影响因服务端权限、限流和轮换策略未在仓库中记录，故整体 finding 标为 suspected。当前只是混淆，不是结构性秘密保护。

**复现/验证方案**

在不输出 token 内容的前提下静态执行同一解码逻辑，比较两端结果指纹；由服务端所有者核对 token scope、限流、有效期和轮换能力，并用最小权限测试账号验证匿名复用是否被接受。若它是公开 client token，应记录威胁模型并移除“隐藏密钥”暗示。

**Swift/Tauri 对齐**

两端完全对齐，也因此共享同一个风险和同一个撤销半径。

### P2-01 confirmed：Swift 与 Tauri 共用 `quota-history.sqlite`，却把同一 Plus/Team 账号写成不同 account key

**代码证据**

- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/Sources/CodexTokenBar/QuotaHistoryStore.swift:743` 到 `:746` 与 `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/core/app_paths.rs:3`、`:19` 到 `:20`、`:129` 到 `:131`：两端都使用 `Application Support/CodexTokenBar/quota-history.sqlite`。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/Sources/CodexTokenBar/QuotaHistoryStore.swift:418` 到 `:425`、`:758` 到 `:762`：Swift 对所有有计划标签的 Codex 主额度强制写成 `Pro|codex`，source 为 `swift`。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/core/quota_history.rs:186` 到 `:205`、`:357` 到 `:372`：Tauri 保留实际 `Plus`、`Pro`、`Team`、`Enterprise` 等计划。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/core/quota_history_tests.rs:117` 到 `:150`：测试明确要求 Plus 写为 `account|Plus|codex`，而不是伪造 Pro。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/core/quota_history/database.rs:97` 到 `:109`：Tauri 的旧 Pro 兼容查询只接纳 `source='tauri'` 的伪 Pro 行，因此不会合并 Swift 写入的 `source='swift'` Pro 行。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/Sources/CodexTokenBar/QuotaHistoryStore.swift:628` 到 `:679`：Swift 读取按最新行的 plan/account 筛选，最新来自 Tauri Plus 时也不会自然并入 Swift Pro 历史。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard/decisions.md:29`：项目决策仍规定规范 key 为 `{account}|Pro|codex`，已被 Tauri `c0b877a` 的实现和测试推翻。

**历史链**

`82238a4`、`a576153` 为 Swift 合并旧 key，形成统一 Pro 身份；Tauri 在 `f2eb97d` 建立共享库兼容层，随后 `c0b877a` 为避免“把读取到的 Plus 伪造成 Pro”改回真实计划，但兼容条件只覆盖 Tauri 自己历史写过的假 Pro。两条各自合理的修复链在共享数据库边界发生冲突。

**用户影响**

Plus、Team 等用户交替运行 Swift 与 Tauri 时，5h/7d 曲线、重置后恢复点和消耗估算会分段、消失或只显示最近由当前平台写入的一半历史。当前额度值仍可正确读取，所以问题容易被误判为“历史不够长”。

**根因状态与兜底性质**

根因没有消失。共用物理库是结构事实，但身份 schema 没有跨端唯一规范；两端测试各自通过也无法证明互操作。

**复现/验证方案**

对一次性共享数据库先按 Swift 规则写入 `Plus -> Pro|codex/source=swift`，再按 Tauri 规则写入 `Plus|codex/source=tauri`，分别调用两端 history reader，比较返回点数和连续性。测试还应覆盖 Pro、Plus、Team、计划未知、计划升级/降级。

**Swift/Tauri 对齐**

不对齐，而且冲突发生在两端刻意共用的持久化边界。

### P2-02 confirmed：Tauri “24h”长图已经扩到 30 天 5 分钟点，但 quota overlay 仍只有 24 小时

**代码证据**

- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/core/usage/token_count_jsonl/aggregates.rs:7` 到 `:12`：`recentUsage24h` 的 5 分钟序列在 `be3eca6` 扩为 `30 * 24 * 12` 点。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/core/quota_history.rs:30` 到 `:54`：`quotaHistory24h` 仍固定为 289 个 5 分钟 bin，只覆盖约 24 小时。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src/state/dashboardMergers.ts:43` 到 `:54`、`:106` 到 `:122`：quota 只按完全相同 timestamp 覆盖已有 usage 点；24 小时以前的点保持 quota 空值。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src/components/RecentUsageChart.tsx:28` 到 `:71`：`24h` range 使用该长序列和横向滚动布局，用户可以滚到 30 天前。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/Sources/CodexTokenBar/CodexUsageAnalyzer+Aggregates.swift:22` 到 `:26` 与 `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/Sources/CodexTokenBar/QuotaHistoryStore.swift:290` 到 `:305`：Swift 的 usage 与 quota 5 分钟序列都覆盖 30 天。

**历史链**

Tauri quota 的 289 点常量从 `64a5960`/`7c925f1` 沿用至今；`be3eca6` 为“24 小时长图”扩展 usage 历史，后续 `28d941d`、`389bd2f`、`50c98a3`、`6a2ea48` 修滚动、固定高度和日期可见范围，但没有同步 quota history 长度。

**用户影响**

用户横向查看 24 小时以前的数据时，token 柱/线仍存在，5h/7d quota 曲线却突然消失；选择旧区间做 quota 消耗估算时证据不完整。Swift 同一视图没有这个断层。

**根因状态与兜底性质**

根因没有消失。布局修复是结构性的，但数据契约仍靠字段名 `recentUsage24h`/`quotaHistory24h` 的旧语义，现有各层测试没有建立“长图两个序列时间范围相同”的不变量。

**复现/验证方案**

输入 8,640 个 usage 5 分钟点和当前 289 个 quota 点，合并后断言距现在 48 小时的 usage 点 quota 字段为空；修复后应断言全部 30 天时间轴的 quota carry-forward 规则与 Swift 一致。

**Swift/Tauri 对齐**

不对齐。Swift 为 30d/30d；Tauri 为 30d usage/24h quota。

### P2-03 suspected：Windows Codex CLI discovery 仍绑定 `Codex` 目录名，未覆盖重命名 App 或稳定注册身份

**代码证据**

- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/core/quota/codex_binary.rs:126` 到 `:176`：Windows 只扫描 `.codex` plugin appserver、`OpenAI/Codex`、`Programs/Codex`、`Codex` 和 PATH，没有 `ChatGPT` 目录、注册表/已注册 App 身份或可配置扫描根。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/core/quota/codex_binary.rs:828` 到 `:892`：测试把同一组 Codex 命名路径完整固化，没有 renamed-app fixture。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/core/quota/codex_binary.rs:87` 到 `:119`：同一 Tauri 实现的 macOS 路径已经支持 LaunchServices、应用根扫描、`ChatGPT.app` 和 `Codex.app`。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/Sources/CodexTokenBar/CodexBinaryLocator.swift:9` 到 `:34`、`:45` 到 `:69`：Swift 以稳定 bundle ID `com.openai.codex` 为首选，再兼容两个 App 名称和标准 CLI 路径。

**历史链**

`c838eb1` 扩展 Windows 多实例与桌面安装发现，但仍以 Codex 文件夹名为边界；macOS 在 `d7d1bb6`、`07eb08c`、`a997c03`、`ab11685`、`16327d6`、`cd33b03` 逐步从名字兼容升级到稳定身份校验。Windows 没有经历后半段演进。

**用户影响**

若 Windows 桌面客户端安装在 `%LOCALAPPDATA%\Programs\ChatGPT\...`、使用其他品牌名，且 PATH/override 均无 codex.exe，额度读取会报告“未找到 Codex”，即使官方 App 内实际带有可用 CLI。

**根因状态与兜底性质**

路径依赖是 confirmed；当前官方 Windows 安装路径是否已经触发该条件未在本仓库证据中确认，因此 finding 标为 suspected。`CODEX_CLI_PATH` 只是用户配置兜底，不是自动发现保证。

**复现/验证方案**

在纯单元 fixture 中只创建 `%LOCALAPPDATA%\Programs\ChatGPT\...\codex.exe`，清空 PATH 且不设 override，验证当前 candidate list 找不到；再依据官方 Windows App 的真实注册信息设计稳定发现路径。

**Swift/Tauri 对齐**

macOS Swift 与 macOS Tauri 已基本对齐；Windows Tauri 未对齐该稳定身份策略。

### P2-04 suspected：Windows updater 使用 GitHub `releases/latest`，所谓双平台独立更新通道仍被“最新 Release 必须含 Windows metadata”耦合

**代码证据**

- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/tauri.conf.json:34` 到 `:42`：Windows updater 固定请求 `https://github.com/hututuo/codex-token-bar/releases/latest/download/latest-windows.json`。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/scripts/package_app.sh:11`：Swift Sparkle feed 固定在 raw `main/appcast.xml`，不依赖 GitHub latest release。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src/app/surfaceState.test.mjs:366` 到 `:401`：测试只检查 updater 插件、签名和 `latest-windows.json` 字符串存在，不模拟 latest release 缺少 Windows metadata。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/release-ledger/v0.7.2.md:107` 到 `:115`：v0.7.2 通过统一 Release、先上传全部资产再设 latest 的流程纪律避免了当前故障。

**历史链**

`0f44865` 引入 Windows 自动更新，`5e6ccea` 加固打包，`1ffcb76`/`a1899cb` 完成 v0.7.1 资产流程；`bf837e1` 到 `e48930a`/`04124ea` 在 v0.7.2 用统一发布顺序保证 metadata 存在。历史上解决的是本次发布原子性，没有消除 endpoint 对 latest 标签的结构耦合。

**用户影响**

未来只发布 macOS hotfix、误把无 Windows 资产的 Release 设为 latest，或两平台采用不同 cadence 时，Windows 更新检查会直接 404；已安装 Windows 用户看不到仍然有效的上一版 `latest-windows.json`。

**根因状态与兜底性质**

耦合本身是 confirmed；是否允许平台独立发布属于尚未确认的发布策略，因此用户缺陷标为 suspected。当前只由 release ledger 和人工顺序兜底，测试不保证未来所有 Release 都遵守。

**复现/验证方案**

在测试仓库/本地 HTTP fixture 中发布一个被标记为 latest、但不含 Windows metadata 的 Mac-only release，确认当前 endpoint 404；比较稳定 metadata URL、独立 Windows channel release 或回退到最近含目标资产的方案。

**Swift/Tauri 对齐**

不对齐。Swift feed 与 latest release 解耦；Windows Tauri 与 latest release 强耦合。

### P3-01 confirmed：项目决策与当前实现已有三处直接矛盾，Swift 还保留不可达的 v5 cache 迁移桥

**代码证据**

- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard/decisions.md:15` 与 `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/Sources/CodexTokenBar/CodexUsageAnalyzer+SessionParsing.swift:252` 到 `:257`：决策说新 `user_message` 即退出 replay，代码要求 2 秒。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard/decisions.md:29` 与 `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/core/quota_history.rs:357` 到 `:372`：决策说主额度统一 Pro，Tauri 刻意保留真实计划。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard/decisions.md:36` 到 `:37` 与 `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/Sources/CodexTokenBar/RateAccumulator.swift:350` 到 `:356`、`/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/core/live_rate/stream.rs:389` 到 `:396`：决策说 reasoning 可进入 live rate，两端当前都明确排除。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/Sources/CodexTokenBar/CodexUsageAnalyzerModels.swift:364` 到 `:399`：生产加载先删除 legacy caches，只调用 v6 loader。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/Sources/CodexTokenBar/CodexUsageAnalyzerModels.swift:442` 到 `:467`：`loadLegacyV5SessionCache()` 仍完整保留，但全仓只有定义、没有调用；`:69` 到 `:70`、`:135` 到 `:159` 的 migration 字段与宽松 key 匹配也因此不进入生产路径。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src/pages/dashboard/useDashboardPageLifecycle.ts:4` 到 `:35`：`summaryReady` 永远初始化为 true，`if (!summaryReady)` 已成为不可达 readiness bridge。

**历史链**

这些矛盾来自几条独立修复链没有回写同一决策入口：`408020a` 把 fork 的“见消息退出”改成 2 秒 grace；`c0b877a` 明确禁止 Tauri 伪造 Pro；`d11fe32` 之后两端收紧主 live-rate 类别；`4757ca8` 重做 Swift cache namespace/加载流程后保留了旧 v5 parser；`b5689e2` 从引入 dashboard lifecycle 起就把 `summaryReady` 固定为 true。当前代码和测试各自连贯，但项目决策与遗留桥停在了不同历史切面。

**用户影响**

这组债务目前主要影响维护与审查：后续修复者会依据失效决策“修回”已经改变的行为，或误以为旧 cache 正在迁移；死桥也使启动/准备态测试看起来覆盖了不存在的状态机。它已经在 fork 与 quota 两个 P1/P2 finding 中造成了判断歧义。

**根因状态与兜底性质**

根因没有消失。代码是事实来源，但决策索引和兼容桥没有随实现收口；现有测试分别保护当前代码，不会提醒文档已经反向。

**复现/验证方案**

为三条产品决策建立轻量 contract test 或在决策文件记录 superseded commit；用编译器可见性/引用扫描确认 legacy v5 loader 和 `summaryReady=false` 无生产入口后删除，或恢复真实入口并补迁移测试，二者只能选一。

**Swift/Tauri 对齐**

fork、quota、live-rate 的文档对齐状态不一致；死 v5 loader 只在 Swift，死 readiness bridge 只在 Tauri。

### P3-02 suspected：Tauri 未读已读基线按 Home 分桶已修好，但落盘仍是无锁、非原子覆盖，解析失败会静默重置全部基线

**代码证据**

- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/core/unread.rs:31` 到 `:42`、`:64` 到 `:85`：当前正确地按规范化 Codex Home 存储 acknowledgement。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/core/unread.rs:88` 到 `:106`：读取 JSON 失败直接返回 default；写入使用 `fs::write` 原地截断覆盖，没有临时文件 + rename、文件锁或进程内互斥。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/full-audit-v0.7.2/tauri-app/src-tauri/src/core/unread.rs:109` 到 `:115`：Home key 已 canonicalize，说明当前剩余风险不是跨 Home key，而是持久化完整性。

**历史链**

`096bd37` 引入 Tauri acknowledgement，`dc43a4e` 改为按 Home 分桶，解决了确定性的跨 Home 污染。该格式在 v0.7.2 发布前完成切换，所以“缺旧格式迁移”不是已发布升级缺陷；但写入方式从引入起没有加固。

**用户影响**

若进程在截断后写完前退出，或两个 acknowledgement 并发读改写，文件可能损坏或丢失其中一方更新；下次启动会把解析失败当成从未已读，使大量旧会话重新显示未读。是否存在足够并发入口尚未动态验证，故标为 suspected。

**根因状态与兜底性质**

跨 Home 根因已结构性消失；崩溃一致性只靠写入窗口很短这一概率兜底，错误还被静默吞掉。

**复现/验证方案**

用可注入文件系统在 truncate 后抛错，验证旧基线是否仍可读；并发对 Home A/B 各 acknowledge 一次，断言最终 JSON 同时保留两个桶。建议采用同目录临时文件、fsync/flush 后原子 rename，并保留损坏文件诊断。

**Swift/Tauri 对齐**

未完全对齐。两端都按 Home 隔离，但 Swift 走 UserDefaults，Tauri 自管 JSON 文件且缺少原子写协议。

## 主题考古总表

下表中的历史症状不是按提交标题推断：均回到对应 patch、当前实现和当前测试/fixture 交叉确认。提交 ID 只用来表达修复顺序。

| 主题 | 历史症状与修复链 | 当前实现位置 | 根因是否消失 | 当前保证与复发边界 |
|---|---|---|---|---|
| 总/今/次与缓存 | Tauri 曾出现增量 offset 重读尖峰、残行漏算、旧 cache 口径继续命中；链为 `7dfb3e7 -> ebf5137 -> 7ad60ac -> 603ec38 -> c6fce8e`。Swift 在 `4757ca8 -> 69c49dd -> 657358f -> 69350f2` 收口 session cache 与摘要准备态。 | Swift `CodexUsageAnalyzerModels.swift:20,364-433`、`CodexUsageAnalyzer+SessionParsing.swift:283-319`；Tauri `app_paths.rs:5,72-87`、`token_event_cache.rs:271-304,363-397`。 | **大部分消失。** cache namespace、完整行 offset、累计 total delta 和 signature 都已进入结构。 | 结构保证强于兼容桥；测试覆盖残行、append、cache round-trip。仍受 fork replay 歧义、Tauri Home 切换和单一 aggregate cache 的跨 Home 淘汰影响，但没有发现旧 Home 数据会绕过 signature 直接当新 Home 精确值。 |
| fork/subagent replay | 最初按时间 cutoff 或简单 fork 标记去重，随后出现纯 replay 重复计入、增量续读重开 replay、普通 subagent 被误排除；链为 `4757ca8/2984513/e5c7ce1/7976b1d/408020a`。 | Swift `CodexUsageAnalyzer+SessionParsing.swift:247-319`；Tauri `session_parser.rs:115-230`；两端 cache 保存 replay 状态。 | **未完全消失。** duplicate replay 已收口，真实快速分支仍会漏算。 | 状态持久化是结构保证；“何时退出”仍是 2 秒启发式，测试保护的是折中而非日志语义。见 P1-02。 |
| Codex Home/source switching | 历史上有旧 source 异步结果覆盖、新 Home 未传给 quota、live-rate/compact summary 残留；链为 `519aebd/f8e4e9a/91a1ce1/411ef08/c2e33c7`。 | Swift `CodexUsageStore.swift:56-98,118-208`；Tauri `useDashboardActions.ts:50-63,124-136`、三个 deferred load hook。 | Swift **基本消失**；Tauri **未消失**。 | Swift sourceID + generation 结构保证；Tauri 只有 stable source 对象上的 generation 去重，Home 切换没递增。见 P1-03。 |
| quota/app-server/计划与历史 | app-server stdout 曾夹日志被当 JSON 失败，失败会覆盖旧额度，计划显示/历史 key 反复调整；链为 `42ac6fd -> b438ee0 -> 70fbaaa -> c0b877a`，更早 `82238a4/a576153` 合并 Swift 旧 key。 | Swift `AccountQuotaReader.swift` 的逐行 JSON 读取、`QuotaHistoryStore.swift:418-425,628-679,743-762`；Tauri `quota.rs:600-755`、`quota_history.rs:186-210,357-372`。 | 解析与旧值保留 **已消失**；跨端计划身份 **未消失**。 | app-server child、选中 Home 环境和诊断 taxonomy 已结构化；共享 DB identity 仍靠不对称兼容 SQL。见 P2-01。 |
| live-rate/pending 状态 | 工具输出曾推高 tok/s；stream 失败、summary cache 重建、quota pending 曾互相覆盖；链包括 `d11fe32/0a20932/3fe00be/ef85185/69350f2`。 | Swift `RateAccumulator.swift:350-366`；Tauri `live_rate/stream.rs:377-396`、`live_rate.rs:189-225`、`compactPanelSnapshotModel.ts:31-32,139-154`。 | **当前实现已充分收口。** | 可见文字/工具参数/patch input 才进速率；`live_rate_stream` 是 failure，`live_rate_summary` 是 pending。结构 taxonomy + tests 双重保证。边界是项目决策仍错误地声称 reasoning 计入，见 P3-01。 |
| Radar public/full/调度 | public summary、RSS 与 authenticated full detail 曾混在前端；自动刷新失败可能重复尝试；链为 `3107b21 -> cf54cb7 -> 086cce9`。 | Swift `CodexRadarStore.swift:53-114`、`CodexRadarDetailRefreshSchedule.swift:3-65`；Tauri `codex_radar.rs:7-75`、`codexRadarDetailRefreshPlan.ts:1-72`、CSP `tauri.conf.json:16`。 | public/full 与 08:00/18:00 调度 **已收口**；client credential 边界 **未收口/未定性**。 | 调度由 successful slot + attempted slot 结构保证；full bearer 仅混淆，见 P1-04。 |
| 未读基线 | 早期 acknowledgement 是单一集合，切 Home 后会把另一 Home 的会话视为已读；`dc43a4e` 改成 `byCodexHome`。 | Swift `TaskCompletionReadBaseline.swift:3-55`；Tauri `unread.rs:14-115`。 | 跨 Home 根因 **已消失**。 | canonical Home key 和 per-home map 是结构保证。剩余边界是 Tauri 非原子写、静默 parse fallback，见 P3-02。 |
| Provider 修复操作 | 历史上重点修了扫描范围、操作生命周期、旧任务回写和入口挂载；`883d9f4/71eae3b/b3acbfe/c6bcb2f`。 | Swift `ProviderSyncEngine+Backups.swift`；Tauri `provider_repair.rs` 与 `provider_repair/backups.rs`。 | Swift **已结构收口**；Tauri **核心回滚安全未消失**。 | Home fingerprint 校验只防错 Home，不能保证备份内容一致。见 P1-01。 |
| CLI/App discovery | App 从 ChatGPT/Codex 名称变化、CLI 不在 PATH、桌面内嵌 binary 导致发现失败；macOS 链为 `d7d1bb6/07eb08c/a997c03/ab11685/16327d6/cd33b03`，Windows 为 `c838eb1`。 | Swift `CodexBinaryLocator.swift:9-90`；Tauri `quota/codex_binary.rs:82-180,828-892`。 | macOS **基本消失**；Windows **条件性残留**。 | macOS 用 bundle ID + LaunchServices + scan；Windows 仍靠目录名和 PATH，见 P2-03。 |
| UI 布局跳动/图表 | 刷新时重置 loading 导致卡片跳动、长图撑高、滚动后日期不可见；链为 `28d941d -> be3eca6 -> 389bd2f -> 50c98a3 -> 6a2ea48`。 | Tauri `RecentUsageChart.tsx:28-90`、recent chart model；Swift 对应图表使用固定布局。 | 布局跳动 **已消失**；数据覆盖范围 **未完全消失**。 | 固定高度、stable dimensions、scroll/date marker 是结构保证；quota overlay 未随长图扩展，见 P2-02。 |
| 更新与发布元数据 | Tauri 过去缺自动更新、签名/metadata/双架构资产；链为 `0f44865 -> 5e6ccea -> 1ffcb76 -> a1899cb -> bf837e1 -> e48930a -> 04124ea`。 | Swift `appcast.xml` + `scripts/package_app.sh:11`；Tauri `tauri.conf.json:34-42`、Windows release script；`release-ledger/v0.7.2.md`。 | v0.7.2 当前源码元数据 **一致**；独立发布耦合 **仍在**。 | 当前由统一 release 顺序、签名和 ledger 保障；latest endpoint 不是独立 channel，见 P2-04。 |

## 相互矛盾、失效或遗留的兼容层

1. **fork 决策已失效。** `decisions.md:15` 的“新 user message 即退出”被 `408020a` 的 2 秒规则取代，却未标记 superseded。
2. **quota identity 决策已失效。** `decisions.md:29` 的全量 Pro 规范仍符合 Swift，却直接违反 Tauri `c0b877a` 的实现与测试。
3. **live-rate reasoning 决策已失效。** `decisions.md:36` 允许 reasoning，Swift/Tauri 当前均排除；历史 `d11fe32` 的实际口径已经超过文档。
4. **Swift v5 cache loader 不可达。** 生产先删 legacy 再只载 v6，但 v5 parser、migration payload 和宽松 key bridge 仍保留，容易让审查者误以为存在迁移支持。
5. **Tauri `summaryReady` 是恒 true 桥。** 它保留了旧的两阶段 readiness 外形，却不能再表达 false，测试也无法覆盖这个状态。
6. **Tauri quota 的 `recent_24h` 名称已承担两种语义。** usage 侧把它当 30 天可滚动 5 分钟序列，quota 侧仍按字面只给 24 小时，是 P2-02 的直接来源。
7. **Windows updater 名义独立、寻址不独立。** metadata 文件独立于 appcast，但 URL 仍依附全仓库 latest release。

## Rejected / Stale Findings

以下候选在回到当前实现、测试和发布时序后被拒绝，不应继续作为 v0.7.2 缺陷上报。

| 候选 | 结论 | 证据 |
|---|---|---|
| `v0.7.2` 到 `origin/main` 有产品回归 | **Rejected** | `git diff --name-status v0.7.2^{commit}..origin/main` 只有 `release-ledger/v0.7.2.md` 与 `release-ledger/v0.7.2-tauri-prep.md`。 |
| Tauri `byCodexHome` 缺旧 flat acknowledgement 迁移，会影响已发布用户 | **Stale** | flat 格式与按 Home 格式都在 v0.7.2 发布前引入/替换；没有证据表明旧 flat 格式曾进入正式 tag。保留的真实风险是非原子写，而不是升级迁移。 |
| state SQLite token 总和仍被当成精确“总/今/次” | **Rejected** | 当前 fast path 明确作为 metadata/cache fallback，precise path 来自 JSONL；`dcc80cb`、`69350f2` 后还用 summary warning 标记重建态。 |
| 工具输出或 reasoning 仍抬高主 tok/s | **Rejected** | Swift `RateAccumulator.swift:350-356` 与 Tauri `stream.rs:389-396` 都只允许 visible/tool arguments/patch input；reasoning 只留在 breakdown。 |
| Radar 失败会在同一 08:00/18:00 slot 无限重试 | **Rejected** | 两端都有 last attempted slot，失败后同一 slot 不再自动尝试；手动刷新仍可强制。 |
| macOS App 改名会导致 Swift/Tauri 找不到内嵌 CLI | **Rejected** | 当前优先稳定 bundle ID `com.openai.codex`，并扫描 `/Applications`、`~/Applications`，再兼容 ChatGPT/Codex 名称。Windows 另见 P2-03。 |
| Swift 必须继续迁移 v5 usage cache | **Stale** | 当前明确采用可重建 namespace 失效策略，生产会删除旧 cache；真正问题是死 loader 仍在，不是缺迁移。 |
| v0.7.2 源码中的 Swift/Tauri 版本、build 或发布资产指向互相冲突 | **Rejected（源码/ledger 层）** | `appcast.xml` 为 0.7.2/build 702，Tauri package/Cargo/conf 都为 0.7.2，ledger 记录两架构 Windows metadata。按任务边界未重新联网验证公开资产。 |

## 已充分关闭的历史问题

1. **partial JSONL 与增量 offset。** 两端只推进到完整/可解析记录，Tauri cache 保存 `parsed_size`、previous total、replay state；namespace 改变会直接失效旧 shard。当前测试覆盖残行、append、cache round-trip 和旧版本 reparse。
2. **Swift source 异步旧结果覆盖。** source ID、generation、Task cancellation 和结果落地 guard 已形成一套完整结构，不再只靠调用顺序。
3. **quota app-server 日志误判。** 当前逐行提取 JSON，WARN/普通日志不会再把成功响应降为 `parse_failure`；失败时保留旧 quota，并有明确诊断来源。
4. **live stream failure 与 usage summary pending 混淆。** 两类 warning source、failure/pending UI 和 compact surface 优先级已经对齐。
5. **Radar 自动调度。** Swift/Tauri 都是本地 08:00/18:00 slot，记录成功 slot 和尝试 slot，手动 refresh 独立。
6. **未读跨 Home 污染。** 两端都按 canonical Home 分桶，读取和 acknowledge 使用同一 key。
7. **图表刷新造成高度跳动。** 固定 chart height、横向内容宽度、日期 marker 和可见窗口标签都已进入布局模型，而不是靠截图参数。
8. **v0.7.2 双平台源码元数据。** tag 到 main 没有产品源码漂移；版本、Sparkle build、Tauri version 与 ledger 在仓库内一致。

## 仍缺测试的高风险交叉点

1. **同一 fork fixture 的双端契约测试。** 必须覆盖真实首条 prompt 在 0.5s、1.999s、2.000s、2.001s，以及无 token 先出现 user message、多个 session_meta、增量续读；期望应由真实日志边界字段决定，而不是复制当前阈值。
2. **Tauri Home A -> B 全数据域切换。** 同时断言 fast、precise、quota、live thread options、live-rate、unread、provider scan 的来源与 generation，并注入 A 的迟到结果。
3. **Swift/Tauri 共享 quota DB 互操作。** 交替写入和读取 Plus/Pro/Team、未知计划、计划变化、旧无 source 行，检查曲线连续性和 estimator 输入。
4. **Provider Repair WAL 安全。** Tauri 缺一致快照、WAL copy failure、恢复 integrity、same-second ID、修复中途失败自动/手动回滚测试；这应在任何进一步开放修复入口前补齐。
5. **30 天长图 quota 连续性。** 后端点数、frontend merge、scroll selection 和 cost/quota estimator 应共享一个时间范围不变量。
6. **Radar credential policy。** 代码测试只能证明“可解码”，不能证明权限安全；需要服务端 scope/限流/轮换合同和泄露演练。
7. **Windows renamed App discovery。** 需要以实际官方安装/注册信息为 fixture，而不是继续枚举产品名目录。
8. **跨平台独立发布模拟。** 测试 Mac-only latest、Windows-only latest、metadata 缺失和上一有效 Windows metadata 回退。
9. **Tauri unread 原子写与并发。** truncate fault、parse corruption、A/B Home lost update、损坏文件诊断均无测试。
10. **决策文档与行为 contract。** fork exit、quota plan identity、live-rate category 三项应能在 CI 或审计脚本中发现文档/代码漂移。

## 实际检查范围与方法

- `git log --all --oneline`：扫描当前所有 refs 的 **577 个可达提交标题**，再回到候选提交 patch、当前源码和测试确认，不以标题单独定案。
- 发布 ancestry：从根提交 `203aad562b1b36838707bc28b2ceb50998c555d0`（2026-06-07）到产品 tag commit `e48930a626679230d5d52267c830812f254fdd26`（2026-07-10），共 **562 个 ancestry commits**（含端点）。
- 集成差异：`e48930a..04124ea` 只有 1 个 post-release ledger 提交；audit HEAD 比 `origin/main` ahead 4，均为审查设计/计划/入口文档，不改变产品 finding 的源码基线。
- `git log -S/-G` 实际检索主题包括：`parsed_size/cacheNamespace/totalCalls`、`forked_from_id/forkReplay/FORK_REPLAY_EXIT_GRACE`、`setCodexHome/sourceGeneration/loadGeneration`、`app-server/parse_failure/plan_label/quota-history`、`live_rate_summary/live_rate_stream/contributesToLiveRate`、`api/v1/current/KEY_CIPHER/MORNING_SLOT_HOUR`、`byCodexHome/UnreadAcknowledgement`、`VACUUM main INTO/state_5.sqlite-wal/create_provider_backup_files`、`com.openai.codex/ApplicationBundles/Programs Codex`、`RECENT_POINT_COUNT/recentChartScrollLayout`、`latest-windows.json/appcast.xml/createUpdaterArtifacts`。
- `git blame` 重点核对：fork 2 秒退出条件、Tauri Home 切换 actions 与 deferred generation guard、Swift/Tauri quota plan identity、Tauri Provider backup/restore、30d usage 与 24h quota 常量、Radar credential、Windows discovery、updater endpoint。
- 当前实现检查覆盖 Swift `Sources/` + `Tests/`，Tauri `src/` + `src-tauri/`，发布脚本、appcast、release ledger 和项目 `decisions.md`。
- 未运行 build、App、测试套件或联网发布验证；报告中的“复现/验证方案”均为后续隔离验证建议，不冒充本轮动态结果。

## 最终判断

v0.7.2 并不是“旧问题仍原样存在”：多数反复维修主题已经从补丁式修复演进到 namespace、generation、warning taxonomy、per-Home key、固定布局和发布 ledger 等结构保证。真正的历史债务集中在跨边界处：**启发式无法表达日志语义、共享持久化没有共享身份 schema、Tauri source 切换没有传播到所有 loader、写操作把备份当安全网却没有一致备份协议、发布/服务凭据依赖未记录的外部假设**。这些边界也是下一轮修复与测试最应优先投入的位置。
