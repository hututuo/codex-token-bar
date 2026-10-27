# 原生侧栏展开、收起卡顿修复

日期：2026-10-23。基线：`906a7554`；分支：`codex/native-jank-20261023`。

本次修复 macOS 原生侧栏动画中的一个已定位阻塞源：每个显示帧都调整 `NSWindow` 大小，导致主线程同步等待 WindowServer。改为动画期间固定原生窗口范围，在窗口内部移动、裁剪原有画布。最新源码的原生夹具已运行；没有替换安装版、推送或发布。Windows 没有本次 AppKit 改动。

## 根因与证据

旧路径是 `QuotaSidebarFrameClock.tick` → `QuotaSidebarController.updateFrames` 的动画闭包 → `NSWindow.setFrame`。即使 `display: false`，AppKit 仍会进入 `_updateWMWindowPresentationMode`，通过 SkyLight 的 `SLSWindowServerClientManagedDisplayGetCurrentSpace` / `get_current_display_system_state` 同步查询显示状态。

对本任务自己启动的 XCTest 进程进行 9 秒、1 ms 间隔采样：修改前主线程 3,654 个采样点，其中动画回调子树 458 个，窗口呈现模式分支 296 个、其显示状态查询分支 263 个。修改后主线程 3,364 个采样点，动画回调子树 84 个。这是调用栈采样数量，不能直接当作整机 CPU、功耗或帧率降幅。

证据保存在项目外层 `runs/20261023-native-jank/`：有效调用栈为 `baseline-main-thread-sample.txt` 和 `after-main-thread-sample.txt`。首次 `baseline-sample.txt` 错误采到了 `swiftpm-xctest-helper`，不用于热点判断；同次 `baseline-profiled.json` 是 XCTest 自己生成的有效时序记录，但该轮另有 helper 采样开销。此限制不能省略。

## 实现与交互约束

生产改动集中在 `Sources/CodexTokenBar/QuotaSidebarController.swift`。

1. 开始动画时，把原生窗口设置为当前可见范围与目标范围的并集。AppKit 会做像素对齐，因此后续换算使用实际 `panel.frame`，而不是请求值。
2. 新增 `QuotaSidebarRevealView`，在这个固定窗口内移动、裁剪既有 `QuotaSidebarCanvasView`。每个显示帧只调整子视图，继续保留原显示时钟、缓动、背景、圆角、握柄和稳定的 SwiftUI 画布尺寸。
3. `presentedRailFrame` 单独保存屏幕坐标中的可见范围。反向动画直接从这个范围继续，避免先收紧原生窗口造成半点取整跳动。
4. 动画结束后才收紧原生窗口。收起终点仍是实际 16pt 宽的窗口，不永久保留一个透明大窗口。
5. 透明区域由视图命中测试排除；动画帧和指针移动时还根据可见范围更新 `ignoresMouseEvents`。终点恢复正常输入。
6. 握柄按下时冻结视觉位置，同时保持原 down/up 窗口坐标。达到拖动阈值才收紧窗口并重新锚定。短点击后继续动画；如果系统丢失 mouse-up，检测到按钮已松开后仍恢复动画，不伪造一次点击。
7. 减少动态效果、立即布局、关闭与屏幕变化沿用原有入口，清理临时呈现状态。无需新增计时器、网络轮询或持久化字段。

不要重新在显示时钟中调用 `NSWindow.setFrame`。也不要用窗口并集替代可见范围做反向动画或握柄命中，否则会重新引入位置跳变或错误输入区域。

## 同机原生夹具结果

使用生产控制器和视图、3 个模型共 864 个合成趋势点。每个场景包含 3 次展开/收起，期间每 0.1 秒触发数据刷新。三轮复测串行执行，没有与构建或主线程采样并行。主循环间隔由测试循环测得，不是显示器硬件帧时间。

| 场景 | 基线主循环 p95 / 最大间隔 ms | 修复后第 1 轮 | 第 2 轮 | 第 3 轮 |
|---|---:|---:|---:|---:|
| 未显示速度图 | 9.92 / 20.36 | 3.31 / 15.66 | 3.74 / 24.35 | 3.34 / 13.97 |
| 显示并刷新速度图 | 9.58 / 35.93 | 3.35 / 34.60 | 3.79 / 25.27 | 3.53 / 33.51 |

可见速度图场景的 p95 在这些观测中降低约 60–65%。基线记录了 170 个相邻原生 resize 间隔（过滤掉 ≥200ms 的间隔，故至少有 171 次通知，不能当成精确总次数）；修复后三轮每个场景均仅 6 次原生 resize 通知。修复后每场景仍观察到 213–220 次视觉范围变化，未通过取消动画或大幅减帧来换取数字改善。

新增 `native_resize_count`、`visual_frame_count` 和 `visual_frame_intervals` 输出。旧 `resize_intervals` 仍保留，但现在原生 resize 只发生在边界，不能再拿它衡量视觉帧率。视觉范围观测是测试循环采样，不等于硬件提交计数。

此前全量审查修复夹具曾出现 79.25ms 尾部间隔；本轮基线最大值为 35.93ms，说明尾部明显波动，不能把 79→25ms 当成稳定收益。带采样器的修复后速度图场景仍出现 65.66ms 最大间隔，非采样三轮也仍有约 25–35ms 最大间隔。因此结论是消除了逐帧调整原生窗口这一阻塞源、常见主循环间隔改善，不是所有设备和场景都不会卡顿。

## 验证与复现

新增 `QuotaSidebarRevealTests` 覆盖左右边缘裁剪、透明区域命中、SwiftUI 画布尺寸、动画中原生窗口不逐帧变化、丢失 mouse-up 后恢复、中途反向连续性和最终 16pt 输入区域。开发阶段的断言实际发现了请求窗口与 AppKit 对齐结果不一致、反向动画半点跳动，修正后通过；相关失败日志也保留。丢失 mouse-up 测试仅调用测试窗口的处理器，不向系统注入鼠标事件；遇到物理鼠标干扰时跳过。

生产侧栏高度/截图夹具通过，查看了三模型侧栏及设置页截图；模型数量改变时的高度余量行为继续由原测试验证（582→582→625pt）。最终代码完整 Swift 回归为 1,882 项、18 项跳过、0 失败；最后侧栏专项为 53 项、2 项可选性能测试跳过、0 失败，三轮可选性能测试另行通过。日志与证据 hash 见外层 `REPORT.md` / `verification.json`。前端、Rust 本次没有修改，前次全量通过记录见 [全量审查修复说明](2026-10-23-whole-app-audit-fixes.md)。

从源码目录执行：

```sh
swift test --jobs 2
swift test --skip-build --filter QuotaSidebarRevealTests
CODEX_SIDEBAR_PERF_OUTPUT=/tmp/sidebar-transition.json \
CODEX_SIDEBAR_RATE_PERF_OUTPUT=/tmp/sidebar-collapsed.json \
swift test --skip-build --filter SidebarTransitionPerformanceTests
```

性能夹具会打开合成原生窗口，应单独运行；普通全量测试跳过可选性能夹具。降低动态效果开启时，动画专属回归会跳过。采样脚本 `runs/20261023-native-jank/profile-native-fixture.py` 只寻找其自己启动的子进程树中的 XCTest，不附加用户正在运行的安装版。

## 交付边界和回退

这是当前源码的生产控制器运行、合成截图和测试证据。尚未替换 `/Applications/Codex Token Bar.app`，也没有进行安装版长时间手动操作或新版本多屏硬件验收。安装版的体感不会因源码提交自动改变；后续统一打包时必须包含本分支修复。

源码回退使用本次修复提交的 `git revert`，基线为 `906a7554`；不要回退账本、删除样本或覆盖后续用户修改。证据目录标记为保留，本次复用现有构建目录，没有新增安装包或全局修改。
