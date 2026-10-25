# 主页面滚动：可见窗口采样与引导动画暂停

## 状态与边界

本线程 API 测速/上报源码已在 `63cba542` 保存。仍未完成：真实服务端注册/签名上报联调、Windows 整机运行验收；本次未代替另一接入分支做这些联调，未发送新设备或测速数据。高清邀请视频已完成。

本次只在本工作树改 macOS 引导动画的滚动策略，未碰另一 fork 的 worktree。正式应用仍为 `/Applications/Codex Token Bar.app` 的 build954，PID7706，启动时间2026-10-25 01:56:31；只做滚动采样，没有安装、重启或替换。Windows 没有这条 SwiftUI 动画布局路径，本次不宣称验证了 Windows 整机性能。

## 现场证据

对正式 Mac 进程做10秒、2ms间隔的 `sample`，期间通过 Computer Use 连续滚动，无中途AX树读取。主线程2754个样本，其中1827个在transaction flush路径，903个在CA commit路径，733个在其中一条window layout路径。它们是嵌套栈计数，不能相加或当作准确CPU占比/帧率。指向布局、绘制与提交竞争，不能单凭此归因到某个视图。

原始采样压缩保存在 [installed-scroll-noax.txt.gz](assets/20261025-scroll-probe/installed-scroll-noax.txt.gz)。

## 配对试验与最终修改

独立临时 AppKit 宿主加载测试bundle，使用真实生产组件：100%缩放容器、全年热力图、8640个五分钟用量桶、引导演示和20行占位内容。数据均为合成；不启动DashboardRuntime，不打开用户数据库，不做网络请求。窗口1000×650，确认真实occlusionState为visible；异步等待图表加载，并通过AX确认显示8640点而非加载占位。

每轮360次同轨迹滚动，以60Hz为目标调度，记录整个进程CPU时间、滚动循环间隔以及强制布局/绘制耗时。每组3轮取中位数；程序实际呈现FPS **未测量**，不能把以下循环间隔换算成屏幕FPS。

| 指标 | 修改前 | 最终代码 |
|---|---:|---:|
| 滚动循环P95 | 35.51ms | 17.85ms |
| 超过25ms的循环 / 360次滚动 | 184 | 6 |
| 同样360次操作的进程CPU耗时 | 3.884s | 2.037s |
| 整轮墙钟时间 | 9.385s | 6.398s |
| 单次强制布局/绘制P95 | 3.58ms | 7.02ms |

循环P95降低49.7%，CPU总耗时降低47.6%。**同步布局子步骤P95反而上升**，因此结论是完整滚动循环改善，不能说每一项绘制指标都下降，更不能等同电池功耗下降。源数据全部保留在 [summary.json](assets/20261025-scroll-probe/summary.json) 和6份 `exposed-before/fixed-*.json`。

单独强制暂停动画的实验已显示相近收益；最终代码使用真实clip bounds变化检测也重现了收益。因此确认引导动画和滚动叠加是这个场景的重要卡顿来源，但不能保证覆盖主页面所有数据规模、所有设置。

最终仅两处产品文件：

- `AnimationActivity.swift`：给现有可见性探针增加可选的滚动暂停；只在坐标确实变化时更新活动时间；持续滚动时合并为一个待执行的恢复检查；停稳180ms后恢复，空闲无轮询。销毁/重挂载取消恢复任务。
- `RecentChartInteractionGuide.swift`：仅图表引导演示启用此策略。测速、扫描、真实速率和账本刷新不受影响；“知道了”的持久化不变。

未保留的试改：100%容器跳过高度回算、给引导绘制缓存、热力图色块合成。热力图合成CPU仅小幅改善、慢循环基本不变，不能算作主要修复。早期命令行XCTest窗口被遮挡，且同步测试会阻止异步图表准备，其数据不用于最终结论；保留在 `/tmp/tokenbar-scroll-20261025` 供追溯。

## 验证

- 55项相关回归通过，1项截图测试按默认opt-in设置跳过；包括连续滚动暂停、180ms后恢复、重复bounds通知不重发、解绑后无延迟回调、懒加载与动态内容高度，以及图表/热力图原有交互测试。
- 最终独立可见宿主3轮均输出visible=true，重现上表收益。
- `git diff --check` 通过。
- 正式应用替换后的真实用户数据整页FPS验收：**NOT_RUN**，遵守用户不安装、不重启、不替换的限制。
- TPS趋势展示仅做了 [真实数据方案预览](2026-10-25-tps-trend-proposal.md)，未修改产品曲线。

## 复现宿主

测试入口为 `ChartGuideScrollPerformanceTests.swift` 中的 `TokenBarScrollProbeEntry`；普通 `swift test` 默认跳过性能窗口。回归测试仍可直接运行。只用命令行XCTest窗口不能保证真实可见，必须检查输出的window_visible。

[ProbeHost.swift](assets/20261025-scroll-probe/ProbeHost.swift) 是临时AppKit宿主源码，不随产品发布。先用 `swift build --build-tests -j 4` 生成测试bundle，然后准备 `/tmp/tokenbar-scroll-probe-config.json`，字段如下：

```json
{
  "test_bundle": "<本工作树>/.build/out/Products/Debug/CodexTokenBarTests.xctest",
  "CODEX_SCROLL_HEATMAP": "1",
  "CODEX_SCROLL_CHART": "1",
  "CODEX_GUIDE_SCROLL_PERF": "/tmp/tokenbar-scroll-result"
}
```

将宿主以 `swiftc` 链接Xcode的macOS Developer `XCTest.framework`，同时加入 `Developer/Library/Frameworks` 和 `Developer/usr/lib` 的rpath，放入临时`.app`（独立bundle id，例如`local.tokenbar.scrollprobe`）。通过正常GUI启动；宿主异步调用测试入口，三轮结束自动退出。不要安装、覆盖或用正式应用的bundle id。采样时保持测试窗口可见，不与其他性能测试并行。
