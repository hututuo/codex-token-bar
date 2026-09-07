# 双端悬浮窗边缘吸附（2026-09-07）

## 当前交互

Swift 与 Tauri 在拖拽结束、启动恢复或布局恢复时检测靠边位置。距当前显示器可用区域边缘 48 个逻辑点以内，或窗口已部分越过边缘时，吸附到对应边缘。完全不与显示器相交的窗口不参与吸附。可用区域避开菜单栏、Dock 和任务栏；角落等距时按左、右、上、下排序。

黑色外壳包裹原卡片，鼠标移出 450ms 后收起。侧边额度条宽 12 点，保留展开窗口的完整高度；上下边额度条厚 12 点、最长 92 点。额度条与内部额度栏复用窗口筛选和配色：两项可用额度显示两段，缺少 5 小时窗口时仅显示 7 天；未读取到的额度不伪装为已用完。

悬停立即开始展开，没有额外的悬停等待。展开约 520ms，收起 300ms，支持反向并遵循减少动态效果。额度条在收起过程中渐显，持续保留同一个界面节点；展开前先确定收起形态的样式起点，避免跳过过渡。详情和引导期间保持完整窗口；Swift 锁定/跟随优先。

## 实现与性能

- 两端在固定原生窗口中执行收放动画，仅在展开开始和收起结束切换原生尺寸。收起后命中区域也缩为额度条。
- Swift 将 `FloatingEdgeTrackingView` 直接挂到原生内容视图，使用 `.activeAlways`。进入事件核对鼠标实际位置，几何更新期间忽略追踪噪声，重复移出事件不能重启正在完成的收起。
- Tauri macOS 通过被动 `NSTrackingArea` 向 floating 页面发送进入/离开事件，失焦时继续工作，不抢焦点、不拦截点击。Windows 保留网页鼠标事件。
- `set_floating_dock_frame` 仅允许 floating 页面调用。macOS 使用一次 `NSWindow.setFrame`，坐标转换与 Tao 一致；Windows 使用 `SetWindowPos` 同时更新位置和大小且不激活窗口。避免两次调用之间在旧位置闪现。
- Tauri 黑壳和额度条始终锚定对应边缘。原生窗口缩小时不切换黑壳的尺寸/节点；展开前同步计算收起样式，再开始 CSS 过渡。
- 没有新增空闲鼠标轮询。仅系统拖拽期间以 60ms 单飞间隔确认释放，最多两分钟；按住按钮时延后收起。收起时停止未读动效。
- 始终保存展开位置；原生过渡尺寸不会进入位置存储。几何更新串行执行，实际尺寸不符合预期时恢复完整窗口。

Swift 入口：`FloatingEdgeDock.swift`、`FloatingEdgeDockController.swift`、`FloatingTokenPanel.swift`、`TokenDisplaySurfaceComponents.swift`。

Tauri 入口：`floatingEdgeDock.ts`、`useFloatingEdgeDock.ts`、`FloatingPanelPreview.tsx`、`floating_hover_macos.rs`、`commands/surface.rs`。

## 验证

| 项目 | 结果 |
|---|---|
| Swift 构建与相关测试 112 项 | PASS，含立即展开、重复退出/伪进入不会打断原生收起 |
| 前端相关测试 64 项 | PASS，含近边/越界、额度一段/两段、样式起点、反向、位置和生命周期 |
| Rust 原生边界参数测试 1 项、窗口授权测试 16 项 | PASS |
| TypeScript/Vite、Tauri macOS debug 构建和候选签名 | PASS；记录在本地 refine-* 日志和交付清单 |
| 前一候选的 Tauri 收起及失焦悬停展开 | 用户已确认可以正常工作 |
| 本轮 Swift 收起修复与最终动画观感 | 待用户验收；用户明确接手，代理不再操作界面 |
| Windows 编译与实机 | NOT_RUN |
| main 合并、远端推送、正式发布 | NOT_RUN |

本地证据位于 `runs/20260907-floating-edge-dock/`。`verification.json` 是首次候选的历史快照；`activation.json` 是首次替换记录；后续修改和替换以 `refine-*` 日志及 `smooth-activation.json` 为准。Swift 本地运行入口为 `dist/Codex Token Bar.app`，Tauri 使用 `target/debug/run-bundle/latest` 指向独立运行包。保留 `42989b38` 运行包作为回退，最终版本的交互验收由用户完成。
