# 多客户端复用现有任务详情

基线 `87aeef83`，分支 `codex/legacy-debt-20261104`。

## 问题与改动

Tauri 任务详情原来将 Codex 的 `RunningDetails` 卡片与 Claude/Antigravity 的 `ClaudeLocalTasks` 简易文字列表直接拼接。它们使用不同排版、各显示一组数量，详情也没有复用小亮条的来源有效性规则。

现在将原有主任务卡片、子代理层级、未关联任务及状态区抽出为 `RunningTaskDetails`。保留原有 `qs-task-*` 样式，增加轻量客户端来源标签；所有客户端复用同一套标题、模型、推理强度和已知状态展示。删除独立文字列表及其缩略 ID 展示。未知推理强度继续明确显示未知，不从模型后缀推测。

`combinedRunningTasks` 将所选 Codex、Claude Code、Claude Desktop 和 Antigravity 统一投影后交给详情组件。侧栏竖条、展开计数和设置预览也使用这一投影；相同输入下计数与模型分布一致，数据继续由已有采集器和窗口订阅提供。

## 保留的规则

- 客户端与任务 ID 共同决定归属，同名 ID 不跨客户端连接；没有可靠父关系的子代理保留在“未关联主任务”。
- 未启用、未选中或不可用来源不贡献当前任务；停止、idle、超过原有活动窗口的记录被排除。
- 有当前来源时不混入已过期 Codex 任务；全部没有当前来源时可保留明确标注的上次 Codex 状态。缺失来源会说明，全部不可用显示未知，不伪造零任务。
- 模型颜色使用主页费用和速度条的同一颜色函数，并订阅配色变更，主/子任务立即同步。
- 沿用现有详情面板尺寸及滚动，不引入另一套 Agent Speed 界面。Mac SwiftUI 已经共用原有任务卡片，本次没有改动 Swift、Rust、C#、采集器、业务账本或额度 API。

## 验证与边界

- 前端定向回归 37 项通过、0 跳过：原任务卡片、跨客户端同 ID、父子与孤立任务、单客户端筛选、来源失效、停止/过期记录、数量与十格模型条、Antigravity 和既有配色。
- TypeScript 与 Vite 生产构建通过，`git diff --check` 通过。
- 浏览器使用真正的 `RunningDetails`、本地读取 hook 和原侧栏 CSS，后端返回合成记录；验证 Antigravity 1 主/2 子、汇总 3 主/4 子、Antigravity 失效后保留 Codex/Claude 的 2 主/2 子、单独失效显示未知、自定义 Gemini 颜色同步。420×600 面板无水平溢出。
- 截图中的任务标题和金额核验场景是合成示例，不是本机实际任务。未安装、重启、推送或发布；未在 Windows 实机运行。

测试和构建原始日志/命令记录：`scratch/integrated-recovery/day-cost-20261106/unified-tasks-tests.{json,log}`、`unified-tasks-build.{json,log}`。组件预览、截图和源码哈希清单：`scratch/integrated-recovery/unified-tasks-20261106/`。
