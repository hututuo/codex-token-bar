# 2026-09-24 上线前外部审查交接

状态：`REVIEW_REQUIRED`（代码回归已通过；正式安装包、Windows 运行与视觉验收仍未放行）

## 1. 审查对象与范围

- 仓库：`hututuo/codex-token-bar`
- 代码基线：`a7bd20b8`（`fix: defer normalization and enable quota anomaly filtering`）
- 审查分支：`codex/sidebar-refresh-20260913`
- 本次目标平台：macOS、Windows x64。Windows ARM64 不作为本轮发布阻断项，但 Windows 源码仍是同一套 `target_os = "windows"` 路径。
- 本文只描述本次候选源码，不包含用户真实账号、Cookie、Token、原始认证响应或数据库副本。

本次请外部审查者重点判断：代码是否可以进入正式打包、安装和用户验收；不要把本地源码测试通过直接等同于正式发行已完成。

## 2. 已确定的产品决策

### 异常点过滤

额度历史增加“过滤异常点”开关，默认开启。开关关闭时只恢复未经过异常投影的原始有效观察值；它不改变实时额度、不删除 SQLite 原始记录，也不改变数据库 schema。缓存按开关模式隔离，不能复用相反模式的历史结果。

主要路径：

- Swift 设置与历史投影：`Sources/CodexTokenBar/QuotaHistoryFilterSettings.swift`、`QuotaHistoryStore.swift`
- Swift 设置界面：`Sources/CodexTokenBar/AppSettingsView.swift`
- Tauri 设置持久化：`tauri-app/src-tauri/src/models/settings.rs`、`platform/settings.rs`、`commands/settings.rs`
- Tauri 历史缓存与投影：`tauri-app/src-tauri/src/core/quota.rs`、`core/quota_history/series.rs`
- Tauri 设置界面：`tauri-app/src/components/settings/QuotaHistoryFilterSetting.tsx`

### 均一化金额延期

本次发布路径只保留原始 API 价格估算，不显示或计算“均一化”金额。GPT-6 Astra、GPT-6 Sol、GPT-6 Luna 的价格卡和模型识别仍在当前版本中。

延期记录：[2026-09-24-plan-cost-normalization-deferred.md](2026-09-24-plan-cost-normalization-deferred.md)。原均一化实现保留在分支 `codex/plan-cost-normalization-future`，后续版本单独评审。

### Luna Reserve 延期

Reserve 读数/回退链路不进入本次发布。完整实现保留在分支 `codex/luna-reserve-read-only`，当前发布源码不应出现 Reserve 协议字段、请求参数或状态机。

## 3. 当前本地验证结果

| 门禁 | 结果 | 证据 |
| --- | --- | --- |
| Swift 全量回归 | **PASS** | `GIT_LFS_SKIP_SMUDGE=1 swift test`：1583 passed，7 skipped，0 failed |
| Rust/Tauri 全量串行回归 | **PASS** | `cargo test --locked --manifest-path tauri-app/src-tauri/Cargo.toml -- --test-threads=1`：1133 passed，10 ignored，0 failed |
| Node/Tauri 前端全量回归 | **PASS** | `node --test $(rg --files src -g '*.test.mjs')`（在 `tauri-app` 内）：1123 passed，0 failed |
| Swift release 构建 | **PASS** | `swift build -c release` |
| Rust 检查 | **PASS** | `cargo check --locked --manifest-path tauri-app/src-tauri/Cargo.toml` |
| 前端生产构建 | **PASS** | `npm run build`（在 `tauri-app` 内） |
| 空间与源码静态检查 | **PASS** | `git diff --check`；当前 tracked files 无软链接；生产源码无 Reserve 协议引用、无均一化金额字段/文案 |

构建过程中仅有既有的 Swift/Rust 弃用或 dead-code 警告，以及前端 chunk/dynamic-import 提示；没有把这些警告当成失败，也没有自动执行依赖升级。

## 4. 尚未放行的门禁

这些项目必须由外部审查者或发布验收阶段单独确认，不能由上表的源码测试替代：

| 项目 | 状态 | 说明 |
| --- | --- | --- |
| Windows x64 最新安装运行 | **NOT_RUN** | 尚未在当前 `a7bd20b8` 候选上完成安装、启动、退出、重启及侧边栏窄条→圆环动画的最终视觉验收 |
| Windows x64 多显示器/DPI | **NOT_RUN** | 需要在实际 Windows 环境检查任务栏边缘、缩放和窗口夹取 |
| macOS 当前候选视觉验收 | **NOT_RUN** | 本次只完成源码/测试/构建证据，未把它当成用户级交互验收 |
| 正式签名安装包与 updater 闭环 | **NOT_RUN** | 未生成并验证正式 NSIS/DMG、签名、更新清单、下载安装和覆盖升级 |
| 真实历史库升级/搬迁 | **NOT_RUN** | 本文未携带真实库；需要用隔离副本验证旧 release schema、WAL、原始字段和增量扫描 |
| 外部安全/依赖审查 | **REVIEW_REQUIRED** | 需要审查者检查依赖、权限、网络请求边界、日志脱敏和打包内容 |

在上述门禁没有完成前，建议对外结论仍写为“代码候选可供审查”，不要写成“已正式发布”。

## 5. 建议外部审查清单

1. 检查额度历史开关的默认值、旧配置缺失字段、保存失败行为和两种缓存模式是否相互隔离。
2. 检查 `5h=0` 与 `7d=0` 的显示/判定边界，不应把单侧窗口耗尽误判为 Reserve 或其他窗口切换。
3. 检查 GPT-6 三个模型在模型占比、价格估算和未知价格提示中的数据流是否一致。
4. 检查均一化逻辑是否确实只在延期分支，当前发布路径是否仍能显示原始 API 价格。
5. 检查 Reserve 是否只存在于延期分支，当前二进制/前端构建输入是否没有对应协议参数或状态字段。
6. 检查 Swift 与 Tauri 的历史 SQLite 读取是否保持账号、套餐、limit ID、时间窗口隔离，并且过滤只改变投影不改原始数据。
7. 检查 Windows 侧边栏 reveal 动画的几何、透明度、窗口可见性发布顺序，以及失败/取消/重复点击时是否能回到稳定状态。
8. 检查所有跨端 IPC 命令是否有窗口权限限制、阻塞工作是否离开 UI 线程、错误是否对用户可解释且不泄漏认证信息。
9. 检查发布包是否只包含当前候选文件，不包含测试数据库、日志、Cookie、Token、软链接或延期功能的残留制品。
10. 在干净 macOS 与 Windows x64 环境分别完成安装、启动、升级、退出、重启和视觉验收后，再给出 `READY` 或 `BLOCKED`。

## 6. 建议复测命令

```sh
# Swift
GIT_LFS_SKIP_SMUDGE=1 swift test
swift build -c release

# Tauri/Rust
cargo test --locked --manifest-path tauri-app/src-tauri/Cargo.toml -- --test-threads=1
cargo check --locked --manifest-path tauri-app/src-tauri/Cargo.toml

# Tauri/Node
cd tauri-app
npm run build
node --test $(rg --files src -g '*.test.mjs')
```

静态边界检查：

```sh
git diff --check
git ls-files -s | awk '$1 ~ /^120000$/ {print}'
git grep -n -I -E 'supportsLunaReserve|supports_luna_reserve|gpt-reserve|lunaReserve|ReserveReadStatus|ordinaryUsageAllowed|base_model_inference' -- Sources/CodexTokenBar tauri-app/src tauri-app/src-tauri
git grep -n -I -E 'PlanCostNormalization|normalizedCostUSD|normalizedMoneyText|均一化' -- Sources/CodexTokenBar tauri-app/src tauri-app/src-tauri
```

最后两条在当前发布源码中应无输出；通用变量名 `normalized` 或 Swift/Rust 的 `reserveCapacity` 不属于延期协议或均一化金额功能，不应作为误报依据。

## 7. Git 交接

本次只应审查 `codex/sidebar-refresh-20260913` 分支及其最新提交。不要把 `main` 或 `codex/luna-reserve-read-only` 当成当前发布候选。`HANDOFF.md` 是工作区中原有的未跟踪文件，本次没有纳入提交，也不属于发布内容。

审查者完成后，请在此文档或对应审查记录中逐项给出 `PASS`、`NOT_RUN`、`FAIL` 或 `BLOCKED`，并附命令、环境、时间、commit 和制品 SHA256；不要只给一个总分。
