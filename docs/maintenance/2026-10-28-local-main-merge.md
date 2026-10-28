# 本地 main 整合记录

本轮按用户要求合并当前这一批相关分支，未合并历史归档/保留分支，未删除分支。

- main 原基线：`9699328d`，已包含速蹬/速度展示、后台启动、本地 Claude 额度、主页错误提示。
- `codex/upgrade-recovery-fixes`：通过 `234bd412` 合并，包含迁移恢复 `9cf6e212`、模型色表 `4f1dcf6d`。
- `codex/sidebar-median-trend`：通过 `35298ed3` 合并，保留固定半小时中位数小趋势。
- 回退点：`codex/pre-upgrade-merge-20261028`，指向整合前 `9699328d`。

祖先关系检查确认：multi-client-tokens、startup-and-local-quota、integrate-speed-startup-20261028、speed-display-modes-20261026、upgrade-recovery-fixes、sidebar-median-trend、cold-history-read-paths 都已经包含在本地 main 中。

## 冲突解决

1. 保留新版模型色表/Claude 家族色，同时保留 main 新加的 GPT-6.1 Terra 颜色与识别、自定义颜色优先级。
2. 侧栏实时速度环继续使用 main 的 `barRates`，保留按模型/客户端分组；正文 TPS 模块切换到中位数趋势卡。
3. Rust 共用 numeric trend store 的读取生命周期；主页 `trend_points` 继续 `read_distribution`，侧栏单独读原始五分钟桶，避免把主页统计口径退回去。
4. 更新 Terra 可选模型列表断言；更新原来检查旧侧栏列表的测试，补实际 SidebarRailContent 到带来源 token 的数字桶读取/渲染链路测试。保留缺样、错误、隐藏、来源切换测试；配色重置断言使用新默认色。

## 验证

日志在本 worktree 的 `scratch/merged-main-*`。Rust 全量 1,508 通过、11 ignored；前端全量 1,313 通过；TypeScript `--noEmit`、Windows xwin library check 和 diff 检查通过。Swift 首次全量运行 2,103 项（27 项条件跳过），只有一条旧 selectableCases 断言未纳入 main 已增加的 Terra；修正期望后，相关 101 项（2 项条件跳过）回归、10 项本地速度展示测试通过。全量中的本地采集 8 项及上游 Agent Speed 655 项也通过。没有把首次全量描述为一次全部绿灯；修正后的失败项与相关逻辑已定向复测通过。

此次仅本地 Git 合并与源码/测试验证：没有推送远端、打包、替换/重启 Mac 正式版、构建替换 Windows EXE。旧分支及 main 回退点均保留。
