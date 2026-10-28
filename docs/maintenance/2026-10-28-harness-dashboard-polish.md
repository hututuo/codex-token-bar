# 2026-10-28 多客户端主页与新特性提示收尾

## 合并与展示

- 合入 `codex/sidebar-median-trend` 的修正提交 `888a5e6e`，保留分布柱（P25–P75）及中位横线，不再使用旧连线图。纵轴边界按 5 TPS 对齐。
- 两端侧栏主数字字号从 18 改为 14。主数字使用近 30 分钟内最新的合格单条正文测速；小图使用固定半小时中位分布，二者独立。最新读数过期时隐藏整个正文 TPS 模块；历史读取失败不隐藏已有最新读数。
- Codex 与 Claude 各占一条主页额度行；Codex 行内保留重置卡、额度节奏和刷新入口。窗口较多时在同一客户端行内换行。
- 主页范围与侧栏范围分开持久化。侧栏默认包括已启用客户端，模块与窗口仍由侧栏设置控制。
- Claude 按本地出现的模型 ID 识别家族与版本，每个家族最新版本用主卡展示，其余分类到下方。版本规则不改模型账本 ID、不猜测价格。双击自定义颜色使用原始模型键，两端调色规则一致。
- 悬浮窗模型名去除 GPT 前缀并隐藏 Auto Review 行。主页独立参考金额、原始统计及费用账本保留。
- 仅额度条有不透明品牌圆点，与二级额度图例做对应移动。速度条不加品牌点。原生端复用 MatchedStrokeMorph；WebView 仅在切换时创建合成动画，结束、反转、卸载时恢复原节点，静止时没有逐帧任务。

## 新特性介绍与同意

两个启动提示合成“本次更新”的新特性介绍，独立选择：

1. 参加速蹬排行榜：默认关闭，继续通过原有数据说明与昵称确认流程后才开启上报。演示视频是已有本地资源，显示介绍不会加载排行榜网页。
2. 识别到 Claude Code：用户主动启用本地统计，明确显示“仅读取本地，不产生任何网络请求”。此操作只保存本地客户端设置并刷新本地记录，不开启排行榜或注册设备。

关闭后持久记录已处理的介绍及客户端发现提示。速蹬状态读取失败不阻断 Claude 本地选择，也不消耗尚未显示的排行榜介绍。设置中仍可随时修改。

## 验证

- TypeScript：`npx tsc --noEmit` 通过。
- 前端全量：1324 项通过，0 失败。
- Swift XCTest：2108 项，0 失败，27 跳过；Claude 本地采集另 8 项通过。
- Swift Testing：产品 10 项通过；Agent Speed 上游 655 项通过。
- 原生定向渲染/布局/动画回归：37 项通过。使用隔离 UserDefaults 和明确模拟额度，不改用户账本。
- 新特性交互覆盖：两个选择独立、本地启用不调用上报开启命令、关闭后不重复、速蹬状态失败仍可启用本地统计。
- 日志：`scratch/harness-polish-{swift-full,ui-full,tsc}.log`。

候选原生组件渲染（非已安装软件截图）：

- `scratch/harness-polish-preview/new-features-native.png`
- `scratch/harness-polish-preview/native-sidebar-median.png`
- `scratch/harness-polish-preview/aggregate-native.png`
- `scratch/harness-polish-preview/many-windows-native.png`

本轮未打包、安装或重启正式版；Windows 已同步前端源码及测试，未做 Windows EXE 构建/真机验收。未修改 Rust 或数据库迁移，本轮未重复 Rust 全量测试。未向 Anthropic 发请求。
