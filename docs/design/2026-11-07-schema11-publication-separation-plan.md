# schema11暂存发布：边界与本批方案

基线`f9203d2a1b6b46b44aec3def77f813251d4206fa`，产品为`a19fb52f`，工作树`f97f/codex-token-dashboard`。用户要求继续后，本笔接续[剩余模块方案](2026-11-07-exact-next-decoupling-plan.md)，仅整理已明确事务边界的pending发布实现。

实施已完成：产品`4e43517d`提取发布函数，主文件净减少391行至15,892行。双平台完整库、生产入口、Public097和四版本接续均通过，原始证据已核对；见[执行与验收记录](../maintenance/2026-11-07-schema11-publication-separation.md)。没有改变最终事务的拥有者或执行顺序。

## 调查与决定

将主文件`publish_schema11_pending_generation`的393行（含末尾空行）移入`exact_usage_index/publication.rs`。它接收调用者借用的`&Transaction`，先检查pending历史合同、唯一活动代次、混入代次及墓碑子行，再应用账本绑定、事件、来源、聚合与暂存清理。保留所有SQL、错误、执行顺序和原入口名；不另开事务或连接。

父模块用私有`use`保留原函数名，使`finalize_generation`及ledger下五个既有测试调用位置不变。新函数仅`pub(super)`，依赖显式列为父模块的`Transaction`别名、`ledger`、`table_exists_checked`，以及rusqlite参数宏和可选行扩展。生产仍使用`StoreTransaction`，单测使用rusqlite事务。

相邻`discard_schema11_tombstone_pending_children`全仓搜索仅有定义。本笔保留其原位置，不增加调用、不清理死代码，也不改变拒绝带子行墓碑的行为。待发布数据校验、`ledger::preserve_pending_missing`、canonical重建、迁移状态机及stage池都留在原模块。

## 必须保持的事务合同

`finalize_generation`继续拥有唯一IMMEDIATE事务和最终commit，包括已被替代代次的原早退分支。执行顺序保持：

1. 检查building代次，保留缺失来源历史及更新canonical。
2. 标题、派生数据与归因处理；保留Summary/Full模式和原聚合滞后水位。
3. 调用pending发布函数，然后写published代次及revision。
4. 处理聚合水位，清building标记并certify。
5. 生产路径通过原绑定连接写暂存消费回执，最后一次commit。

任何后续步骤失败，前面的正式行、binding、pending清理及消费回执都由同一事务回滚。新模块不接管commit、不提前消耗或回收stage，也不修改池版本和所有权。没有数据库结构、索引、序列化合同或查询算法改动，不预期性能变化。

## 已核查的覆盖与验收

- `canonical_ledger_publication_rolls_back_certificate_and_every_reader_together`在后段certify注入失败，核对旧数值、归因和证明保留，重试后得到完整结果。
- ledger的`publication_fills_null_association_fields_but_preserves_known_values`、`publication_refuses_unknown_pending_fingerprint_history_before_clearing_rows`，以及三项缺失来源175-token发布测试覆盖补充字段、未知历史拒绝和旧账保全。
- `schema11_active_build_fences_current_writes_and_hides_stale_pending_rows`、持久墓碑恢复、未完成来源不发布部分结果、Summary之后Full聚合水位等既有测试一起复用。
- stage池已有正式代次/消费回执同事务回滚和成功提交测试；非test生产fixture另验绑定连接及旧stage回执。单测与生产证据分开记录。

这是行为保持的单函数提取，未发现需要为此次移动新增的独立测试合同；不复制一套与实现同构的测试。先按固定基线重建整个父文件和新模块，确认finalizer、所有调用点及其它既有生产/测试文件不变，再在精确候选SHA上运行云端双平台完整库、非test生产入口和原负控，以及Public097和0.9.8–0.9.11双平台历史形成状态矩阵。

按原始日志和源码清单核对执行、跳过、候选身份与旧材料保留。本机不编译、不访问正式库；通过后记录产品提交及云端结果。本笔到发布SQL归位即收束，迁移切换、暂存导入和路由拆分另行调查；不合并、安装或发布。
