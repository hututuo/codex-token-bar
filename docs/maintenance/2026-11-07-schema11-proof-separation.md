# schema11迁移证明职责分离

本批执行[迁移证明方案](../design/2026-11-07-schema11-proof-separation-plan.md)，在已完成初始化、目录、标题三步后，单独归位迁移事实生成和比较。切换状态机、文件/命名空间操作、事务控制和旧物理清单恢复保持原位置。

工作树`f97f/codex-token-dashboard`，分支`codex/storage-responsibility-split-20261106`，搬迁基线`d0af260cb3278162e3e328a7927d3335f4de8f24`。方案提交`a751760d`，产品与两项合同测试提交`a19fb52f236aea949fc44e7a82efedd8ea2d953d`。

## 边界与结果

提取63行事实类型及713行迁移专用函数（均含空行），新增`migration/proof.rs`803行及8行入口模块；两项新测试位于独立78行`migration/proof/tests.rs`。父文件补充5行导入后净减少771行，从17,054行降至16,283行。

| 职责 | 本次归属和不变量 |
| --- | --- |
| 迁移事实、代次选择、lineage和专用指纹摘要 | 集中到proof；使用原借入连接，不创建连接、快照事务、文件或writer；查询顺序和错误优先级保持 |
| 序列化事实 | serde字段、字段顺序、类型和`protected_tables`缺省规则保持；旧manifest和accounting结构收据继续使用原格式 |
| `preserves`比较 | 原普通字段全等、旧受保护表摘要覆盖规则保持；新受保护表可以加入，但不能改变或丢失旧登记表 |
| 共享逐行摘要 | 62行`schema11_digest_value`、finish、query留在父模块；ledger仍直接使用同一实现，未反向依赖迁移模块 |
| 旧指纹转换 | `canonicalize_legacy_fingerprint`留在父模块，暂存导入/转换/证明继续共用；proof仍按原canonical字节排序 |
| manifest/receipt/phase、候选转换和切换 | 全部留在父模块，Prepared至Retained阶段、持久化点、回滚材料和Validated重启重验保持 |
| 生产/单测差异 | 生产仍在A内clone/replace；单测仍为物理数据库和sidecar改名，本次没有把两条路径统一 |

`migration.rs`只重导出原父模块需要的三项函数及事实类型。proof内部的类型和入口只开放到`exact_usage_index`这一层；事实类型仅`lineage`字段供原accounting复用判断读取，LegacyGenerationState仅向原转换器暴露published/building，其他字段与辅助保持私有。没有批量开放`pub(crate)`或通配导入。

## 源码核对

从固定基线重建完整父文件、proof及入口模块，比较完整文件内容。原函数体、13段raw SQL、其它SQL字符串、serde属性及比较算法保持；ledger、之前三个模块、external_state和runtime_recovery逐字不变。初稿补丁误把共享摘要片段一起纳入，并缺少部分跨层导入/可见范围；提交前源码复核已按方案纠正，随后完整重建核对通过，未将该中间稿提交或交给云端。

此次收益是迁移证明有集中审查入口。数据库格式、迁移策略和运行时查询数未变化，不作性能提升或完全解耦声明。

## 补充的合同测试

新增两项测试针对原有直接断言缺口，固定输入是手写的旧格式事实JSON，不由当前serializer生成，也不冒充历史版本实际产生的数据库：

- `legacy_migration_facts_preserve_persisted_fields_and_default_only_protection`：读取缺少protected_tables的旧事实，逐字段往返保持；缺失必需事实和显式null保护列表仍拒绝。
- `migration_facts_allow_added_protection_but_reject_changed_or_missing_old_evidence`：新增保护表允许，反向少保护、旧表摘要变化/缺失、相同行数但事件内容不同和lineage变化均拒绝；序列化重开后规则保持。

继续复用实际schema9/10迁移、同数量内容损坏、Validated恢复重验、切换阶段中断、旧补全收据、聚合滞后重绑定和accounting事实复用测试。两端实际日志要求53项指定保护用例通过，并核对旧完整Rust测试名/结果保持，新增只能是上述两项。

## 云端验收

所有编译与原生运行都在云端隔离合成数据中进行；本机仅编辑、源码核对和解析云端证据，没有访问正式库。

| 运行 | 范围 | 状态 |
| --- | --- | --- |
| [42354523749](https://github.com/hututuo/codex-token-bar/actions/runs/42354523749) | macOS/Windows完整库与非test生产入口、原备份清理负控、Swift/前端；0.9.8–0.9.11四版本双平台 | 全部通过，原始证据已核对 |
| [42354527686](https://github.com/hututuo/codex-token-bar/actions/runs/42354527686) | Public097原输入升级、旧schema13输入、Windows生产恢复及组合故障 | 全部通过，原始证据已核对 |

两轮均显式使用`a19fb52f`完整SHA和同提交workflow。`[skip ci]`避免push自动运行与手动完整运行重复，不禁用上述两轮。普通单测、非test生产路径和实际历史Rust producer分别核对，不能互相替代。

| 范围 | 实际结果 |
| --- | --- |
| macOS完整Rust库 | 1798通过、0失败、14项原有opt-in未执行；上一版1796项原成功用例和全部原有未执行项保留，仅新增两项proof合同用例 |
| Windows完整Rust库 | 1742通过、0失败、14项原有opt-in未执行；上一版1740项原成功用例和全部原有未执行项保留，仅新增两项proof合同用例 |
| 指定保护用例 | 两端各53项全部实际执行成功；包括新旧proof、迁移中断、候选损坏、事实复用以及之前目录/标题/存储保护 |
| 两端非test生产入口 | 各16场景通过，完整报告重新经原校验器验证；包括旧账、暂存恢复、真实分区绑定和发布读取 |
| 两端备份清理负控 | 原实现PASS、禁用清理FAIL、恢复后PASS；退出码0/101/0，源码恢复hash和原日志hash匹配 |
| Swift完整库 | 2361通过、37项跳过，execution记录与原日志hash相符 |
| 前端及脚本 | 前端1421和云端脚本18通过、无跳过；发布脚本111通过、1项跳过 |
| 0.9.8–0.9.11接续 | 8条双平台lane、64条真实场景报告和48次独立重开通过；旧值`[162,310]`、恢复材料和迁移状态保持 |
| Public097 Swift | 原输入升级8项、支持回归104项通过，均无跳过 |
| Public097 Windows | 原输入3项测试、4个生产阶段、19种旧清单/组合故障情形通过 |

历史lane源码清单包含本次`migration.rs`、`migration/proof.rs`和前面三步模块，所有记录的生产文件Git blob与候选提交一致；场景日志和汇总逐字段相符。历史矩阵是实际历史Rust实现，不代表四版本原生Swift producer矩阵。Public097的missing/unknown/stray-wal继续按保护性拒绝启动核对，两个组合故障情形各包含prepare/resume/reopen三阶段。

本轮已提交候选没有出现编译或产品测试失败，未放宽原工作流门禁。新增JSON合同测试是合成输入，实际旧版producer证据单列；既有备份清理负控不能当作新proof测试的变异验证。原有跳过项没有计为通过，可选性能矩阵未启用。

## 证据与收束范围

证据目录`scratch/schema11-proof-split-20261107/`保存`extract.mjs --verify`、`equivalence.json`、`validate.py`以及本次云端产物和原日志。`native-validation.json`、`historical-validation.json`、`final-validation.json`为复核结果；`library-*`、`control-*`、`swift`、`formed`和`public097`保存原始产物，`ci-passed`与`ci-execution`保存CI封存记录。源码核对器保留共享摘要和原模块hash；产物核对器绑定候选SHA、日志hash、旧测试身份及历史源码清单。

产品已提交并推送任务分支，两轮云端运行及原始证据复核完成。本笔证明职责归位到此收束，切换状态机、暂存导入、最终发布和路由仍属另行调查规划范围。没有合并、安装或发布；真实安装/UI和任意损坏库恢复不是本次验收结论。原有Windows报告hash保持`63801116c53adee10cb0692cdad6553e6187906f7659ae0aea67b69d4f24ecef`，其他未跟踪材料保留。
