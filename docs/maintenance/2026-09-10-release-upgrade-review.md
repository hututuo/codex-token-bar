# v0.9.1 正式升级链路：多 Agent 复核

2026-09-10；基线 `v0.9.1 / 6e2889f8ecef771719eb58cab0366f505500c2c5`，当前 `main / 50251cb7c7b75108267862e3352d95927e11cccf` 加未提交工作树。

验收范围是普通用户 Swift schema6 / Rust schema9 → 当前 schema13，以及升级后的查询、增量和上游转写。未扩大开发中间版本兼容矩阵。下午的本机恢复实现保留。本轮没有安装、替换运行应用、修改用户活动库、发布或删除备份。

## 本轮已修复

1. **Windows 候选库刷盘调用。** 候选文件原先只读打开后调用 `sync_all`；目录又用普通文件方式打开。现在文件以读写方式打开（不创建、不截断），目录统一复用项目已有的 Windows 专用目录刷盘实现，最终目录搬迁也走同一实现。Microsoft 明确要求 [FlushFileBuffers 的句柄具有 GENERIC_WRITE](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-flushfilebuffers)，以及[目录句柄使用 FILE_FLAG_BACKUP_SEMANTICS](https://learn.microsoft.com/en-us/windows/win32/fileio/obtaining-a-handle-to-a-directory)。源码问题已修正，Windows 实机门禁仍未完成。
2. **双端候选迁移的磁盘预检。** 原预估少算 VACUUM 的一份临时分配；现按候选副本、压实临时库、回滚日志三份估算，并考虑 WAL 可能扩大副本，保留原有 512 MiB 余量。已占用的旧库不重复算入剩余空间。依据 [SQLite VACUUM 文档](https://www.sqlite.org/lang_vacuum.html)，压实本身可能需要约两倍数据库大小的额外空间。Swift 测试验证旧预算放行的容量现在会在修改旧库前拒绝；Rust 使用稀疏文件验证大库预算，未写入 GiB 测试负载。这是预检改进，不能阻止其他程序在迁移过程中耗尽磁盘。

涉及生产文件：`CodexUsageHistoryIndex.swift`、Rust `exact_usage_index.rs` 和 `atomic_file.rs`。没有因审计推测修改计费规则或增加兼容器。

## 真实正式版库与生产入口

沿用 [真实历史升级记录](2026-09-09-real-history-upgrade.md) 的 164 个旧 JSONL，经实际 v0.9.1 代码生成的 Swift6 / Rust9 输入。两端各 13,112 条旧入账记录。不是给当前库改版本号。

- Swift 新增默认构造入口测试：在旧 Caches 路径放入随机测试 Home 的 schema6 副本，实际迁往 Application Support；保留旧库、13,112 行和新 schema13，重开不重复。
- Swift 再补旧进程退出后仍有已提交 WAL 的场景。独立测试进程提交后直接退出，留下非空 WAL；没有活跃旧连接绕过应用锁。迁移后专用 WAL 证明行存在，全部旧行保留，重开一致。
- Rust 新增实际 `relocate_legacy_index` 入口测试：传入的旧路径与默认路径不同，确认只迁指定旧库、无 JSONL 读取、默认路径的另一个隔离测试库字节不变、旧库保留、第二次搬迁无操作。
- 本轮 Swift 再跑 13,112 行逐字段保全和重开；Rust 再跑 13,112 行真实目录搬迁。前一轮已完成同一批原文首次/再次刷新零重解析、+5/+7 增量探针、原文消失保全；本轮未再次复扫这批全部原文。

旧 total-only 的 8,659,677 Token 差额仍按原审计保留证据、从正常消费排除，详见前述记录；不能把“字段全部保留”写成“新旧总数完全相等”。

## 审计判断

Luna max 分查 Swift 迁移、Rust 迁移、计费/原文绑定、查询刷新；主 Agent 复核和修改生产实现。查询代理因网络中断两次未能交付，另起精简审计补查；失败尝试不计为审计通过。

- **Swift 切换断点：** 新版本中断后由 manifest 恢复的路径及测试通过。旧 v0.9.1 进程恰在重命名间隙重新启动并写库属于旧新程序并发/降级边界，未据此扩展普通升级兼容器。曾用绕过应用操作锁的活跃 SQLite 连接测试，产生 IOERR_SHMMAP；该夹具不代表正常升级。最终无活跃旧连接、遗留 WAL 的测试通过。
- **reset 去重建议未采用：** 累计下降也可能是交错重放，原始样本没有可用的 counter epoch。代理最初把 accounting 单元契约推成生产漏记，复核现有 replay 测试及原文后撤回。保留 durable 去重，避免“下降即清空”引入重复计费。
- **空间建议经复核收窄：** Rust 目录搬迁预算不足的初步意见撤回，因为 free space 已排除旧库，现有预算已覆盖目的副本；VACUUM 额外空间问题确认，并同步修复 Swift。
- **旧 source fingerprint 不等于已经入账：** Rust 代理提出无逐事件绑定时的重复入账候选分支。核对实际 v0.9.1 解析器发现它先插入 fingerprint，再跳过 inherited/replay/zero delta；集合中本来就可以有未入账的观察。旧版可用 last 的组件与新版一致，而没有 last 的旧行组件为零，迁移后保留为诊断证据，新累计组件解析不能因此被阻挡。没有给出正常正式版输入下的重复计费复现，最终标记为 **UNPROVEN / legacy ambiguity**，未采用“旧 source fingerprint 已知即 hold”的危险修复。旧 schema9 没有原始字节位置，不承诺给所有旧事件无损重建身份；歧义保持隔离，已有数值保留。
- **查询链路没有新确认缺陷：** 精简审计最初把后台 `Full` intent 当作全量重解析，并怀疑 Summary promotion 的代次不同。主 Agent 核对后，代理撤回两项定性：Full 是完整仪表盘投影，内部仍增量；旧 optional aggregate identity 会保守失效，不证明数字错配。Swift generation/有界重试与只读额度周期路径未发现新问题。根代理补跑摘要/Full promotion/聚合水位 27 项通过；本轮未测实际安装应用的 CPU。

补充计费回归 `release_offsetless_cumulative_fallback_preserves_evidence_and_counts_components_once`：只有累计值的 schema9 语义夹具，已有 source fingerprints，升级重读后仍只计 120，重开不重复，旧 total 证据保留。与旧无位置歧义用例共 2 项通过。初次夹具误留 `accounting_revision` 等新版标记，造成 240；读取失败夹具逐行确认旧行没有执行会计迁移后，去掉正式版不存在的标记再测通过。该失败属于测试输入混合了新旧契约，不是实际 v0.9.1 升级缺陷。未修改生产计费逻辑；此用例也不能冒充实际 release 生成测试。

## 测试记录

日志目录 `runs/20260910-release-review/`。以下分组有重叠，不相加冒充独立用例总数。

| 验证 | 结果 | 日志 |
| --- | --- | --- |
| 本轮初始 Swift accounting/analyzer/retention/ledger | PASS 166，SKIP 2 | `swift-initial.log` |
| 本轮初始 Rust token_count_jsonl 模块 | PASS 244，IGNORE 5 | `rust-initial.log` |
| 修复后 Swift 低空间 + 实际旧库逐字段 + 默认路径/WAL | PASS 3 | `swift-migration-final.log` |
| 修复后 Swift schema6/7 中断恢复及事件账本 | PASS 13 | `swift-recovery-final.log` |
| Swift 额度周期/历史和 accounting | PASS 67，SKIP 2（未给输入的实际库测试） | `swift-query-final.log` |
| 修复后 Rust 刷盘和大库容量预检 | PASS 2（macOS） | `rust-durability-final.log` |
| 修复后 Rust 候选完整性/中断恢复 | PASS 6 | `rust-migration-final.log` |
| Rust schema9 定向迁移/回滚 | PASS 5 | `rust-schema9-final.log` |
| 修复后 Rust 实际旧库指定路径搬迁 | PASS 1 | `rust-real-path-final.log` |
| Rust 额度历史 | PASS 74 | `rust-quota-final.log` |
| Rust 摘要、全量查询、刷新复用及聚合水位 | PASS 27 | `rust-refresh-final.log` |
| Rust 旧无位置歧义、累计组件补入且不重复 | PASS 2 | `rust-offsetless-corrected.log` |
| Rust 非 test 生产编译 | PASS | `rust-production-final.log` |
| Swift 产品编译/链接 | PASS | 上述 Swift 测试日志 |
| 工作树空白检查 | PASS | `git diff --check` |

最早两个 WAL 测试尝试分别未留下 WAL、以及使用了绕过应用锁的活跃连接，失败日志保留；最终测试已修正为旧进程退出的真实边界。完整 Swift/Rust 全仓测试、Windows 安装/文件锁/刷盘故障恢复、实际安装包与运行 UI/CPU 验收为 **NOT_RUN**，不能用 macOS 编译或这些定向测试替代。

## 发布门禁

本轮确认问题已修复并完成上述回归。正式发布仍需 Windows 实机升级（尤其此次修复的目录句柄和刷盘路径），以及候选安装包端到端验收。源码审计不能承诺任何用户环境下绝无错误。原始历史、旧账本和保护快照继续保留。
