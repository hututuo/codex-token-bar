# Dock 主界面恢复修复（2026-09-07）

用户要求点击底部 Dock 图标即可重新激活主界面，包括主界面及悬浮窗都已关闭的情况；实际界面验收由用户完成。

## 变更

- Swift 的 Dock reopen 不再被其他可见面板拦截；明确取消应用隐藏，并还原最小化的主窗口，再激活它。主窗口不存在时沿用 SwiftUI window scene 创建路径。
- Swift 登录启动隐藏只消费一次；用户明确打开后，尚未执行的延迟隐藏也失效，避免恢复后又消失。
- Tauri 沿用无条件响应 Dock reopen 的已有路径；共享主窗口激活流程补充应用取消隐藏、主窗口取消最小化，再设置焦点。主窗口销毁后沿用重建及加载回调显示路径。
- 本次没有修改悬浮窗边缘动画，也没有新增常驻菜单栏功能。

## 验证

- PASS：Swift StartupPresentationTests 5 项。
- PASS：Rust startup 9 项、surfaces 31 项；覆盖有无主窗口、先还原后聚焦和错误传播。
- 本地 macOS 产物构建、签名和进程替换结果见 `runs/20260907-dock-reopen/activation.json`。
- USER_OWNED：关闭主界面和悬浮窗后点击 Dock；隐藏或最小化后点击 Dock。
- NOT_RUN：Windows 构建与实机任务栏验收。

本地任务分支 `fix/dock-dashboard-reopen-20260907`；不包含远端推送或发布。
