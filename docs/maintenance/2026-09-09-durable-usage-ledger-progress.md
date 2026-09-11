# 持久用量账本：实现与升级验证记录

2026-09-10 复核补充：多路 Luna max 审计后由主 Agent 修复 Windows 候选刷盘和双端 VACUUM 空间预检，并新增实际默认路径、退出后遗留 WAL 的升级测试。见 [正式升级链路复核](2026-09-10-release-upgrade-review.md)。Windows 实机和安装包门禁仍未完成。

最新：已使用找到的164个真实旧会话，由v0.9.1实际生成Swift6/Rust9后升级到13并验证增量。见 [真实历史验收及旧total-only差额](2026-09-09-real-history-upgrade.md)，不再仅有构造数据或开发库12的证据。

最新正式升级证据见 [v0.9.1 正式升级验收](2026-09-09-release-direct-upgrade.md)：本机开发兼容先保留；已新增实际 v0.9.1 代码生成的 Swift6 / Rust9 → 13 验证，不能以本文 schema12 大库测试代替。七月 schema2 经正式版仍需原文补全，未伪报该大库完成到6的升级。

2026-09-09，`main` / `50251cb7c7b75108267862e3352d95927e11cccf`，工作树未提交。本文取代本文件此前“仅保护层/纯合并核心”的状态；总体设计与边界仍见 [执行计划](2026-09-09-durable-usage-ledger-execution.md)。用户最新优先级是 v0.9.1 升级与日常增量，不再追找全部本机缺失历史。本阶段由主 Agent 完成实现与复核。

用户最新收束要求：普通用户只按 v0.9.1 → 新版验收；开发环境的中间版本不再扩展兼容矩阵或额外防御。保留已完成、已测试的处理，停止新增假设性恢复分支。

## 当前实现

1. **统一数值来源已接线。** Swift `events`、Rust `event_rows` 就是 canonical 数值账本。总数、费用、周期、曲线、排行继续从这一套表派生，不把 retained 备份与当前事件相加。原文位置单独存入 `usage_ledger_bindings`，新事件使用与字节位置分离的 ID；turn 分组也不再把旧 offset 当新文件坐标。
2. **覆盖旧发布和中间版本。** Swift schema 6/7/11/12 → 13，Rust schema 9/10/11/12 → 13；结构候选契约仍为 11，会计仍为 `codex-components-v1`，
账本组件为 1，保护层为 schema 2 / writer 4。未知版本或 schema13 缺账本表时先拒绝，不自动清空重建。旧程序的未来版本判断会拒绝 schema13；这不承诺降级后继续精确增量。
3. **原文改写不再清空旧账。** 完整前缀证明可按旧代原文位置重新关联；已绑定的完整指纹在来源内关联；上游 paginated 改写中有独立证据的新消费追加。旧来源 fingerprint 集合不作为旧事件身份。没有关联证明的观察进入 unresolved，下一次“文件已经稳定”也不会自动重复入账。旧 schema9 缺字节位置时，重复时间/组件的歧义观察会保留，不用序号硬配、也不再当新调用加一遍。
4. **保全仍支持修正。** 同一代完整前缀和同一旧字节位置证明是同一观察后，当前解析器可以修正旧数值；`usage_ledger_corrections` 记录算法、位置和旧/新 Token，旧完整组件由 retention 触发器保全，数值与聚合同事务提交。只有来源消失、转写后某行不见、或身份冲突不足以撤销一笔消费。不能从不充分证据强行认定“继承重复”。
5. **缺失、归档、增量。** 来源消失只撤销原文可用性，保留数值与检查点；唯一任务的归档移动沿用 source ID。恢复后重新验证绑定，再恢复后缀增量。同路径不同 owner 的未知冲突仍安全拒绝，不能混合两人的账。缺失来源从“当前需要扫描”的探测集合排除，但保留在数值查询中，避免永远触发删除检测。
6. **中断恢复。** Rust 旧 building/pending、未发布 staging，以及旧 tombstone 恢复前会保住已发布消费；Swift/Tauri 能恢复“schema12 会计已提交、schema11 manifest 尚未退休”的中间态。候选对账包含 ledger/retained 数值摘要，旧 manifest 缺新字段按既有结构契约继续，不凭新表存在跳过原有检查。
7. **应用数据目录。** 默认账本由 Caches 迁往 Application Support（Tauri 使用平台应用数据目录）；测试/显式缓存覆盖保持隔离。先完成旧入口支持的升级，再在旧、新路径锁内用 SQLite backup 复制 WAL 一致快照；校验、刷盘后同目录发布，旧库保留且已经是 schema13。复制中断可以重做私有副本；目标已存在则不覆盖。搬迁前跨平台仍可只读旧库的 lastGood 身份，主界面首屏不必等待迁移。
8. **修复摘要/主界面衔接。** Summary 后落后的派生聚合水位不能被下一次 Full 假标为完成；先补齐 SQLite 中漏下的区间。已结束 refresh flight 不再因 owner 尚未清理槽位而被新请求复用。修复了对应旧数字滞留的回归。
9. **性能与清理。** 新来源全量导入走集合 SQL；旧来源对账使用 SQLite 临时文件并流式取行，不收集整个来源到 Rust Vec。稳定文件仍走元数据命中，追加仅验证尾块并读后缀，迁移不全局提升 parser revision 强制重扫。清理只删白名单可重建汇总文件；不自动删旧事件缓存、旧账本或保护快照。额度维护 policy3 保留原始采样和锚点，不做旧式仅按 reset 清理。

## 验证

全部日志在 `runs/20260909-cycle-audit/`。测试数据位于隔离临时目录；没有将这次代码装入运行应用，也没有迁移用户活动数据库。

| 验证范围 | 结果 | 证据 |
| --- | --- | --- |
| Swift analyzer / retention / accounting / ledger | PASS 158；显式实机项 NOT_RUN 2 | `ledger-swift-regression-v7.log`（共160项） |
| Rust token_count_jsonl 整模块 | PASS 244；显式实机项 NOT_RUN 3 | `ledger-rust-module-final.log` |
| Swift quota、reconciler、cache/ledger 定向 | PASS 26 | `ledger-swift-final-targeted.log` |
| Swift quota history | PASS 47 | `ledger-swift-quota-history.log` |
| Rust quota history | PASS 74 | `ledger-rust-quota-history-v2.log` |
| Swift 真实 schema12 → 13 | PASS：423,317 行逐字段相等，绑定完整；另验证30,968行来源删除保全 | `ledger-swift-real-upgrade.log` |
| Rust 真实 schema12 → 13 | PASS：423,315 行逐字段相等，绑定完整，JSONL body/append bytes均0；另验证30,968行来源删除保全 | `ledger-rust-real-upgrade.log` |
| 旧 release → 转写 → 重开 → 追加 → 缺失恢复 → 归档 → 修正 → 搬迁 | 双端 PASS | `ledger-swift-correction.log`、`ledger-rust-final-storage.log`；广泛回归再次覆盖 |
| 20,001 会话文件规模 | PASS，不截断 | `ledger-rust-scale-final.log`，整个测试219.89秒，包含造数与清理，不等同启动时间 |
| Rust 非 test 的生产路径编译 | PASS | `ledger-rust-production-build-final.log`（最终复验） |
| Swift 编译 | PASS | 上述 swift test 同时编译/链接产品目标 |
| git diff --check | PASS | 当前工作树 |
| 安装/活动库端到端、Windows 安装/文件锁/故障恢复实机 | NOT_RUN | 不用 macOS 单元测试替代 |

本轮还修了两个测试夹具问题：Swift 并行解析回调向共享数组追加时缺锁；Rust 额度测试临时目录只按时钟取名会碰撞，导致用例互相删除目录。旧 release 夹具的 turn ordinal 也改回旧格式，避免把新账本高位 ID 冒充旧序号。数值断言的更新仅限新契约明确保留旧账的情形；有证据的异常校正与重复来源仍有独立测试。

## 边界与后续

2026-09-09 19:24 用户要求压缩后重新复核：重读双端实际 ledger 入账、full 发布调用点、目录搬迁实现及旧 release 测试夹具，并重新运行 Swift `testReleaseUpgradePreservesLegacyRowsThroughPaginatedRewriteMoveAndAppend` 与 Rust `release_upgrade_keeps_legacy_ledger_through_paginated_rewrite_and_append`，各 1 项通过。日志为 `ledger-swift-user-recheck.log`、`ledger-rust-user-recheck.log`。这两个用例使用旧版结构/身份夹具和生产入口，属于隔离集成测试，不是实际 v0.9.1 安装包升级验收；真实大库副本验证仍是上述 schema12 → 13。执行计划早期清单已明确标为历史快照，避免误读。

- 不再扩大历史恢复，也未导入 69 个来源的恢复候选或自动补差。原文和旧索引都没有的详细用量无法凭迁移源码重建。
- 新绑定无法证明的原文不展示错误摘录；时间、模型未知时不编造周期归属或费用。旧 schema9 的歧义重叠保持 unresolved，但已有消费可正常查询，后续新调用继续增量。
- 手动补差（范围、撤销、双端 UI）仍是后续独立功能；未由程序给用户填写任何差值。
- P5/P6 仍剩候选应用安装、活动运行账目/CPU/增量验收，以及 Windows 门禁。运行应用尚未替换，未发布、未推送、未打 tag。
- 旧路径备份、恢复材料与跨端各自账本暂保留；发布验收前不按“冗余缓存”清走。已有其他 UI 工作树变更完整保留。
