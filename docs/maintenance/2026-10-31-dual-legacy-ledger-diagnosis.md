# 新旧目录双索引冲突：只读诊断与复现

用户截图报错：`同一业务分区存在内容不同的旧库候选；保留所有来源并拒绝切换：exact/index/...`。截图未显示版本、物理来源路径或两库内容，不能确认该用户具体差异。

## 已确认的代码问题

公开 v0.9.7 的 `relocate_legacy_index` 复制 cache 索引到 support 目录，在目标库 metadata 中写入 `release_upgrade_retention_v1`，保留原库。之后目标库还可能持续新增真实账目。

当前发现阶段枚举 support 和 cache 两个 `exact-token-index`，将同相对文件名映射到同一逻辑目标。`business_store_route::open_store_at_with_hook` 要求多个候选的 `snapshot_digest_path` 一致；该摘要包含完整 schema 和所有表行，也包括 metadata。因而正常搬迁副本也可能被拒绝。此处不是单纯比较数据库文件字节，但语义上依然过严。

上一轮恢复测试验证了迁移清单阶段、主库/回滚选择、中断和 A 初始化前后，但未覆盖真实搬迁后 support/cache 同名双库共同参与导入且证明不同的路径。

## 本地可重复证据

分支：`codex/diagnose-dual-legacy-ledgers`，仅添加诊断测试及本记录，未修改生产逻辑、打包、部署或发布。

测试 `diagnostic_relocated_legacy_pair_reproduces_conflicting_candidates`：在临时隔离目录创建真实 Exact 索引和 115 Token 记录，调用保留自旧版的搬迁实现，然后让双目录一起走发现器与真实容器导入器。

结果：两库 `SUM(event_rows.tokens)` 均为 115，复现与截图相同的中文错误；两库文件在诊断导入前后字节不变。测试 1 通过、0 失败（断言当前错误确实存在，并非修复已通过）。完整日志：`scratch/legacy-migration-hotfix/dual-legacy-repro.log`。

这证明正常旧搬迁路径足以触发该错误；不证明用户两库只有 metadata 差异，也不证明所有差异可直接忽略。

## 修复必须覆盖的范围

不能简单忽略错误、按修改时间选最新或任选一库。应先识别并验证迁移凭据、Home 身份、来源谱系，区分保留原件与已接续使用的活动账本；只差迁移元信息/可再生投影时允许接续。包含额外真实记录时需核对稳定记录身份、覆盖关系和冲突，保留两边独有的历史及 fork 后新增记录，避免重复计数。无法证明安全的冲突仍保留双方并输出具体来源/差异诊断。

验收应加入：正常搬迁后双库、仅迁移元数据不同、活动副本继续新增、旧库独有且原始会话已删除的记录、双方各有独有记录、同记录身份数值冲突，以及跨 schema 的可比较性。需要 Windows 非 cfg(test) 入口复现并验证，不能用单源恢复测试替代。
