# PR #8 与当前恢复分支的增补

> 后续实际安装：28源码的build991在首次后台维护回调发生actor隔离崩溃；已以c5e3714d作最小线程修复并替换本机build992。原因、独立测试、同源码回归和实际启动观测见[维护定时器崩溃记录](2026-11-03-stage-maintenance-startup-crash.md)。以下28结论保留为当时的自动化证据，不能改称991安装运行通过。

核查基线：本分支产品 `02c493fae3ccbf76df21524771cee4802a330d0e`，文档 HEAD `2e64e187dc7ea65ea565e58f4a82f960f5bd19b5`。外部 PR [shawway #8](https://github.com/hututuo/codex-token-bar/pull/8) 冻结在 `3cbd383f3daf3f37ab6b5ac52676895c18a5440a`，本地只抓取审计 ref。整合提交 `f6582f3d` 的父提交为 #6 的 `41058ffe` 和 #7 的 `faa06a5b`。不再整份合并。

**最终状态（2026-11-03）：本次确认的增补已实现并推送至 `codex/fix-integrated-ledger-recovery`，产品及测试源码固定为 `28a0dc6a7411b1caf8962bd11d5e180472f92139`。同一 SHA 的常规、Public097、0.9.8–0.9.11 双端形成状态矩阵均已通过，结果见文末。后面的首轮红灯与定位过程保留为历史记录，不表示当前仍失败。** 终核时 #8 仍为同一 head、open/draft。

## 已确认的增补范围

1. Swift 重试替换的旧历史覆盖。当前实际存储模块、一次性 SQLite 探针中：A 原有两条事实，新候选删除其中一条，原代码接受替换并只剩一条。此前的“目标仍是冻结导入镜像”检查只保护目标未被改写，不能证明候选完整。新增反向覆盖校验；从 durable import receipt 找回同目录 UUID 绑定的 normalized 镜像，以全结构、类型、隐藏 rowid、重复数和序列证明旧历史，再在原子写事务中复核目标和源。相同候选的 no-op 仍保留 A 后来产生的独立事实。正常追加、受限额度维护时钟推进、Exact 模型/轮次补全和派生投影重算分别用窄口径证明，不能一律当成历史丢失拒绝。只读 Exact 证明算法及相关测试改编自 #8；保留本分支 admission、池化暂存和指标。
2. Swift 活着的旧库路径别名。实际存储模块探针：physical support 完成导入后，改用指向同目录的 alias，旧库仍存在，重启报 unmigratedInput。现有测试只覆盖 alias 后旧叶子已删除。新增按真实父目录、叶子、设备/inode、catalog 和 journal 所有权核对的别名复用；不能凭内容相等、同名或其他路径硬链接改归属。保留已知 receipt/source key，不建立第二份账本。
3. Rust 已导入但未发布的历史。正常发布前校验与历史补全两入口，在原始日志确实消失时，验证 pending 的完整数值、代次、引用后继续发布并撤销原文可读标记；不能用 tombstone 清掉待发布事实。重导入前后在同一事务中核对旧数值及已知关联，仅允许 NULL 补全；发布补齐 canonical 的四个 prompt/assistant 边界。采用 #8 的相关保全实现，保留本分支固定 stage pool。另补 #8 未覆盖的 pending_fingerprints 未知列防护，避免可空未知字段在删除/重建时丢失。
4. Rust Exact 路径身份。符号链接根下多级父目录从不存在到存在时，旧 fallback 身份会变，A-only 旧 owner 查不到。采用 #8 有界路径候选及实际 catalog owner 复用，随后补足 Windows 原生分隔符和已配置系统根的旧拼写；多份不同事实不能任选、覆盖或合并。只读 miss 不注册/创建。最终双端完整 native 回归和 Windows 实际 production fixture 已通过，早期隔离探针不单独作为通过依据。

## 不采用的部分与边界

- 不整份搬入 #8 的启动/UI/更新控制和额外诊断系统；未证明它们是这次数据保全修复的必要依赖。
- 不倒退本分支已实现的只读 admission、空闲连接 quiescence、固定 stage pool、有限重试和诊断。#8 的 Windows park 路径曾删除 quiescence，不能照搬。
- 不改 A/B 原始事实、费用规则、永久库数量；不重构性能架构、不新建清理系统、不操作用户数据库。
- 上一轮 `02c493fa` 的云端成功不覆盖本次新增代码。最终结果使用文末同 `28a0dc6a` 的三个 run，不移用旧绿灯。
- 未合并 main、未安装/替换/启动正式应用、未打包/签名/发布，未请求 Anthropic。

## 首轮验证（506d73b8，不是通过结论）

- 本地限定实际存储模块 XCTest：首轮14项全过；新增相同内容异目录/硬链接不可改归属后15项全过。Exact解析依赖未包含在此小模块，完整Exact走云端。
- [首轮常规](https://github.com/hututuo/codex-token-bar/actions/runs/41584919541)：前端、更新器、双端production fixture步骤通过；Swift全量2348 executed / 37 skipped / 10 failures（5个failed cases，其中1个unexpected）；Rust Mac1727 pass / 2 fail / 14 ignored，Windows1670 pass / 3 fail / 14 ignored。不能用这轮作收束绿灯。
- [真实公开0.9.7双端升级](https://github.com/hututuo/codex-token-bar/actions/runs/41584919508)：Mac、Windows均success；仅证明该SHA的真实097入口。
- 两端Rust同样失败于补全进度口径：旧函数直接数收据，未按published_files的size/prefix过滤，也未计入已证明missing来源。已补PR8对应窄查询，待重测。
- Windows另有实际native反例：旧PathBuf join保存“本机前缀+正斜杠相对父目录+本机分隔叶子”的混合路径，后续canonical调用丢失该拼写。PR8原候选也未涵盖；已增加与请求组件等价、数量随组件线性增长的legacy join拼写，仍通过完整catalog tuple/多owner proof选取，未扩大到任意目录扫描。
- Swift几条期望不能照搬PR8：本分支助手历史标记仅挂在相应事件，不能要求同一回复的两条用量都重复标记；未变化来源也不一定新增optional representation hint。测试改为保留每条数值、模型/prompt、已知助手标记及新旧raw binding的对应关系；攻击fixture显式构造基于实际observation的可选hint，要求UPDATE实际改到行，避免“0行UPDATE”误判漏保。
- 仍在定位v3 pre-compaction receipt正向接续的误拒，未放宽未知状态或删除该正向测试。尚未采用最后版本、未替换或发布。

### 检查点编码的确定反例

实际编译本分支 `TokenUsageAccounting.swift` + `CodexCompactionAccounting.swift` 后，将同一 `UsageAccountingState` 编码100次，本地观察到5种不同TEXT，解码后状态全部相等。新深验对未改变size/probe/generation的来源逐字比较 accounting_state 会误拒这种合法状态；这与金融事实不属于同一层。小修保留其余checkpoint列的SQLite类型/值精确比较，JSON双方仍须先完整round-trip（拒绝未知字段），之后比较已知状态语义，仅保留已有限定的v3缺省/已证明空compaction例外。新增重排键正向接续、未知字段和实际状态变化拒绝用例。它是独立复现的误拒；是否同时解决首轮v3用例仍以新SHA完整回归为准，不靠静态推断宣布通过。

### Unicode路径保全

013新增的Unicode反例触发当前Swift `Dictionary(uniqueKeysWithValues:)` fatal：SQLite BINARY 可区分 NFC/NFD，而 Swift String 键规范等价，不能放入同一个字典。PR8的`indexedSources`已有可恢复拒绝，本分支还需覆盖自己的`indexedSourceIdentities`/canonical fast-path入口。已改为逐项检查并抛出已存在的 malformed-source 错误；不任选、不覆盖、不改写两份旧事实。新增fixture仍保留 source/frozen 文件不变断言。此项修复尚待最终SHA云端验证。

## de6259e3验证进展

- 同SHA Swift：2352 executed / 37 skipped / 0 failures；新增Exact suite22/22、snapshot/alias suite6/6实际通过，含v3普通追加、JSON键序正向和未知字段反向、NFC/NFD错误可恢复用例。
- 同SHA macOS Rust：1729 pass / 14 ignored / 0 fail，production fixture PASS；11个path_identity与8个pr8_recovery_tests均实际执行。
- 同SHA Public097两端success。
- Windows Rust仍有唯一 `old_a_only_primary_owner_is_read_without_registration_after_directory_creation` 在canonical Windows caller处找不到旧owner。不能由无路径的panic猜测原因。增加快速Windows文件系统诊断：直接抽取生产路径变换/候选函数，保留hash的输入文本以便定位；它不是Container/账本native验证，完整native gate保留。
- e76的真实Rust形成矩阵8/8成功（0.9.8–0.9.11各Mac/Windows；e76至de的Rust源码无差异）。每lane committed/interrupted数值、typed proof、WAL、原日志消失后历史和三次独立reopen材料校验均保留。该矩阵不冒称原生Swift历史producer矩阵。

## Windows唯一反例的确定原因与修复

657beedb 的 Windows job `125768598261` 实际执行抽取探针，输出 `matched=false aliases=12`：legacy与系统TEMP均为 `C:\Users\RUNNER~1\AppData\Local\Temp\...`，preferred/candidates为 `\\?\C:\Users\runneradmin\AppData\Local\Temp\...`。这是8.3系统配置根与canonical长名不一致；前一轮仅补分隔符尚不完整。证据是隔离Windows文件系统路径输入，不冒充最终Container读取已通过。

增补只考虑四个已配置根（TEMP、LOCALAPPDATA、APPDATA、USERPROFILE），要求绝对路径、实际目录、OS canonicalize后确为本次请求的祖先；将同一相对组件接回已配置拼写，再复用同样的候选/完整catalog tuple/多owner冲突校验。不开全盘搜索，不以同名认领，不改旧ID、不删除旧owner。抽取的两分支在本地只做编译检查；Windows运行与native A-only旧账读取仍以新SHA云端为准。

## Windows生产fixture红灯的定位

7a24 Windows Rust全量1673 pass / 14 ignored / 0 fail，旧A-only owner单测与路径探针已过；但production fixture红灯，不能相互抵销。c875保留同样判断、只加实际路径，479-byte artifact（仅纯文本标准输出）明确报错在 `\\?\D:\a\_temp\...\index.sqlite3.staging/<64位SHA>.sqlite3`。

该路径由 `business_store_fixture.rs::stage_path` 的 `format!("{}.staging/{hash}.sqlite3", index.display())` 产生；实际扫描器 `staging_database_path` 使用OsString追加`.staging`再原生`PathBuf::join`。修正fixture使用相同的原生拼接，不把os123当成文件缺失，也不放宽owner/path验证。快速Windows诊断同时抽取fixture的真实路径构造（只将无关的hash计算替换为合法固定hex输入），增加`FIXTURE_STAGE_PATH`检查；完整production gate继续保留。修复后仍需新SHA云端验证，未以单测绿灯宣布production通过。

## 最终同源码验证与交付边界

产品及测试源码均为 `28a0dc6a7411b1caf8962bd11d5e180472f92139`。根通过 GitHub API 复核三个 run 的 `head_sha`、最终状态，以及各 job／production 步骤；形成矩阵逐份报告的语义另核对如下。

| 范围 | 最终证据与结果 |
|---|---|
| 常规 Swift／Rust／前端／更新器及双端实际 production 存储恢复 | [41603039637](https://github.com/hututuo/codex-token-bar/actions/runs/41603039637)，success。Swift XCTest：2352 executed，含37 skipped，0 failures，即2315项未跳过；Exact追加22/22、snapshot/alias 6/6。Rust macOS：1729 passed、14 ignored、0 failed；Windows：1673 passed、14 ignored、0 failed。两端 production fixture 及其强制校验步骤实际成功。 |
| 公开0.9.7源码产库直接升级 | [41603039546](https://github.com/hututuo/codex-token-bar/actions/runs/41603039546)，两端success。Swift release升级8项通过、支持套件96项通过；Windows原生旧producer及3项升级恢复断言通过。Mac强退86后行保全、旧字段、目标独有事实及缺失原文历史均有实际断言。输入是历史源码产生的隔离fixture，不是用户原数据库。 |
| 0.9.8、0.9.9、0.9.10、0.9.11 × macOS／Windows | [41603237675](https://github.com/hututuo/codex-token-bar/actions/runs/41603237675)，8/8成功。各lane运行固定历史Rust源码producer、当前production存储入口；committed及interrupted恢复后的账目均为[162,310]，typed/WAL/原日志缺失保全通过；每场景再经3个独立进程重开，恢复材料及迁移摘要保持。 |

Windows快速探针记录 `matched=true aliases=24`，三例verbatim missing path和实际fixture构造的 `FIXTURE_STAGE_PATH` 均accepted=true；最终真实production步骤也通过，因此不再用抽取探针替代真实存储入口。`StoreConnection`及事务内proof继续核对完整catalog owner，未通过扩宽归属或把路径错误当missing取得通过。

本轮还确认并修复了 #8 本身没有完整覆盖的四处：`pending_fingerprints` 可空未知字段保全；相同checkpoint JSON键序误拒；Swift NFC/NFD路径键碰撞导致进程trap；Windows 8.3配置根及原生stage路径构造。没有靠删除原正向测试、放宽未知数据或修改数值规则取得通过。

矩阵的 `oldBPreserved=false` 在interrupted场景是形成器未创建B的既有前提；`mtimeCompared=false` 表示按材料内容而非mtime比较，SQLite sidecar排除。两者不改写为true，也不解释为账目丢失。该矩阵证明的是历史Rust源码形成状态与production存储入口，不宣称原生Swift历史producer、完整App/UI或正式安装验收。

常规run里的额外scale／formed任务按配置跳过；formed已由独立run补齐。50万压力、长写锁、P95及功耗优化仍按用户决定延期，旧FAIL和未测项保留，本轮未重测为性能达标。源码和证据收束完成；未整份合并 #8，未合main、打包、签名、替换、重启或发布，未操作正式用户库、未请求Anthropic。
