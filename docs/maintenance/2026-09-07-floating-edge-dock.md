# 双端悬浮窗边缘吸附（2026-09-07）

## 交互

Swift 与 Tauri 均在拖拽结束、启动恢复或布局恢复时检测靠边位置：距当前显示器可用区域边缘 14 个逻辑点以内，吸附到最近的一边。可用区域避开系统菜单栏、Dock 和任务栏。角落按左、右、上、下的顺序解决距离相同的情况。

首次吸附时，黑色外壳从边缘伸出，包裹原有卡片。鼠标离开 450ms 后收起，边缘仅留下 6 个逻辑点宽/高的黑色把手；侧边把手最长 72 点，上下把手最长 92 点。悬停 100ms 展开，点击把手也可以展开。展开使用弹性曲线，收起使用 300ms 非线性曲线，支持中途反向并遵循减少动态效果设置。拖离边缘后解除吸附。

详情、引导期间保持完整窗口；Swift 锁定/跟随优先于边缘吸附。关闭详情后恢复吸附意图。多屏使用各自的可用区域；Tauri 几何以物理像素计算，界面按显示器 scale factor 换算为逻辑像素。

## 实现边界与性能

- 收放动画在固定的原生窗口内完成；只在展开开始、收起结束时切换原生窗口尺寸，避免逐帧跨原生桥移动窗口。
- 收起后实际原生命中区域也缩为黑色把手，不保留透明大窗口遮挡其他应用。
- Swift 采用 tracking area、窗口拖拽回调和一次性延时；Tauri 采用 DOM 进入/离开、窗口移动和缩放事件。Tauri 仅在系统拖拽期间以 60ms 单飞间隔确认鼠标释放，上限两分钟；按住按钮时也会延后收起。没有新增空闲鼠标轮询。
- 收起时停止浮窗内的未读动效。正常数据采集策略保持现状。
- 保存的始终是完整展开时的位置。收放写入由程序化几何保护隔离，布局写入串行执行；拖拽结束的实际位置单独进入原有尾随持久化队列。
- Tauri 原生最小尺寸改为 6×6 逻辑点，正常窗口尺寸仍由前端布局决定、窗口仍不可由用户直接缩放。切换尺寸后读取实际大小，约束拒绝或部分写入失败时尝试恢复完整窗口。
- Tauri 的鼠标状态命令只允许 floating 窗口调用，仅实现 macOS 与 Windows；其他平台读取失败时保留普通浮窗，不尝试自动隐藏。

Swift 实现入口：`FloatingEdgeDock.swift`、`FloatingEdgeDockController.swift`，通过 `FloatingTokenPanel.swift` 与锁定/位置保存逻辑接入。

Tauri 实现入口：`floatingEdgeDock.ts`、`useFloatingEdgeDock.ts`、`floatingGeometryLifecycle.ts`；原生鼠标状态在 `commands/surface.rs`，窗口约束在 `platform/surfaces.rs`。

## 验证与待验收

| 项目 | 状态 |
|---|---|
| Swift 构建、相关单元测试 109 项 | PASS |
| 前端几何、状态机、位置保存、详情和引导等相关测试 65 项 | PASS |
| Rust 窗口授权测试 16 项、surface 测试 31 项 | PASS |
| TypeScript/Vite 与 Tauri macOS debug app 构建 | PASS；产物校验见本地 verification.json |
| Swift macOS 候选 app 签名完整性 | PASS |
| 实际鼠标拖拽、悬停、动画观感、跨屏以及隐藏命中区域 | BLOCKED：电脑锁屏，待手动解锁后进行 |
| Windows 编译与实机运行 | NOT_RUN |
| 安装、切换当前运行版本、main 合并、推送、发布 | NOT_RUN |

本轮证据位于 `runs/20260907-floating-edge-dock/`。Swift 候选位于 `dist/edge-dock-candidate/Codex Token Bar.app`；Tauri 候选位于 `tauri-app/src-tauri/target/debug/bundle/macos/Codex Token Bar.app`。两者均为本地候选，不代表已完成真实交互验收。原先运行的 Swift/Tauri app 保持原版本。

恢复源码可以回到本轮起点 `cec7e326`；在候选版本验收前保留原有运行 app 作为回退。没有修改用户已有的浮窗位置或正式配置。
