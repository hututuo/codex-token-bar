# Dirty worktree 收束审计

日期：2026-08-16

本次目标是保存所有未提交改动、按平台区分候选内容，并明确哪些可以后续合入，避免把未验证 WIP 当成正式发布版本。

## 安全边界

- 未使用 `git reset --hard`、`git clean`、`git branch -D`。
- 未 push、未发布、未部署、未重启运行中的 Token Bar。
- 主工作树原有 Swift/Tauri 修改分别保存为 WIP 提交；quota 候选树的所有 dirty 内容也完整保存为 WIP 提交。
- `main` 未被本次 WIP 提交改写。

安全引用：

- `archive/pre-dirty-audit-root-20260816` → `57a5ff65ea0c553cc6de7470ca27ab5636e66d9b`
- `archive/pre-dirty-audit-quota-20260816` → `d56e55254045fbd850f02925e6729d0c0c580e9b`
- `archive/pre-dirty-audit-fix-tauri-20260816` → `79f7e4795a669788d0c68fb015475fff4f25e411`

## 主工作树：Swift

工作树：`/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard`

提交：`d05118d wip(swift): preserve dirty index and dashboard work`

范围：29 个 Swift 源码/测试文件，`+996/-96`。

内容分组：

- 精确索引进度、模型归因桶完成状态、SQLite 跨进程等待；
- 自动审查 2026-07-30 Luna 生效时间规则；
- Spark 暂定参考价（明确不进入主总计）；
- Swift 主界面本 7d 模型费用、悬浮窗费用/雷达排版与缩写；
- 额度/精确统计状态指示器及相关测试。

验证：源码编译通过；全量 1248 个测试中 1247 通过、4 跳过、1 失败。唯一失败是 `InterfaceScaleSettingsTests.testStatStripKeepsCompactHeightAtLargeManualScale`：实际高度 162，旧断言上限 116。它是布局契约不一致，不是编译错误或索引损坏。

决策：保留为 Swift WIP，不合入 `main`，待确认是收紧布局还是更新合理高度契约后再处理。

## 主工作树：Tauri/跨平台

提交：`58aca13 wip(tauri): preserve dirty dashboard and precise-index work`

范围：48 个 Tauri/Rust/前端文件，`+1212/-94`。

内容分组：

- Tauri 精确扫描预扫描进度、索引迁移进度、跨进程锁等待；
- dashboard 数值/模型费用/自动审查时间规则/Spark 参考价；
- 悬浮窗雷达、模型行、7d 图表与状态显示；
- 前端 API、状态机、启动刷新与兼容字段。

验证：前端 `837 passed / 0 failed`；Rust `917 passed / 0 failed / 5 ignored`。

决策：保留为 Tauri WIP，不直接发布；后续应先把 `79f7e47` 的 dashboard 数值缓存 lineage 修复移植进来，再做一次双端集成验证。

## quota 候选工作树

工作树：`/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard-worktrees/quota-refresh-decoupling-backoff`

提交：`9acad75 wip: preserve pre-consolidation quota candidate`

范围：26 个文件，包含原来两个未跟踪文件，`+1358/-186`。

其中已经被主工作树较新实现替代的内容：

- 本 7d 模型费用/自动审查规则/主界面费用行的旧版本；
- 部分 Swift 数值阶段与 Tauri 7d 展示逻辑；
- `floatingPresentation.ts` 相关预览统一代码需要与主工作树当前 UI 重新对齐，不能直接整分支合并。

仍有价值但尚未移植的内容：

- state_5.sqlite 瞬时替换时更长的有界重试与 3 秒 busy timeout；
- `CodexUsageHistoryIndexError` 的瞬时读取错误传播；
- 保留原刷新参数的瞬时恢复调度；
- Swift 拖拽预览坐标修复、Tauri 设置预览与真实悬浮窗样式统一。

验证：代码可编译；布局测试实际高度 171，而该候选把断言上限改成 170，仍失败。因此该树明确是未收敛 WIP，不能直接合并或发布。

决策：完整保留提交，后续按上述独有改动逐项移植；不采用它的旧 7d fallback 计价逻辑，除非重新确认“精确统计不可用时是否允许估算”的产品契约。

## 其他 worktree/分支

当前所有 worktree 已无 dirty 状态。按 `git cherry` 对主工作树核对：

- 已被等价吸收：`7d-cost-option-swift`、`7d-cost-option-tauri`、`startup-quota-cadence`、`startup-swift-numeric-detail`、`startup-tauri-live-unread`、`startup-tauri-precise-coordinator`、`startup-ui-model-strip-spacing`、`feature/model-share-visualization`。
- 仍有独有提交、暂不删除：
  - `codex/swift-floating-drag-followup-20260813`：`866f143`，Swift 拖拽预览附着修复；
  - `codex/tauri-preview-parity-followup-20260813`：`ba8117d`，Tauri 真实悬浮窗与设置预览统一；
  - `codex/fix-tauri-repeated-full-20260816`：`79f7e47`，数值 dashboard cache lineage 与线程元数据解耦。

这些独有分支即使当前 worktree 干净，也不能只按分支名或日期删除；要等移植、验证并确认没有活跃会话依赖后再用 `git branch -d` 和 `git worktree remove` 收束。

## 下一步决策顺序

1. 先修正 Swift 高度契约并跑 Swift 全量测试。
2. 从 quota WIP 中单独移植瞬时 SQLite 读取恢复与拖拽/预览修复，避免带入旧的 7d fallback 计价。
3. 在 Tauri WIP 上审查并合入 `79f7e47`，验证元数据变化不触发数值 dashboard 全量重算。
4. 处理两个仍有独有提交的浮窗分支，完成双端构建前再决定是否删除。
5. 在所有 WIP 收敛并通过双端验证前，不更新 `main`、不替换运行实例、不发布。
