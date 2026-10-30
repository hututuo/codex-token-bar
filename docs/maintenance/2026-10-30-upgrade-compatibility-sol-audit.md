# 2026-10-30 上一公开版本升级兼容性审计（Sol Max）

审计起点：`dea70b3a7208fb95f68a301b46c400cd2fc79eeb`。修复由 root 与本审计 worker 分工完成，冻结源码为 `09709b766e8e85ed66621d82cf2c7a7de9900bfd`，统一 CI 为 [41027520753](https://github.com/hututuo/codex-token-bar/actions/runs/41027520753)。本报告完成时尚未取得云端最终结果。所有本 worker 运行夹具位于临时目录；没有打开或修改真实 A/B、安装应用、重启正式进程、运行 Windows EXE 或请求 Anthropic。

## 升级基线与结论

通过只读 `gh release list/view` 核实，最近公开稳定版为 [v0.9.7](https://github.com/hututuo/codex-token-bar/releases/tag/v0.9.7)，发布时间 `2026-10-22T05:37:47Z`，本地 tag 指向 `0219554ce444b0013987da7b82e3c2e891f4afdb`。这里审查的是该公开版本及较早已知索引到当前双库方案的升级；build 979 仅是本次任务提供的已安装版本参照。

主 Exact 索引版本号覆盖公开基线，原记录与 fork/删除保留路径仍在。不过“能识别 schema14”不能证明整个升级完整：本次发现两个会使旧历史从界面中消失的缺口，均需修复与当前源码 CI 通过后再接受候选。

| 输入基线 | Swift Exact | Rust Exact | 当前接入与边界 |
| --- | --- | --- | --- |
| v0.9.0 / v0.9.1 | 6 | 9 | 已知结构转换、会计与表示层迁移；原库保留，变换作用于快照/受管候选 |
| v0.9.2 / v0.9.3 | 13 | 13 | 已知版本可前向升级到 14，再进入 A 的独立来源分区 |
| v0.9.4 至 v0.9.7 | 14 | 14 | 主版本号不变；迁移重点是原独立索引/模块库进入 A，而非重算原 Token |
| 已知中间候选 | 7 / 11 / 12 | 10 / 11 / 12 | 既有允许集合覆盖；仍检查 accounting/parser/provenance 等子版本 |
| 更早、未知或未来版本 | 不在 Swift 6/7/11/12/13/14 集合内 | 不在 Rust 9…14 范围内 | 不宣称可用；Swift 可原样保留休眠来源，活动 Home 的读取仍拒绝未知版本 |
| v0.9.7 正文测速历史 | `observed-speed-<SHA>.json` 数组 | `observed-speed-<FNV>.json`，`StoredSamples.version=1` | 审计起点遗漏；本次补 JSON 到 B 的一次性导入，不能只测试中间 SQLite 到 B |
| 本分支已有 B | `user_version=2`；活动速度子 schema 1→2 | 同左 | 活动速度添加 source identity，旧表保留；未知子版本拒绝，B 的物理版本归 usage ledger 所有 |

版本数字来自 `git show <tag>:<file>`，不是把当前空库改数字模拟公开版本。较早真实发行版的结构迁移、对账与失败恢复记录见 `docs/releases/v0.9.2-statistics-index-migration.md`；此前容器升级恢复缺口及修复见 `docs/maintenance/2026-10-28-upgrade-compatibility-audit.md` 和 `2026-10-28-upgrade-recovery-fixes.md`。这些既有结果不冒充本次重新运行。

## 本次发现与最小修复

### P1：不完整的旧库发现可以发布“已完成”

起点 `BusinessDatabaseMigration.swift:302-329` 先用 `fileExists` 判定目录存在，再创建没有 `errorHandler` 的 Foundation 枚举器。权限错误可能成为“目录不存在”或“枚举到 0 个文件”。真实生产迁移/SQLite/容器七个源码文件组成的临时小 harness 复现：旧 `modeltrace/modeltrace.sqlite` 有 id 42，父目录 chmod 000 后迁移返回 READY，写入 initialized 标记，A 的 `tb_stores=0`。原文件未删除，但升级错误地宣布完整并隐藏旧历史。

Rust 的 `business_store_route.rs` 旧 quota/ModelTrace `.filter(path.is_file())`，以及 Exact `collect_exact_legacy_inputs` 的 `source_root.is_dir()` 也把 metadata 错误折叠成缺失；这是同类源级缺口，未冒称已做 Windows ACL 实机复现。

修复：root 改 Swift 为严格 stat/lstat 与带错误回调的枚举；仅确认缺失允许空输入。实际遍历解析后的根，保留配置路径映射，以继续支持合法的目录根符号链接；悬空根和后代不安全链接仍拒绝。本 worker 改 Rust 旧文件与 Exact 根为严格 metadata 检查，保留原先可用的配置目录别名；已经发现的根/子目录在遍历中消失也报错。权限/I/O 失败不会生成“迁移完成”回执。

### P1：真实 v0.9.7 的 JSON 测速历史没有进入新库

公开 tag 的 Swift `LiveRateMonitor.swift:1030-1042` 加载 `observed-speed-*.json`；审计起点 `LiveRateMonitor.swift:1153-1161` 建立空 collector，只读新的 `body-speed-*.sqlite`/B。`BodySpeedMigration` 复制四张既有 SQLite 表，无法读取该旧 JSON。Rust tag 的 `observed.rs:1310-1357,1461-1485` 使用 JSON `StoredSamples`；新 `ensure_loaded` 和 `storage_path` 只读取 SQLite。原 JSON 留在磁盘不能代表旧正文历史仍可显示；Rust 的 `bodyRetentionDays=15` 也被遗漏。

修复：在已有 SQLite/A→B 迁移后、读取 retention/宣布 body owner loaded 前，按同一来源文件名导入 JSON。Swift 由 root 实现；Rust 位于 `speed_trend/legacy_json.rs`，`speed_trend.rs:103` 提供窄入口，`observed.rs` 调用。仅 completed_body/o200k 数据进入正文表/趋势；完整原 JSON 与哈希备份保留，包括旧 stream 证据。已存在的 SQLite ID 优先，不被旧 JSON 覆写；数据、retention 与来源级 meta 回执同事务提交。回执阻止重启后复活已清理旧行。Rust 保留旧封装 version1、15/30 偏好及 networkWarning 的历史布尔兼容，输入上限 16 MiB；Swift 保持旧上限 64 MiB。未知格式、不可读文件、损坏备份、未来时间样本均故障关闭，不把失败当作空历史。

## 其余兼容性检查

- **两个可写业务库**：A `codex-ledger.sqlite` 的物理 `user_version=1` 与每个旧模块版本分开管理；B `multi-client-usage.sqlite` 管多客户端用量、活动速度与新正文历史。旧模块文件、快照、JSON 和 SQLite 临时 spill 是保留/恢复证据。没有新增第三份业务数据库。
- **原记录和账值**：A 的 store ID 基于 module/source identity，不按会话 UUID 跨 Home 合并；导入证明比较 schema、类型敏感行、隐藏 rowid、主键、自增序列等。相对 v0.9.7，`UsageEventLedger.swift`、`UsageHistoryRetention.swift`、`UsageAccountingState.swift` 没有改动。不能把后续派生曲线重算称为原账重建。
- **删除、归档与 fork**：已入账历史的保留仍依赖 durable ledger；缺失 JSONL 不应触发删除已索引账值。fork 已继承段去重与新增轮次归属路径保留。既有 A 迁移与 Exact 回归覆盖这些路径，本 worker 未重新跑全量。
- **启动顺序**：Swift `ApplicationStartupCoordinator` 在后台门成功后才构建 runtime；Rust coordinator 在 bootstrap/maintenance 完成前阻止普通 store owner。迁移失败保留旧库/候选并可重试。Body JSON 迁移失败另行阻止该正文 owner，不能变成 loaded 空历史。
- **恢复与备份**：此前的 pending journal 修复仍在；未完成批次重试重新核对，已激活分区不重新灌入冻结旧库。Rust A 的备份使用唯一临时文件、内容校验、单文件封装、同步与原子发布；Swift 每次 A 导入有独立 attempt。A 丢失而 initialized 仍在时拒绝建空库；运行中 A 身份替换也拒绝继续写入。
- **来源和账户**：Exact 按 Home 隔离；quota 还使用 Home、稳定账户、plan、limit 身份。B 的用量主键为 client/event ID，展示语义是本机该客户端的累积用量，不因此获得“每个订阅账户独立账本”的保证。活动速度有 source identity，预览 B 使用单独路径；没有发现本次迁移把 Codex 原账复制到 B 的路径。
- **旧设置**：既有 display/surface、侧栏次序/隐藏、颜色、source 开关兼容路径仍在；新增项补默认值。上报沿用明确 consent，默认关闭，Claude 仍从上报来源排除。扫描旧持久 JSON 文件名时，除上述 observed-speed 路由，settings、实例登记、unread、auto-resume、侧栏位置与旧缓存位置仍有生产引用；未对每个设置做本次运行验收。
- **降级边界**：没有 A/B→v0.9.7 的反向同步。旧版可能继续读取冻结的旧文件，无法看到新版新增记录；旧版运行后产生的分叉也不能靠普通重新升级猜测合并。回退必须保留最新 A/B 与原始日志，并单独对账；不能覆盖最新 A/B 为旧快照。

## 本次验证与剩余门禁

新增 Swift `UpgradeCompatibilitySolAuditTests.swift` 共 8 项，覆盖不可读嵌套目录/根/祖先、真正缺失、合法/悬空根链接、公开 JSON 导入/幂等/原文件、较新 SQLite ID、回执防重放、坏 JSON。`swiftc -frontend -parse` 通过，尚待当前源码云端 XCTest。

Rust 新增 JSON 回归 8 项、Exact 发现回归 3 项、route 元数据回归 2 项。覆盖旧 stream 排除、历史布尔 warning、15 日偏好、已有 ID/偏好优先、重启/清理、防损坏与超限、回执失败回滚、未来样本、缺失/权限/链接。新模块 rustfmt 解析通过；按 root 的构建边界未做本地 Rust/app 大编译。当前源码的 cfg(test)、非 cfg(test) business-store-fixture 与 Windows 编译由统一云端 CI 完成。

独立小 harness 保存在 `Tests/CompatibilityFixtures/UpgradeCompatibilitySolProbe.swift`，只为发现门提供 AppResources 定位及无关 Exact/SourceFileObservation stub；迁移、SQLite driver、SQL namespace、容器、路由、文件锁均使用实际源码。它不验证完整 Exact schema 转换或新 JSON importer。编译七个生产文件：`SQLiteDatabaseDriver.swift`、`SQLiteStoreNamespace.swift`、`SQLiteStoreConnection.swift`、`CodexBusinessDatabase.swift`、`BusinessStoreFiles.swift`、`CodexCrossProcessFileLock.swift`、`BusinessDatabaseMigration.swift`，加该 fixture；只需把 `TOKENBAR_AUDIT_REPO` 指向源码以读取 SQL 资源。场景参数为 `nested/root/ancestor/absent/root-symlink/dangling`。

未执行：真实旧安装包覆盖安装、真实数据库迁移前后对账、Windows ACL/进程中断实机注入、降级/重新升级恢复演练。源码审查与夹具不能替代这些接受条件。根链接的第一轮 harness 曾准确发现 Foundation ENOTDIR，已反馈 root 修正遍历根；最终小 harness 结果由最后验证补记记录。

### 最终小 harness 验证

七个实际生产源码文件与独立 fixture 编译成功，六个场景均通过，进程退出码均为 0：

| 场景 | 迁移结果 | initialized | 结论 |
| --- | --- | --- | --- |
| 嵌套 ModelTrace 目录不可读 | 抛出权限错误 | 不存在 | PASS |
| Exact 根目录不可读 | 抛出权限错误 | 不存在 | PASS |
| Exact 祖先目录不可搜索 | 抛出权限错误 | 不存在 | PASS |
| 旧目录真正不存在 | ready | 存在 | PASS |
| 合法的配置目录根链接 | ready | 存在 | PASS |
| 悬空的配置目录根链接 | 抛出不安全输入错误 | 不存在 | PASS |

这次编译也验证了 Swift 枚举错误回调和后台迁移源文件之间的实际类型兼容；它仍不替代云端 XCTest、Rust 编译或安装验收。`git diff --check` 通过。Native 8 项新测试与 Rust 13 项新测试的执行结果由上述冻结源码 CI 提供，不能从语法解析或该小 harness 推定全套已经通过。

## 独立保留的已知问题

macOS 27 的 SwiftUI 懒列表辅助功能整页跳转（AXScrollToBottom/Top）崩溃仍未关闭，见 `2026-10-30-build976-accessibility-scroll-crash.md`。本次减少数据库读取与无效刷新，不声称修复该系统交互路径；普通滚动与此特殊动作分开验收。
