# Exact结构初始化职责分离

本批落实[剩余大模块方案](../design/2026-11-07-exact-next-decoupling-plan.md)第一步，仅分离建表、兼容视图、触发器和初始化时的缺失列补齐。会话目录、标题同步、迁移状态机和整代发布未纳入本批。

工作树为`f97f/codex-token-dashboard`，分支为`codex/storage-responsibility-split-20261106`。搬迁基线`c99fbc5ddde3a5a0887716bad045f6607f1e63b3`，产品提交`b0f2b462e2bd2040cc30e4559e0945daeb084aae`。

## 具体边界

从`exact_usage_index.rs`移出两个连续函数及其空行，共1520行，归入`exact_usage_index/schema.rs`。新模块含职责说明和显式导入，共1526行；父文件由19,581行变成18,063行。

- 父模块保留两个原名称导入。新模块内两个入口仅为`pub(super)`，没有新增对外API、服务、trait或全局状态。
- 通过父模块导入`Connection`，生产环境仍为绑定分区的`StoreConnection`，单测仍为普通rusqlite连接。没有在新模块绕过分区绑定。
- `ensure_source_observations`、`column_exists_checked`和`dashboard_buckets::install`保持原拥有者，新模块显式调用。没有复制工具或改变查询次数。
- 四段SQL、条件分支、错误文字和执行批次逐字保持。顺序仍为来源观察表、基础表/视图、已有聚合索引安装、缺失列补齐、轮次视图和写入触发器。
- 初始化时机、连接、事务及commit仍由原调用方控制。本批未新增数据库、表、索引、字段或schema版本；原有初始化SQL只是换了源码位置。

## 源码核对

本地`extract.mjs`从固定基线提取两个完整函数，只调整函数可见性并添加模块导入，然后重建整个父文件和新模块，与工作区完整文本比较。该核对通过；四段原始SQL的SHA256分别为：

| SQL段 | SHA256 |
| --- | --- |
| 基础表与兼容视图 | `402c0e61d20a4dbead33978dce6984ffcaca4dd2d0923e0ef15c1d9e9fbd66fc` |
| 轮次候选视图 | `5227aead523c424fc2b2a32d416c01c836491e8d0b7a9d060d2bc741e4ee05f9` |
| 兼容写入触发器 | `63142b72b0c13812e39ee60913bbe7022f61ee9157b2da70b381dae7a284d19a` |
| 旧结构初始化 | `dbabfa033ab0c929a6ee2ba16adabd08c0279c9d3d931884d2d640e2773958f6` |

这证明搬迁文本保持，不替代Rust编译、真实分区绑定和旧库接续验证。Rust回归沿用现有实际业务测试。源码核对器第一次使用了错误的下一段常量类型作为边界，断言在修改前拒绝执行；改为实际的`&[&str]`边界后重新生成补丁并核对通过，产品源码没有经历不完整搬迁。

另以原始/搬迁后的SQL执行轻量对照：新结构空库、新结构已有数据、旧表缺3个可选列、旧结构已有数据四类合成输入，各覆盖直接执行和调用者IMMEDIATE事务，共8组。比较完整`sqlite_master`、所有表行值、metadata、user_version和`sqlite_sequence`；两侧输入与输出均一致，显式回滚后恢复原输入，外键检查通过。这是提取SQL在内存SQLite中的检查，Rust条件编排由诊断脚本重现，**不算完整产品测试，也不证明生产分区绑定**。对应证据为`sql-parity.mjs`和`sql-parity.json`。

## 云端验证

编译和原生运行遵守项目云端构建要求，使用隔离合成数据。本机没有编译产品、打开正式数据库或安装应用。

| 运行 | 范围 | 结果 |
| --- | --- | --- |
| [42281605939](https://github.com/hututuo/codex-token-bar/actions/runs/42281605939) | 当前macOS/Windows Rust库、非test生产入口、备份清理负控、Swift/前端；0.9.8–0.9.11四版本×两平台 | 全部通过，原始证据已核对 |
| [42281613480](https://github.com/hututuo/codex-token-bar/actions/runs/42281613480) | Public097原输入升级及Windows生产恢复/组合故障 | 全部通过，原始证据已核对 |

两轮均显式使用产品完整SHA，workflow来自同一提交。产品提交带`[skip ci]`只用于避免push自动运行与手动完整运行重复；上述手动运行未关闭回归门禁。

关键核对包括未来版本拒绝、schema9/10保行升级、活动building代次隔离、候选内容损坏拒绝、Validated恢复时复核、迁移各切换阶段中断恢复，以及生产绑定的聚合索引重开。还比较上一批与本批的完整测试名/结果，不能以总数相等替代实际测试身份。

| 范围 | 实际结果及核对 |
| --- | --- |
| macOS完整Rust库 | 1796通过、0失败、14项原有opt-in未执行；测试名与各项结果和上一批完全一致 |
| Windows完整Rust库 | 1740通过、0失败、14项原有opt-in未执行；测试名与各项结果和上一批完全一致 |
| 两端非test生产入口 | 各16个场景通过，包括真实分区绑定、暂存发布、原文消失保留和运行时恢复；完整报告再次经校验器解析 |
| 两端备份清理负控 | 原实现PASS、关闭清理FAIL、恢复后PASS；退出码依次0/101/0，原日志hash和源码恢复hash匹配 |
| Swift完整库 | 2361通过、37项跳过；实际日志与execution记录hash、计数匹配 |
| 前端/云端脚本 | 前端1421、云端脚本18通过，无跳过；发布脚本111通过、1项跳过 |
| 0.9.8–0.9.11 | 8条双平台lane、64条实际报告、48次独立重开全部通过；恢复材料和迁移状态保持，旧值为`[162,310]` |
| Public097 Swift | 升级8项和支持回归104项通过，无跳过 |
| Public097 Windows | 原输入3项测试、4个生产阶段及19种旧清单/组合故障情形通过 |

8条历史lane的候选源码清单均绑定`b0f2b462`，包含本次新`schema.rs`，每个生产报告与原始日志逐字段一致。历史矩阵使用真实历史Rust生产实现，不代表四版本原生Swift producer矩阵。两个组合故障情形分别含prepare/resume/reopen三阶段；Public097的missing/unknown/stray-wal仍按保护性拒绝启动核对，未放宽为ready。

本轮没有产品测试失败，没有修改测试、门禁或工作流。主动性能矩阵未启用；既有库内压力用例按原完整回归执行，不据此宣称性能改善。上述跳过项没有计为通过。

## 证据和剩余边界

本机证据目录为`scratch/storage-schema-split-20261107/`，源码核对入口`extract.mjs --verify`及`equivalence.json`，云端产物核对器为`validate.py`。`native-validation.json`、`historical-validation.json`、`final-validation.json`保存复核结论，`library-*`、`control-*`、`swift`、`formed`和`public097`保存原始云端产物；`ci-passed`与`ci-execution`保存CI封存记录。本轮不作性能改善声明；源码拆分不增加运行时查询或数据库层级，也不消除整个Exact模块的依赖关系。

本批产品已提交、推送任务分支并完成云端验收。未合并、安装或发布；云端测试不等于真实安装/UI验收。会话目录和标题同步仍待后续各自实施和验收，不自动扩大到迁移状态机、回填或发布事务。原有Windows报告修改的SHA256仍为`63801116c53adee10cb0692cdad6553e6187906f7659ae0aea67b69d4f24ecef`，其它未跟踪资料保留。
