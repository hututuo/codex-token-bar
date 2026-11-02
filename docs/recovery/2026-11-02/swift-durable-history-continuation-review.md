# 缺失原文与多次旧版补全：独立设计审查

## 审查范围与状态

本轮从 `104c5cae`（主分支整合为 `5f30bb6c`）的 metadata replay 及真实旧版 formed-release `enriched` 场景继续审查。实现文件为 `ExactRetryMetadataReplay.swift`、`ExactRetryAppendCoverage.swift`、`CodexUsageHistoryIndex.swift` 与 `UsageEventLedger.swift`。

这份记录说明数据保全边界和新增回归要求，不声称完成了这些状态的原生验收。新增 XCTest 使用当前生产 owner 的 `synchronize`、生产 parser、迁移和重开接口形成状态；它们不是替代真实 v0.9.8–v0.9.11 producer 的矩阵。

本地 Linux 没有执行 Swift 编译或 XCTest。实际执行了一个有限的 SQLite 检查：从生产 Swift 源码提取 `sources`、`events` 和 ledger 表的 DDL，从新增测试逐字提取 15 条攻击 SQL；每条语句都能改变隔离数据且仍通过 `PRAGMA quick_check`。这只验证反例不是语法错误或底层损坏造成的假拒绝，不能证明 Swift 恢复实现通过它们。

## 已识别的合法状态

### 同一来源连续两次 full reparse

G0 的数据库已被导入未完成 A，其中事件的 model、turn 和 assistant 位置尚为 NULL。旧 owner 在 G1 通过真实 `admit` / `enrichTurn` 补齐这些信息。之后 G2 在原文前加入不产生消费的上下文并再次完整扫描。

生产 ledger 保留第一次形成的非 NULL 事件 metadata；当前 `usage_ledger_bindings` 则指向 G2 的原文位置。`usage_ledger_turns` 同时保留 G1 与 G2 的关联。只从 G0 重放最终 G2 原文会出现两个问题：

- 见证没有观察到 G1 的历史 turn 行；要求候选严格等于“G0 + 最后一次 parse”会拒绝正常候选。
- `events.assistant_start_offset` 保留 G1 的位置；从 G0 的 NULL 直接按 G2 parse 推导这个值会得到另一位置。只允许额外历史 turn 行不足以解决此问题。

同类问题也适用于 G1 填入 model 后，G2 原文的 context 发生变化：生产 ledger 保留第一次获得的非 NULL model。最后一份原文不是数据库中所有中间历史版本的唯一证明。

### 已落库后原文消失

旧 owner 已正常写入追加事件或补全 metadata，然后原文被归档、删除或暂时不可用。这个顺序与“迁移成功后再删除 raw 并重开”不同。原有 formed-release enriched 场景主要证明后者，不能据此宣称前者已通过。

还需允许旧 owner 已观察到缺失的状态：它会把 `usage_ledger_sources.missing` 置为 1，并使绑定 unavailable，但保留数值 ledger。文本可用性下降不等于消费历史应被撤销。

## assistant 字段的使用边界

实际详情查询 `turnSourceReferencesExclusively` 使用当前 binding 的 `raw_offset`、`prompt_offset`、`assistant_offset`，并要求 binding `available=1`、与 `usage_ledger_sources.generation` 相同、source `missing=0`。它没有把旧事件的 assistant 数值当成当前原文地址。

dashboard 两个 turn 聚合使用 `events.assistant_start_offset IS NOT NULL` 选择代表事件；它们不读取该数值指向的文本。`UsageHistoryRetention.locationExpressions` 在存在 bindings 的 schema 中也使用绑定位置。

因此可以保留 G1 事件字段作为历史信息，同时对可用的当前 binding 作独立验证。把 G1 字段改为 G2 数值以满足重放比较，会改变已有历史，不能作为修复方案。

## 可证明的保全要求

持久数据库是迁移输入。原文存在时提供额外验证；缺失原文不能单独成为丢弃已落库历史或永久拒绝正常状态的理由。替换未完成 A 仍须满足以下要求。

| 方面 | 必须保全或验证的内容 |
| --- | --- |
| 旧事实 | 冻结事件的稳定 ID、时间、所有 typed 数值与 accounting 字段逐条接续，包含零 token 诊断；不能只比较 SUM、行数或 ordinal。 |
| 旧 metadata | 原先非 NULL 的 model、逻辑 turn 等不能被覆盖或清空。NULL 补全和新增历史关联须与替换已有事实分开处理。 |
| 身份与归属 | 冻结 identity / fingerprint 映射和 source 归属不能消失或被重新指向另一个事件、来源或 Home。 |
| 当前绑定 | source / event 引用必须存在且同属一个来源；可用绑定必须对应 owner 的当前 generation。缺失文本可以使绑定不可用，不得因此撤销数值事实。 |
| 历史关联 | 旧 turn / identity 行必须完整保留；多次扫描新增的历史 generation 不能因为最终原文未再提及就被删除。新增关联也不能引用不存在或属于其他 source 的对象。 |
| 可见性 | 不能通过添加 fabricated duplicate 标记，让冻结的有效 canonical 事件从统计中消失。物理行还在并不等于历史仍可使用。 |
| 未识别历史 | 未识别表及其中已有 typed 行、rowid 等仍需完整接续；不能因当前兼容代码不理解它们而忽略。 |
| 结构 | 列名、类型、键、表形态、索引、触发器和视图是契约的一部分。相同 row digest 不能授权 input/output 列角色互换或新增会删除历史的 trigger。 |
| 派生值 | 当前投影应由保留的 ledger 按生产规则重建或验证。无法由这些事件解释的旧 attribution floor 不能被重建为更低值后遗忘。 |
| 发布窗口 | 原始输入和规范化候选须有独立快照与完整 proof。最终替换时，在同一写事务内重验旧 A 与候选的绑定 proof；读取时通过不等于发布前仍相同。 |

这些要求不意味着沿用旧错误计费。确有证据的数值纠错应有明确、独立的契约及旧版本保留方式。本轮 model / turn 接续不能借“兼容”泛化为任意数值替换授权。

## 不能从现有证据推出的保证

假设冻结数据库 O 保存 120，候选 C 保存相同旧 120 加一个内部自洽的新 55。如果原文已经不存在，而且 C 的事件、identity、checkpoint、cache 都一致，那么仅用 O 与 C 无法区分“真实旧 writer 写入 55”和“其他工具同时伪造全部新增记录”。普通哈希和 fingerprint codec 都不构成签名或外部事实证明。

可靠的迁移保证应是：保全 O 的有效历史，完整保留 C 的已有记录，验证 C 的结构、归属和引用一致性，并通过 snapshot + CAS 确认导入的就是接受审查的那份 C。它不能声称缺失原文时重新认证了所有新增消费的外部真实性。

因此新增负例针对可判定的丢旧行、改旧值、隐藏历史、错引用和结构变更；没有设置“原文缺失但仍能认证任意新增消费事实”的伪门禁。对无法判定的状态，需要保留原件及历史证据并明确说明验证边界，不能悄悄把新增历史截掉。

## 新增成功要求与反例

测试文件为 `Tests/CodexTokenBarTests/BusinessDatabaseMigrationExactAppendTests.swift`。

- `testTwoReleasedStyleMetadataReparsesAfterFrozenImportResumeWithHistoricalTurnsAndMissingRaw`：真实 G0 → G1 → G2；验证两代 turn 和移动后的 binding，要求迁移成功，再删除 raw 并以新 owner 重开。已单独提交 `f77bacfd`。
- `testDurableOldWriterAppendRecoversWhenRawDisappearsBeforeMigration`：追加 17 后已落库，升级前 raw 消失，最终 canonical 总量应为 482。
- `testDurableOldWriterMetadataCompletionRecoversWhenRawDisappearsBeforeMigration`：单次 metadata 补全落库后 raw 消失，要求 465 及完整历史 metadata 接续。
- `testDurableRepeatedMetadataCompletionRecoversWhenRawDisappearsBeforeMigration`：G1 与 G2 都已经落库后再删除 raw。
- `testDurableAppendAlreadyMarkedMissingByOldWriterRecoversWithoutRaw`：旧 owner 自己完成空发现并持久标记 missing 后再迁移。
- `testMissingRawContinuationRejectsLostFactsHiddenRowsBrokenReferencesAndUnknownHistoryLoss`：先要求一个合法无 raw 候选成功，再分别执行 15 个可判定攻击。这样“全部拒绝”的实现不能成为假成功。

成功测试额外放入包含 NUL 文本和 BLOB 的 opaque 历史表。迁移后要求目标 namespace 的完整 proof 等于 receipt 与独立规范化快照，后续无 raw 同步/重开仍保留历史。原数据库、冻结快照、原备份和测试保留的 raw 副本都检查 full proof 或字节不变；拒绝路径也不能改写原件。

原生运行入口为 macOS 上的 `swift test --filter BusinessDatabaseMigrationExactAppendTests`，实际 runner / Xcode 版本由恢复 workflow 固定。需要观察这些成功要求真实通过，同时所有攻击被拒绝，再将这部分状态标为已验收。当前报告不能代替运行结果。
