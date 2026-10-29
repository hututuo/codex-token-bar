# Codex 旧库归并与共享日志读取

本分支 `codex/multi-client-tokens`，起点 `d195cbb4`。本批只改独立工作树；未迁移真实用户库、未安装或重启正式应用、未替换 Windows EXE、未请求 Anthropic、未启动 enabled reporter。

## 两个长期可写业务库

- A：`codex-ledger.sqlite`。Swift 位于原生版 Application Support/CodexTokenBar；Tauri 位于其既有应用支持目录（由原 quota-history 路径定位）。归并各 Home 的 Exact 索引、额度历史、正文速度、ModelTrace；Swift 还归并原 SQLite 安全协调库，Rust 的既有安全 JSON 不改成第三个数据库。
- B：`multi-client-usage.sqlite`。保留本分支已实现的多客户端用量、活动速度明细/五分钟桶、旧 Claude 测速隔离记录。保留原 TTL；不把 Codex 原账复制到 B。
- 旧文件、只读迁移快照、WAL/SHM、SQLite 自动 TEMP spill 都不是第三个活跃业务写入库。旧文件不再作为普通业务写入目标，不自动删除。

### A 的共同容器规范

Swift/Rust 引用同一 `Sources/CodexTokenBar/Resources/codex-ledger-schema.sql`，物理 `user_version=1`。六张容器表分别登记模块/来源、原对象、导入证明、不可变 job 封印及旧输入退役回执。

旧模块表以 `s<store-id>_` 隔离；store-id 为 `SHA256("tokenbar-store-v1\0" + module + "\0" + sourceIdentity)`。保留每个旧库的原行号、主键、隐藏 rowid、原 schema 与模块版本，不以 UUID 合并不同 Home。Swift/Rust 旧 Exact 本来不是相同 DDL，本次保留为显式不同的版本化模块；共同容器版本不冒充旧模块 schema 版本。SQL 兼容层只绑定对象标识符，字面值/参数/注释不变；模块不能切换物理 journal、替换整库或运行全库 VACUUM。

### 升级、恢复与旧账证明

1. 启动门在所有业务 writer 前完成。已有正式实例/迁移锁冲突时停止迁移；不结束别人的进程。
2. 枚举受支持旧库；SQLite backup API 获取含 WAL 的一致快照。保留原文件与快照；旧 schema 升级只作用于私有副本，磁盘空间不足/未来版本/未知 schema/源变化时停止，不删旧账腾空间。
3. 每个模块导入事务同时提交原对象、逐表计数、规范化 schema 和类型敏感行哈希、来源回执。证明包含 NULL/Blob/NUL 文本、Int64/Double、主键、隐藏 rowid、WITHOUT ROWID、索引/外键/触发器、模块版本及 AUTOINCREMENT 序列；不只比较总 Token。重复导入不会覆盖已在 A 发生的新写入。
4. Swift 首次在固定私有候选完成，原子激活并写 initialized 标记；Rust 在独立模块事务中导入，全部完成后写同格式标记。中断可重试，业务模块不得在门完成前启动。激活后 A 丢失或 inode/FileID 被替换时故障关闭，不从残留旧文件偷偷建立空库/回灌旧账。
5. 旧 schema11 交换中断保留原 manifest/candidate/rollback，从最后已提交主库或经严格校验的 rollback 重新准备；不信任未完成候选。原 JSONL 删除/归档不删除已提交历史；fork 去重/新增轮次算法不变。
6. Exact job 在 A 内隔离并封印；job 的完整性/大小取其自己的逻辑证明，不取 A 文件大小/mtime，因此额度等模块写入不使已完成 job 失效。成功发布后仅退役已消费 job；原旧 stage 输入回执继续保留，防止下次启动复活旧 job。
7. 解析先写连接内 TEMP（FILE，4MiB 页缓存），不长时间占用 A 的唯一 writer；源验证后短事务物化四张 stage 表，再沿原整代发布事务提交。失败留断点和上次可信代。Swift 两阶段调度避免发布事务中再用第二连接写 stage 的自锁。
8. Swift safety 逻辑恢复只导出/重置自己的命名空间；物理 A 损坏直接停止，不把全 A 隔离成只剩安全表的新库。

物理维护由容器统一节流到每日；新 A 使用 incremental auto-vacuum，旧模式只复用空闲页。不能用 full VACUUM：SQLite 会重编号无 INTEGER PRIMARY KEY 的隐藏 rowid。备份回退仅用于保留/人工恢复；新版发生的新账不能靠覆盖回旧快照安全撤销，需显式对账，不提供静默降级覆盖。

## 共享读取边界

两端共用“物理字节读取”，保留独立的解析器、游标、持久断点和计算口径。

- Swift `SharedSourceIO`；Rust `shared_source_io`：同物理文件版本共享 64KiB 页，缓存总上限 64MiB、256 文件，单次请求不超过 4MiB。按设备/inode 或 Windows 128 位 FileID 与大小/mtime/ctime 验证；前后版本变化返回失败，原消费者保留断点重试。
- 历史、Bar、正文 TPS、多客户端记录及 vendored plain/zstd tailer 走该入口。验证前缀/压缩帧边界必须 uncached 物理复核，不能拿缓存证明缓存；没有强行共用消费游标或改变 Token 存在性语义。
- Windows C# reader/reporter 的 transcript 通过有界 stdin/stdout `sourceRead` 帧向 Rust 读取服务取字节；不是另开本地服务器，也不代理请求。校验用户许可根、文件身份、范围/帧大小、并发数、取消/超时/EOF；禁止 UNC/远程映射盘、设备路径、reparse/offline/cloud recall。小元数据验证、根发现仍有必要的本地 stat/探测。
- OpenCode 等外部 SQLite 保留原生 **只读** SQLite/WAL 查询，不包装成 transcript 字节流；不声称消除了重复 SQL 查询。缓存逐出或文件追加/改写会合法重读；这里不是“整份日志永远只读一次”。
- Agent Speed 原解析/计算继续维护。Bar 原曲线、错误停止/收尾、正文 TPS 与排行榜计算不合并；Claude 没有新增正文 TPS、网络额度请求或上报。原显示/上报来源开关语义不变。

### 上游同步

Pin 仍为 `a94a67fcc78e5d8eea5f82d8d5e737bccf994e2c`。来源锁登记 34 个适配文件；新增共享 IO 位于 vendor 外，vendor 只加入口及本地盘保护。同步需同时检查 Package.swift、C# Core/Reader/Reporter 项目链接、LocalSourceReadPipe、PositionedReadBackend、Rust 服务协议及两端文件身份规则，不能只复制 vendor。离线来源校验和工具测试通过；本批未查询远端 HEAD。

## 验收

最终结果在下方追加；日志仅位于本分支忽略目录 `scratch/`。所有迁移运行均为临时夹具，不是实际安装验收。Rust 除旧 cfg(test) 回归外，还提供显式 feature-gated `business-store-fixture` Cargo example，运行真实非 cfg(test) 的 bootstrap/Exact/Quota/ModelTrace/BodySpeed 路径；使用 `cargo run --example business-store-fixture --features business-store-fixture -- <临时根>`，必须给五个任务专用路径覆盖且全部落在临时根内，拒绝用户 Home。该 example 不作为应用 binary 被 Tauri installer bundle 收集。

Windows 真机文件系统、正式包升级、长期运行/功耗为 NOT_RUN；交叉编译与离线管道自测不能替代这些验收。

### 已确认结果

- PASS：Swift 最终全量应用 XCTest 2056 项（20 项条件跳过）、本地采集 8 项、Agent Speed 649 项/76 suites，零失败。`scratch/a-migration-swift-final2.log`。新增迁移/证明/共享 IO 回归含跨模块自增序列、隐藏 rowid、NUL、WAL、不同 Home 同 UUID、旧 stage、schema11 中断回滚、safety 局部恢复与 TEMP 期间第二连接写入。
- PASS：Rust 非 cfg(test) 生产路径 fixture，`scratch/a-production-fixture-final3.log`。临时根 `/private/tmp/tokenbar-business-production-u2xaguyd`；quota/ModelTrace/body/Exact 读写、两 Home 175/240 Token 隔离、旧文件哈希不变、stage 恢复/保留、重复启动、丢失 A 故障关闭。TEMP 事务未提交时使用第二连接成功写入 A。五个任务专用环境变量均限制在临时根，未改 HOME/CODEX_HOME。
- PASS：前端 1289/1289，TypeScript/Vite 构建；`scratch/a-migration-ui-tests.log`、`scratch/a-migration-ui-build.log`。本轮未修改 UI 模块。
- PASS：Reader/Reporter .NET 编译 0 warnings/0 errors（本轮临时 SDK），最终离线 self-test 均通过，含共享读取管道契约；`scratch/a-migration-dotnet-reader-final.log`、`scratch/a-migration-dotnet-reporter-final.log`。没有运行 enabled 网络入口。
- PASS：Agent Speed 干净上游来源锁核对、维护工具 7/7；`scratch/a-migration-vendor-final.log`、`scratch/a-migration-vendor-tests.log`。
- PASS：Rust 最终全量 1481 通过、0 失败、11 ignored，`scratch/a-migration-rust-final2.log`。共 1492 项，包含共享读取、模块证明、旧输入保留、错误停止、fork/归档/删除历史及 watcher 回归。新增路由夹具初次误用只读连接更新旧输入，修正夹具后定向和完整回归都通过。
- PASS：Windows 最终 `cargo xwin check --target x86_64-pc-windows-msvc --lib --offline --locked`，`scratch/a-migration-windows-final2.log`，含既有警告；未生成或执行正式 EXE。
- PASS：新 Rust 文件 rustfmt，`git diff --check`。未对庞大的旧 Exact 模块树作无关格式化。

初始回归曾发现并修复：macOS `/var`/`/private/var` 枚举别名导致漏发现中断迁移；逻辑证明不应依赖其他模块是否创建 sqlite_sequence；空 AUTOINCREMENT 表的目标序列必须连同缺失状态一起替换；Rust TEMP 比较表、封印 stage 别名的查询/元数据绑定必须走实际对象目录。这些失败日志保留在 scratch，不能作为当前通过回执引用。
