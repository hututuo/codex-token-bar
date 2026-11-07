# schema11暂存发布职责分离

本笔执行[发布分离方案](../design/2026-11-07-schema11-publication-separation-plan.md)。工作树`f97f/codex-token-dashboard`，分支`codex/storage-responsibility-split-20261106`；搬迁基线`f9203d2a1b6b46b44aec3def77f813251d4206fa`，方案提交`7a3260c8`，产品提交`4e43517d877acf3706ce51a6660bec5601db91bc`。

## 结果与边界

`publish_schema11_pending_generation`的393行（含分隔空行）归入401行的`exact_usage_index/publication.rs`。父文件新增2行模块声明和私有导入，净减少391行，从16,283降到15,892行。最终发布事务依然由父模块`finalize_generation`拥有。

| 责任 | 本笔处理 |
| --- | --- |
| pending合同、活动代次和墓碑子行校验 | 移入publication，顺序和错误保持 |
| ledger绑定、正式事件/来源/聚合写入、pending清理 | 原SQL整体归位，不修改语句、参数和执行次序 |
| 正式代次、revision、聚合水位、certify与stage消费回执 | 留在原finalizer，同一IMMEDIATE事务最后一次commit |
| 缺失来源历史保留、canonical、Summary/Full模式 | 原调用点及实现保持 |
| 未调用的墓碑子行清理函数 | 留在父文件；未增加调用或删除它 |
| 迁移、暂存导入与池、路由、以前的性能修复 | 既有源码保持 |

新模块只显式依赖`ledger`、`table_exists_checked`、父模块`Transaction`别名和rusqlite查询辅助。生产使用绑定分区的`StoreTransaction`，单测使用rusqlite；不重新获得连接、不提交事务，也不提前消耗stage。函数只开放到父模块，父模块保留原入口名，finalizer及ledger既有测试调用不改位置。

这是职责归位，未改变数据结构、索引、持久化格式和查询算法；不作性能提升或整个大模块已完全解耦的结论。

## 源码与测试覆盖核对

固定基线完整重建父文件与新模块通过，函数体和全部SQL逐字一致，最终事务函数完整不变。另对`tauri-app/src-tauri/src`其余213个既有文件逐字比较通过，包括前面各批拆分、ledger、stage池、迁移与测试源码；共保存215个文件hash。没有新增测试，没有更改既有测试身份或预期。

复用后段certify失败整体回滚、pending未知历史拒绝、字段补充、缺失来源175-token保留、持久墓碑恢复、未完成扫描保持旧结果、Summary/Full聚合水位和暂存消费回执同事务回滚等用例。完整库原始日志确认前一候选全部测试身份/结果保持，两平台各68项指定保护用例实际通过。

## 云端验收

以下运行均绑定产品完整SHA，所有编译和原生测试都在云端隔离数据中进行。本机仅编辑和解析证据，没有运行产品构建或访问正式库。

| 运行 | 范围 | 状态 |
| --- | --- | --- |
| [42359741172](https://github.com/hututuo/codex-token-bar/actions/runs/42359741172) | 双平台完整库、非test生产入口、既有负控、Swift/前端及0.9.8–0.9.11接续 | 全部通过，原始证据已核对 |
| [42359742095](https://github.com/hututuo/codex-token-bar/actions/runs/42359742095) | Public097真实输入升级与Windows旧清单/组合故障 | 全部通过，原始证据已核对 |

| 已复核范围 | 实际结果 |
| --- | --- |
| macOS完整Rust库 | 1798通过、0失败、14项原有opt-in未执行；全部测试身份及结果与前一候选相同 |
| Windows完整Rust库 | 1742通过、0失败、14项原有opt-in未执行；全部测试身份及结果与前一候选相同 |
| 指定保护用例 | 两端各68项实际通过，包括发布、缺失旧账、失败回滚、Summary/Full水位、stage回执和前几批拆分保护 |
| 两端非test生产入口 | 各16场景通过；完整报告通过原校验器，包含绑定连接、旧账、暂存恢复和发布读取 |
| 两端既有备份清理负控 | 原实现PASS、禁用清理FAIL、恢复后PASS；退出码0/101/0，源码恢复及日志hash匹配 |
| Swift完整库 | 2361通过、37项跳过，原日志及execution记录一致 |
| 前端和脚本 | 前端1421、云端脚本18通过且无跳过；发布脚本111通过、1项跳过 |
| 0.9.8–0.9.11接续 | 8条双平台lane、64条真实场景报告及48次独立重开通过，旧值`[162,310]`、恢复材料和迁移状态保持 |
| Public097 Swift | 原输入升级8项、支持回归104项通过，均无跳过 |
| Public097 Windows | 原输入3项测试、4个生产阶段、19种旧清单/组合故障情形通过 |

八条历史lane的源码清单均包含本次`publication.rs`和前几批新模块，清单内所有生产文件Git blob与候选提交一致；场景原日志与汇总逐字段相符。Public097的missing/unknown/stray-wal按预期拒绝启动，两个组合故障情形分别核查prepare/resume/reopen三阶段。历史矩阵来自实际历史Rust实现，不代表四版本原生Swift producer矩阵。

本轮没有编译或产品测试失败，没有调整工作流或放宽门禁。负控中的101是预期拒绝；既有备份清理负控不等同于本次publication模块的专用变异验证。原有跳过项没有计为通过，可选性能矩阵未启用。

## 证据与收束

原始产物与核对结果保存在`scratch/generation-publication-split-20261107/`，其中`extract.mjs`负责源码重建，`validate.py`负责候选身份、日志hash、实际测试、生产报告和历史源码清单复核。`equivalence.json`、`native-validation.json`、`historical-validation.json`与`final-validation.json`保存本次结果；`library-*`、`production-*`、`control-*`、`swift`、`frontend`、`formed`、`public097`及`ci-*`保存云端原始产物。此前的成功报告仅用于比较测试身份，不充当本次候选的执行证据。

产品已提交并推送任务分支，本笔发布SQL归位及对应验证到此收束。后续仅补充验收文档；实际受测产品为`4e43517d`。最终事务编排、迁移切换、暂存导入和路由留待独立调查，没有继续扩大到新一批拆分。

真实安装/UI、任意损坏库恢复和可选性能矩阵不在本轮验证范围。没有合并、安装或发布。用户原有Windows报告hash仍为`63801116c53adee10cb0692cdad6553e6187906f7659ae0aea67b69d4f24ecef`，其余未跟踪材料保留。
