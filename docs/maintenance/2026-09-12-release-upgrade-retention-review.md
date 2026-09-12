# v0.9.1 → 当前版本兼容复审与旧数据保留

2026-09-12。基线：正式 tag v0.9.1（6e2889f8）；目标：781813e2 加本次工作树修复，分支 codex/sync-updates-20260912。
用户要求仅检查正式用户 Swift schema6 / Rust schema9 → 当前 schema13，不扩展开发中间版本矩阵；本版保留旧数据，下版再安排清理。

## 本轮修复

主 Agent 实施和验证，3 路 Astra medium 只读核查 Swift、Rust、Windows 历史增量验收。

- 双端删除成功刷新后自动清理 schema11 rollback 库及迁移清单的路径。
- 双端停止旧摘要缓存的自动清理。旧目录、原版回滚库、迁移清单均保留；原始 JSONL 不修改、不删除。
- 迁移清单增加终态 retained（Rust 序列化为 Retained）。重开跳过已经结束的候选迁移，继续走正常索引校验，避免保留 switched 后每次重复扫描 SQLite。
- 后端现有元数据表新增键 release_upgrade_retention_v1，不升级 schema。目录搬迁时在候选副本中写入 copied 来源凭据，随 SQLite 副本原子发布；正常增量同步成功后才标记 succeeded。
- 成功凭据记录旧库、回滚库、清单路径，来源和目标 schema，完成时间及成功发布的 generation。成功后不重复改写。写入失败保留旧数据、下次同步重试；不触发重建。
- Swift 修正同一数据库 /var 与 /private/var 路径别名比较，避免保留迁移清单后将同一库误判为路径不匹配。

普通用户目录迁移会先在旧位置完成结构升级，再复制到持久目录；原始 schema6/9 位于 rollback，新位置继续增量更新。旧位置的结构迁移清单可以仍是 switched，**当前数据库中的成功凭据**是后续清理的完成记录。不能仅看到旧路径或 copied 就判定迁移成功。下版清理仍需核对当前可用库和这些受管路径，不能按整个缓存根目录递归删除。

## 保留的升级策略

- 结构和计费口径转换读取旧 SQLite，不因版本变化全量重解析 JSONL。
- 未改变文件沿用检查点；正常追加从检查点增量读；上游转写只处理受影响来源，已入账的历史数值保留。
- 原始历史缺失不清空旧账本；旧格式、paginated 格式继续复用现有解析和 durable ledger。
- 本次未增加中间开发版本之间的兼容器，也未重建本机活动索引。
- “Full dashboard”请求是完整显示投影，不等于全量 JSONL 重扫；这两项在验收中分别判断。

## 真实正式版输入

沿用164个历史原文经实际 v0.9.1 代码生成的 Swift6 / Rust9 库；本轮用 SQLite backup 导出新的隔离副本，未改旧版本号伪造夹具。每端13,112条记录。

Swift真实输入验证逐字段保全、首次 changedFiles=0、再次 changedFiles=0、+5/+7增量、所有来源暂时消失后仍保留旧值；默认路径迁移还覆盖旧进程遗留已提交 WAL。Rust真实输入验证指定旧路径→持久目录、首次及再次刷新 scan_bytes 不增长、旧库字节保留、成功凭据不重复改写、无关索引不变。

旧版 total-only 的8,659,677 Token依然保留为 legacy_tokens 证据，不并入组件口径消费；这沿用既定修复，不能把“逐字段保全”说成新旧展示总数绝对相同。

## 验证记录

日志与隔离输入：runs/20260912-release-retention/。

| 最终检查 | 结果 |
| --- | --- |
| Swift迁移/保留/账本/路径/增量定向回归 | PASS 35，SKIP 1（未提供专用历史输入） |
| Swift实际v0.9.1输入、默认路径及遗留WAL | PASS 2 |
| Rust schema迁移及中断恢复 | PASS 22 |
| Rust实际v0.9.1目录搬迁和首次零扫描 | PASS 1 |
| Rust旧格式、转写、增量和搬迁 | PASS 1 |
| Rust缓存保留 | PASS 9 |
| git diff --check | PASS |
| Windows实机、安装包及运行UI验收 | NOT_RUN |


- Swift正式版实库与默认目录迁移：swift-real-release-final.log。
- Swift迁移、中断恢复、旧格式转写、保留账本、增量检查：swift-targeted-final.log。
- Rust schema迁移及中断恢复：rust-schema-final.log。
- Rust正式版实库及迁移成功凭据：rust-real-release.log。
- Rust旧格式→转写→追加→搬迁：rust-ledger-final.log。
- Rust缓存保留：rust-cache-final.log。

过程中修正了测试回调缺少返回值、导出夹具保留WAL模式却无sidecar的问题，以及真实捕获的Swift路径别名问题。初始 Rust 广泛模块回归在无关的20,000文件冷建测试处人工停止，不能报告为全模块通过；改为迁移和增量定向回归。

## Windows 与发布边界

用户本轮明确“先不用 win”，Windows实机验收为 NOT_RUN。
旧安装增量脚本只等待120秒，实际默认轻量刷新150秒；该超时不能证明生产watcher有缺陷。已修订本地验收脚本按至少两个刷新周期加60秒等待并记录轮询，未在Windows执行，也未改变生产刷新策略。此前安装增量失败记录不冒充已通过。

该兼容审查阶段的源码和隔离数据库验证不等于安装包或运行UI验收。后续本地提交、应用替换与本机启动验收见 [周期金额收束记录](2026-09-12-quota-cycle-refresh-review.md)；未推送或发布。
