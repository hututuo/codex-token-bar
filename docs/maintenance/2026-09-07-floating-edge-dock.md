# 双端悬浮窗边缘吸附（2026-09-07）

## 当前交互

Swift 与 Tauri 在拖拽结束、启动恢复或布局恢复时检测靠边位置。距当前显示器可用区域边缘 48 个逻辑点以内，或窗口已部分越过边缘时，吸附到对应边缘。完全不与显示器相交的窗口不参与吸附。可用区域避开菜单栏、Dock 和任务栏；角落等距时按左、右、上、下排序。

黑色外壳包裹原卡片，鼠标移出 450ms 后收起。侧边额度条宽 12 点，保留展开窗口的完整高度；上下边额度条厚 12 点、最长 92 点。额度条与内部额度栏复用窗口筛选和配色：两项可用额度显示两段，缺少 5 小时窗口时仅显示 7 天；未读取到的额度不伪装为已用完。

悬停立即开始展开，没有额外的悬停等待。主体展开约 260ms，收起 150ms，支持反向并遵循减少动态效果。Swift 额度条在收起过程中渐显；Tauri 额度条持续保留同一个界面节点，待窄视口就绪后再用 120ms 淡入，避免缩窗时先出现、消失、再出现。展开前先确定收起形态的样式起点，避免跳过过渡。详情和引导期间保持完整窗口；Swift 锁定/跟随优先。

## 实现与性能

- 两端在固定原生窗口中执行收放动画，仅在展开开始和收起结束切换原生尺寸。收起后命中区域也缩为额度条。
- Tauri 收起期间保持额度条透明，主体动画完成后切换原生尺寸，再等待 WebKit viewport 匹配及布局绘制，才允许额度条淡入。等待期间重新进入会取消旧显现；原生缩窗期间收到的进入事件在尺寸操作完成后接续展开。等待失败恢复完整窗口。
- Swift 将 `FloatingEdgeTrackingView` 直接挂到原生内容视图，使用 `.activeAlways`。进入事件核对鼠标实际位置，几何更新期间忽略追踪噪声，重复移出事件不能重启正在完成的收起。原生拖拽命令返回后仍检测左键是否按住，使用独立的 30ms 释放确认回调；松开后才按最终位置决定吸附，布局刷新不能取消该确认。
- Tauri macOS 通过被动 `NSTrackingArea` 向 floating 页面发送进入/离开事件，失焦时继续工作，不抢焦点、不拦截点击。Windows 保留网页鼠标事件。
- `set_floating_dock_frame` 仅允许 floating 页面调用。macOS 使用一次 `NSWindow.setFrame`，坐标转换与 Tao 一致；Windows 使用 `SetWindowPos` 同时更新位置和大小且不激活窗口。避免两次调用之间在旧位置闪现。
- Tauri 黑壳和额度条始终锚定对应边缘。原生窗口缩小时不切换黑壳的尺寸/节点；展开时先将旧窄画面淡出 40ms，保留透明状态进行原生尺寸切换；等待 WebKit 实际 viewport 匹配和新布局绘制后，才恢复可见并开始 CSS 过渡，避免旧额度条先出现在展开窗口原点。等待失败时恢复可用的完整窗口；重复进入和取消不会留下隐形窗口。
- 没有新增空闲鼠标轮询。仅系统拖拽期间以 60ms 单飞间隔确认释放，最多两分钟；按住按钮时延后收起。收起时停止未读动效。
- 始终保存展开位置；原生过渡尺寸不会进入位置存储。几何更新串行执行，实际尺寸不符合预期时恢复完整窗口。

Swift 入口：`FloatingEdgeDock.swift`、`FloatingEdgeDockController.swift`、`FloatingTokenPanel.swift`、`TokenDisplaySurfaceComponents.swift`。

Tauri 入口：`floatingEdgeDock.ts`、`useFloatingEdgeDock.ts`、`FloatingPanelPreview.tsx`、`floating_hover_macos.rs`、`commands/surface.rs`。

## 验证

| 项目 | 结果 |
|---|---|
| Swift 构建与相关测试 113 项 | 前一提交 PASS，本次未改 Swift |
| 前端相关测试 74 项 | PASS，含收起额度延后显现、等待期间反向、失败恢复、缩窗期间重新进入，以及画面淡出、viewport/绘制等待、额度、位置和生命周期 |
| Rust 原生边界参数测试 1 项、窗口授权测试 16 项 | 前一提交 PASS；本次未改 Rust，完整 macOS app 重新构建通过 |
| TypeScript/Vite、Tauri macOS debug 构建和候选签名 | PASS；记录在本地 collapse-* 日志和交付清单 |
| 前一候选的 Tauri 收起及失焦悬停展开 | 用户已确认可以正常工作 |
| 本轮 Tauri 收起额度闪烁修复的实机效果 | 待用户验收；用户明确接手，代理不再操作界面 |
| Windows 编译与实机 | NOT_RUN |
| main 合并、远端推送、正式发布 | NOT_RUN |

本地证据位于 `runs/20260907-floating-edge-dock/`。本轮 Tauri 修改和替换以 `collapse-*` 日志及 `collapse-activation.json` 为准；Swift 保持 `fast-activation.json` 中的版本。Swift 本地运行入口为 `dist/Codex Token Bar.app`，Tauri 使用 `target/debug/run-bundle/latest` 指向独立运行包。Tauri 保留 `c050fc09` 运行包回退；Swift 保留 `abd750d3` 回退。最终交互验收由用户完成。
