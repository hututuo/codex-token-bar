# 分区数据搬运职责拆分

本批执行[存储拆分方案](../design/2026-11-06-storage-decoupling-plan.md)第2步，承接已完成的[备份模块拆分](2026-11-07-storage-backup-separation.md)。仅整理分区导入、导出与克隆；旧库接续策略、Exact整代发布及schema11迁移状态机保持原样。

工作树`f97f/codex-token-dashboard`，分支`codex/storage-responsibility-split-20261106`。基线`bf0fcf5e`，测试补强提交`201b8741`，产品搬迁提交`ebcdf377aa0f448c8f5faba250e2468ef9d53ad1`。

## 拆分边界

原有577行代码归入603行的`business_store_container/transfer.rs`。其中导入包装入口28行、导入内部实现183行、导出与克隆145行、导出辅助和schema遍历101行、表及sequence复制102行、导出目标清空16行、附加库别名2行。父容器从3142行变为2605行，含本批补充的45行测试。

新模块仍是同一个`Container`类型的固有方法实现，保留原公共入口和连接。仅`import_snapshot_inner`为供父模块的旧库导入调用而改为`pub(super)`；其它内部方法私有，不新增服务、trait、全局状态或writer。共享的列检查、rowid、对象删除、proof和回执写入函数仍在原拥有者处，通过明确导入使用，没有复制第二套实现。

| 职责 | 现在的位置 | 保持的合同 |
| --- | --- | --- |
| 普通快照/冻结快照导入 | `transfer.rs` | 来源只读ATTACH，目标/来源proof在原IMMEDIATE事务内复核；目录、数据、导入回执一起提交 |
| 单分区导出 | `transfer.rs` | 原目标连接和事务、DDL与sequence顺序、proof校验、DETACH、FK设置恢复及错误返回优先级 |
| 容器内分区克隆 | `transfer.rs` | 原source/target证明、事务和外键校验；失败不覆盖已有目标数据 |
| 旧输入选择、身份、激活/退休、覆盖判定 | 父容器及路由/恢复模块 | 来源和旧账保护策略未变；可选回执仍在原导入事务写入 |

不能把这次职责归位理解为完全消除依赖循环。新模块仍依赖父容器的小工具与类型；其收益是能集中审查数据复制与连接清理，而不必同时修改历史接续策略。

## 失败边界的验证补强

已有导入/克隆失败测试继续保留目标及旁边分区的proof检查，新增以下实际断言：失败后原连接回到autocommit、外键开关恢复、没有残留附加数据库，随后在同一连接上重试成功。

新增导出失败测试：目标已有需保留的数据，开启query_only让复制被SQLite拒绝；必须收到ReadOnly错误，原目标完整proof保持、连接设置和附加库状态恢复。再关闭query_only并在同一连接上导出成功。分别覆盖调用者原外键设置为开和关的情况。

没有为纯搬文件重新复制业务测试。云端必跑列表明确要求这些测试，以及完整schema往返、sequence保全、冻结目标在写事务内复核、冻结来源变更拒绝等既有反例，不能因为改了路径便少跑。

## 验证方式与运行入口

本机通过固定提交整文件重建核对：先从`201b8741`提取搬迁段，再重建新模块和删减后的父文件；两份文件与实际完整文本相等。测试区逐字保持，函数体、SQL、错误条件、事务种类及调用顺序保持，唯一可见性变化已单列。

所有编译和native运行都在云端，测试使用隔离合成数据库。本机没有构建Rust/Swift/前端、访问正式库、安装应用或发布。

| 云端运行 | 范围 | 当前状态 |
| --- | --- | --- |
| [42267052083](https://github.com/hututuo/codex-token-bar/actions/runs/42267052083) | 当前Mac/Windows完整库及生产fixture、原备份清理负控、Swift/前端；另明确开启0.9.8–0.9.11四版本×两平台矩阵 | 全部通过 |
| [42267059803](https://github.com/hututuo/codex-token-bar/actions/runs/42267059803) | Public097原始输入升级、旧schema13输入、Windows生产恢复及组合故障场景 | 全部通过 |

两轮均显式传入完整候选提交`ebcdf377aa0f448c8f5faba250e2468ef9d53ad1`，workflow也来自同一分支提交。0.9.8–0.9.11矩阵使用实际历史Rust生产实现；不能称为四版本原生Swift producer矩阵。每条lane包含committed/interrupted两种状态，各一次resume及三次独立reopen，验证旧值、WAL和原文消失后的历史保全，另比较恢复材料及迁移状态摘要。

## 实际结果与证据核对

| 范围 | 本次结果 | 核对内容 |
| --- | --- | --- |
| macOS完整Rust库 | 1796通过、0失败、14项原有opt-in未执行 | 原测试名和结果全部保留；新增恰好1项导出失败测试，原导入/克隆测试增加连接恢复断言 |
| Windows完整Rust库 | 1740通过、0失败、14项原有opt-in未执行 | 同上；原CRLF门禁修复继续生效 |
| 两端非test生产存储入口 | 各16场景通过 | 用完整报告校验器再次解析；路由、旧账保全、发布、原文消失和暂存恢复通过 |
| 两端备份清理负控 | 通过 | 原实现PASS、关闭清理FAIL、源码恢复后PASS；三份原日志hash和源码前后hash匹配 |
| Swift完整库 | 2361通过、37项跳过 | execution与原日志hash匹配；跳过不算通过 |
| 0.9.8–0.9.11实际旧版矩阵 | 四版本×两平台8条lane全部通过 | 64条真实生产报告；48次独立reopen保留恢复材料及迁移状态摘要；旧值保持`[162,310]` |
| Public097 Swift | 升级8项、支持回归104项通过，均无跳过 | 当前升级日志、支持回归日志和候选SHA重新核对 |
| Public097 Windows | 原输入3项测试通过，无跳过；4个生产阶段及19种旧清单/组合恢复情形通过 | 接续、重开、缺A拒绝；组合故障的目标独有账、冻结备份、额度恰好一次和B首次初始化凭据保留 |

8条历史lane的候选源码清单均与本次Git树匹配，包含新`transfer.rs`；没有用旧候选或抽取替代实现冒充本次接续。每个场景的实际日志与汇总报告逐字段一致。`interrupted`场景旧形成器原本没有B，所以`oldBPreserved=false`按该前提核对，不改成true。

Public097的`missing`、`unknown`、`stray-wal`场景是保护性拒绝启动，`startupReady=false`是预期结果；其它正常场景ready。19种情形中有2种组合情形各跑prepare/resume/reopen三个阶段，不把它们误计成只运行19次进程。Rust的三项旧输入测试是串行`--nocapture`日志，按完整测试名、固定producer标记、随后`ok`和总计核对，不放宽通用日志门禁。

本轮没有发生产品测试失败或修改生产行为。第一次下载macOS报告时产物尚未上传，稍后重取成功；本机证据脚本首次用系统旧Python缺少`tomllib`，改用已有Python3.13执行成功，没有安装依赖或本地编译。

本机证据入口为`scratch/storage-transfer-split-20261107/`，包含`extract.mjs`、`equivalence.json`、只读证据核对器`validate.py`及`native-validation.json`、`historical-validation.json`、`final-validation.json`。`library-*`、`control-*`、`swift`、`formed`、`public097`保存原始云端产物；`ci-passed/checked-source.json`保存最终CI身份封存。搬迁器只做固定片段移动并核对完整文件；证据核对器不运行产品或打开数据库。

## 收束与剩余边界

至此，原规划中“补准备份验收 → 备份分离 → 分区复制分离”已完成。先前拆出的proof和Exact连接扩展也在本次完整候选的双平台及历史接续范围内；不需要再以拆文件为由继续扩大修改。

本批提交已推送任务分支，未合并、安装或发布。当前已获得云端生产路径和历史输入验证，尚不等于真实安装环境/UI验收或任意损坏库都能恢复，也没有性能提升声明。Rust池v2不能直接退回旧v1二进制的边界未改变；代码回退不应恢复旧整库覆盖后续新账。

近2万行的`exact_usage_index.rs`、旧库接续状态机及循环依赖的进一步改造仍属单独后续工作，本批没有触动。用户原有Windows报告修改hash仍为`63801116c53adee10cb0692cdad6553e6187906f7659ae0aea67b69d4f24ecef`，其它已有未跟踪资料保留。
