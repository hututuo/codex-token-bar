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

原文件仍是 `use super::*`。本次明确从 `connection` 获取生产/test Connection 别名和 effectful `open_read_only_index`，从 `store_metadata` 获取 metadata/表检查，从 `projections` 获取 attribution safety，从 `contracts` 获取版本/转换合同。仅测试使用的 metadata writer/常量保持 `cfg(test)`。

donor 新 `read_day/read_ranges` 和生产 `range_has_unreported_compaction` 完整保留。周期的 `(from, through]` 消费证明与日历的 `[start,end)` 查询各自不变；ranges 与 missing 检查仍共用一个 deferred 快照。补注释说明 legacy open 可能恢复 pool 或进入 namespace 准入，不能按名字当成纯读取 helper。

### QuotaSnapshot 与生产 fixture

当前全 Rust source 的 8 处 QuotaSnapshot 构造均有新字段或合法 struct update；serde default/skip-none 保留旧载荷兼容。`business_store_fixture::quota_bundle` 增加 None。`route_identity.rs` 只构造真实 generic/Exact canary，没有 QuotaSnapshot，因此无需额外字段或修改。

### 多客户端与 Antigravity

`multi_client_usage` 原本管理独立 B，继续使用自身 schema/gate/事务，不能误改为 A 的 StoreConnection。Antigravity 外部源通过只读/query_only connection 与一致快照读取，事件和 checkpoint 由既有 B 的 `persist_source_update` 同事务持久化；没有注册额外 A namespace。新本地发现复用原偏好选择、去重和限额，默认含 Orca macOS 路径，显式选择替换默认。

`quota/connection_mode` 只读取有界 config/auth 并判定模式，配置身份变化使旧在途结果失效。API 模式不发订阅额度请求、不把 API 当作订阅可测零；历史费用/已有账本仍保留。未添加后台授权、自动开通上报或新网络服务。

## 构建与安装计划

所有编译、完整测试和安装包构建仅通过云端。目标本机候选为 **0.9.11 / build 993 / arm64**，现有安装为 **build 992**。保持 bundle ID `local.codex.token-bar`、原指定签名要求、Sparkle feed 和公钥。按现有策略为 ad-hoc 签名，非 Apple 公证；候选包不签自动更新、不发布公开 feed。

AgentSpeed 继续固定 `a94a67fcc78e5d8eea5f82d8d5e737bccf994e2c`，donor 的本地 patches/additions 已由 vendor 工具校验。远端当前 HEAD 已前进，使用工作流支持的 reviewed_upstream_pin 与明确理由：此轮只集成已审查的两分支及其本地补丁，不夹带未审查的上游升级。没有更改 pin 或放宽哈希检查。

功能分支自身文档保留过两项 Swift 全量失败（active append 日汇总、superseded context load）；它们不是本次通过证据，不删测试或预判原因。只接受合并后同 SHA 的完整云端实际结果。

云端通过后核对 manifest/source SHA、资产 hash、ZIP 完整性、App 版本/架构/codesign/更新身份，再保留唯一命名的旧 App 回滚副本并替换、启动、检查进程与窗口。安装结果与测试结果分别记录；目前尚未安装。

## 最终结果

待合并后云端执行和本机安装完成后补充 SHA、run、测试、签名、回滚路径和启动证据。
