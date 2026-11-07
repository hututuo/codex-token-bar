# schema11迁移证明：边界与本批方案

基线`d0af260cb3278162e3e328a7927d3335f4de8f24`，产品为`de4c48ad`，工作树`f97f/codex-token-dashboard`。这是用户要求继续后对[已完成三步](../maintenance/2026-11-07-thread-metadata-separation.md)的下一笔独立整理，不把迁移状态机整体并入。

实施已完成：`a19fb52f`归位迁移证明并新增两项旧格式合同测试，双平台完整库、生产入口、Public097和四版本接续均通过。主文件净减少771行至16,283行；见[执行与验收记录](../maintenance/2026-11-07-schema11-proof-separation.md)。以下保留本笔调查和边界，切换状态机没有迁移到新模块。

## 调查结论与决策

可先分离迁移事实和比较规则。主文件现有`schema11_lineage`至`schema11_migration_facts`共775行，夹有被ledger复用的62行通用逐行摘要实现。因此本次移动其中713行迁移专用逻辑及其事实类型，保留共享摘要工具在父模块；不是把775行一次全部挪走。

目标`exact_usage_index/migration/proof.rs`，`migration.rs`只转出父模块需要的入口。迁移状态机、候选转换和文件/命名空间操作仍在父模块，proof不创建连接、事务或文件，不决定是否切换。该边界已经足以实施一笔行为保持的提取；更深的状态机拆分需另行调查每个返回点和锁的释放顺序。

## 对象与调用关系

| 对象 | 本批处理 | 兼容合同 |
| --- | --- | --- |
| `Schema11MigrationFacts`、UsageFacts、MigrationDigests | 迁入proof，保留serde字段、顺序、类型和默认值 | manifest的`source_facts`及`accounting_structural_receipt`继续读写相同JSON |
| `LegacyGenerationState`与代次检查 | 迁入proof，供原候选转换调用 | published/building合法范围、聚合水位和错误优先级不变 |
| lineage、按来源的canonical指纹、迁移统计及摘要 | 迁入proof，所有SQL和编码顺序保持 | schema9/10选择旧已发布/构建代次，schema11读取兼容视图；不重写CTE或改成COUNT证明 |
| `preserves` | 与事实类型同处 | 普通字段全等；expected登记的受保护表摘要必须匹配，允许actual新增受保护表 |
| `schema11_digest_value`、finish、query | 留在父模块 | ledger受保护表摘要和迁移共用，不让ledger依赖迁移实现 |
| `canonicalize_legacy_fingerprint` | 留在父模块 | 暂存导入、候选转换与证明共用；canonical排序和旧fixed/text codec不改 |
| manifest、phase、source receipt、ValidatedStorage | 留在父模块 | 持久化状态不充当本次进程生成的验证凭据；不修改阶段或清单版本 |
| 候选转换、copy/switch/rollback、retention | 留在父模块 | 原连接、事务、锁、持久化点和材料保留保持 |

新模块继续使用父模块`Connection`别名，生产是绑定分区的StoreConnection，单测是rusqlite。事实生成借用原连接，查询后返回拥有数据的证明，不携带SQLite游标、连接或锁。trace和test计数仍调用原对象，避免改变重复计算监控。

## 已复读的恢复与事务边界

`open_at`先持有Home操作锁和跨进程路径锁，再进入候选准备；原活动库在候选处理前保持只读，正常writer在切换后创建。准备阶段先取得receipt，再读取facts，并在resume前显式释放来源连接，避免Windows句柄阻止切换。

持久化阶段为Prepared→Copied→Migrated→Validated→Switching→Switched，普通扫描成功后才Retained。跨进程恢复Validated必须重新校验候选；Switched可包含合法新增pending，不能再按切换前facts否定它。schema12/13/14接续通过原`accounting_structural_receipt`解码事实，serde合同必须保留。

生产切换在A内clone rollback、replace active、校验、记Switched并移除candidate；单测切换是物理库与sidecar改名，并可复用本次锁内生成的验证凭据。两条路径不互相替代，本批不修改任一条。`exact_legacy_recovery`对旧物理清单仍只选已提交main，或明确Switching且main缺失的可恢复rollback，不导入candidate。

## 验收及停止条件

1. 固定基线重建整个父文件和新增模块；SQL、类型字段/serde属性、编码函数体、比较规则、全部调用点逐字保持，仅允许显式导入和最小可见性变化。旧共享工具、ledger、既有三个新模块和状态机完整内容不得变化。
2. 复用实际schema9/10迁移、同数量内容损坏拒绝、持久化Validated重验、各切换点中断、旧补全收据、聚合滞后重绑定、事实复用/计数与旧原文缺失保护测试。迁移事实是跨版本序列化合同，核查后确认缺少针对缺省protected_tables与新增受保护表规则的直接断言；仅为此补两项聚焦用例，分别验证旧格式反序列化和受保护历史比较，不复制业务测试。
3. 云端运行双平台完整库、非test生产入口和原有负控；以本笔完整SHA运行Public097及0.9.8–0.9.11双平台历史形成状态接续，核对原始日志、源码清单和重复重开材料。测试成功不扩大为任意损坏库恢复或安装验收。
4. 本机不编译产品、不打开正式库；不合并、安装或发布。若要改SQL、摘要格式、迁移策略或锁/事务模型，在本步重新评估，不夹带行为修改。

完成证明提取和对应验证即结束本笔；不继续拆迁移切换、发布或路由。
