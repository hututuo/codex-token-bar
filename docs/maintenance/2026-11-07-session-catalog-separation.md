# 会话目录职责分离

本批落实[剩余大模块方案](../design/2026-11-07-exact-next-decoupling-plan.md)第二步，承接已验收的[结构初始化分离](2026-11-07-exact-schema-separation.md)。仅整理会话目录的schema兼容、文件观察、首行读取、刷新和已发布快照读取；标题同步、会计扫描、旧库接续和整代发布没有纳入本批。

工作树为`f97f/codex-token-dashboard`，分支为`codex/storage-responsibility-split-20261106`。基线`30ca234df6e11087b63aa5c9e2182add0c3131ea`，产品提交`f23411cc68e93121e5f1e13dc1291549a4e6b838`。

## 实施边界

新增753行的`exact_usage_index/session_catalog.rs`，归位两个私有目录类型、两个方法的实现、专用schema/观察/首行辅助及发布故障钩子。原提取片段含空行共727行；补回薄入口并加模块导入后，主文件净减少705行，由18,063行变为17,358行。

原`ExactUsageIndex::refresh_session_catalog`和`session_catalog_snapshot`入口保留，分别把原`ManagedIndexConnection`作为可变/不可变借用传给新模块。没有新建连接、writer或生命周期持有者；Managed连接的Drop、完整性收据、Home操作锁与外层目录构建锁仍由原代码拥有。

| 边界 | 保留的行为 |
| --- | --- |
| 目录刷新 | 原连接先标dirty，读取旧目录和来源观察、核验首行后才开始IMMEDIATE写事务；目录行、删除行和发布代次一起commit，成功后才标eligible |
| 无变化刷新 | 原有快速返回和eligible时点保持；不额外解析首行，不推进目录代次 |
| 已发布快照 | 原连接上的unchecked读取事务、排序和commit保持，没有新开数据库 |
| 外层容错 | `token_count_jsonl.rs`继续负责全局目录锁、恢复期只读浏览、刷新失败时回退上一份完整目录并警告 |
| schema兼容 | 未来版本和未知未标记结构仍先拒绝；v1→v2去身份列的事务、保行检查及发布代次恢复保持 |
| 首行读取 | 普通/压缩来源选择、物理文件句柄及路径复核、完整首行校验、首行摘要复用和原错误信息保持 |
| 故障注入 | 一次性thread-local状态及执行点一起归入目录模块；父模块保留原测试调用入口 |

三项共享合同没有随目录私有化：`SESSION_CATALOG_SCHEMA_COLUMNS`仍由父模块单一定义，供目录与迁移摘要共用；`SESSION_CATALOG_SCHEMA_VERSION`仍供整体打开准入使用；`reject_session_catalog_reparse_point`仍供旧库恢复、来源发现和目录共同调用。其它目录辅助保持私有，没有批量扩大为`pub(crate)`或通配导入。

与最初方案中“归位后向父模块暴露列清单”的选项相比，本次直接保留父模块的共同定义。两种消费者继续使用同一份清单，避免让迁移证明反向依赖目录实现。

## 源码核对

本地核对器从固定基线重建整个父文件和新模块；只允许方法receiver改为原连接借用、原方法留薄入口、必要可见性及模块导入变化。方法去缩进时保留raw SQL字符串中的全部空白。完整文件重建及三段SQL逐字比较通过，没有修改测试、工作流、SQL、数据库版本或锁/事务策略。

源码核对器第一次生成的补丁片段顺序错误，补丁工具拒绝，工作区未变化；调整片段顺序后应用并重建核对通过。这是补丁生成问题，没有形成部分产品修改。

编译和原生运行遵守项目云端构建要求。本机只检查源码和云端日志，没有编译产品、打开正式库或安装应用。

## 云端验证

| 运行 | 范围 | 状态 |
| --- | --- | --- |
| [42336108887](https://github.com/hututuo/codex-token-bar/actions/runs/42336108887) | 当前macOS/Windows完整库及非test生产入口、既有备份清理负控、Swift/前端；0.9.8–0.9.11四版本×两平台 | 全部通过，原始证据已核对 |
| [42336113257](https://github.com/hututuo/codex-token-bar/actions/runs/42336113257) | Public097原始输入升级、旧schema13输入、Windows生产恢复和组合故障 | 全部通过，原始证据已核对 |

两轮均显式绑定完整产品SHA，workflow来自同一提交。提交中的`[skip ci]`用于避免push自动运行和手动完整运行重复，不跳过这两轮回归。

两端日志均已核对11项目录测试的实际通过记录：不变目录不重解析、创建时间漂移不误解析、增量/追加元数据复用、归档/删除、截断/替换、发布中断后旧目录保留及重试、压缩首行读取与普通文件优先/失败原子性、已知无标记结构恢复、未知无标记结构拒绝、未来目录版本拒绝。上一批schema9/10升级、迁移中断、候选复核和其它存储保护测试也通过；完整Rust测试名与结果和上一版逐项相等。

| 范围 | 实际结果 |
| --- | --- |
| macOS完整Rust库 | 1796通过、0失败、14项原有opt-in未执行；原日志hash、源码SHA与execution记录一致 |
| Windows完整Rust库 | 1740通过、0失败、14项原有opt-in未执行；原日志hash、源码SHA与execution记录一致 |
| 两端非test生产入口 | 各16个场景通过，完整报告由原校验器再次核对 |
| 两端备份清理负控 | 原实现PASS、禁用清理FAIL、恢复后PASS；退出码0/101/0，源码恢复hash和三份原日志hash相符 |
| Swift完整库 | 2361通过、37项跳过；原日志与execution记录一致 |
| 前端及脚本 | 前端1421和云端脚本18通过、无跳过；发布脚本111通过、1项跳过 |
| 0.9.8–0.9.11历史形成状态 | 四版本×两平台8条lane全部通过，64条实际报告、48次独立重开均保留恢复材料和迁移状态；旧值保持`[162,310]` |
| Public097 Swift | 原输入升级8项、支持回归104项通过，均无跳过 |
| Public097 Windows | 原输入3项测试、4个生产阶段、19种旧清单/组合故障情形通过 |

8条历史lane的候选源码清单包含本次新`session_catalog.rs`，所有记录的生产文件Git blob与本次提交匹配，实际场景日志与汇总逐字段一致。历史矩阵使用真实历史Rust生产实现，不代表四版本原生Swift producer矩阵。Public097的missing/unknown/stray-wal仍为保护性拒绝；两个组合情形各运行prepare/resume/reopen三阶段。没有把原有跳过计为通过，也没有新增产品测试来凑数量。

生产fixture的`published-recovery-reads`覆盖正常目录发布及恢复期从已发布快照浏览，要求parser未调用、A不变且存在警告。`catalogActionsVerified=false`仍表示未用该生产fixture验收会话删除等危险操作；不能把浏览通过扩大成删除流程已验收。

## 证据与剩余边界

本机证据目录为`scratch/storage-catalog-split-20261107/`。`extract.mjs --verify`及`equivalence.json`记录完整源码重建和SQL摘要；`validate.py`用于核对云端日志、候选源码清单与原测试身份，不运行产品或打开数据库。`native-validation.json`、`historical-validation.json`和`final-validation.json`保存复核结果，`library-*`、`control-*`、`swift`、`formed`、`public097`保存原始云端产物，`ci-passed`和`ci-execution`保存CI封存记录。

产品已提交并推送任务分支，两轮云端验收及原始证据复核完成，未出现产品测试失败。没有合并、安装或发布，没有性能改善声明；未启用可选性能矩阵，真实安装/UI也不在本轮验收范围。第三步标题同步仍待后续独立实施；本批不扩大到迁移状态机、暂存导入或最终发布。原有Windows报告hash仍为`63801116c53adee10cb0692cdad6553e6187906f7659ae0aea67b69d4f24ecef`，其它未跟踪材料保留。
