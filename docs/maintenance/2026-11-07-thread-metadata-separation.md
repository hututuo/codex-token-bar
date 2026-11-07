# 标题同步职责分离与三步收束

本批落实[剩余大模块方案](../design/2026-11-07-exact-next-decoupling-plan.md)第三步，承接已验收的[结构初始化分离](2026-11-07-exact-schema-separation.md)和[会话目录分离](2026-11-07-session-catalog-separation.md)。仅归位标题来源读取、暂存结果应用、单独发布和专用展示/时间工具。

工作树`f97f/codex-token-dashboard`，分支`codex/storage-responsibility-split-20261106`，基线`26df5633e84b7ae3393a8f603faf3ff06b719302`，产品提交`de4c48adb5cb261d2933190b0cb78983cd29e3b5`。

## 实施边界

从父文件提取311行（含空行）：类型23行、同步函数272行、标题上限常量1行、时间规范化8行、专用警告7行。新`exact_usage_index/thread_metadata.rs`含说明与显式导入共328行，父文件补充7行模块导入后净减少304行，从17,358行变为17,054行。

三个被父模块调用的函数通过原名称导入，调用点完全保持。`sync_thread_metadata_without_scan`仍在父模块，继续管理原连接的dirty/eligible标记及迁移状态判断。新模块使用父模块的`Connection`和`Transaction`别名，生产仍为绑定分区的连接和事务。

| 入口/职责 | 保持的行为 |
| --- | --- |
| `stage_thread_metadata` | 只读现有`external_state`来源，返回Unchanged/Updated/Failed；不发布目标数据 |
| `sync_thread_metadata`及私有apply | 使用整代发布传入的同一个事务；不创建第二个事务，也不commit |
| `publish_thread_metadata_only` | 在原可写连接上使用既有IMMEDIATE事务；只在标题或时间内容变化时推进通用revision |
| 缓存与代次 | 单纯标题变化不改变数值dashboard revision或Exact发布代次；原Summary/Full调用时点保持 |
| 来源失败 | 必需列缺失、SQLite读取失败等保留已发布标题和来源签名；合法空结果及状态库不存在仍按原逻辑处理，不改成读取失败 |
| 跨平台来源签名 | Windows仍读实际内容并结合物理身份；macOS仍使用既有只读连接快照和来源token；只写入WAL的变化必须可见 |
| 标题/时间 | 正式标题逐字保留；备用标题按原240个Unicode字符上限处理；秒/毫秒判断及警告内容保持 |

`StagedThreadMetadata`及三个字段仅扩大到`pub(super)`，让现有运行时恢复测试/生产fixture继续读取同样的事实；父模块只在test或`business-store-fixture`配置导入该类型。`ThreadMetadataStage`及三个入口同样仅对父模块可见。apply结果类型、apply实现和展示/时间工具保持模块私有，没有对外API或通配导入。

已有`external_state`读取器和缓存留在原模块，未新建服务、连接持有者或缓存。前两步的`schema.rs`、`session_catalog.rs`以及原`runtime_recovery.rs`逐字保持。

## 源码核对与验收方法

本机从固定基线重建整个父文件和新模块，允许的差异仅为文件归位、显式导入和必要可见性。所有函数体、四段raw SQL、其它SQL字符串、错误处理与事务顺序保持；完整重建检查通过，并复核前两步模块及外部来源读取/恢复模块hash不变。

复用13个既有实际业务用例：读取失败保留标题及签名、只更新改变行、仅签名变化不推进revision、增删行、正式标题和Unicode备用标题、数值缓存复用；旧state可选列、缺必需列和WAL-only刷新；外部读取器的不变来源复用、写入拒绝、物理替换及并发WAL快照一致性。前两步的目录/schema及其它存储保护用例继续要求实际通过，并比较完整Rust测试名和结果。

生产fixture继续核对`liveStateRefreshed`、`externalStateReadOnly`、`legacyStateColumnsReadWithoutImport`等真实非test入口事实。标题模块提取不改变已有fixture或放宽门禁；普通测试与生产分区绑定分别验证。

所有编译、原生回归和合成数据库操作都在云端。本机仅编辑、检查源码和解析云端证据，未打开正式库或启动本地产品构建。

## 云端运行

| 运行 | 范围 | 状态 |
| --- | --- | --- |
| [42348516640](https://github.com/hututuo/codex-token-bar/actions/runs/42348516640) | 当前macOS/Windows完整库和生产入口、既有备份清理负控、Swift/前端、0.9.8–0.9.11四版本×两平台 | 全部通过，原始证据已核对 |
| [42348520418](https://github.com/hututuo/codex-token-bar/actions/runs/42348520418) | Public097原输入、旧schema13接续、Windows生产恢复与组合故障 | 全部通过，原始证据已核对 |

两轮均绑定`de4c48ad`完整产品SHA和同提交workflow。提交的`[skip ci]`只避免push自动运行与手动运行重复，不关闭这两轮检查。这一次历史链在同时包含三个新模块的最终候选上重跑。

| 范围 | 实际结果与证据 |
| --- | --- |
| macOS完整Rust库 | 1796通过、0失败、14项原有opt-in未执行；完整测试名和每项结果与上一版一致 |
| Windows完整Rust库 | 1740通过、0失败、14项原有opt-in未执行；完整测试名和每项结果与上一版一致 |
| 指定保护用例 | 两端各42项实际通过，其中13项为标题/外部来源、11项为会话目录，其余覆盖结构兼容及既有存储保护；没有只依赖总数 |
| 两端非test生产入口 | 各16个场景通过，真实标题来源的WAL更新、只读性和旧可选字段读取均确认 |
| 两端备份清理负控 | 原实现PASS、禁用清理FAIL、恢复后PASS；退出码依次0/101/0，三份日志hash与源码恢复hash匹配 |
| Swift完整库 | 2361通过、37项跳过；日志hash与execution记录一致 |
| 前端及脚本 | 前端1421和云端脚本18通过，无跳过；发布脚本111通过、1项跳过 |
| 0.9.8–0.9.11接续 | 8条双平台lane全部通过，64条真实场景报告和48次独立重开；旧值`[162,310]`、恢复材料及迁移状态保持 |
| Public097 Swift | 原输入升级8项、支持回归104项通过，均无跳过 |
| Public097 Windows | 原输入3项测试、4个生产阶段、19种旧清单/组合故障情形通过 |

8条历史lane的源码清单均包含`schema.rs`、`session_catalog.rs`和`thread_metadata.rs`，清单中的生产文件Git blob全部与最终候选一致，场景原始日志和汇总逐字段相符。该矩阵使用真实历史Rust生产实现，不能称为四版本原生Swift producer矩阵。Public097的missing/unknown/stray-wal仍按保护性拒绝启动核对，两个组合情形分别含prepare/resume/reopen三阶段。

本轮没有产品测试失败、修改业务测试或放宽工作流门禁。原有跳过项未计为通过；可选性能矩阵未启用。生产目录浏览fixture的`catalogActionsVerified=false`仍不代表删除操作已验收，真实安装/UI也不在本轮验证范围。

## 三步范围与证据

三步实施后，Exact主文件从19,581行变为17,054行，净减少2,527行（约12.9%）；三个新模块分别为1526、753和328行。收益是初始化、目录和标题各有集中入口，仍非完全消除依赖循环。迁移状态机、暂存导入、最终发布及路由继续留在既定后续范围，不能因为完成这三步便自动开始改造。

本地证据目录为`scratch/storage-thread-metadata-split-20261107/`，`extract.mjs --verify`及`equivalence.json`记录完整源码等价核对；`validate.py`核对云端日志、候选源码清单和原测试身份。`native-validation.json`、`historical-validation.json`、`final-validation.json`保存复核结果；`library-*`、`control-*`、`swift`、`formed`、`public097`保存原始产物，`ci-passed`和`ci-execution`保存最终CI封存记录。

三步产品均已提交并推送任务分支，且在最终候选完成云端整链验证，本批至此收束。尚未合并、安装或发布，没有性能提升声明。原有Windows报告hash保持`63801116c53adee10cb0692cdad6553e6187906f7659ae0aea67b69d4f24ecef`，其它未跟踪材料保留。
