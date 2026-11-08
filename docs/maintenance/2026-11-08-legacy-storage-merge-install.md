# 多客户端功能与存储拆分分支融合及本机安装

用户明确授权将 `codex/legacy-debt-20261104` 合入 `codex/storage-responsibility-split-20261106`，云端验证和打包通过后直接替换 `/Applications/Codex Token Bar.app`，保留旧 App 回滚备份并验证启动。此次不合入 main，不创建 Release/tag 或更新公开 appcast。

## 固定输入和保全

- 存储侧：`dca3dcf6c8befe74b4106a07f55912e229b84d5c`（产品 `05a2b8d5`，之后仅收官文档）。
- 功能侧：`df826bb8bb77365641ef42058a245112ff6b6bff`，9 个提交，134 个文件。
- 共同祖先：`7e9d88d20758e53f959b496e3abb867ac337fd0e`。
- 本地功能分支存在；origin 没有同名 ref，因此以用户点名且已验证的完整本地 SHA 为 merge parent。
- 两侧唯一共同改动文件为 `business_store_fixture.rs`；Git 自动合并，无文本冲突。

`scratch/legacy-storage-merge-20261108/preflight.json` 保存两侧完整改动清单、9 个 donor SHA 和既有工作树文件 hash；`merge-equivalence.json` 证明：

1. donor 的 132 个文件与其 Git blob 逐字一致；cycle_range 与 fixture 是仅有的两处结合点。
2. 存储侧其余 81 个独有改动文件逐字一致，包含 A–D 模块、两类负控及 CI；没有回填旧大文件覆盖新模块。
3. fixture 恰好为存储侧原文加 donor 的 `connection_mode: None`；D 新 `route_identity.rs` 未变。
4. cycle_range 的全部定义/函数体/SQL/字面量/属性与 donor 一致，只有显式 imports 和副作用注释不同。
5. 原有 Windows 报告与未跟踪资料 hash 保持，不混入 merge。

## 结合点复核

### cycle_range

功能分支的该文件使用 `use super::*`。融合后明确从 `connection` 获取生产/test Connection 别名和 effectful `open_read_only_index`，从 `store_metadata` 获取 metadata/表检查，从 `projections` 获取 attribution safety，从 `contracts` 获取版本/转换合同。仅测试使用的 metadata writer/常量保持 `cfg(test)`。

donor 新 `read_day/read_ranges` 和生产 `range_has_unreported_compaction` 完整保留。周期的 `(from, through]` 消费证明与日历的 `[start,end)` 查询各自不变；ranges 与 missing 检查仍共用一个 deferred 快照。补注释说明 legacy open 可能恢复 pool 或进入 namespace 准入，不能按名字当成纯读取 helper。

### QuotaSnapshot 与生产 fixture

当前全 Rust source 的 8 处 QuotaSnapshot 构造均有新字段或合法 struct update；serde default/skip-none 保留旧载荷兼容。`business_store_fixture::quota_bundle` 增加 None。`route_identity.rs` 只构造真实 generic/Exact canary，没有 QuotaSnapshot，因此无需额外字段或修改。

### 多客户端与 Antigravity

`multi_client_usage` 原本管理独立 B，继续使用自身 schema/gate/事务，不能误改为 A 的 StoreConnection。Antigravity 外部源通过只读/query_only connection 与一致快照读取，事件和 checkpoint 由既有 B 的 `persist_source_update` 同事务持久化；没有注册额外 A namespace。新本地发现复用原偏好选择、去重和限额，默认含 Orca macOS 路径，显式选择替换默认。

`quota/connection_mode` 只读取有界 config/auth 并判定模式，配置身份变化使旧在途结果失效。API 模式不发订阅额度请求、不把 API 当作订阅可测零；历史费用/已有账本仍保留。未添加后台授权、自动开通上报或新网络服务。

## 云端构建与安装约束

所有编译、完整测试和安装包构建仅通过云端。本机已由 **build 992** 替换为 **0.9.11 / build 993 / arm64**。保持 bundle ID `local.codex.token-bar`、原指定签名要求、Sparkle feed 和公钥。按现有策略为 ad-hoc 签名，非 Apple 公证；候选包不签自动更新、不发布公开 feed。

AgentSpeed 继续固定 `a94a67fcc78e5d8eea5f82d8d5e737bccf994e2c`，donor 的本地 patches/additions 已由 vendor 工具校验。远端当前 HEAD 已前进，使用工作流支持的 reviewed_upstream_pin 与明确理由：此轮只集成已审查的两分支及其本地补丁，不夹带未审查的上游升级。没有更改 pin 或放宽哈希检查。

功能分支自身文档保留过两项 Swift 全量失败（active append 日汇总、superseded context load）；它们不是本次通过证据，不删测试或预判原因。只接受合并后同 SHA 的完整云端实际结果。

云端通过后已核对 manifest/source SHA、资产 hash、ZIP 完整性、App 版本/架构/codesign/更新身份，再保留唯一命名的旧 App 回滚副本并替换、启动、检查进程与窗口。安装结果与测试结果分别记录如下。

## 最终结果

正式 merge 为 `d4f41ec43e695db15d6da9dea68e8efcd1be4f44`，两个 parent 正是上述存储/功能 SHA。后续夹具适配提交为 **`9762f7542665aa900df7a24f57eb782d77b4b2ef`**，产品实现仍与 merge 相同；所有最终云端验证和打包均固定此 SHA。

- [完整 CI 与四版本矩阵 42443303941](https://github.com/hututuo/codex-token-bar/actions/runs/42443303941)：success。
- [Public097 42443304857](https://github.com/hututuo/codex-token-bar/actions/runs/42443304857)：success。
- [云端候选打包 42443306447](https://github.com/hututuo/codex-token-bar/actions/runs/42443306447)：success；下载产物与 manifest/hash 校验通过，本机已安装。

| 最终同 SHA 证据 | 实际结果 |
| --- | --- |
| macOS Rust 完整库 | 1,811 通过、0 失败、14 ignored；旧存储侧全部测试身份/结果保留，新增 13 项 |
| Windows Rust 完整库 | 1,755 通过、0 失败、14 ignored；旧存储侧全部测试身份/结果保留，新增 13 项 |
| 显式保护清单 | macOS 144 / Windows 143 项实际通过，合并 A–D 历史清单与 API 模式、Antigravity/Orca、按日读取用例 |
| 两端生产场景 | 各 16 项通过；原始输出、报告和两个 artifact 中重复材料 hash 一致 |
| 备份负控 | 两端 0/101/0；清理关闭必须具体因残留而失败，恢复源码 hash 相同 |
| 物理 A 替换负控 | 两端 0/1/0；正常/恢复各六真实入口拒绝替换，disabled 轮因接受替换而失败；三轮编译均成功 |
| Swift XCTest | 2,384 通过、38 跳过；两项 donor 文档旧失败用例本轮实际通过，未改其源码/断言。新增跳过为显式本机 Antigravity 数据验收，不算通过 |
| AgentSpeed Swift Testing | 674 项、79 suites 通过；与 XCTest 口径分开 |
| 前端 / cloud scripts / release scripts | 1,437 / 18 / 111 通过；前两组零跳过，发布脚本原有 1 项跳过 |
| 四版本历史矩阵 | 0.9.8–0.9.11 × macOS/Windows，8/8 链路、64 份真实报告、48 次独立重开通过 |
| Public097 | Swift 升级 8 + 配套 104、Rust 升级 3、生产 4 阶段、manifest 19 类场景通过 |

下载后的原始日志、checked-source、CI job outcomes、历史 archive 全生产文件 hash 和负控原始输出已再次解析校验；证据位于 `scratch/legacy-storage-merge-20261108/verified-9762f754/`。四版本矩阵证明的是归档 Rust 生产链路；不将它写成原生 Swift 四版本 producer 矩阵，Swift 完整库与 Public097 的证据单列。

### 产物校验与本机安装实况

macOS arm64 与 Windows x64/arm64 产物均已下载，资产大小、SHA-256 与固定 SHA 的 manifest 一致。macOS ZIP 完整性检查通过，App `codesign --verify --deep --strict` 通过，指定签名要求为 `identifier "local.codex.token-bar"`；ad-hoc 签名没有 Apple 公证，`spctl` 拒绝结果按该边界记录，未称为 Apple 公证通过。

| 校验对象 | SHA-256 |
| --- | --- |
| macOS App ZIP | `831582ea64cda2f1413beeae267338f9ed68e3a1926deec5199df19d06752967` |
| macOS DMG | `df69173ebbcaa753152b91bfa6a89c2d7756ceb5408fa680f312fad569449393` |
| 云端与安装后 build 993 可执行文件 | `c785588982bac565ebe6d4c0db2dd1d9743792f60c2f4248f699da9d59a8435d` |
| 原 build 992 回滚可执行文件 | `810258c2f95820fe1889aaff8c73e959253fd713b808d918c0a585690b0428f7` |
| 最终云端验证汇总 JSON | `b2b9bcd674c09f0a965a7e7ff008570c3b17cb185fd925668e011e88527cf4a2` |

2026-11-08 12:10:48（Asia/Shanghai）完成替换并启动 `/Applications/Codex Token Bar.app`。旧进程 PID 1056 已正常退出，新进程 PID 76255 从该安装路径启动。安装后的全部 bundle 文件与云端候选一致，签名及可执行文件 hash 复核通过。

旧 build 992 完整备份位于本工作树的 `scratch/legacy-storage-merge-20261108/local-install-993-a9eom_fo/rollback-build992/Codex Token Bar.app`，使用新建独立目录，未覆盖已有 rollback。备份完整性已验证；后续可执行文件 hash 复核仍一致。

12:13:17 的辅助功能查询成功：进程可见，主窗口标题 `Codex Token Bar`，位置 `(0,33)`、尺寸 `1512×895`。12:13:44 再查，仍为 PID 76255，连续运行 2 分 56 秒。用户及系统 `DiagnosticReports` 中匹配该 App 的报告均早于本次启动，未发现本次启动后的新崩溃报告。这里证明安装与启动/窗口可访问，不代替所有页面交互、动画或本机实时账目人工验收。

安装和启动证据分别保存在 `local-install-993-a9eom_fo/installation.json`、`runtime-verification.json`（同属上述 scratch 根目录）；`verified-9762f754/installation-pointer.json` 指向安装记录。`final-validation.json` 中的 `installed:false` 保留为安装前门禁快照，最终安装状态以独立安装/运行记录为准，不回写旧证据。

收官只补本文档，产品源码仍与云端验证的 `9762f754` 相同。原有未提交 Windows 报告及未跟踪资料保留，没有本地编译、额外数据库清理或公开发布。

### 首轮云端反馈（保留失败，不作为安装验收）

合并提交 `d4f41ec43e695db15d6da9dea68e8efcd1be4f44` 的完整 CI `42442655690` 中，macOS 16 个生产场景已通过，前端 1,421 通过/16 失败。失败均是旧侧栏测试仅提供 total/status，缺少既有 RunningThreadSummary 合同的 groups/unassignedSubagents；新统一任务投影对数组调用 map。补测试 fixture 的完整默认形状和已知计数，保留全部原断言，不给产品增加掩盖非法载荷的默认分支。

四版本矩阵另在候选注入的 `formed_release_probe.rs` 报 E0063：该独立历史模板没有新增的 connection_mode。普通生产 fixture 的 8 处构造已对齐，但此前构造扫描只涵盖 src，遗漏脚本注入模板。本次按被归档版本的公开 QuotaSnapshot 字段形状，仅给当前候选的合成初始化插入 None；旧 producer 原样，所有归档产品源文件仍逐字核验。新增正反例保证未知字段类型、重复适配/重复初始化不会静默通过；Python 门禁 14 项通过。

首轮原始前端日志和历史 candidate-build/report 保存在 scratch 的 attempt1；不改旧日志，不拼接这轮通过结果用于新 SHA。后续修正仅测试夹具/历史注入脚本，产品代码不变。
