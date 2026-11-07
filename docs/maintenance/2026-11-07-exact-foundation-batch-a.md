# Exact 拆分批次 A：连接寿命与领域合同

按[总计划](../design/2026-11-07-storage-global-decomposition-master-plan.md)执行第一批。基线 `ba9b222ef5e1c2de5f4368f63dbb56d2912b3270`，工作树 `f97f/codex-token-dashboard`，分支 `codex/storage-responsibility-split-20261106`。本报告不表示后续 B–D 已实施。

## 本批边界

| 文件 | 职责 | 当前行数 |
| --- | --- | ---: |
| `exact_usage_index/connection.rs` | 生产/单测连接别名、打开入口、完整性检查、gate、唯一 active count、收据、ManagedIndexConnection/Drop、已发布只读 open、原测试钩子 | 1,192 |
| `exact_usage_index/contracts.rs` | 既有共享值类型、版本文字、目录列合同、纯编码/整数转换；不做数据库、文件系统、锁或恢复操作 | 399 |
| `exact_usage_index/store_metadata.rs` | 借入调用者绑定连接的 metadata 读写、schema 探测与逐行摘要；不另开连接、不开始/提交事务 | 141 |
| `exact_usage_index.rs` | 保留启动、扫描、回填、最终发布及迁移编排 | 15,892 → 14,321 |

`store_metadata.rs` 是对计划中“共享合同”的必要细分：不能把会执行 SQL、会写 metadata 的 helper 塞进声称纯数据的 `contracts.rs`。没有按预估行数强行移动迁移 manifest、proof 或文件系统扫描。阶段类型仍只有一份；原 serde 字段、字段次序、缺省值、版本字符串和字节编码不变。

连接原始 `Option<Connection>`、`receipt_eligible`、`tracks_integrity` 保持私有。将 `open_published` 原方法体归到连接模块内实现，让父层继续从原方法访问，无需开放这三个内部字段。`path` 仅对 Exact 域可见，服务原有单测维护分支；未提供裸生产句柄的新出口。

## 按生产副作用分类，而非按函数名分类

| 入口 | 核对的生产调用链/副作用 | 本批放置与约束 |
| --- | --- | --- |
| `open_read_only_index` | pool 路径：`Pool::current → open/prepare_schema（首次）→ lookup → restore`；普通路径：`open_exact_business_store → route::open_exact_store`，可能注册、导入、恢复 journal | 放入明确有副作用的连接层；函数注释注明不承诺只读，不用于 published reader |
| `existing_regular_index` | pool registry/handle 锁、首次 pool 准备、seal/旧暂存 ownership 查询、route 注册状态查询；已注册空命名空间路径还会打开 store | 放连接层；不能当 stat 或纯 exists；没有缓存“缺失”结论 |
| `open_index_connection_with_recovery` | 持 per-path gate 重查存在性、打开/PRAGMA、候选 receipt 核对、quick-check、active count 登记；receipt 路径可能调用 migration seal | 与 gate、receipt、Drop 在同一模块；仍拒绝损坏/临时失败，不删除重建 |
| `verify_no_orphaned_index_rows` | 缺 marker 时开启 deferred 事务，检查异常、写 clean marker、commit；marker 命中仍走原快路径 | 放连接完整性层，注明会写 marker；纯读取预检仍调用 `reject_orphaned_index_rows` |
| `schema11_file_stamp` | `route::exact_store_observation` 缺 seal 时调用 `seal_exact_store`；单测才是物理文件 metadata | 保留迁移编排，补注释；不移动到 contracts/文件签名工具 |
| `active_schema11_paths` / `_on` | 可能核验并登记旧迁移 receipt；`_on` 遇新旧 manifest 仍可回退 effectful 路径 | 保留迁移编排；只格式化路径的 `schema11_paths_for_namespace` 与其区别写明 |
| `validate_pending_snapshot` / `validate_pending_batch` | 相同 frozen proof 才允许 `Container::ensure_verified_backup` 重建；helper 可能保留异常 app-owned image 并写新备份 | 留在 route 导入恢复；只加注释，不移动、不重排 journal/activation |
| `turn_candidates` / `representations::verify_excerpt_source` | 摘录验证在原 snapshot 上用 savepoint 写物理证明、representation 状态和 raw binding availability | 原位置补注释；published-read-only 分支仍跳过摘录补充 |
| `runtime_recovery::valid_for_earlier_request` | 经 effectful open 打开/restore，读取来源字节验证；不是纯 predicate | 保留暂存恢复模块，注释传播其间接副作用 |
| `file_signature` | 打开 rollout reader、求 logical length；压缩源不等价于物理 stat | 保留原来源实现，注明非纯 metadata 计算 |

`open_published_index_read_only` 仍只开注册 namespace；`open_read_only_source` 仍是外部源的 unbound/query_only 连接。没有把这两类受限读取统一到旧 `open_read_only_index`。本批不改函数名字，以便严格核对原函数体和调用链；副作用说明放在调用者能看到的函数与模块注释中。

## 不变量与等价证据

- `ExactUsageIndex` 字段次序不变，managed connection 在 Home 租约前析构。
- `ManagedIndexConnection::drop` 原体保持：连接存活时捕获 receipt metadata → 关闭连接 → 进入 per-path gate → 关闭后签名/写 receipt → active count 减一 → 释放 gate。文件 I/O 不移进全局状态锁。
- `IntegrityGate`、弱引用 registry、active count、全部 receipt 类型和检查函数一起归位，未复制全局状态。原 fault hooks 的位置和测试方法路径保持。
- 生产 `StoreConnection` / `StoreTransaction` 与 `cfg(test)` 的 rusqlite 别名在连接模块唯一声明；消费方显式导入。未修改容器/绑定实现，未新增连接、事务、线程或 hash/quick-check 次数。
- ledger、canonical、representations、empty_sources、runtime_recovery、message_links 的生产入口不再通配导入整个父模块。目录、标题、schema、publication、proof 改为直接引用相应基础模块；函数体不变。域内测试/fixture 的既有通配导入没有一并重写。

本地只做源码检查：完整文件重建核对 17 个变动/新文件，并检查其余 202 个既有 Rust 源文件逐字保持。独立词法核对覆盖这 17 个文件内的 **615 个函数体和 3,135 个业务字符串/SQL 字面量**，前后字节一致；新增 import 的 cfg feature 属性单独排除，不排除函数体、SQL、schema 或 serde 字符串。覆盖范围包括 scale fixture 的既有函数体，因为该文件新增一条指向收据后缀常量的 import。使用 rustfmt 的 stdout 模式只解析语法，不改写源码、不编译依赖。

字节核对器还在内存副本中改动关闭语句和 quick-check SQL，两种变异均被拒绝；没有改动产品文件。这是静态核对器的负控，不冒充生产行为负控。

证据位于 `scratch/exact-foundation-a-20261107/`：`extract.mjs`（完整重建/修改白名单）、`equivalence.json`、`verify-bodies.mjs`（独立逐体/字面量核对）、`body-equivalence.json`。这类静态证据不替代云端的类型检查和生产路径验证。

## 云端验收状态

受测产品为 `4e0b4143707a4a0fc4feff7fc543a9f7cd5a19d7`，[云端运行 42388387325](https://github.com/hututuo/codex-token-bar/actions/runs/42388387325)全部成功，原始产物于 2026-11-08（Asia/Shanghai）下载并复核完成。本批复用既有完整库、非 test 生产场景和备份清理负控；额外核对连接/gate/receipt/orphan 测试实际执行，不编造“新增完整性变异负控”。

| 证据范围 | 当前候选实际结果 |
| --- | --- |
| macOS 完整 Rust 库 | 1,798 通过，0 失败，14 项原有 opt-in ignored；与紧邻受测基线全部测试身份和结果一致 |
| Windows 完整 Rust 库 | 1,742 通过，0 失败，14 项原有 opt-in ignored；与紧邻受测基线全部测试身份和结果一致 |
| 指定保护用例 | 两端各 96 项实际通过，含前批 80 项及本批额外核对的 16 项 connection/gate/receipt/orphan/snapshot 用例 |
| 常规生产与 fixture feature | 两端编译通过，两端各 16 个非 test 生产场景通过，使用原校验器逐份复核 |
| 原有备份清理负控 | 两端原实现通过、禁用清理失败、恢复后通过，退出码 0/101/0，源码恢复 hash 与日志 hash 一致 |
| Swift 完整库 | 2,361 通过，37 项原有跳过；与 execution 记录和日志摘要一致 |
| 前端、云端脚本、发布脚本 | 分别 1,421、18、111 通过；发布脚本原有 1 项跳过，前两者无跳过 |
| Windows updater / packaging 检查 | CI job 与 native 步骤通过；未生成或安装发行包 |
| CI 封存 | sourceSha、runId、expected job outcomes、checked-source 与当前候选严格一致 |

生产报告保留恢复期只读、暂存恢复、旧源保全、namespace 绑定、持有连接查 owner 和并发 A 写入等 16 个场景。报告中的目录操作边界没有扩大：`catalogActionsVerified=false` 仍不能当成会话删除功能已验收。没有新增查询数、quick-check 或回填速度结论。

按总计划，本批没有单独运行 Public097、四版本历史 producer 或全量性能矩阵；这些仍是 C/D 和最终同 SHA 收束的验收项。相关 job 在封存中明确为 skipped，不计作本批通过。

首轮 `145167da` 的[云端运行 42386443810](https://github.com/hututuo/codex-token-bar/actions/runs/42386443810)在生产编译中拒绝了错误的导入条件：`ledger` 的 `set_metadata`、`column_exists_checked`、`Transaction` 被误标为 test-only，继而触发类型推导错误。macOS 单测分支仍通过 1,798 项，恰好说明单测不能代替生产配置。后续 `cb121ae1` 修正这些 import；提交后送重跑前，又核对 fixture feature 的模块依赖，`46bf3ad1` 补齐其显式 `stage_pool` import。修正均只涉及 use/cfg，前述函数体和 SQL 等价核对继续通过。失败轮不计为本批验收通过，未放宽任何门禁。

第二轮 `46bf3ad1` 的[云端运行 42387555344](https://github.com/hututuo/codex-token-bar/actions/runs/42387555344)通过了两端常规生产编译，随后 fixture feature 编译发现 `ledger/scale_fixture.rs` 原先通配导入的 `INDEX_INTEGRITY_RECEIPT_SUFFIX` 已不在父层。`4e0b4143` 将该常量仅开放到原 Exact 域，并让夹具明确从 `connection` 导入；常量值、收据协议和夹具函数体未改。未恢复父层的通配中转，也没有修改工作流跳过失败。

两轮的完整 Rust 测试分别均为 macOS 1,798 / Windows 1,742 通过，但不能抵消生产配置/feature 编译失败。第二轮两端 native 完成后，为释放分支队列取消了旧轮剩余任务，最终状态为 cancelled；原始日志保存在 `attempt1/`、`attempt2/`。最终轮重新执行所有本批必需步骤，没有拼接旧轮的通过证据。

`validate.py` 复用前批原证据校验器，再加入紧邻基线测试身份全等、本批 16 项保护、受测 Git blob 与当前源码逐字对应、CI 封存和用户原文件 hash 核对；生成 `native-validation.json` 与 `final-validation.json`，两者为 PASS。执行只解析已下载文件，不运行原生程序、不访问数据库。本批产品已提交/推送任务分支，后续仅封存本文及总计划的实施状态。

没有访问正式数据库、安装或发布。原有 Windows 报告和未跟踪材料均保留；该报告原 SHA256 为 `63801116c53adee10cb0692cdad6553e6187906f7659ae0aea67b69d4f24ecef`。
