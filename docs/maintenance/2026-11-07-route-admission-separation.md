# 业务库访问准入职责分离

本笔执行[准入分离方案](../design/2026-11-07-route-admission-separation-plan.md)，工作树`f97f/codex-token-dashboard`，分支`codex/storage-responsibility-split-20261106`。搬迁基线`a7f16792407ac0ffb4e3231985c53df3329b6633`，方案提交`82f57761`，产品提交`05b23d54f78fe79ca8ae93c2ac735bfeb37bb058`。

## 结果与边界

把9行身份类型/状态、18行已发布读取准入和190行检查函数（均含分隔空行）归入230行的`business_store_route/admission.rs`。父文件从2389行降到2182行，净减少207行；Exact主文件保持15,892行。

| 职责 | 本次归属与保持项 |
| --- | --- |
| 初始化标记、ready/readable与文件身份 | 集中到admission，保留函数体、错误及全部平台/cfg分支 |
| `ACTIVE_CONTAINER_IDENTITY` | 原唯一OnceLock/Mutex和私有类型一起迁移，未复制状态或添加重置入口 |
| `verify_initialized` | 保留原`Container::open`及身份登记顺序，未改成只读open；原open可能执行PRAGMA/初始化 |
| 运行时与bootstrap打开入口 | 保留各自准入要求、打开前后身份检查、连接返回和析构时点 |
| 已发布读取 | 原只读打开、catalog验证；恢复中只可读已发布账本，写入仍被协调器拒绝 |
| Exact暂存保留句柄 | 标记/身份仍动态复核，不添加每来源重开或全catalog扫描 |
| 导入/迁移/维护/路径归属 | 保留父模块及既有子模块，journal、收据、事务、owner和根版本校验未改 |

三个原`pub(crate)`入口通过父模块原路径转出：`admit_published_reads`、`published_reads_only`、`validate_exact_stage_container`。内部调用入口仅`pub(super)`；私有身份状态、读取身份和remember辅助不暴露。外部调用方、启动协调器和既有测试没有改变。

此次收益是准入检查有集中审查入口。它不是纯只读模块，也不等于所有存储安全都归到这里；根版本、owner及pending所有权继续由原入口检查。没有数据库结构、索引、迁移格式或性能算法修改。

## 源码和覆盖核对

固定基线完整重建父文件及新模块通过，只允许模块声明、显式导入、必要可见性和专用import归位。所有函数体、错误、cfg及平台分支逐字一致；bootstrap、打开前后复核、导入和维护编排完整保持。

对`tauri-app/src-tauri/src`其余214个既有文件逐字核对通过，保存216个文件hash，包括前面几批拆分和所有测试源码。没有新增测试或修改预期；本轮复用现有行为覆盖，不添加只复述实现的用例。

指定保护清单共80项，包括之前发布/迁移保护，加上路由并发只读、无标记不创建、旧账导入、bootstrap中断恢复、v1收据、保留句柄标记/owner/版本检查以及协调器恢复重试。macOS/Windows完整原始日志均确认80项实际通过，全部测试身份及结果与前一候选相同。

单测的进程全局ready/identity分支关闭，因此生产证据单列。既有生产fixture的`public-read-only-routing`、`published-recovery-reads`、`held-owner-lookup`和`rerun-and-fail-closed`覆盖实际调用；缺失A拒绝不是“有效但不同物理A”的专用替换负控。本笔保留原身份算法并检查调用点，没有新增该负控，不声称其已执行。

## 云端验收

所有原生编译、测试和历史数据库生成均在云端隔离夹具完成，本机仅源码编辑、轻量核对和产物解析，不访问正式库。

| 运行 | 范围 | 状态 |
| --- | --- | --- |
| [42364105613](https://github.com/hututuo/codex-token-bar/actions/runs/42364105613) | 双平台完整库、非test生产入口、既有负控、Swift/前端及0.9.8–0.9.11接续 | 全部通过，原始证据已核对 |
| [42364106688](https://github.com/hututuo/codex-token-bar/actions/runs/42364106688) | Public097实际旧输入及Windows旧清单/组合故障恢复 | 全部通过，原始证据已核对 |

已下载并通过原校验器复核双平台各16个非test生产场景。其中`held-owner-lookup`两平台均执行16次discovery lookup、11次persist lookup，每来源重开0次，fresh-open对照1次；恢复期旧数值`[123,789]`与缺失原文后的175 tokens保持，A逻辑摘要不变，重试仍只读。会话目录动作明确`catalogActionsVerified=false`，不扩大为删除/动作验收。

| 原始证据范围 | 实际结果 |
| --- | --- |
| macOS完整Rust库 | 1798通过、0失败、14项原有opt-in未执行，旧测试身份/结果全部保持 |
| Windows完整Rust库 | 1742通过、0失败、14项原有opt-in未执行，旧测试身份/结果全部保持 |
| 指定保护用例 | 两端各80项实际通过 |
| 非test生产入口 | 两端各16场景通过，完整报告经原校验器复核 |
| 两端既有备份清理负控 | 原实现PASS、禁用清理FAIL、恢复后PASS，退出码0/101/0；源码恢复及日志hash一致 |
| Swift完整库 | 2361通过、37项跳过，execution记录及原日志一致 |
| 前端和脚本 | 前端1421、云端脚本18通过且无跳过；发布脚本111通过、1项跳过 |
| 0.9.8–0.9.11接续 | 8条双平台lane、64份实际场景报告、48次独立重开通过，旧值`[162,310]`、恢复材料及迁移状态保持 |
| Public097 Swift | 原输入升级8项和支持回归104项通过，均无跳过 |
| Public097 Windows | 原输入3项测试、4个生产阶段、19种旧清单/组合故障情形通过 |

八条历史lane的源码清单均包含新`business_store_route/admission.rs`，全部登记生产文件的Git blob与候选提交一致，场景原日志和汇总逐字段匹配。Public097的missing/unknown/stray-wal仍按预期拒绝启动，两个组合故障情形分别核对prepare/resume/reopen三阶段；不把保护性拒绝称为恢复成功。

本候选没有编译或产品测试失败，未更改工作流或放宽门禁。负控中的101是预期拒绝；既有备份清理负控不是本次准入模块的专用变异验证。原有跳过项单列、不计为通过，可选性能矩阵未启用。

## 证据与收束

证据目录`scratch/route-admission-split-20261107/`保存`extract.mjs`、`equivalence.json`、`validate.py`，以及`native-validation.json`、`historical-validation.json`和`final-validation.json`。`library-*`、`production-*`、`control-*`、`swift`、`frontend`、`formed`、`public097`和`ci-*`保存云端原始产物。核对器绑定本次完整候选SHA、日志hash、测试身份、生产报告和历史源码清单；CI封存结果也与本次run/SHA一致。此前报告仅用于比较，不替代本次候选执行。

产品已提交并推送任务分支，本笔到准入模块归位及对应验收收束；后续只补验收文档，受测产品仍为`05b23d54`。没有开始迁移状态机或暂存导入拆分。未合并、安装或发布，不把测试通过扩大为真实安装/UI、任意损坏库恢复或性能提速。四版本历史矩阵是Rust producer，不代表四版本原生Swift producer矩阵。用户原有Windows报告hash仍为`63801116c53adee10cb0692cdad6553e6187906f7659ae0aea67b69d4f24ecef`，其他未跟踪材料保留。
